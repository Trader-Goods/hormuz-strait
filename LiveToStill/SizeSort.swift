import Photos
import SwiftUI
import UIKit

enum SizeFilter: String, CaseIterable, Identifiable {
    case all
    case photos
    case videos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .photos: return "Photos"
        case .videos: return "Videos"
        }
    }

    func includes(_ item: SizeItem) -> Bool {
        switch self {
        case .all: return true
        case .photos: return !item.isVideo
        case .videos: return item.isVideo
        }
    }
}

struct SizeItem: Identifiable, Equatable, Sendable {
    let id: String
    /// Nil when the library has no file size for this item.
    let byteCount: Int64?
    let isVideo: Bool
    let duration: TimeInterval
}

private struct SizePreview: Identifiable {
    let id: String
    let isVideo: Bool
}

enum SizeText {
    static func string(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 MB" }
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes >= 1 {
            return labeled(gigabytes, "GB")
        }
        let megabytes = Double(bytes) / 1_000_000
        if megabytes < 1 {
            return String(format: "%.2f MB", megabytes)
        }
        return labeled(megabytes, "MB")
    }

    private static func labeled(_ value: Double, _ unit: String) -> String {
        if value >= 10 || abs(value - value.rounded()) < 0.05 {
            return String(format: "%.0f %@", value, unit)
        }
        return String(format: "%.1f %@", value, unit)
    }
}

@MainActor
final class SizeModel: ObservableObject {
    @Published var items: [SizeItem] = []
    @Published var filter: SizeFilter = .all
    @Published var scanning = false
    @Published var checked = 0
    @Published var total = 0
    @Published var selecting = false
    @Published var selected: Set<String> = []
    @Published private(set) var selectedBytes: Int64 = 0
    @Published private(set) var selectedUnknown = 0
    @Published var deleting = false
    @Published var progress: WorkProgress?
    @Published var deletion: ClipDeletionResult?

    private var generation = 0

    var shown: [SizeItem] {
        items.filter { filter.includes($0) }
    }

    var shownBytes: Int64 {
        shown.reduce(0) { $0 + ($1.byteCount ?? 0) }
    }

    var shownUnknown: Int {
        shown.filter { $0.byteCount == nil }.count
    }

    var allShownSelected: Bool {
        let visible = shown
        return !visible.isEmpty && visible.allSatisfy { selected.contains($0.id) }
    }

    func scan() async {
        guard !scanning, !deleting else { return }
        generation += 1
        let token = generation
        scanning = true
        checked = 0
        total = 0
        items = []
        let found: [SizeItem] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let collected = SizeScan.collect { checked, total, partial in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token else { return }
                        self.checked = checked
                        self.total = total
                        self.items = partial
                    }
                }
                continuation.resume(returning: collected)
            }
        }
        guard generation == token else { return }
        items = found
        scanning = false
        pruneSelection()
    }

    func beginSelection() {
        selecting = true
    }

    func cancelSelection() {
        selecting = false
        selected.removeAll()
        selectedBytes = 0
        selectedUnknown = 0
    }

    func selectAll() {
        for item in shown {
            selected.insert(item.id)
        }
        recomputeSelection()
    }

    func toggle(_ item: SizeItem) {
        if selected.contains(item.id) {
            selected.remove(item.id)
        } else {
            selected.insert(item.id)
        }
        recomputeSelection()
    }

    func applyFilter(_ next: SizeFilter) {
        filter = next
        let visible = Set(shown.map(\.id))
        selected = selected.intersection(visible)
        recomputeSelection()
    }

    func deleteSelected() async {
        let chosen = items.filter { selected.contains($0.id) }
        guard !chosen.isEmpty, !deleting else { return }
        generation += 1
        scanning = false
        deleting = true
        let bytes = chosen.reduce(Int64(0)) { $0 + ($1.byteCount ?? 0) }
        progress = WorkProgress(
            title: "Waiting for deletion confirmation",
            detail: "iOS asks once. Confirm to move them to Recently Deleted. Their space stays used until that album is emptied in Photos.",
            completed: 0,
            total: chosen.count
        )
        var didDelete = false
        do {
            try await LibraryModel.delete(localIdentifiers: chosen.map(\.id))
            didDelete = true
        } catch {
            didDelete = false
        }
        progress = nil
        if didDelete {
            let removed = Set(chosen.map(\.id))
            items.removeAll { removed.contains($0.id) }
            selected.removeAll()
            selectedBytes = 0
            selectedUnknown = 0
            selecting = false
        }
        deletion = ClipDeletionResult(
            freedBytes: didDelete ? bytes : 0,
            count: chosen.count,
            deleted: didDelete
        )
        deleting = false
    }

    private func pruneSelection() {
        let known = Set(items.map(\.id))
        selected = selected.intersection(known)
        recomputeSelection()
    }

    private func recomputeSelection() {
        var bytes: Int64 = 0
        var unknown = 0
        for item in items where selected.contains(item.id) {
            if let byteCount = item.byteCount {
                bytes += byteCount
            } else {
                unknown += 1
            }
        }
        selectedBytes = bytes
        selectedUnknown = unknown
    }
}

