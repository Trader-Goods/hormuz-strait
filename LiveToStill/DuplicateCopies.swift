import AVFoundation
import AVKit
import Photos
import SwiftUI
import UIKit

struct CopyVideo: Identifiable, Equatable, Sendable {
    let id: String
    let duration: TimeInterval
    let pixelWidth: Int
    let pixelHeight: Int
    let creationDate: Date?
    let modificationStamp: TimeInterval
    let byteCount: Int64
    let hasLocation: Bool
    let cameraLikeName: Bool
    let filename: String
}

enum CopyRole: Equatable {
    case original
    case edited
}

enum CopyKeepChoice: String, CaseIterable, Identifiable {
    case edited
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .edited: return "Keep Edited"
        case .original: return "Keep Original"
        }
    }

    var detail: String {
        switch self {
        case .edited:
            return "Keeps the copy with text, stickers or filters (like from Snapchat) and deletes the plain original."
        case .original:
            return "Keeps the plain video straight from your camera and deletes the edited copy."
        }
    }
}

struct CopyMember: Identifiable, Equatable {
    var id: String { video.id }
    let video: CopyVideo
    let role: CopyRole
}

struct CopyGroup: Identifiable, Equatable {
    let id: String
    let members: [CopyMember]
    /// True when one clip is a clear unedited original. Groups that are not confident are not shown.
    let confident: Bool
}

@MainActor
final class CopiesModel: ObservableObject {
    @Published var groups: [CopyGroup] = []
    @Published var selected: Set<String> = []
    @Published var selectedBytes: Int64 = 0
    @Published var scanning = false
    @Published var checked = 0
    @Published var candidateCount = 0
    @Published var status = "Scan your videos for an original and an edited copy."
    @Published var deletion: ClipDeletionResult?
    @Published var keepChoice: CopyKeepChoice {
        didSet {
            UserDefaults.standard.set(keepChoice.rawValue, forKey: Self.keepChoiceKey)
            guard keepChoice != oldValue else { return }
            touched = []
            publish(groups, resetTouched: true)
            if !groups.isEmpty {
                status = selectionStatus(for: groups)
            }
        }
    }

