import ImageIO
import Photos
import SwiftUI
import UIKit

struct AttachmentItem: Identifiable, Equatable, Sendable {
    let id: String
    let byteCount: Int64
    let created: Date?
    let cameraModel: String?
    let modelKey: String?
    let fromWhatsApp: Bool
}

struct OwnCamera: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let count: Int
    let isOwn: Bool
}

struct DeviceTally: Equatable, Sendable {
    let key: String
    let name: String
    let count: Int
}

struct AttachmentDeletion: Identifiable, Equatable {
    let id = UUID()
    let freedBytes: Int64
    let count: Int
    let deleted: Bool
}

struct AttachmentPass: Sendable {
    var candidates: [AttachmentItem]
    var tallies: [DeviceTally]
}

/// Photos saved from other people. iMessage keeps the sender's camera details and
/// often saves them as Live Photos. PhotoKit does not record which app saved a photo.
/// A model that accounts for at least 15 percent of camera photos, and the most
/// common model, start as this person's own cameras. Nothing is downloaded.
enum AttachmentScan {
    private static let convertedKey = "convertedLivePhotoIDs"
    private static let batchSize = 200
    static let ownShare = 0.15

    nonisolated static func collect(onProgress: @escaping (_ checked: Int, _ total: Int) -> Void) -> AttachmentPass {
        let converted = Set(UserDefaults.standard.stringArray(forKey: convertedKey) ?? [])
        let whatsApp = whatsAppImageIDs(excluding: converted)
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        let total = result.count
        var candidates: [AttachmentItem] = []
        var counts: [String: Int] = [:]
        var names: [String: String] = [:]
        var index = 0
        while index < total {
            let end = min(index + batchSize, total)
            autoreleasepool {
                let indexes = IndexSet(integersIn: index..<end)
                result.enumerateObjects(at: indexes, options: []) { asset, _, _ in
                    autoreleasepool {
                        guard !asset.mediaSubtypes.contains(.photoScreenshot) else { return }
                        guard !converted.contains(asset.localIdentifier) else { return }
                        let fromWhatsApp = whatsApp.contains(asset.localIdentifier)
                        let facts = originalCamera(asset)
                        if let facts, let key = facts.key, let name = facts.name, !fromWhatsApp {
                            counts[key, default: 0] += 1
                            if names[key] == nil {
                                names[key] = name
                            }
                        }
                        if fromWhatsApp || facts?.key != nil {
                            candidates.append(AttachmentItem(
                                id: asset.localIdentifier,
                                byteCount: imageByteCount(asset),
                                created: asset.creationDate,
                                cameraModel: facts?.name ?? (fromWhatsApp ? "WhatsApp" : nil),
                                modelKey: facts?.key,
                                fromWhatsApp: fromWhatsApp
                            ))
                        }
                    }
                }
            }
            index = end
            onProgress(index, total)
        }
        if total == 0 {
            onProgress(0, 0)
        }
        let tallies = counts.map { key, count in
            DeviceTally(key: key, name: names[key] ?? key, count: count)
        }.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return AttachmentPass(candidates: candidates, tallies: tallies)
    }

    /// Own cameras are any model with at least 15 percent of camera photos, plus the most common model.
    nonisolated static func heuristicOwnKeys(_ tallies: [DeviceTally]) -> Set<String> {
        let total = tallies.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        let top = tallies.map(\.count).max() ?? 0
        var own = Set<String>()
        for tally in tallies {
            let share = Double(tally.count) / Double(total)
            if share >= ownShare || tally.count == top {
                own.insert(tally.key)
            }
        }
        return own
    }