enum SizeScan {
    /// File sizes come from resource metadata only. Nothing is downloaded.
    nonisolated static func collect(
        onProgress: @escaping (_ checked: Int, _ total: Int, _ items: [SizeItem]) -> Void
    ) -> [SizeItem] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        let total = result.count
        var all: [SizeItem] = []
        let batchSize = 200
        var index = 0
        while index < total {
            let end = min(index + batchSize, total)
            autoreleasepool {
                let indexes = IndexSet(integersIn: index..<end)
                result.enumerateObjects(at: indexes, options: []) { asset, _, _ in
                    autoreleasepool {
                        guard asset.mediaType == .image || asset.mediaType == .video else { return }
                        let video = asset.mediaType == .video
                        all.append(SizeItem(
                            id: asset.localIdentifier,
                            byteCount: byteCount(of: asset),
                            isVideo: video,
                            duration: video ? asset.duration : 0
                        ))
                    }
                }
            }
            index = end
            onProgress(index, total, sorted(all))
        }
        if total == 0 {
            onProgress(0, 0, [])
        }
        return sorted(all)
    }

    nonisolated private static func byteCount(of asset: PHAsset) -> Int64? {
        let resources = PHAssetResource.assetResources(for: asset)
        var total: Int64 = 0
        var known = false
        for resource in resources {
            let size = LiveResourceFileSize(resource)
            if size > 0 {
                total += size
                known = true
            }
        }
        return known ? total : nil
    }

    nonisolated private static func sorted(_ items: [SizeItem]) -> [SizeItem] {
        items.sorted { lhs, rhs in
            switch (lhs.byteCount, rhs.byteCount) {
            case let (left?, right?):
                if left != right { return left > right }
                return lhs.id < rhs.id
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.id < rhs.id
            }
        }
    }
}