    static let matchInfoSeenKey = "copyMatchInfoSeen"
    private static let keepChoiceKey = "copyKeepChoice"
    private var touched: Set<String> = []
    private var cancelFlag = CancelFlag()

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.keepChoiceKey) ?? ""
        keepChoice = CopyKeepChoice(rawValue: stored) ?? .edited
    }

    func scan() async {
        cancelFlag.cancel()
        let flag = CancelFlag()
        cancelFlag = flag
        scanning = true
        checked = 0
        candidateCount = 0
        groups = []
        selected = []
        selectedBytes = 0
        touched = []
        status = "Reading the video library…"
        let records = await Task.detached(priority: .userInitiated) {
            CopyScanner.metadata(cancelled: flag)
        }.value
        if flag.isCancelled {
            scanning = false
            status = "Scan cancelled."
            return
        }
        let candidates = CopyScanner.durationCandidates(in: records)
        candidateCount = candidates.count
        status = candidates.isEmpty
            ? "No videos share a close enough length to compare."
            : "Comparing \(candidates.count.formatted()) videos with a similar length."
        var prints = CopyScanner.loadCache()
        var finished = 0
        for record in candidates {
            if flag.isCancelled { break }
            let cached = prints[record.id]
            if cached == nil || cached?.stamp != record.modificationStamp || (cached?.print.frames.count ?? 0) < 3 {
                if let made = await CopyScanner.fingerprint(id: record.id, cancelled: flag) {
                    prints[record.id] = CachedPrint(stamp: record.modificationStamp, print: made)
                }
            }
            finished += 1
            checked = finished
            if finished % 20 == 0 {
                CopyScanner.saveCache(prints)
            }
        }
        CopyScanner.saveCache(prints)
        if flag.isCancelled {
            scanning = false
            status = "Scan cancelled."
            return
        }
        let built = CopyScanner.groups(from: candidates, prints: prints, cancelled: flag)
        publish(built, resetTouched: true)
        scanning = false
        if built.isEmpty {
            status = "No edited copies found."
            if ProcessInfo.processInfo.arguments.contains("-copyDebug") {
                status += " " + CopyScanner.debugSummary(records: records, candidates: candidates, prints: prints)
            }
        } else {
            status = selectionStatus(for: built)
        }
    }

    private func selectionStatus(for built: [CopyGroup]) -> String {
        let which = keepChoice == .edited
            ? "The plain original is selected for deletion"
            : "The edited copies are selected for deletion"
        return "\(built.count.formatted()) groups. \(which)."
    }

    func cancel() {
        cancelFlag.cancel()
    }

    func toggle(_ member: CopyMember, in group: CopyGroup) {
        touched.insert(member.id)
        if selected.contains(member.id) {
            selected.remove(member.id)
            selectedBytes -= member.video.byteCount
        } else {
            selected.insert(member.id)
            selectedBytes += member.video.byteCount
        }
        _ = group
    }

    func deleteSelected() async {
        let ids = groups
            .flatMap(\.members)
            .map(\.video)
            .filter { selected.contains($0.id) }
        guard !ids.isEmpty, !scanning else { return }
        let bytes = ids.reduce(Int64(0)) { $0 + $1.byteCount }
        do {
            try await LibraryModel.delete(localIdentifiers: ids.map(\.id))
            deletion = ClipDeletionResult(freedBytes: bytes, count: ids.count, deleted: true)
            await scan()
        } catch {
            deletion = ClipDeletionResult(freedBytes: 0, count: ids.count, deleted: false)
        }
    }

    private func publish(_ built: [CopyGroup], resetTouched: Bool) {
        if resetTouched { touched = [] }
        var next = Set<String>()
        var bytes: Int64 = 0
        for group in built {
            let chosen: [String]
            if group.members.contains(where: { touched.contains($0.id) }) {
                chosen = group.members.map(\.id).filter { selected.contains($0) }
            } else if group.confident {
                let roleToDelete: CopyRole = keepChoice == .edited ? .original : .edited
                chosen = group.members.filter { $0.role == roleToDelete }.map(\.id)
            } else {
                chosen = []
            }
            for id in chosen {
                next.insert(id)
                if let video = group.members.first(where: { $0.id == id })?.video {
                    bytes += video.byteCount
                }
            }
        }
        groups = built
        selected = next
        selectedBytes = bytes
    }
}

struct AssetPlayerSheet: View {
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView("Opening video")
                }
            }
            .background(Color.black)
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        player?.pause()
                        dismiss()
                    }
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear { player?.pause() }
    }

    private func load() {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = assets.firstObject else { return }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
            DispatchQueue.main.async {
                guard let item else { return }
                let player = AVPlayer(playerItem: item)
                self.player = player
                player.play()
            }
        }
    }
}