    nonisolated private static func whatsAppImageIDs(excluding converted: Set<String>) -> Set<String> {
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var ids = Set<String>()
        albums.enumerateObjects { collection, _, _ in
            let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard title.compare("WhatsApp", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else { return }
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            assets.enumerateObjects { asset, _, _ in
                guard asset.mediaType == .image else { return }
                if asset.mediaSubtypes.contains(.photoScreenshot) { return }
                if converted.contains(asset.localIdentifier) { return }
                ids.insert(asset.localIdentifier)
            }
        }
        return ids
    }

    nonisolated private static func imageByteCount(_ asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { $0.type == .photo } ?? resources.first { $0.type == .fullSizePhoto }
        guard let resource else { return 0 }
        return max(0, LiveResourceFileSize(resource))
    }

    /// Camera identity from the original photo resource only. Nil means the metadata
    /// could not be read, so the photo is left out unless it is in a WhatsApp album.
    /// A readable photo with no model is not a saved attachment.
    nonisolated private static func originalCamera(_ asset: PHAsset) -> CameraFacts? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo }) else { return nil }
        let probe = Probe()
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let requestID = manager.requestData(for: resource, options: options) { chunk in
            if probe.absorb(chunk) {
                let id = probe.currentRequest()
                if id != PHInvalidAssetResourceDataRequestID {
                    manager.cancelDataRequest(id)
                }
            }
        } completionHandler: { error in
            probe.finish(error: error)
        }
        probe.setRequest(requestID)
        if !probe.wait() {
            manager.cancelDataRequest(requestID)
        }
        return probe.facts
    }

    /// Model, then a device name taken from LensModel, then Software or HostComputer.
    /// Make alone is not a model. A version string such as 18.6.2 is not a device.
    nonisolated static func cameraModel(in properties: CFDictionary) -> String? {
        let raw = properties as NSDictionary
        let tiff = raw[kCGImagePropertyTIFFDictionary] as? NSDictionary
        let exif = raw[kCGImagePropertyExifDictionary] as? NSDictionary
        if let model = text(tiff, kCGImagePropertyTIFFModel) ?? text(raw, kCGImagePropertyTIFFModel) {
            return model
        }
        if let lens = text(exif, kCGImagePropertyExifLensModel) ?? text(raw, kCGImagePropertyExifLensModel),
           let device = deviceName(fromLens: lens) {
            return device
        }
        if let software = text(tiff, kCGImagePropertyTIFFSoftware) ?? text(raw, kCGImagePropertyTIFFSoftware),
           let device = deviceName(fromSoftware: software) {
            return device
        }
        if let host = text(tiff, kCGImagePropertyTIFFHostComputer) ?? text(raw, kCGImagePropertyTIFFHostComputer) {
            return host
        }
        return nil
    }

    nonisolated private static func text(_ dictionary: NSDictionary?, _ key: CFString) -> String? {
        guard let value = dictionary?[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func deviceName(fromLens lens: String) -> String? {
        let markers = [" back ", " front ", " rear "]
        var name = lens
        for marker in markers {
            if let range = lens.range(of: marker, options: [.caseInsensitive]) {
                name = String(lens[..<range.lowerBound])
                break
            }
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func deviceName(fromSoftware software: String) -> String? {
        let version = #"^(?:ios|ipados|macos|watchos|android|windows)?\s*\d+(?:\.\d+){0,3}$"#
        if software.range(of: version, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        return software
    }

    nonisolated static func modelKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { $0.isWhitespace }
            .joined(separator: " ")
    }

    private struct CameraFacts {
        let name: String?
        let key: String?
    }

    private final class Probe: @unchecked Sendable {
        let source: CGImageSource
        private var data = Data()
        private var readable = false
        private var model: String?
        private var requestID: PHAssetResourceDataRequestID = PHInvalidAssetResourceDataRequestID
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var signaled = false
        private let byteCap = 8 * 1024 * 1024

        var facts: CameraFacts? {
            lock.lock()
            defer { lock.unlock() }
            guard readable else { return nil }
            let key = model.map { AttachmentScan.modelKey($0) }
            return CameraFacts(name: model, key: key)
        }

        init() {
            source = CGImageSourceCreateIncremental(nil)
        }

        func setRequest(_ id: PHAssetResourceDataRequestID) {
            lock.lock()
            requestID = id
            lock.unlock()
        }

        func currentRequest() -> PHAssetResourceDataRequestID {
            lock.lock()
            defer { lock.unlock() }
            return requestID
        }

        func absorb(_ chunk: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if readable { return false }
            data.append(chunk)
            if update(final: false) { return true }
            if data.count >= byteCap {
                _ = update(final: true)
                return true
            }
            return false
        }

        func finish(error: Error?) {
            lock.lock()
            if !readable && error == nil {
                _ = update(final: true)
            }
            lock.unlock()
            signal()
        }

        func wait() -> Bool {
            semaphore.wait(timeout: .now() + 20) == .success
        }

        private func update(final: Bool) -> Bool {
            CGImageSourceUpdateData(source, data as CFData, final)
            let status = CGImageSourceGetStatus(source)
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
               let model = AttachmentScan.cameraModel(in: properties) {
                self.model = model
                readable = true
                return true
            }
            if status == .statusComplete {
                readable = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
                return true
            }
            return false
        }

        private func signal() {
            lock.lock()
            let first = !signaled
            signaled = true
            lock.unlock()
            if first { semaphore.signal() }
        }
    }
}

@MainActor
final class AttachmentsModel: ObservableObject {
    @Published var items: [AttachmentItem] = []
    @Published var selected: Set<String> = []
    @Published var selectedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var scanning = false
    @Published var checked = 0
    @Published var total = 0
    @Published var found = 0
    @Published var deleting = false
    @Published var deletion: AttachmentDeletion?
    @Published var devices: [OwnCamera] = []

    private static let overrideKey = "attachmentOwnDeviceOverrides"
    private var didScan = false
    private var generation = 0
    private var candidates: [AttachmentItem] = []
    private var tallies: [DeviceTally] = []
    private var overrides: [String: Bool] = [:]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.overrideKey),
           let stored = try? JSONDecoder().decode([String: Bool].self, from: data) {
            overrides = stored
        }
    }

    var allSelected: Bool {
        !items.isEmpty && selected.count == items.count
    }

    func scanIfNeeded() async {
        guard !didScan else { return }
        await scan()
    }

    func scan() async {
        guard !deleting else { return }
        generation += 1
        let token = generation
        scanning = true
        checked = 0
        total = 0
        found = 0
        devices = []
        clearSelection()
        items = []
        totalBytes = 0
        candidates = []
        let collected: AttachmentPass = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let batch = AttachmentScan.collect { checked, total in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        self.checked = checked
                        self.total = total
                    }
                }
                continuation.resume(returning: batch)
            }
        }
        guard token == generation else { return }
        candidates = collected.candidates
        tallies = collected.tallies
        applyFilter()
        scanning = false
        didScan = true
    }

    func setOwn(_ key: String, own: Bool) {
        guard !scanning, !deleting else { return }
        overrides[key] = own
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.overrideKey)
        }
        applyFilter()
    }

    func toggle(_ item: AttachmentItem) {
        if selected.contains(item.id) {
            selected.remove(item.id)
            selectedBytes -= item.byteCount
        } else {
            selected.insert(item.id)
            selectedBytes += item.byteCount
        }
    }

    func selectAll() {
        selected = Set(items.map(\.id))
        selectedBytes = totalBytes
    }

    func cancelSelection() {
        clearSelection()
    }

    func deleteSelected() async {
        let chosen = items.filter { selected.contains($0.id) }
        guard !chosen.isEmpty, !deleting else { return }
        deleting = true
        defer { deleting = false }
        do {
            try await LibraryModel.delete(localIdentifiers: chosen.map(\.id))
        } catch {
            return
        }
        let bytes = chosen.reduce(Int64(0)) { $0 + $1.byteCount }
        let ids = Set(chosen.map(\.id))
        candidates.removeAll { ids.contains($0.id) }
        clearSelection()
        applyFilter()
        deletion = AttachmentDeletion(freedBytes: bytes, count: chosen.count, deleted: true)
    }

    private func applyFilter() {
        let heuristic = AttachmentScan.heuristicOwnKeys(tallies)
        devices = tallies.map { tally in
            OwnCamera(
                id: tally.key,
                name: tally.name,
                count: tally.count,
                isOwn: overrides[tally.key] ?? heuristic.contains(tally.key)
            )
        }
        let own = Set(devices.filter(\.isOwn).map(\.id))
        let visible = candidates.filter { item in
            if item.fromWhatsApp { return true }
            guard let key = item.modelKey else { return false }
            return !own.contains(key)
        }
        let visibleIDs = Set(visible.map(\.id))
        selected = selected.intersection(visibleIDs)
        items = visible
        totalBytes = visible.reduce(0) { $0 + $1.byteCount }
        selectedBytes = visible.reduce(0) { partial, item in
            partial + (selected.contains(item.id) ? item.byteCount : 0)
        }
        found = visible.count
    }

    private func clearSelection() {
        selected.removeAll()
        selectedBytes = 0
    }
}

