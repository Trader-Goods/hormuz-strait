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
    case unsure
}

struct CopyMember: Identifiable, Equatable {
    var id: String { video.id }
    let video: CopyVideo
    let role: CopyRole
}

struct CopyGroup: Identifiable, Equatable {
    let id: String
    let members: [CopyMember]
    /// True when one clip is a clear unedited original. Unsure groups preselect nothing.
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

    private var touched: Set<String> = []
    private var cancelFlag = CancelFlag()

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
            if prints[record.id] == nil || prints[record.id]?.stamp != record.modificationStamp {
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
        status = built.isEmpty
            ? "No edited copies found."
            : "\(built.count.formatted()) groups. The likely original is selected. Unsure groups select nothing."
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
                chosen = group.members.filter { $0.role == .original }.map(\.id)
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
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Finds a video and an edited copy of it, even when stickers, captions, or a different size cover part of the frame. Nothing leaves this iPhone. Nothing is selected in a group marked Unsure.")
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Rescan") { Task { await model.scan() } }
                    .disabled(model.scanning)
            }
        }
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

private struct CopyGroupCard: View {
    let group: CopyGroup
    let selected: Set<String>
    let store: ThumbnailStore
    let side: CGFloat
    let play: (String) -> Void
    let toggle: (CopyMember) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.confident ? "Original selected" : "Unsure")
                .font(.headline)
            Text(group.confident
                 ? "The likely unedited original is selected for deletion. The edited copy is not. Change either one before you delete."
                 : "These look related, but it is not clear which is the original. Nothing is selected.")
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
                .font(.caption)
                .fontWeight(.semibold)
            Text(durationText)
            Text(member.video.byteCount > 0 ? ByteText.string(member.video.byteCount) : "Size unknown")
            Text(member.video.pixelWidth > 0 ? "\(member.video.pixelWidth)×\(member.video.pixelHeight)" : "Resolution unknown")
            Text(dateText)
            Button(action: toggle) {
                Label(marked ? "Selected" : "Select", systemImage: marked ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.bordered)
            .tint(marked ? pine : nil)
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
        case .unsure: return "Unsure"
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
        var ids = Set<String>()
        var end = 0
        for start in records.indices {
            if end < start { end = start }
            while end + 1 < records.count && durationsMatch(records[start].duration, records[end + 1].duration) {
                end += 1
            }
            if end > start {
                for index in start...end {
                    ids.insert(records[index].id)
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
        guard frames.count >= 2 else { return nil }
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
            .filter { $0.count > 1 }
            .map(label)
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

    private static func label(_ videos: [CopyVideo]) -> CopyGroup {
        let maxPixels = videos.map { $0.pixelWidth * $0.pixelHeight }.max() ?? 0
        let earliest = videos.compactMap(\.creationDate).min()
        let ranked = videos
            .map { ($0, originality($0, earliest: earliest, maxPixels: maxPixels)) }
            .sorted { $0.1 > $1.1 }
        let id = videos.map(\.id).sorted().joined(separator: "|")
        guard let best = ranked.first, ranked.count > 1 else {
            return CopyGroup(id: id, members: videos.map { CopyMember(video: $0, role: .unsure) }, confident: false)
        }
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
        if !confident {
            return CopyGroup(id: id, members: videos.map { CopyMember(video: $0, role: .unsure) }, confident: false)
        }
        let members = videos.map { video in
            CopyMember(video: video, role: video.id == best.0.id ? .original : .edited)
        }
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

    private static func videosMatch(_ lhs: VideoPrint, _ rhs: VideoPrint, _ leftDate: Date?, _ rightDate: Date?) -> Bool {
        let count = min(lhs.frames.count, rhs.frames.count)
        guard count >= 2 else { return false }
        var total = 0.0
        for index in 0..<count {
            total += frameScore(lhs.frames[index], rhs.frames[index])
        }
        let score = total / Double(count)
        if score >= 0.72 { return true }
        if score >= 0.58, let leftDate, let rightDate, abs(leftDate.timeIntervalSince(rightDate)) <= 3 * 86400 {
            return true
        }
        return false
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
            if distance <= 16 || meanGap <= 18 { similar += 1 }
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
