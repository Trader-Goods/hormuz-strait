import CoreLocation
import Photos
import SwiftUI
import UIKit

struct LiveItem: Identifiable, Equatable, Sendable {
    let id: String
    let videoByteCount: Int64
}

struct WorkProgress: Equatable {
    var title: String
    var detail: String
    var completed: Int
    var total: Int
}

struct ConversionResult: Identifiable, Equatable {
    let id = UUID()
    let freedBytes: Int64
    let converted: Int
    let skipped: Int
    let deleted: Bool
}

enum LibraryAccess: Equatable {
    case requesting
    case denied
    case restricted
    case limited
    case full
}

enum ConvertError: Error {
    case missing
    case unavailable
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var access: LibraryAccess = .requesting
    @Published var items: [LiveItem] = []
    @Published var selected: Set<String> = []
    @Published var selectedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var scanning = false
    @Published var scannedCount = 0
    @Published var progress: WorkProgress?
    @Published var result: ConversionResult?

    private var didPrepare = false
    private var scanGeneration = 0

    var allSelected: Bool {
        !items.isEmpty && selected.count == items.count
    }

    func prepare() async {
        guard !didPrepare else { return }
        didPrepare = true
        let status = await Self.requestAccess()
        access = Self.map(status)
        if access == .full || access == .limited {
            await scan()
        }
    }

    func onForeground() async {
        guard didPrepare, progress == nil, result == nil else { return }
        let mapped = Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard mapped != access else { return }
        access = mapped
        if mapped == .full || mapped == .limited {
            await scan()
        } else {
            clearLibrary()
        }
    }