struct AttachmentsScreen: View {
    @StateObject private var model = AttachmentsModel()
    @StateObject private var thumbnails = ThumbnailKeeper()
    @Environment(\.displayScale) private var displayScale
    @State private var preview: AttachmentItem?
    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                if !model.devices.isEmpty {
                    cameras
                }
                Text("Saved attachments are photos, including Live Photos, from a camera that is not yours. Your cameras start as any model in at least 15 percent of the camera photos here, plus the most common model. Switch one off if it is not yours, or on if it is. Screenshots, photos whose details could not be read, and photos this app has saved but not yet deleted are left out. Pictures in an album named WhatsApp are included. A sender with the same phone model cannot be told apart. Nothing is downloaded, and nothing leaves this iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.scanning && model.items.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(scanningText)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if !model.scanning && model.items.isEmpty {
                    Text("No saved attachments in the photos you allowed.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(model.items) { item in
                            AttachmentCell(
                                item: item,
                                selected: model.selected.contains(item.id),
                                store: thumbnails.store,
                                side: 140 * displayScale,
                                onOpen: { preview = item },
                                onToggle: { model.toggle(item) }
                            )
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Saved Attachments")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            if !model.deleting {
                await model.scan()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("Select All") { model.selectAll() }
                    .disabled(selectDisabled)
                Button("Cancel") { model.cancelSelection() }
                    .disabled(cancelDisabled)
            }
        }
        .safeAreaInset(edge: .bottom) {
            selectionBar
        }
        .sheet(item: $preview) { item in
            AttachmentViewer(item: item)
        }
        .sheet(item: $model.deletion) { result in
            PostDeleteSummary(
                title: "In Recently Deleted",
                message: "Deleted \(result.count.formatted()) photos. About \(ByteText.string(result.freedBytes)) stays used until you empty Recently Deleted in Photos.",
                footnote: nil,
                dismiss: { model.deletion = nil }
            )
        }
        .task { await model.scanIfNeeded() }
    }

    private var selectDisabled: Bool {
        model.items.isEmpty || model.scanning || model.deleting || model.allSelected
    }

    private var cancelDisabled: Bool {
        model.selected.isEmpty || model.scanning || model.deleting
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(model.items.count.formatted()) photos")
                .font(.title2)
                .fontWeight(.semibold)
            Text(summaryLine)
                .foregroundStyle(.secondary)
            if model.scanning {
                Text(scanningText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(pine.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var summaryLine: String {
        guard model.totalBytes > 0 else {
            return "Sizes appear as the library is measured"
        }
        return "About \(ByteText.string(model.totalBytes)) total"
    }

    private var scanningText: String {
        if model.total == 0 {
            return "Scanning your photo library…"
        }
        return "Checked \(model.checked.formatted()) of \(model.total.formatted()) photos"
    }

    private var cameras: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your cameras")
                .font(.headline)
            Text("On means this camera is yours, so its photos are left out.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.devices) { device in
                Toggle(isOn: Binding(
                    get: { device.isOwn },
                    set: { model.setOwn(device.id, $0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text("\(device.count.formatted()) photos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(model.scanning || model.deleting)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(model.selected.count.formatted()) selected · \(ByteText.string(model.selectedBytes))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Nothing is selected until you choose it. Delete uses the iOS confirmation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Select All") { model.selectAll() }
                    .buttonStyle(.bordered)
                    .disabled(selectDisabled)
                Button("Cancel") { model.cancelSelection() }
                    .buttonStyle(.bordered)
                    .disabled(cancelDisabled)
                Button("Delete") {
                    Task { await model.deleteSelected() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selected.isEmpty || model.scanning || model.deleting)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }
}

private struct AttachmentCell: View {
    let item: AttachmentItem
    let selected: Bool
    let store: ThumbnailStore
    let side: CGFloat
    let onOpen: () -> Void
    let onToggle: () -> Void
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Color(uiColor: .secondarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay {
                Button(action: onOpen) {
                    Color.clear
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(openLabel)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onToggle) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? pine : Color.white)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(selected ? "Cancel selection" : "Select photo")
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    if let cameraModel = item.cameraModel {
                        Text(cameraModel)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .foregroundStyle(.white)
                    }
                    Text(dateText)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(6)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .onAppear(perform: load)
            .onDisappear {
                if let requestID {
                    store.cancel(requestID)
                }
                image = nil
            }
    }

    private var dateText: String {
        guard let created = item.created else { return "—" }
        return created.formatted(date: .numeric, time: .omitted)
    }

    private var openLabel: String {
        let model = item.cameraModel.map { "\($0), " } ?? ""
        if let created = item.created {
            return "Open \(model)photo from \(created.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Open \(model)photo"
    }

    private func load() {
        guard image == nil, requestID == nil else { return }
        requestID = store.request(id: item.id, side: side) { loaded in
            image = loaded
        }
    }
}

private struct AttachmentViewer: View {
    let item: AttachmentItem
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .accessibilityLabel("Photo")
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear(perform: load)
        .onDisappear {
            if let requestID {
                PHImageManager.default().cancelImageRequest(requestID)
            }
        }
    }

    private var title: String {
        guard let created = item.created else { return "Photo" }
        return created.formatted(date: .abbreviated, time: .omitted)
    }

    private func load() {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
        guard let asset = assets.firstObject else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { loaded, info in
            let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
            if cancelled { return }
            guard let loaded else { return }
            DispatchQueue.main.async { image = loaded }
        }
    }
}
