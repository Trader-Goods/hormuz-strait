import ImageIO
import Photos
import SwiftUI
import UIKit

struct AttachmentItem: Identifiable, Equatable, Sendable {
    let id: String
    let byteCount: Int64
    let created: Date?
}

struct AttachmentDeletion: Identifiable, Equatable {
    let id = UUID()
    let freedBytes: Int64
    let count: Int
    let deleted: Bool
}

/// Photos saved from messages and other apps. PhotoKit does not record the source app,
/// so this uses image metadata only and never downloads or sends anything.
enum AttachmentScan {
    private static let convertedKey = "convertedLivePhotoIDs"
    private static let batchSize = 200

    nonisolated static func collect(onProgress: @escaping (_ checked: Int, _ found: Int, _ total: Int) -> Void) -> [AttachmentItem] {
        let converted = Set(UserDefaults.standard.stringArray(forKey: convertedKey) ?? [])
        let whatsApp = whatsAppImageIDs(excluding: converted)
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        let total = result.count
        var all: [AttachmentItem] = []
        var index = 0
        while index < total {
            let end = min(index + batchSize, total)
            autoreleasepool {
                let indexes = IndexSet(integersIn: index..<end)
                result.enumerateObjects(at: indexes, options: []) { asset, _, _ in
                    autoreleasepool {
                        guard let item = item(for: asset, converted: converted, whatsApp: whatsApp) else { return }
                        all.append(item)
                    }
                }
            }
            index = end
            onProgress(index, all.count, total)
        }
        if total == 0 {
            onProgress(0, 0, 0)
        }
        return all
    }

    /// Screenshots and stills this app converted are never offered. Conversion copies
    /// the original photo bytes unchanged, so a camera Make or Model survives on the
    /// new still. The stored IDs cover a converted still that never had either one.
    /// A photo in an album named WhatsApp is included even when it has camera details.
    nonisolated private static func item(for asset: PHAsset, converted: Set<String>, whatsApp: Set<String>) -> AttachmentItem? {
        if asset.mediaSubtypes.contains(.photoScreenshot) { return nil }
        if converted.contains(asset.localIdentifier) { return nil }
        let fromWhatsApp = whatsApp.contains(asset.localIdentifier)
        if !fromWhatsApp && !confirmedNoCameraIdentity(asset) { return nil }
        return AttachmentItem(
            id: asset.localIdentifier,
            byteCount: imageByteCount(asset),
            created: asset.creationDate
        )
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

    /// True only when the image properties were actually read and neither Make nor Model
    /// is present. Unreadable photos, including ones not stored on this iPhone, return false
    /// so they are not listed. Nothing is downloaded.
    nonisolated private static func confirmedNoCameraIdentity(_ asset: PHAsset) -> Bool {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo })
            ?? resources.first(where: { $0.type == .fullSizePhoto }) else {
            return false
        }
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
        guard probe.wait() else {
            manager.cancelDataRequest(requestID)
            return false
        }
        return probe.confirmedAbsent
    }

    private static func propertiesHaveCamera(_ properties: CFDictionary) -> Bool {
        let raw = properties as NSDictionary
        if dictionaryHasCamera(raw) { return true }
        if let tiff = raw[kCGImagePropertyTIFFDictionary] as? NSDictionary, dictionaryHasCamera(tiff) { return true }
        if let exif = raw[kCGImagePropertyExifDictionary] as? NSDictionary, dictionaryHasCamera(exif) { return true }
        return false
    }

    private static func dictionaryHasCamera(_ dictionary: NSDictionary) -> Bool {
        let keys = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, "Make" as CFString, "Model" as CFString]
        for key in keys {
            guard let text = dictionary[key] as? String else { continue }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    private final class Probe: @unchecked Sendable {
        let source: CGImageSource
        private var data = Data()
        private var hasCamera = false
        private var complete = false
        private var requestID: PHAssetResourceDataRequestID = PHInvalidAssetResourceDataRequestID
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var signaled = false

        var confirmedAbsent: Bool {
            lock.lock()
            defer { lock.unlock() }
            return complete && !hasCamera
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
            if complete || hasCamera { return false }
            data.append(chunk)
            return update(final: false)
        }

        func finish(error: Error?) {
            lock.lock()
            if error == nil && !hasCamera && !complete {
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
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil), AttachmentScan.propertiesHaveCamera(properties) {
                hasCamera = true
                return true
            }
            if CGImageSourceGetStatus(source).rawValue == 0 {
                complete = true
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

    private var didScan = false
    private var generation = 0

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
        clearSelection()
        items = []
        totalBytes = 0
        let collected: [AttachmentItem] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let batch = AttachmentScan.collect { checked, found, total in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        self.checked = checked
                        self.found = found
                        self.total = total
                    }
                }
                continuation.resume(returning: batch)
            }
        }
        guard token == generation else { return }
        items = collected
        totalBytes = collected.reduce(0) { $0 + $1.byteCount }
        found = collected.count
        scanning = false
        didScan = true
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
        items.removeAll { ids.contains($0.id) }
        totalBytes = items.reduce(0) { $0 + $1.byteCount }
        clearSelection()
        deletion = AttachmentDeletion(freedBytes: bytes, count: chosen.count, deleted: true)
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
                Text("Photos saved from messages and other apps usually have no camera make or model. Screenshots are left out. Stills converted here are left out, because conversion copies the original photo file unchanged, including its camera details. Pictures in an album named WhatsApp are included. Nothing is downloaded, and nothing leaves this iPhone.")
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
        return "Checked \(model.checked.formatted()) of \(model.total.formatted()) photos · \(model.found.formatted()) saved attachments"
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
                Text(dateText)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
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
        if let created = item.created {
            return "Open photo from \(created.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Open photo"
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
