import CoreLocation
import Photos
import PhotosUI
import SwiftUI
import UIKit

struct LiveItem: Identifiable, Equatable, Sendable {
    let id: String
    let videoByteCount: Int64
    var stillByteCount: Int64 = 0
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
    let retainedClipBytes: Int64
    let converted: Int
    let skipped: Int
    let deleted: Bool
    let keptClips: Bool
    var remaining: Int = 0
    /// Stills saved in this run whose Live Photos were not deleted.
    var undeletedSaves: Int = 0
}

enum CloudTransfer: Sendable {
    case downloading(Double)
    case saving
}

struct ClipDeletionResult: Identifiable, Equatable {
    let id = UUID()
    let freedBytes: Int64
    let count: Int
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

struct StoragePause: Identifiable, Equatable {
    let id = UUID()
    let converted: Int
    let remaining: Int
}

enum StorageCapacity {
    /// Leave room so iOS is not filled to the last byte. A single photo can still
    /// proceed when it fits in the raw free space.
    static let safetyMargin: Int64 = 150 * 1024 * 1024

    static func available() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Bytes that must be free before saving this Live Photo. The new file is written
    /// to a temporary file and then copied into the library, so both exist briefly.
    /// Deleted originals stay in Recently Deleted and do not give this space back.
    static func bytesNeeded(for item: LiveItem, keepingClips: Bool) -> Int64 {
        let still = item.stillByteCount > 0 ? item.stillByteCount : 8 * 1024 * 1024
        if keepingClips {
            let video = item.videoByteCount > 0 ? item.videoByteCount : still
            return (still + video) * 2
        }
        return still * 2
    }

    static func fits(_ item: LiveItem, keepingClips: Bool) -> Bool {
        available() >= bytesNeeded(for: item, keepingClips: keepingClips)
    }

    static func chunk(from items: [LiveItem], available: Int64, keepingClips: Bool) -> [LiveItem] {
        let usable = available > safetyMargin ? available - safetyMargin : 0
        var chosen: [LiveItem] = []
        var used: Int64 = 0
        for item in items {
            let need = bytesNeeded(for: item, keepingClips: keepingClips)
            if used + need <= usable {
                chosen.append(item)
                used += need
            } else {
                break
            }
        }
        if chosen.isEmpty, let first = items.first, bytesNeeded(for: first, keepingClips: keepingClips) <= available {
            return [first]
        }
        return chosen
    }
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
    @Published var scanChecked = 0
    @Published var scanTotal = 0
    @Published var progress: WorkProgress?
    @Published var result: ConversionResult?
    @Published var keepVideoClips: Bool {
        didSet { UserDefaults.standard.set(keepVideoClips, forKey: Self.keepClipsKey) }
    }
    @Published var clips: [LiveItem] = []
    @Published var clipsSelected: Set<String> = []
    @Published var clipsSelectedBytes: Int64 = 0
    @Published var clipsTotalBytes: Int64 = 0
    @Published var clipsLoading = false
    @Published var clipDeletion: ClipDeletionResult?
    @Published var storagePause: StoragePause?
    @Published var cloudItems: [LiveItem] = []
    @Published var cloudTotalBytes: Int64 = 0
    @Published var cloudScanning = false
    @Published var cloudChecked = 0
    @Published var cloudScanTotal = 0
    @Published var cloudFound = 0
    @Published var cloudProgress: WorkProgress?
    @Published var cloudResult: ConversionResult?
    @Published var cloudStoragePause: StoragePause?
    @Published var cloudRunning = false
    @Published var cloudScanFinished = false

    nonisolated static let clipsAlbumTitle = "Live Photo Clips"
    private static let keepClipsKey = "keepVideoClips"
    private static let savedKey = "convertedLivePhotoIDs"
    private var didPrepare = false
    private var scanGeneration = 0
    private var conversionActive = false
    private var pendingItems: [LiveItem] = []
    private var savedIDs: Set<String> = []
    private var sessionConverted = 0
    private var sessionSkipped = 0
    private var sessionFreed: Int64 = 0
    private var sessionRetained: Int64 = 0
    private var sessionDeletedAny = false
    private var cloudScanGeneration = 0
    private var cloudPending: [LiveItem] = []
    private var cloudSessionDeleted = 0
    private var cloudSessionSkipped = 0
    private var cloudSessionFreed: Int64 = 0
    private var cloudSessionDeletedAny = false
    private var cloudUndeletedSaves = 0
    private var cloudCancelRequested = false
    private var cloudJobTotal = 0
    private var cloudActiveItemID: String?