struct SizeSortScreen: View {
    @StateObject private var model = SizeModel()
    @StateObject private var thumbnails = ThumbnailKeeper()
    @Environment(\.displayScale) private var displayScale
    @State private var confirming = false
    @State private var preview: SizePreview?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("Show", selection: filterBinding) {
                    ForEach(SizeFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                Text("Largest first. Sizes are read from each file’s details on this iPhone. Nothing is downloaded. Items with no size are listed last.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.scanning && model.items.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Reading sizes…")
                            .foregroundStyle(.secondary)
                    }
                } else if !model.scanning && model.shown.isEmpty {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.shown) { item in
                            SizeRow(
                                item: item,
                                selected: model.selected.contains(item.id),
                                selecting: model.selecting,
                                store: thumbnails.store,
                                side: 64 * displayScale
                            ) {
                                if model.selecting {
                                    model.toggle(item)
                                } else {
                                    preview = SizePreview(id: item.id, isVideo: item.isVideo)
                                }
                            }
                            Divider().padding(.leading, 84)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Sort by Size")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if model.selecting {
                    Button("Select All") {
                        model.selectAll()
                    }
                    .disabled(model.shown.isEmpty || model.allShownSelected || model.deleting)
                    Button("Cancel") {
                        model.cancelSelection()
                    }
                    .disabled(model.deleting)
                } else {
                    Button("Select") {
                        model.beginSelection()
                    }
                    .disabled(model.shown.isEmpty || model.deleting)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.selecting {
                selectionBar
            }
        }
        .overlay {
            if let progress = model.progress {
                WorkOverlay(progress: progress)
            }
        }
        .refreshable {
            await model.scan()
        }
        .task {
            await model.scan()
        }
        .confirmationDialog(
            "Delete \(model.selected.count.formatted()) items?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmDetail)
        }
        .sheet(item: $model.deletion) { result in
            PostDeleteSummary(
                title: result.deleted ? "In Recently Deleted" : "Nothing deleted",
                message: deletionMessage(result),
                footnote: nil,
                dismiss: { model.deletion = nil }
            )
        }
        .fullScreenCover(item: $preview) { item in
            if item.isVideo {
                AssetPlayerSheet(id: item.id)
            } else {
                SizePhotoViewer(id: item.id)
            }
        }
    }

    private var filterBinding: Binding<SizeFilter> {
        Binding(
            get: { model.filter },
            set: { model.applyFilter($0) }
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.shown.count.formatted()) \(model.filter == .videos ? "videos" : model.filter == .photos ? "photos" : "items")")
                .font(.title2)
                .fontWeight(.semibold)
            Text(headerSize)
                .foregroundStyle(.secondary)
            if model.scanning {
                ProgressView(value: model.total == 0 ? nil : Double(model.checked), total: Double(max(model.total, 1)))
                    .tint(pine)
                Text(model.total == 0
                     ? "Reading sizes…"
                     : "Checked \(model.checked.formatted()) of \(model.total.formatted())")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(pine.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var headerSize: String {
        if model.shown.isEmpty && model.scanning {
            return "Total size appears as the library is measured"
        }
        var line = "\(SizeText.string(model.shownBytes)) shown"
        if model.shownUnknown > 0 {
            line += " · \(model.shownUnknown.formatted()) with no size"
        }
        return line
    }

    private var emptyText: String {
        switch model.filter {
        case .all:
            return "No photos or videos in the photos you allowed."
        case .photos:
            return "No photos in the photos you allowed."
        case .videos:
            return "No videos in the photos you allowed."
        }
    }

    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selectionSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Cancel") {
                    model.cancelSelection()
                }
                .buttonStyle(.bordered)
                .disabled(model.deleting)
                Button("Select All") {
                    model.selectAll()
                }
                .buttonStyle(.bordered)
                .disabled(model.shown.isEmpty || model.allShownSelected || model.deleting)
                Button("Delete") {
                    confirming = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selected.isEmpty || model.deleting)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }

    private var selectionSummary: String {
        var line = "\(model.selected.count.formatted()) selected · \(selectionSizeText)"
        if model.selectedUnknown > 0 {
            line += " · \(model.selectedUnknown.formatted()) with no size"
        }
        return line
    }

    private var selectionSizeText: String {
        SizeText.string(model.selectedBytes)
    }

    private var confirmDetail: String {
        if model.selectedBytes > 0 {
            return "iOS asks once. They stay in Recently Deleted, and about \(SizeText.string(model.selectedBytes)) stays used until you empty Recently Deleted in Photos."
        }
        return "iOS asks once. They stay in Recently Deleted and still use space until you empty that album in Photos."
    }

    private func deletionMessage(_ result: ClipDeletionResult) -> String {
        if result.deleted && result.freedBytes > 0 {
            return "Deleted \(result.count.formatted()) items. About \(SizeText.string(result.freedBytes)) stays used until you empty Recently Deleted in Photos."
        }
        if result.deleted {
            return "Deleted \(result.count.formatted()) items. They stay in Recently Deleted and still use space until you empty that album in Photos."
        }
        return "The items were not deleted, so their space is still in use."
    }
}

private struct SizeRow: View {
    let item: SizeItem
    let selected: Bool
    let selecting: Bool
    let store: ThumbnailStore
    let side: CGFloat
    let onTap: () -> Void
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Color(uiColor: .secondarySystemFill)
                    .overlay {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.byteCount.map(SizeText.string) ?? "No size")
                        .font(.body)
                        .fontWeight(.semibold)
                    if item.isVideo {
                        Text(Self.duration(item.duration))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? pine : Color.secondary)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onAppear(perform: load)
        .onDisappear {
            if let requestID {
                store.cancel(requestID)
            }
            image = nil
        }
    }

    private var accessibilityName: String {
        let kind = item.isVideo ? "Video" : "Photo"
        let size = item.byteCount.map(SizeText.string) ?? "size unknown"
        if item.isVideo {
            return "\(kind), \(size), \(Self.duration(item.duration))"
        }
        return "\(kind), \(size)"
    }

    private func load() {
        guard image == nil, requestID == nil else { return }
        requestID = store.request(id: item.id, side: side) { loaded in
            image = loaded
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

private struct SizePhotoViewer: View {
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var missing = false
    @State private var requestID: PHImageRequestID?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else if missing {
                    Text("This photo is not on this iPhone. Nothing was downloaded.")
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(24)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
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

    private func load() {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = assets.firstObject else {
            missing = true
            return
        }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isSynchronous = false
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { loaded, info in
            let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
            if cancelled { return }
            let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
            DispatchQueue.main.async {
                if let loaded {
                    image = loaded
                    missing = false
                } else if !degraded {
                    missing = image == nil
                }
            }
        }
    }
}