    func scan() async {
        guard progress == nil else { return }
        scanGeneration += 1
        let generation = scanGeneration
        scanning = true
        scannedCount = 0
        clearLibrary()
        let found: [LiveItem] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let items = Self.collect { _ in }
                continuation.resume(returning: items)
            }
        }
        guard generation == scanGeneration else { return }
        items = found
        totalBytes = found.reduce(0) { $0 + $1.videoByteCount }
        scannedCount = found.count
        scanning = false
    }

    func toggle(_ item: LiveItem) {
        if selected.contains(item.id) {
            selected.remove(item.id)
            selectedBytes -= item.videoByteCount
        } else {
            selected.insert(item.id)
            selectedBytes += item.videoByteCount
        }
    }

    func toggleAll() {
        if allSelected {
            selected.removeAll()
            selectedBytes = 0
        } else {
            selected = Set(items.map(\.id))
            selectedBytes = totalBytes
        }
    }

    func convertSelected() async {
        let chosen = items.filter { selected.contains($0.id) }
        guard !chosen.isEmpty, progress == nil else { return }
        var convertedIDs: [String] = []
        var freed: Int64 = 0
        var skipped = 0
        for (index, item) in chosen.enumerated() {
            progress = WorkProgress(
                title: "Saving still photos",
                detail: "The originals stay until every still copy is saved.",
                completed: index,
                total: chosen.count
            )
            do {
                try await Self.convert(localIdentifier: item.id)
                convertedIDs.append(item.id)
                freed += item.videoByteCount
            } catch {
                skipped += 1
            }
        }
        var deleted = false
        if !convertedIDs.isEmpty {
            progress = WorkProgress(
                title: "Waiting for deletion confirmation",
                detail: "iOS asks once. Confirm to move the Live Photos to Recently Deleted for 30 days.",
                completed: chosen.count,
                total: chosen.count
            )
            do {
                try await Self.delete(localIdentifiers: convertedIDs)
                deleted = true
            } catch {
                deleted = false
                freed = 0
            }
        } else {
            freed = 0
        }
        progress = nil
        result = ConversionResult(
            freedBytes: deleted ? freed : 0,
            converted: convertedIDs.count,
            skipped: skipped,
            deleted: deleted
        )
    }

    func chooseMorePhotos() {
        guard let controller = Self.topController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) { [weak self] _ in
            Task { @MainActor in
                await self?.scan()
            }
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func clearLibrary() {
        items = []
        selected.removeAll()
        selectedBytes = 0
        totalBytes = 0
    }

    private static func requestAccess() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func map(_ status: PHAuthorizationStatus) -> LibraryAccess {
        switch status {
        case .authorized:
            return .full
        case .limited:
            return .limited
        case .restricted:
            return .restricted
        case .denied, .notDetermined:
            return .denied
        @unknown default:
            return .denied
        }
    }

    nonisolated static func collect(onCount: @escaping (Int) -> Void) -> [LiveItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "(mediaSubtype & %d) != 0",
            Int(PHAssetMediaSubtype.photoLive.rawValue)
        )
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var all: [LiveItem] = []
        all.reserveCapacity(result.count)
        var sinceReport = 0
        result.enumerateObjects { asset, _, _ in
            autoreleasepool {
                all.append(LiveItem(id: asset.localIdentifier, videoByteCount: videoByteCount(of: asset)))
            }
            sinceReport += 1
            if sinceReport == 40 {
                sinceReport = 0
                onCount(all.count)
            }
        }
        onCount(all.count)
        return all
    }

    nonisolated static func videoByteCount(of asset: PHAsset) -> Int64 {
        var total: Int64 = 0
        for resource in PHAssetResource.assetResources(for: asset) where isPairedVideo(resource.type) {
            let size = LiveResourceFileSize(resource)
            if size > 0 {
                total += size
            }
        }
        return total
    }

    nonisolated static func isPairedVideo(_ type: PHAssetResourceType) -> Bool {
        switch type {
        case .pairedVideo, .fullSizePairedVideo, .video, .fullSizeVideo:
            return true
        default:
            return false
        }
    }

    nonisolated static func convert(localIdentifier: String) async throws {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetch.firstObject else { throw ConvertError.missing }
        guard let resource = stillResource(for: asset) else { throw ConvertError.unavailable }
        let url = temporaryURL(for: resource)
        defer { try? FileManager.default.removeItem(at: url) }
        try await write(resource, to: url)
        let albums = userAlbums(containing: asset)
        let creationDate = asset.creationDate
        let location = asset.location
        let favorite = asset.isFavorite
        if albums.isEmpty {
            try await save(fileURL: url, creationDate: creationDate, location: location, favorite: favorite, albums: [])
        } else {
            do {
                try await save(fileURL: url, creationDate: creationDate, location: location, favorite: favorite, albums: albums)
            } catch {
                try await save(fileURL: url, creationDate: creationDate, location: location, favorite: favorite, albums: [])
            }
        }
    }

    nonisolated static func delete(localIdentifiers: [String]) async throws {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard fetch.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(fetch)
        }
    }

    nonisolated private static func stillResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        if let photo = resources.first(where: { $0.type == .photo }) {
            return photo
        }
        return resources.first(where: { $0.type == .fullSizePhoto })
    }

    nonisolated private static func temporaryURL(for resource: PHAssetResource) -> URL {
        let ext = (resource.originalFilename as NSString).pathExtension
        let suffix = ext.isEmpty ? "jpg" : ext
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(suffix)
    }

    nonisolated private static func write(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    nonisolated private static func userAlbums(containing asset: PHAsset) -> [PHAssetCollection] {
        let fetched = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var albums: [PHAssetCollection] = []
        fetched.enumerateObjects { collection, _, _ in
            if collection.assetCollectionType == .album && collection.assetCollectionSubtype == .albumRegular {
                albums.append(collection)
            }
        }
        return albums
    }

    nonisolated private static func save(
        fileURL: URL,
        creationDate: Date?,
        location: CLLocation?,
        favorite: Bool,
        albums: [PHAssetCollection]
    ) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: fileURL, options: nil)
            request.creationDate = creationDate
            request.location = location
            request.isFavorite = favorite
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            for album in albums {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

enum ByteText {
    static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}

final class ThumbnailStore {
    private let manager: PHCachingImageManager = {
        let manager = PHCachingImageManager()
        manager.allowsCachingHighQualityImages = false
        return manager
    }()

    func request(id: String, side: CGFloat, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = assets.firstObject else {
            completion(nil)
            return nil
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        return manager.requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
            if cancelled { return }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    func cancel(_ requestID: PHImageRequestID) {
        manager.cancelImageRequest(requestID)
    }
}