struct CopiesScreen: View {
    @StateObject private var model = CopiesModel()
    @StateObject private var thumbnails = ThumbnailKeeper()
    @State private var playing: String?
    @State private var confirming = false
    @State private var showMatchInfo = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                keepChoiceCard
                Text("Finds a video and an edited copy from the same day, even when stickers, captions, or a different size cover part of the frame. Nothing leaves this iPhone. Only a clear match is listed. A green KEEP stays. A red DELETE is removed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.scanning {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: model.candidateCount == 0 ? nil : Double(model.checked), total: Double(max(model.candidateCount, 1)))
                        Text(model.candidateCount == 0 ? model.status : "Checked \(model.checked.formatted()) of \(model.candidateCount.formatted())")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Cancel", action: model.cancel)
                            .buttonStyle(.bordered)
                    }
                } else if model.groups.isEmpty {
                    Text(model.status)
                        .foregroundStyle(.secondary)
                    Button("Scan videos") { Task { await model.scan() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text(model.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ForEach(model.groups) { group in
                        CopyGroupCard(
                            group: group,
                            keepChoice: model.keepChoice,
                            selected: model.selected,
                            store: thumbnails.store,
                            side: 160 * displayScale,
                            play: { playing = $0 },
                            toggle: { model.toggle($0, in: group) }
                        )
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            if !model.groups.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(model.selected.count.formatted()) selected · \(ByteText.string(model.selectedBytes))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Delete selected") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selected.isEmpty || model.scanning)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
            }
        }
        .confirmationDialog(
            "Delete \(model.selected.count.formatted()) selected videos?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await model.deleteSelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the videos you selected are deleted. iOS asks once. They stay in Recently Deleted, and that space stays used until you empty Recently Deleted in Photos. About \(ByteText.string(model.selectedBytes)).")
        }
        .sheet(item: $model.deletion) { result in
            PostDeleteSummary(
                title: result.deleted ? "In Recently Deleted" : "Nothing deleted",
                message: result.deleted
                    ? "Deleted \(result.count.formatted()) videos. About \(ByteText.string(result.freedBytes)) stays used until you empty Recently Deleted in Photos."
                    : "The videos were not deleted, so their space is still in use.",
                footnote: nil,
                dismiss: { model.deletion = nil }
            )
        }
        .sheet(item: playingBinding) { token in
            AssetPlayerSheet(id: token.id)
        }
        .sheet(isPresented: $showMatchInfo, onDismiss: {
            UserDefaults.standard.set(true, forKey: CopiesModel.matchInfoSeenKey)
        }) {
            MatchInfoSheet()
        }
        .onAppear {
            if !UserDefaults.standard.bool(forKey: CopiesModel.matchInfoSeenKey) {
                showMatchInfo = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Rescan") { Task { await model.scan() } }
                    .disabled(model.scanning)
            }
        }
    }

    private var keepChoiceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Which copy to keep")
                    .font(.headline)
                Spacer()
                Button {
                    showMatchInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                }
                .accessibilityLabel("How copies are matched")
            }
            Picker("Which copy to keep", selection: $model.keepChoice) {
                ForEach(CopyKeepChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            Text(model.keepChoice.detail)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var playingBinding: Binding<PlayerToken?> {
        Binding(
            get: { playing.map(PlayerToken.init) },
            set: { playing = $0?.id }
        )
    }
}

struct PlayerToken: Identifiable {
    let id: String
}

private struct MatchInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Only videos shot on the same calendar day are compared. Live to Still checks several frames from each clip on this iPhone, and most of those frames have to look the same. Stickers, captions, and filters can cover part of the picture. If the match is not clear, or it is not clear which video is the plain original, that pair is left out.")
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .navigationTitle("How copies are matched")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct CopyGroupCard: View {
    let group: CopyGroup
    let keepChoice: CopyKeepChoice
    let selected: Set<String>
    let store: ThumbnailStore
    let side: CGFloat
    let play: (String) -> Void
    let toggle: (CopyMember) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(group.members) { member in
                        CopyMemberCard(
                            member: member,
                            marked: selected.contains(member.id),
                            store: store,
                            side: side,
                            play: { play(member.id) },
                            toggle: { toggle(member) }
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var heading: String {
        keepChoice == .edited ? "Original selected" : "Edited selected"
    }

    private var detail: String {
        if keepChoice == .edited {
            return "The plain original is marked DELETE. The edited copy is marked KEEP. Change either tag before you delete."
        }
        return "The edited copies are marked DELETE. The plain original is marked KEEP. Change any tag before you delete."
    }
}

private struct CopyMemberCard: View {
    let member: CopyMember
    let marked: Bool
    let store: ThumbnailStore
    let side: CGFloat
    let play: () -> Void
    let toggle: () -> Void
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(uiColor: .secondarySystemFill)
                .frame(width: 148, height: 148)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Button(action: play) {
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .black.opacity(0.45))
                    }
                    .padding(6)
                }
            Text(roleTitle)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            Button(action: toggle) {
                Text(marked ? "DELETE" : "KEEP")
                    .font(.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(.white)
                    .background(marked ? Color.red : Color.green, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(marked ? "Delete this video" : "Keep this video")
            Text(durationText)
            Text(member.video.byteCount > 0 ? ByteText.string(member.video.byteCount) : "Size unknown")
            Text(member.video.pixelWidth > 0 ? "\(member.video.pixelWidth)×\(member.video.pixelHeight)" : "Resolution unknown")
            Text(dateText)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: 148, alignment: .leading)
        .onAppear {
            guard image == nil, requestID == nil else { return }
            requestID = store.request(id: member.id, side: side) { image = $0 }
        }
        .onDisappear {
            if let requestID { store.cancel(requestID) }
            image = nil
        }
    }

    private var roleTitle: String {
        switch member.role {
        case .original: return "Original"
        case .edited: return "Edited"
        }
    }

    private var durationText: String {
        let total = Int(member.video.duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var dateText: String {
        guard let date = member.video.creationDate else { return "Date unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

fileprivate enum CopyScanner {
    struct CellPrint: Codable {
        var mean: UInt8
        var variance: UInt16
        var hash: UInt64
    }

    struct FramePrint: Codable {
        var cells: [CellPrint]
    }

    fileprivate struct VideoPrint: Codable {
        var frames: [FramePrint]
    }

    static func metadata(cancelled: CancelFlag) -> [CopyVideo] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "duration", ascending: true)]
        let result = PHAsset.fetchAssets(with: .video, options: options)
        var records: [CopyVideo] = []
        records.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, stop in
            if cancelled.isCancelled {
                stop.pointee = true
                return
            }
            autoreleasepool {
                guard asset.duration >= 0.5 else { return }
                let resources = PHAssetResource.assetResources(for: asset)
                let resource = resources.first { $0.type == .video } ?? resources.first { $0.type == .fullSizeVideo }
                let name = resource?.originalFilename ?? ""
                let bytes = resource.map { max(Int64(0), LiveResourceFileSize($0)) } ?? 0
                records.append(CopyVideo(
                    id: asset.localIdentifier,
                    duration: asset.duration,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    creationDate: asset.creationDate,
                    modificationStamp: (asset.modificationDate ?? asset.creationDate)?.timeIntervalSince1970 ?? 0,
                    byteCount: bytes,
                    hasLocation: asset.location != nil,
                    cameraLikeName: cameraLike(name),
                    filename: name
                ))
            }
        }
        return records
    }

    static func durationCandidates(in records: [CopyVideo]) -> [CopyVideo] {
        guard records.count > 1 else { return [] }
        var byDay: [Date: [CopyVideo]] = [:]
        for record in records {
            guard let day = localDayStart(record.creationDate) else { continue }
            byDay[day, default: []].append(record)
        }
        var ids = Set<String>()
        for dayRecords in byDay.values {
            guard dayRecords.count > 1 else { continue }
            let sorted = dayRecords.sorted { $0.duration < $1.duration }
            var end = 0
            for start in sorted.indices {
                if end < start { end = start }
                while end + 1 < sorted.count && durationsMatch(sorted[start].duration, sorted[end + 1].duration) {
                    end += 1
                }
                if end > start {
                    for index in start...end {
                        ids.insert(sorted[index].id)
                    }
                }
            }
        }
        return records.filter { ids.contains($0.id) }
    }

    static func fingerprint(id: String, cancelled: CancelFlag) async -> VideoPrint? {
        if cancelled.isCancelled { return nil }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetch.firstObject else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .fastFormat
        let avAsset: AVAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { item, _, info in
                let cancelledRequest = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
                continuation.resume(returning: cancelledRequest ? nil : item)
            }
        }
        guard let avAsset else { return nil }
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 64, height: 64)
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let duration = CMTimeGetSeconds(avAsset.duration)
        guard duration.isFinite, duration > 0 else { return nil }
        var frames: [FramePrint] = []
        for fraction in [0.12, 0.37, 0.62, 0.87] {
            if cancelled.isCancelled { return nil }
            let time = CMTime(seconds: min(duration * fraction, max(duration - 0.05, 0)), preferredTimescale: 600)
            if let image = try? generator.copyCGImage(at: time, actualTime: nil), let print = framePrint(from: image) {
                frames.append(print)
            }
        }
        guard frames.count >= 3 else { return nil }
        return VideoPrint(frames: frames)
    }

    static func groups(from records: [CopyVideo], prints: [String: CachedPrint], cancelled: CancelFlag) -> [CopyGroup] {
        var parent: [String: String] = [:]
        func find(_ id: String) -> String {
            if parent[id] == nil { parent[id] = id }
            if parent[id] != id { parent[id] = find(parent[id]!) }
            return parent[id]!
        }
        func unite(_ a: String, _ b: String) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        var windowStart = 0
        for index in records.indices {
            if cancelled.isCancelled { break }
            while windowStart < index && !durationsMatch(records[windowStart].duration, records[index].duration) {
                windowStart += 1
            }
            guard let right = prints[records[index].id]?.print else { continue }
            for other in windowStart..<index {
                guard let left = prints[records[other].id]?.print else { continue }
                if videosMatch(left, right, records[other].creationDate, records[index].creationDate) {
                    unite(records[other].id, records[index].id)
                }
            }
        }
        var buckets: [String: [CopyVideo]] = [:]
        for record in records {
            buckets[find(record.id), default: []].append(record)
        }
        return buckets.values
            .filter { $0.count > 1 && pairsMatch($0, prints: prints) }
            .compactMap { label($0) }
            .sorted { ($0.members.first?.video.creationDate ?? .distantPast) > ($1.members.first?.video.creationDate ?? .distantPast) }
    }

    static func loadCache() -> [String: CachedPrint] {
        guard let url = cacheURL(), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: CachedPrint].self, from: data)) ?? [:]
    }

    static func saveCache(_ cache: [String: CachedPrint]) {
        guard let url = cacheURL(), let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func label(_ videos: [CopyVideo]) -> CopyGroup? {
        let maxPixels = videos.map { $0.pixelWidth * $0.pixelHeight }.max() ?? 0
        let earliest = videos.compactMap(\.creationDate).min()
        let ranked = videos
            .map { ($0, originality($0, earliest: earliest, maxPixels: maxPixels)) }
            .sorted { $0.1 > $1.1 }
        guard let best = ranked.first, ranked.count > 1 else { return nil }
        let second = ranked[1]
        let gap = best.1 - second.1
        let bestPixels = best.0.pixelWidth * best.0.pixelHeight
        let secondPixels = second.0.pixelWidth * second.0.pixelHeight
        let clearerPicture = bestPixels > 0 && secondPixels > 0 && bestPixels >= Int(Double(secondPixels) * 1.25)
        let earlier: Bool = {
            guard let firstDate = best.0.creationDate, let secondDate = second.0.creationDate else { return false }
            return secondDate.timeIntervalSince(firstDate) >= 60
        }()
        let cleanerMetadata = (best.0.hasLocation && !second.0.hasLocation) || (best.0.cameraLikeName && !second.0.cameraLikeName)
        let confident = gap >= 1.5 && (clearerPicture || earlier || cleanerMetadata)
        guard confident else { return nil }
        let members = videos.map { video in
            CopyMember(video: video, role: video.id == best.0.id ? .original : .edited)
        }
        let id = videos.map(\.id).sorted().joined(separator: "|")
        return CopyGroup(id: id, members: members, confident: true)
    }

    private static func originality(_ video: CopyVideo, earliest: Date?, maxPixels: Int) -> Double {
        var score = 0.0
        let pixels = video.pixelWidth * video.pixelHeight
        if maxPixels > 0 && pixels > 0 {
            score += Double(pixels) / Double(maxPixels) * 3
        }
        if video.hasLocation { score += 2 }
        if video.cameraLikeName { score += 2 }
        if let date = video.creationDate, let earliest {
            score -= min(2, date.timeIntervalSince(earliest) / 86400)
        }
        return score
    }

    private static func durationsMatch(_ lhs: TimeInterval, _ rhs: TimeInterval) -> Bool {
        abs(lhs - rhs) <= max(0.5, 0.03 * max(lhs, rhs))
    }

    private static func sameLocalDay(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        return Calendar.current.isDate(lhs, inSameDayAs: rhs)
    }

    private static func localDayStart(_ date: Date?) -> Date? {
        guard let date else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    /// Every pair in the group has to match on its own. A chain of loose matches is not shown.
    private static func pairsMatch(_ videos: [CopyVideo], prints: [String: CachedPrint]) -> Bool {
        guard videos.count > 1 else { return false }
        for leftIndex in videos.indices {
            for rightIndex in (leftIndex + 1)..<videos.count {
                let leftVideo = videos[leftIndex]
                let rightVideo = videos[rightIndex]
                guard let left = prints[leftVideo.id]?.print,
                      let right = prints[rightVideo.id]?.print,
                      videosMatch(left, right, leftVideo.creationDate, rightVideo.creationDate) else {
                    return false
                }
            }
        }
        return true
    }

    private static func videosMatch(_ lhs: VideoPrint, _ rhs: VideoPrint, _ leftDate: Date?, _ rightDate: Date?) -> Bool {
        guard sameLocalDay(leftDate, rightDate) else { return false }
        let count = min(lhs.frames.count, rhs.frames.count)
        guard count >= 3 else { return false }
        var strong = 0
        for index in 0..<count {
            if frameScore(lhs.frames[index], rhs.frames[index]) >= 0.80 {
                strong += 1
            }
        }
        return strong >= 3 && strong * 4 >= count * 3
    }

    private static func frameScore(_ lhs: FramePrint, _ rhs: FramePrint) -> Double {
        var similar = 0
        var compared = 0
        for index in 0..<min(lhs.cells.count, rhs.cells.count) {
            let left = lhs.cells[index]
            let right = rhs.cells[index]
            if left.variance < 80 || right.variance < 80 { continue }
            compared += 1
            let distance = (left.hash ^ right.hash).nonzeroBitCount
            let meanGap = abs(Int(left.mean) - Int(right.mean))
            if distance <= 16 && meanGap <= 36 { similar += 1 }
        }
        guard compared >= 6 else { return 0 }
        return Double(similar) / Double(compared)
    }

    private static func framePrint(from image: CGImage) -> FramePrint? {
        let side = 64
        let cells = 4
        let cell = side / cells
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: side * side)
        defer { pixels.deallocate() }
        guard let context = CGContext(
            data: pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var prints: [CellPrint] = []
        prints.reserveCapacity(cells * cells)
        for gridY in 0..<cells {
            for gridX in 0..<cells {
                var sum = 0
                var sumSquares = 0
                var samples = [UInt8]()
                samples.reserveCapacity(cell * cell)
                for y in 0..<cell {
                    for x in 0..<cell {
                        let value = pixels[(gridY * cell + y) * side + gridX * cell + x]
                        samples.append(value)
                        sum += Int(value)
                        sumSquares += Int(value) * Int(value)
                    }
                }
                let count = cell * cell
                let mean = sum / count
                let variance = max(0, sumSquares / count - mean * mean)
                var bits: UInt64 = 0
                var bit = 0
                var sampleY = 0
                while sampleY < cell {
                    var sampleX = 0
                    while sampleX < cell {
                        if Int(samples[sampleY * cell + sampleX]) >= mean {
                            bits |= (1 << bit)
                        }
                        bit += 1
                        sampleX += 2
                    }
                    sampleY += 2
                }
                prints.append(CellPrint(mean: UInt8(clamping: mean), variance: UInt16(min(variance, 65535)), hash: bits))
            }
        }
        return FramePrint(cells: prints)
    }

    static func debugSummary(records: [CopyVideo], candidates: [CopyVideo], prints: [String: CachedPrint]) -> String {
        let described = records.prefix(8).map { video in
            let frames = prints[video.id]?.print.frames.count ?? 0
            let day = video.creationDate.map { String(format: "%.0f", $0.timeIntervalSince1970) } ?? "nil"
            return "\(video.filename) \(String(format: "%.2f", video.duration))s \(video.pixelWidth)x\(video.pixelHeight) \(day) loc=\(video.hasLocation) cam=\(video.cameraLikeName) frames=\(frames)"
        }
        var match = ""
        if candidates.count >= 2,
           let left = prints[candidates[0].id]?.print,
           let right = prints[candidates[1].id]?.print {
            let score = debugScore(left, right)
            match = " score=\(String(format: "%.2f", score))"
        }
        return "n=\(records.count) c=\(candidates.count)\(match) " + described.joined(separator: " | ")
    }

    private static func debugScore(_ lhs: VideoPrint, _ rhs: VideoPrint) -> Double {
        let count = min(lhs.frames.count, rhs.frames.count)
        guard count > 0 else { return 0 }
        var total = 0.0
        for index in 0..<count {
            total += frameScore(lhs.frames[index], rhs.frames[index])
        }
        return total / Double(count)
    }

    private static func cameraLike(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["IMG_", "VID_", "MOV_", "PHOTO_", "VIDEO_"].contains { upper.hasPrefix($0) }
    }

    private static func cacheURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("copy-prints.json")
    }
}

fileprivate struct CachedPrint: Codable {
    var stamp: TimeInterval
    var print: CopyScanner.VideoPrint
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