    var allClipsSelected: Bool {
        !clips.isEmpty && clipsSelected.count == clips.count
    }

    init() {
        keepVideoClips = UserDefaults.standard.bool(forKey: Self.keepClipsKey)
        savedIDs = Set(UserDefaults.standard.stringArray(forKey: Self.savedKey) ?? [])
    }

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
        guard didPrepare, progress == nil, result == nil, storagePause == nil, !conversionActive else { return }
        guard cloudProgress == nil, cloudStoragePause == nil, !cloudRunning else { return }
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
        guard progress == nil, storagePause == nil, !conversionActive, !cloudRunning, cloudStoragePause == nil else { return }
        scanGeneration += 1
        let generation = scanGeneration
        scanning = true
        scannedCount = 0
        scanChecked = 0
        scanTotal = 0
        clearLibrary()
        let found: [LiveItem] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let items = Self.collect { checked, foundCount, total in
                    DispatchQueue.main.async {
                        self?.scanChecked = checked
                        self?.scanTotal = total
                        self?.scannedCount = foundCount
                    }
                }
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
        await runConversion(resume: false)
    }

    func resumeAfterStoragePause() async {
        storagePause = nil
        await runConversion(resume: true)
    }

    func stopConversionForNow() {
        storagePause = nil
        progress = nil
        conversionActive = false
        guard sessionConverted > 0 || sessionSkipped > 0 else { return }
        result = sessionResult(keptClips: keepVideoClips)
    }

    func scanCloud() async {
        guard cloudProgress == nil, cloudStoragePause == nil, !cloudRunning else { return }
        guard progress == nil, storagePause == nil, !conversionActive else { return }
        cloudScanGeneration += 1
        let generation = cloudScanGeneration
        cloudScanning = true
        cloudScanFinished = false
        cloudChecked = 0
        cloudScanTotal = 0
        cloudFound = 0
        cloudItems = []
        cloudTotalBytes = 0
        let found: [LiveItem] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let items = Self.collectCloudOnly { checked, foundCount, total in
                    DispatchQueue.main.async {
                        guard let self, generation == self.cloudScanGeneration else { return }
                        self.cloudChecked = checked
                        self.cloudScanTotal = total
                        self.cloudFound = foundCount
                    }
                }
                continuation.resume(returning: items)
            }
        }
        guard generation == cloudScanGeneration else { return }
        cloudItems = found
        cloudFound = found.count
        cloudTotalBytes = found.reduce(0) { $0 + $1.videoByteCount }
        cloudScanning = false
        cloudScanFinished = true
    }

    func convertCloud() async {
        await runCloud(resume: false)
    }

    func resumeCloudAfterStoragePause() async {
        cloudStoragePause = nil
        await runCloud(resume: true)
    }

    func requestCloudCancel() {
        guard cloudRunning else { return }
        cloudCancelRequested = true
        guard var progress = cloudProgress, progress.title != "Waiting for deletion confirmation" else { return }
        progress.title = "Finishing this photo"
        progress.detail = "This photo will be saved and its Live Photo deleted. The next download will not start."
        cloudProgress = progress
    }

    func stopCloudForNow() {
        cloudStoragePause = nil
        cloudProgress = nil
        cloudRunning = false
        cloudCancelRequested = false
        cloudActiveItemID = nil
        guard cloudSessionDeleted > 0 || cloudSessionSkipped > 0 || cloudUndeletedSaves > 0 else { return }
        cloudResult = cloudSessionResult()
    }

    private func runCloud(resume: Bool) async {
        guard cloudProgress == nil, cloudStoragePause == nil, !cloudRunning else { return }
        guard progress == nil, storagePause == nil, !conversionActive else { return }
        if !resume {
            cloudPending = cloudItems
            cloudSessionDeleted = 0
            cloudSessionSkipped = 0
            cloudSessionFreed = 0
            cloudSessionDeletedAny = false
            cloudUndeletedSaves = 0
            cloudCancelRequested = false
            cloudJobTotal = cloudPending.count
        }
        guard !cloudPending.isEmpty else { return }
        cloudRunning = true

        while !cloudPending.isEmpty {
            if cloudCancelRequested {
                break
            }
            if let next = cloudPending.first, savedIDs.contains(next.id) {
                cloudPending.removeFirst()
                let deleted = await deleteCloudItem(next)
                if !deleted {
                    cloudPending.insert(next, at: 0)
                    cloudUndeletedSaves += 1
                    break
                }
                continue
            }

            let item = cloudPending[0]
            if !StorageCapacity.fits(item, keepingClips: false) {
                pauseCloudForStorage()
                return
            }
            cloudActiveItemID = item.id
            let done = cloudSessionDeleted + cloudSessionSkipped
            cloudProgress = WorkProgress(
                title: "Downloading the photo",
                detail: "Downloading the photo file only. The paired video stays in iCloud and is not downloaded.",
                completed: done,
                total: max(cloudJobTotal, 1)
            )
            do {
                try await Self.convertFromCloud(localIdentifier: item.id) { [weak self] transfer in
                    Task { @MainActor in
                        self?.applyCloudTransfer(transfer, itemID: item.id)
                    }
                }
                savedIDs.insert(item.id)
                persistSavedIDs()
                cloudPending.removeAll { $0.id == item.id }
                cloudActiveItemID = nil
                let deleted = await deleteCloudItem(item)
                if !deleted {
                    cloudPending.insert(item, at: 0)
                    cloudUndeletedSaves += 1
                    break
                }
            } catch {
                cloudActiveItemID = nil
                if Self.isStorageError(error) {
                    pauseCloudForStorage()
                    return
                }
                cloudSessionSkipped += 1
                cloudPending.removeAll { $0.id == item.id }
            }
        }

        cloudRunning = false
        cloudProgress = nil
        cloudCancelRequested = false
        cloudActiveItemID = nil
        guard cloudSessionDeleted > 0 || cloudSessionSkipped > 0 || cloudUndeletedSaves > 0 else { return }
        cloudResult = cloudSessionResult()
    }

    private func applyCloudTransfer(_ transfer: CloudTransfer, itemID: String) {
        guard cloudActiveItemID == itemID, cloudRunning else { return }
        if cloudCancelRequested {
            cloudProgress = WorkProgress(
                title: "Finishing this photo",
                detail: "This photo will be saved and its Live Photo deleted. The next download will not start.",
                completed: cloudSessionDeleted + cloudSessionSkipped,
                total: max(cloudJobTotal, 1)
            )
            return
        }
        let done = cloudSessionDeleted + cloudSessionSkipped
        switch transfer {
        case .downloading(let fraction):
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
            cloudProgress = WorkProgress(
                title: "Downloading the photo",
                detail: "Downloading the photo file only, \(percent)%. The paired video stays in iCloud and is not downloaded.",
                completed: done,
                total: max(cloudJobTotal, 1)
            )
        case .saving:
            cloudProgress = WorkProgress(
                title: "Saving the still photo",
                detail: "The photo file is copied unchanged. The paired video is not downloaded.",
                completed: done,
                total: max(cloudJobTotal, 1)
            )
        }
    }

    private func deleteCloudItem(_ item: LiveItem) async -> Bool {
        cloudProgress = WorkProgress(
            title: "Waiting for deletion confirmation",
            detail: "iOS asks once for this Live Photo. It moves to Recently Deleted and still uses space, including in iCloud, until that album is emptied.",
            completed: cloudSessionDeleted,
            total: max(cloudJobTotal, 1)
        )
        do {
            try await Self.delete(localIdentifiers: [item.id])
        } catch {
            return false
        }
        savedIDs.remove(item.id)
        cloudSessionDeleted += 1
        cloudSessionFreed += item.videoByteCount
        cloudSessionDeletedAny = true
        persistSavedIDs()
        markRemoved([item])
        cloudItems.removeAll { $0.id == item.id }
        cloudFound = cloudItems.count
        cloudTotalBytes = cloudItems.reduce(0) { $0 + $1.videoByteCount }
        return true
    }

    private func pauseCloudForStorage() {
        cloudCancelRequested = false
        cloudProgress = nil
        cloudRunning = false
        cloudActiveItemID = nil
        cloudStoragePause = StoragePause(converted: cloudSessionDeleted, remaining: cloudPending.count)
    }

    private func cloudSessionResult() -> ConversionResult {
        ConversionResult(
            freedBytes: cloudSessionDeletedAny ? cloudSessionFreed : 0,
            retainedClipBytes: 0,
            converted: cloudSessionDeleted,
            skipped: cloudSessionSkipped,
            deleted: cloudSessionDeletedAny,
            keptClips: false,
            remaining: cloudPending.count,
            undeletedSaves: cloudUndeletedSaves
        )
    }

    private func runConversion(resume: Bool) async {
        guard progress == nil, storagePause == nil, !conversionActive else { return }
        guard cloudProgress == nil, cloudStoragePause == nil, !cloudRunning else { return }
        let keeping = keepVideoClips
        if !resume {
            pendingItems = items.filter { selected.contains($0.id) }
            sessionConverted = 0
            sessionSkipped = 0
            sessionFreed = 0
            sessionRetained = 0
            sessionDeletedAny = false
        }
        guard !pendingItems.isEmpty else { return }
        conversionActive = true
        let jobTotal = pendingItems.count + sessionConverted + sessionSkipped

        if !StorageCapacity.fits(pendingItems[0], keepingClips: keeping) {
            pauseForStorage()
            return
        }

        let album: PHAssetCollection?
        if keeping {
            do {
                album = try await Self.clipsAlbum()
            } catch {
                conversionActive = false
                if !StorageCapacity.fits(pendingItems[0], keepingClips: true) {
                    pauseForStorage()
                } else {
                    result = ConversionResult(
                        freedBytes: 0,
                        retainedClipBytes: 0,
                        converted: sessionConverted,
                        skipped: pendingItems.count,
                        deleted: false,
                        keptClips: true,
                        remaining: pendingItems.count
                    )
                }
                return
            }
        } else {
            album = nil
        }

        while !pendingItems.isEmpty {
            var awaitingDelete: [LiveItem] = []
            while let next = pendingItems.first, savedIDs.contains(next.id) {
                awaitingDelete.append(pendingItems.removeFirst())
            }
            if !awaitingDelete.isEmpty {
                let deleted = await deleteChunk(awaitingDelete, keeping: keeping, total: jobTotal)
                if !deleted {
                    pendingItems.insert(contentsOf: awaitingDelete, at: 0)
                    conversionActive = false
                    progress = nil
                    result = sessionResult(keptClips: keeping)
                    return
                }
                continue
            }

            let available = StorageCapacity.available()
            let chunk = StorageCapacity.chunk(from: pendingItems, available: available, keepingClips: keeping)
            if chunk.isEmpty {
                pauseForStorage()
                return
            }

            var savedThisChunk: [LiveItem] = []
            var ranOutOfSpace = false
            for item in chunk {
                let needed = StorageCapacity.bytesNeeded(for: item, keepingClips: keeping)
                if StorageCapacity.available() < needed {
                    ranOutOfSpace = true
                    break
                }
                let done = sessionConverted + sessionSkipped + savedThisChunk.count
                progress = WorkProgress(
                    title: keeping ? "Saving stills and clips" : "Saving still photos",
                    detail: keeping
                        ? "Saving a batch that fits the free space, including the clip. Originals in this batch are deleted only after both files are saved."
                        : "Saving a batch that fits the free space. Each original is deleted only after its still is saved.",
                    completed: done,
                    total: jobTotal
                )
                do {
                    try await Self.convert(localIdentifier: item.id, keepClip: keeping, clipsAlbum: album)
                    savedIDs.insert(item.id)
                    persistSavedIDs()
                    savedThisChunk.append(item)
                    pendingItems.removeAll { $0.id == item.id }
                } catch is ConvertError {
                    sessionSkipped += 1
                    pendingItems.removeAll { $0.id == item.id }
                } catch {
                    ranOutOfSpace = true
                    break
                }
            }

            if !savedThisChunk.isEmpty {
                let deleted = await deleteChunk(savedThisChunk, keeping: keeping, total: jobTotal)
                if !deleted {
                    pendingItems.insert(contentsOf: savedThisChunk, at: 0)
                    conversionActive = false
                    progress = nil
                    result = sessionResult(keptClips: keeping)
                    return
                }
            }

            if ranOutOfSpace {
                pauseForStorage()
                return
            }
        }

        conversionActive = false
        progress = nil
        result = sessionResult(keptClips: keeping)
    }

    private func deleteChunk(_ chunk: [LiveItem], keeping: Bool, total: Int) async -> Bool {
        progress = WorkProgress(
            title: "Waiting for deletion confirmation",
            detail: "iOS asks once for this batch. These Live Photos move to Recently Deleted and still use space until that album is emptied in Photos.",
            completed: sessionConverted,
            total: max(total, 1)
        )
        do {
            try await Self.delete(localIdentifiers: chunk.map(\.id))
        } catch {
            return false
        }
        for item in chunk {
            savedIDs.remove(item.id)
            sessionConverted += 1
            if keeping {
                sessionRetained += item.videoByteCount
            } else {
                sessionFreed += item.videoByteCount
            }
        }
        sessionDeletedAny = true
        persistSavedIDs()
        markRemoved(chunk)
        return true
    }

    private func pauseForStorage() {
        progress = nil
        conversionActive = false
        storagePause = StoragePause(converted: sessionConverted, remaining: pendingItems.count)
    }

    private func sessionResult(keptClips: Bool) -> ConversionResult {
        ConversionResult(
            freedBytes: sessionDeletedAny && !keptClips ? sessionFreed : 0,
            retainedClipBytes: sessionDeletedAny && keptClips ? sessionRetained : 0,
            converted: sessionConverted,
            skipped: sessionSkipped,
            deleted: sessionDeletedAny,
            keptClips: keptClips,
            remaining: pendingItems.count
        )
    }

    private func persistSavedIDs() {
        UserDefaults.standard.set(Array(savedIDs), forKey: Self.savedKey)
    }

    private func markRemoved(_ done: [LiveItem]) {
        let ids = Set(done.map(\.id))
        items.removeAll { ids.contains($0.id) }
        selected.subtract(ids)
        totalBytes = items.reduce(0) { $0 + $1.videoByteCount }
        selectedBytes = items.reduce(0) { partial, item in
            partial + (selected.contains(item.id) ? item.videoByteCount : 0)
        }
    }

    func loadClips() async {
        clipsLoading = true
        let found: [LiveItem] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.collectClips())
            }
        }
        clips = found
        clipsTotalBytes = found.reduce(0) { $0 + $1.videoByteCount }
        clipsSelected = []
        clipsSelectedBytes = 0
        clipsLoading = false
    }

    func toggleClip(_ item: LiveItem) {
        if clipsSelected.contains(item.id) {
            clipsSelected.remove(item.id)
            clipsSelectedBytes -= item.videoByteCount
        } else {
            clipsSelected.insert(item.id)
            clipsSelectedBytes += item.videoByteCount
        }
    }

    func toggleAllClips() {
        if allClipsSelected {
            clipsSelected.removeAll()
            clipsSelectedBytes = 0
        } else {
            clipsSelected = Set(clips.map(\.id))
            clipsSelectedBytes = clipsTotalBytes
        }
    }

    func deleteSelectedClips() async {
        let chosen = clips.filter { clipsSelected.contains($0.id) }
        guard !chosen.isEmpty, progress == nil else { return }
        let bytes = chosen.reduce(Int64(0)) { $0 + $1.videoByteCount }
        progress = WorkProgress(
            title: "Waiting for deletion confirmation",
            detail: "iOS asks once. Confirm to move the clips to Recently Deleted. Their space stays used until that album is emptied in Photos.",
            completed: 0,
            total: chosen.count
        )
        var deleted = false
        do {
            try await Self.delete(localIdentifiers: chosen.map(\.id))
            deleted = true
        } catch {
            deleted = false
        }
        progress = nil
        clipDeletion = ClipDeletionResult(
            freedBytes: deleted ? bytes : 0,
            count: chosen.count,
            deleted: deleted
        )
        await loadClips()
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

    /// Images only. A Live Photo with the Live switch turned off keeps its paired video
    /// resource but loses the photoLive subtype, so the subtype flag is not used.
    nonisolated static func collect(onProgress: @escaping (_ checked: Int, _ found: Int, _ total: Int) -> Void) -> [LiveItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        let total = result.count
        var all: [LiveItem] = []
        let batchSize = 200
        var index = 0
        while index < total {
            let end = min(index + batchSize, total)
            autoreleasepool {
                let indexes = IndexSet(integersIn: index..<end)
                result.enumerateObjects(at: indexes, options: []) { asset, _, _ in
                    autoreleasepool {
                        let resources = PHAssetResource.assetResources(for: asset)
                        let paired = resources.filter { isReclaimablePairedVideo($0.type) }
                        guard !paired.isEmpty else { return }
                        let videoBytes = paired.reduce(Int64(0)) { sum, resource in
                            sum + max(0, LiveResourceFileSize(resource))
                        }
                        all.append(LiveItem(
                            id: asset.localIdentifier,
                            videoByteCount: videoBytes,
                            stillByteCount: displayedStillByteCount(in: resources, adjusted: asset.hasAdjustments)
                        ))
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

    /// Live Photos whose still file is not on this iPhone. The paired-video check
    /// matches the regular scan. Nothing is downloaded while scanning.
    nonisolated static func collectCloudOnly(onProgress: @escaping (_ checked: Int, _ found: Int, _ total: Int) -> Void) -> [LiveItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        let total = result.count
        var all: [LiveItem] = []
        let batchSize = 200
        var index = 0
        while index < total {
            let end = min(index + batchSize, total)
            autoreleasepool {
                let indexes = IndexSet(integersIn: index..<end)
                result.enumerateObjects(at: indexes, options: []) { asset, _, _ in
                    autoreleasepool {
                        let resources = PHAssetResource.assetResources(for: asset)
                        let paired = resources.filter { isReclaimablePairedVideo($0.type) }
                        guard !paired.isEmpty else { return }
                        guard stillIsCloudOnly(in: resources, adjusted: asset.hasAdjustments) else { return }
                        let videoBytes = paired.reduce(Int64(0)) { sum, resource in
                            sum + max(0, LiveResourceFileSize(resource))
                        }
                        all.append(LiveItem(
                            id: asset.localIdentifier,
                            videoByteCount: videoBytes,
                            stillByteCount: displayedStillByteCount(in: resources, adjusted: asset.hasAdjustments)
                        ))
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

    /// The still that conversion would copy is not stored on this device.
    /// A missing still resource is not offered, because there is nothing to download.
    nonisolated private static func stillIsCloudOnly(in resources: [PHAssetResource], adjusted: Bool) -> Bool {
        let type: PHAssetResourceType = adjusted ? .fullSizePhoto : .photo
        guard let resource = resources.first(where: { $0.type == type }) else { return false }
        return !LiveResourceIsLocal(resource)
    }

    nonisolated private static func displayedStillByteCount(in resources: [PHAssetResource], adjusted: Bool) -> Int64 {
        let type: PHAssetResourceType = adjusted ? .fullSizePhoto : .photo
        guard let resource = resources.first(where: { $0.type == type }) else { return 0 }
        return max(0, LiveResourceFileSize(resource))
    }

    /// Motion that converting can drop: the current paired video, its full-size render,
    /// or the original paired video kept behind an edit such as Live turned off.
    nonisolated static func isReclaimablePairedVideo(_ type: PHAssetResourceType) -> Bool {
        switch type {
        case .pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo:
            return true
        default:
            return false
        }
    }

    nonisolated static func convert(localIdentifier: String, keepClip: Bool, clipsAlbum: PHAssetCollection?) async throws {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetch.firstObject else { throw ConvertError.missing }
        let still = try stillResource(for: asset)
        let clip = keepClip ? try clipResource(for: asset) : nil
        let stillURL = temporaryURL(for: still, fallback: "jpg")
        defer { try? FileManager.default.removeItem(at: stillURL) }
        let clipURL = clip.map { temporaryURL(for: $0, fallback: "mov") }
        defer { if let clipURL { try? FileManager.default.removeItem(at: clipURL) } }
        try await write(still, to: stillURL)
        try assertCopiedSize(of: still, at: stillURL)
        if let clip, let clipURL {
            try await write(clip, to: clipURL)
            try assertCopiedSize(of: clip, at: clipURL)
        }
        let albums = userAlbums(containing: asset)
        let creationDate = asset.creationDate
        let location = asset.location
        let favorite = asset.isFavorite
        if let clip, let clipURL, let clipsAlbum {
            let clipName = clip.originalFilename
            do {
                try await saveStillAndClip(
                    stillURL: stillURL,
                    stillFilename: still.originalFilename,
                    clipURL: clipURL,
                    clipFilename: clipName,
                    creationDate: creationDate,
                    location: location,
                    favorite: favorite,
                    stillAlbums: albums,
                    clipsAlbum: clipsAlbum
                )
            } catch {
                try await saveStillAndClip(
                    stillURL: stillURL,
                    stillFilename: still.originalFilename,
                    clipURL: clipURL,
                    clipFilename: clipName,
                    creationDate: creationDate,
                    location: location,
                    favorite: favorite,
                    stillAlbums: [],
                    clipsAlbum: clipsAlbum
                )
            }
        } else if albums.isEmpty {
            try await save(
                fileURL: stillURL,
                originalFilename: still.originalFilename,
                creationDate: creationDate,
                location: location,
                favorite: favorite,
                albums: []
            )
        } else {
            do {
                try await save(
                    fileURL: stillURL,
                    originalFilename: still.originalFilename,
                    creationDate: creationDate,
                    location: location,
                    favorite: favorite,
                    albums: albums
                )
            } catch {
                try await save(
                    fileURL: stillURL,
                    originalFilename: still.originalFilename,
                    creationDate: creationDate,
                    location: location,
                    favorite: favorite,
                    albums: []
                )
            }
        }
    }

    /// Downloads and saves only the still. The paired video is never requested.
    /// Clips are not kept. Original bytes, date, location, favorite, and regular albums match the regular convert path.
    nonisolated static func convertFromCloud(
        localIdentifier: String,
        onProgress: @escaping @Sendable (CloudTransfer) -> Void
    ) async throws {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetch.firstObject else { throw ConvertError.missing }
        let still = try stillResource(for: asset)
        let stillURL = temporaryURL(for: still, fallback: "jpg")
        defer { try? FileManager.default.removeItem(at: stillURL) }
        try await writeAllowingNetwork(still, to: stillURL) { fraction in
            onProgress(.downloading(fraction))
        }
        try assertCopiedSize(of: still, at: stillURL)
        onProgress(.saving)
        let albums = userAlbums(containing: asset)
        let creationDate = asset.creationDate
        let location = asset.location
        let favorite = asset.isFavorite
        if albums.isEmpty {
            try await save(
                fileURL: stillURL,
                originalFilename: still.originalFilename,
                creationDate: creationDate,
                location: location,
                favorite: favorite,
                albums: []
            )
        } else {
            do {
                try await save(
                    fileURL: stillURL,
                    originalFilename: still.originalFilename,
                    creationDate: creationDate,
                    location: location,
                    favorite: favorite,
                    albums: albums
                )
            } catch {
                try await save(
                    fileURL: stillURL,
                    originalFilename: still.originalFilename,
                    creationDate: creationDate,
                    location: location,
                    favorite: favorite,
                    albums: []
                )
            }
        }
    }

    nonisolated static func collectClips() -> [LiveItem] {
        guard let album = fetchClipsAlbum() else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(in: album, options: options)
        var items: [LiveItem] = []
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .video else { return }
            autoreleasepool {
                items.append(LiveItem(id: asset.localIdentifier, videoByteCount: storedVideoByteCount(of: asset)))
            }
        }
        return items
    }

    nonisolated static func clipsAlbum() async throws -> PHAssetCollection {
        if let existing = fetchClipsAlbum() { return existing }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: clipsAlbumTitle)
        }
        guard let created = fetchClipsAlbum() else { throw ConvertError.unavailable }
        return created
    }

    nonisolated private static func fetchClipsAlbum() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", clipsAlbumTitle)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
    }

    nonisolated private static func storedVideoByteCount(of asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        let resource = resources.first { $0.type == .video } ?? resources.first { $0.type == .fullSizeVideo }
        guard let resource else { return 0 }
        return max(0, LiveResourceFileSize(resource))
    }

    nonisolated static func delete(localIdentifiers: [String]) async throws {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        guard fetch.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(fetch)
        }
    }

    /// The still file to copy. Edited photos, including Live turned off, use the full-size
    /// rendered photo so the picture matches what Photos is showing. Unedited ones use the
    /// original photo resource. Either way the bytes are copied as stored; nothing is
    /// decoded or resized, and the paired video is not added to the new still.
    nonisolated private static func stillResource(for asset: PHAsset) throws -> PHAssetResource {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.hasAdjustments {
            guard let rendered = resources.first(where: { $0.type == .fullSizePhoto }) else {
                throw ConvertError.unavailable
            }
            return rendered
        }
        guard let original = resources.first(where: { $0.type == .photo }) else {
            throw ConvertError.unavailable
        }
        return original
    }

    /// The motion file to copy when clips are kept. Prefer the current rendered paired
    /// video, then the current paired video, then the original kept behind an edit
    /// (Live turned off). Bytes are copied as stored.
    nonisolated private static func clipResource(for asset: PHAsset) throws -> PHAssetResource {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.hasAdjustments, let rendered = resources.first(where: { $0.type == .fullSizePairedVideo }) {
            return rendered
        }
        if let current = resources.first(where: { $0.type == .pairedVideo }) {
            return current
        }
        if let stored = resources.first(where: { $0.type == .adjustmentBasePairedVideo }) {
            return stored
        }
        throw ConvertError.unavailable
    }

    nonisolated private static func assertCopiedSize(of resource: PHAssetResource, at url: URL) throws {
        let expected = LiveResourceFileSize(resource)
        guard expected > 0 else { return }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let actual = values.fileSize, Int64(actual) == expected else {
            throw ConvertError.unavailable
        }
    }

    nonisolated private static func temporaryURL(for resource: PHAssetResource, fallback: String) -> URL {
        let ext = (resource.originalFilename as NSString).pathExtension
        let suffix = ext.isEmpty ? fallback : ext
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

    /// Network is allowed only for the still resource passed by convertFromCloud.
    nonisolated private static func writeAllowingNetwork(
        _ resource: PHAssetResource,
        to url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { progress in
            onProgress(progress)
        }
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

    nonisolated private static func isStorageError(_ error: Error) -> Bool {
        func matches(_ error: NSError) -> Bool {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError {
                return true
            }
            if error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXError.ENOSPC.rawValue) {
                return true
            }
            if error.domain == PHPhotosErrorDomain, let code = PHPhotosError.Code(rawValue: error.code), code == .notEnoughSpace {
                return true
            }
            return false
        }
        let ns = error as NSError
        if matches(ns) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, matches(underlying) {
            return true
        }
        return false
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
        originalFilename: String,
        creationDate: Date?,
        location: CLLocation?,
        favorite: Bool,
        albums: [PHAssetCollection]
    ) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = originalFilename
            options.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: fileURL, options: options)
            request.creationDate = creationDate
            request.location = location
            request.isFavorite = favorite
            guard let placeholder = request.placeholderForCreatedAsset else { return }
            for album in albums {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
    }

    nonisolated private static func saveStillAndClip(
        stillURL: URL,
        stillFilename: String,
        clipURL: URL,
        clipFilename: String,
        creationDate: Date?,
        location: CLLocation?,
        favorite: Bool,
        stillAlbums: [PHAssetCollection],
        clipsAlbum: PHAssetCollection
    ) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let stillRequest = PHAssetCreationRequest.forAsset()
            let stillOptions = PHAssetResourceCreationOptions()
            stillOptions.originalFilename = stillFilename
            stillOptions.shouldMoveFile = false
            stillRequest.addResource(with: .photo, fileURL: stillURL, options: stillOptions)
            stillRequest.creationDate = creationDate
            stillRequest.location = location
            stillRequest.isFavorite = favorite
            if let placeholder = stillRequest.placeholderForCreatedAsset {
                for album in stillAlbums {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }

            let clipRequest = PHAssetCreationRequest.forAsset()
            let clipOptions = PHAssetResourceCreationOptions()
            clipOptions.originalFilename = clipFilename
            clipOptions.shouldMoveFile = false
            clipRequest.addResource(with: .video, fileURL: clipURL, options: clipOptions)
            clipRequest.creationDate = creationDate
            clipRequest.location = location
            if let placeholder = clipRequest.placeholderForCreatedAsset {
                PHAssetCollectionChangeRequest(for: clipsAlbum)?.addAssets([placeholder] as NSArray)
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
