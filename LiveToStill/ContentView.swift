import Photos
import SwiftUI
import UIKit

let pine = Color(red: 0.09, green: 0.33, blue: 0.30)

struct ContentView: View {
    @StateObject private var model = LibraryModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.access {
            case .requesting:
                NavigationStack {
                    ProgressView("Requesting photo access")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("Live to Still")
                }
            case .denied:
                NavigationStack {
                    AccessNotice(
                        title: "Photo access is off",
                        message: "Live to Still needs access to find Live Photos, save still copies, and delete the originals after you confirm. Nothing leaves this iPhone.",
                        button: "Open Settings",
                        action: model.openSettings
                    )
                    .navigationTitle("Live to Still")
                }
            case .restricted:
                NavigationStack {
                    AccessNotice(
                        title: "Photo access is restricted",
                        message: "This iPhone is not allowing Live to Still to use the photo library. Nothing leaves this iPhone.",
                        button: "Open Settings",
                        action: model.openSettings
                    )
                    .navigationTitle("Live to Still")
                }
            case .limited, .full:
                TabView {
                    NavigationStack {
                        LibraryScreen(model: model)
                            .navigationTitle("Live to Still")
                            .navigationBarTitleDisplayMode(.large)
                            .toolbar {
                                ToolbarItem(placement: .navigationBarTrailing) {
                                    Button(model.allSelected ? "Cancel" : "Select All") {
                                        model.toggleAll()
                                    }
                                    .disabled(model.items.isEmpty || model.scanning || model.progress != nil || model.cloudRunning)
                                }
                            }
                    }
                    .tabItem {
                        Label("Live Photos", systemImage: "livephoto")
                    }

                    NavigationStack {
                        ClipsScreen(model: model)
                            .navigationTitle("Clips")
                            .navigationBarTitleDisplayMode(.large)
                            .toolbar {
                                ToolbarItem(placement: .navigationBarTrailing) {
                                    Button(model.allClipsSelected ? "Cancel" : "Select All") {
                                        model.toggleAllClips()
                                    }
                                    .disabled(model.clips.isEmpty || model.clipsLoading || model.progress != nil)
                                }
                            }
                    }
                    .tabItem {
                        Label("Clips", systemImage: "film")
                    }

                    NavigationStack {
                        CopiesScreen()
                            .navigationTitle("Delete Copies")
                            .navigationBarTitleDisplayMode(.large)
                    }
                    .tabItem {
                        Label("Copies", systemImage: "rectangle.on.rectangle")
                    }
                }
            }
        }
        .tint(pine)
        .task { await model.prepare() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await model.onForeground() }
            }
        }
    }
}

private struct LibraryScreen: View {
    @ObservedObject var model: LibraryModel
    @StateObject private var thumbnails = ThumbnailKeeper()
    @Environment(\.displayScale) private var displayScale
    @State private var confirming = false
    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                if model.access == .limited {
                    limitedBanner
                }
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.scanning && model.items.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(scanningText)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                } else if !model.scanning && model.items.isEmpty {
                    Text("No Live Photos in the photos you allowed.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(model.items) { item in
                            LivePhotoCell(
                                item: item,
                                selected: model.selected.contains(item.id),
                                store: thumbnails.store,
                                side: 140 * displayScale,
                                accessibilityPrefix: "Live Photo"
                            ) {
                                model.toggle(item)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable {
            if model.progress == nil && model.storagePause == nil {
                await model.scan()
            }
        }
        .safeAreaInset(edge: .bottom) {
            convertBar
        }
        .overlay {
            if let progress = model.progress {
                WorkOverlay(progress: progress)
            }
        }
        .confirmationDialog(
            "Convert \(model.selected.count.formatted()) Live Photos?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Convert") {
                Task { await model.convertSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .sheet(item: $model.result, onDismiss: {
            Task { await model.scan() }
        }) { result in
            PostDeleteSummary(
                title: resultTitle(result),
                message: resultMessage(result),
                footnote: result.skipped > 0
                    ? "\(result.skipped.formatted()) Live Photos were skipped because the full photo is not on this iPhone. Nothing was downloaded."
                    : nil,
                dismiss: { model.result = nil }
            )
        }
        .fullScreenCover(item: $model.storagePause) { pause in
            OutOfSpaceScreen(
                converted: pause.converted,
                remaining: pause.remaining,
                onContinue: { Task { await model.resumeAfterStoragePause() } },
                onStop: model.stopConversionForNow
            )
            .interactiveDismissDisabled()
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(model.items.count.formatted()) Live Photos")
                .font(.title2)
                .fontWeight(.semibold)
            Text(summaryLine)
                .foregroundStyle(.secondary)
            NavigationLink {
                AttachmentsScreen()
            } label: {
                Label("Saved Attachments", systemImage: "paperclip")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            NavigationLink {
                CloudSpaceScreen(model: model)
            } label: {
                Label("Free Up iCloud Space", systemImage: "icloud.and.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            EmptyRecentlyDeletedButton()
            Toggle("Keep video clips", isOn: $model.keepVideoClips)
                .font(.subheadline)
            Text(model.keepVideoClips
                 ? "On: each Live Photo becomes a still and a video in \(LibraryModel.clipsAlbumTitle). Clip space stays in use until you delete those clips."
                 : "Off: the motion video is discarded when you convert.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(pine.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var scanningText: String {
        if model.scanTotal == 0 {
            return "Scanning your photo library…"
        }
        return "Checked \(model.scanChecked.formatted()) of \(model.scanTotal.formatted()) photos · \(model.scannedCount.formatted()) with motion"
    }

    private var summaryLine: String {
        guard model.totalBytes > 0 else {
            return "Paired video size appears as the library is measured"
        }
        if model.keepVideoClips {
            return "About \(ByteText.string(model.totalBytes)) would be kept as clips"
        }
        return "About \(ByteText.string(model.totalBytes)) in paired videos"
    }

    private var explanation: String {
        let shared = "Converting copies the full-size photo file unchanged, including edits, format, and embedded details, plus its date, location, favorite flag, and regular albums. Photos with Live turned off are included when the motion file is still stored. Photos that are not stored on this iPhone are skipped, because nothing is downloaded. Stills are saved in batches that fit the free space, then that batch’s originals are deleted. They stay in Recently Deleted and still use space until you empty that album in Photos."
        if model.keepVideoClips {
            return "\(shared) Each batch also saves the paired video in \(LibraryModel.clipsAlbumTitle)."
        }
        return "\(shared) Only the Live Photo video is removed."
    }

    private var confirmMessage: String {
        if model.keepVideoClips {
            return "Stills and clips are saved in batches that fit the free space. iOS asks once per batch. Originals stay in Recently Deleted and still use space until you empty that album in Photos. About \(ByteText.string(model.selectedBytes)) remains in \(LibraryModel.clipsAlbumTitle)."
        }
        return "Stills are saved in batches that fit the free space. iOS asks once per batch. Originals stay in Recently Deleted and still use space until you empty that album in Photos. About \(ByteText.string(model.selectedBytes)) of paired video can be freed then."
    }

    private func resultTitle(_ result: ConversionResult) -> String {
        if !result.deleted {
            return result.converted == 0 ? "Nothing saved" : "Originals kept"
        }
        return result.keptClips ? "Clips kept" : "In Recently Deleted"
    }

    private func resultMessage(_ result: ConversionResult) -> String {
        let waiting = result.remaining > 0 ? " \(result.remaining.formatted()) are left for when there is room." : ""
        if result.deleted && result.keptClips {
            return "Saved \(result.converted.formatted()) still photos and \(result.converted.formatted()) video clips in \(LibraryModel.clipsAlbumTitle). The original Live Photos are in Recently Deleted. About \(ByteText.string(result.retainedClipBytes)) of clip video stays in use until you delete those clips. The originals stay used until you empty Recently Deleted in Photos.\(waiting)"
        }
        if result.deleted {
            return "Saved \(result.converted.formatted()) still photos. The Live Photos are in Recently Deleted. About \(ByteText.string(result.freedBytes)) of paired video stays used until you empty Recently Deleted in Photos.\(waiting)"
        }
        if result.converted == 0 {
            return "No still photos were saved, so nothing was deleted."
        }
        return "Saved \(result.converted.formatted()) still photos, but the Live Photos were not deleted, so their video space is still in use."
    }

    private var limitedBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Only selected photos are visible. Live Photos you left out will not appear.")
                .font(.subheadline)
            Button("Choose More Photos", action: model.chooseMorePhotos)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var convertBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(model.selected.count.formatted()) selected · \(ByteText.string(model.selectedBytes))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(model.allSelected ? "Cancel" : "Select All") {
                    model.toggleAll()
                }
                .buttonStyle(.bordered)
                .disabled(model.items.isEmpty || model.scanning || model.progress != nil || model.cloudRunning)
                Button("Convert") {
                    confirming = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selected.isEmpty || model.scanning || model.progress != nil || model.cloudRunning)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
    }
}

private struct CloudSpaceScreen: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                if model.progress != nil || model.storagePause != nil {
                    Text("A conversion is already running. This starts after that conversion finishes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if model.cloudScanning || !model.cloudScanFinished {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(scanningText)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if model.cloudItems.isEmpty && model.cloudResult == nil {
                    Text("No Live Photos were found. This includes every photo that still has a paired video, with Live on or off, whether the files are on this iPhone, only in iCloud, or both. If iCloud Photos is off, pictures that exist only in iCloud are not in this library. If you already converted them, the video is gone and there is nothing left to free.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    EmptyRecentlyDeletedButton()
                } else if !model.cloudItems.isEmpty {
                    Text("Every Live Photo is included, including ones already on this iPhone and ones with Live turned off. The photo file is saved unchanged. When it is not on this iPhone, only that photo is downloaded, never the paired video. Deleting the original syncs, so iCloud storage is freed after Recently Deleted is emptied. One photo is handled at a time so the download has room. Photos that cannot be read stay in the library and can be tried again later.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Free Up iCloud Space") {
                        Task { await model.convertCloud() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(model.cloudScanning || model.cloudRunning || model.cloudProgress != nil || model.progress != nil || model.storagePause != nil)
                    EmptyRecentlyDeletedButton()
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Free Up iCloud Space")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.cloudRunning || model.cloudProgress != nil)
        .refreshable {
            if model.cloudProgress == nil && model.cloudStoragePause == nil && !model.cloudRunning {
                await model.scanCloud()
            }
        }
        .task {
            await model.scanCloud()
        }
        .onChange(of: model.progress == nil && model.storagePause == nil) { ready in
            if ready {
                Task { await model.scanCloud() }
            }
        }
        .overlay {
            if let progress = model.cloudProgress {
                WorkOverlay(progress: progress) {
                    model.requestCloudCancel()
                }
            }
        }
        .sheet(item: $model.cloudResult, onDismiss: {
            Task { await model.scanCloud() }
        }) { result in
            PostDeleteSummary(
                title: resultTitle(result),
                message: resultMessage(result),
                footnote: result.skipped > 0
                    ? "\(result.skipped.formatted()) Live Photos were skipped because the photo could not be downloaded. They stay in your library and can be tried again later."
                    : nil,
                dismiss: { model.cloudResult = nil }
            )
        }
        .fullScreenCover(item: $model.cloudStoragePause) { pause in
            OutOfSpaceScreen(
                converted: pause.converted,
                remaining: pause.remaining,
                onContinue: { Task { await model.resumeCloudAfterStoragePause() } },
                onStop: model.stopCloudForNow
            )
            .interactiveDismissDisabled()
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\((model.cloudScanning ? model.cloudFound : model.cloudItems.count).formatted()) Live Photos")
                .font(.title2)
                .fontWeight(.semibold)
            if model.cloudScanFinished && !model.cloudScanning {
                Text("\(model.cloudOnDevice.formatted()) on this iPhone")
                    .foregroundStyle(.secondary)
                Text("\(model.cloudOnlyCount.formatted()) only in iCloud")
                    .foregroundStyle(.secondary)
                Text("\(model.cloudItems.count.formatted()) will be converted")
                    .foregroundStyle(.secondary)
            }
            Text(summaryLine)
                .foregroundStyle(.secondary)
            if model.cloudScanning && model.cloudScanTotal > 0 {
                Text(scanningText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(pine.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var scanningText: String {
        if model.cloudScanTotal == 0 {
            return "Scanning your photo library…"
        }
        return "Checked \(model.cloudChecked.formatted()) of \(model.cloudScanTotal.formatted()) photos"
    }

    private var summaryLine: String {
        if model.cloudScanning || !model.cloudScanFinished {
            return "Paired video size appears as the library is measured"
        }
        if model.cloudItems.isEmpty {
            return "Nothing with a paired video is left to convert"
        }
        guard model.cloudTotalBytes > 0 else {
            return "Paired video size is unavailable"
        }
        return "About \(ByteText.string(model.cloudTotalBytes)) of paired video can be freed in iCloud"
    }

    private func resultTitle(_ result: ConversionResult) -> String {
        if result.deleted {
            return "In Recently Deleted"
        }
        if result.undeletedSaves > 0 {
            return "Originals kept"
        }
        return "Nothing saved"
    }

    private func resultMessage(_ result: ConversionResult) -> String {
        let waiting = result.remaining > 0 ? " \(result.remaining.formatted()) are left for another run." : ""
        if result.deleted {
            let stillWaiting = result.undeletedSaves > 0
                ? " \(result.undeletedSaves.formatted()) still photos were saved, but those Live Photos were not deleted. Run this again to delete them without downloading again."
                : ""
            return "Saved \(result.converted.formatted()) still photos. The Live Photos are in Recently Deleted. About \(ByteText.string(result.freedBytes)) of paired video stays used on this iPhone and in iCloud until you empty Recently Deleted. Emptying it frees that space in iCloud too.\(stillWaiting)\(waiting)"
        }
        if result.undeletedSaves > 0 {
            return "Saved \(result.undeletedSaves.formatted()) still photos, but the Live Photos were not deleted, so their space is still in use in iCloud. Run this again to delete them without downloading again.\(waiting)"
        }
        return "No still photos were saved, so nothing was deleted.\(waiting)"
    }
}

private struct ClipsScreen: View {
    @ObservedObject var model: LibraryModel
    @StateObject private var thumbnails = ThumbnailKeeper()
    @Environment(\.displayScale) private var displayScale
    @State private var confirming = false
    @State private var playing: String?
    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 6)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(model.clips.count.formatted()) clips")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(model.clipsTotalBytes > 0
                         ? "About \(ByteText.string(model.clipsTotalBytes)) still in use"
                         : "Clips you keep stay as normal videos")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(pine.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("Videos saved while Keep video clips is on. Play one, then delete the clips you do not want. Deleting moves them to Recently Deleted. Their space stays used until you empty that album in Photos. Clips you leave here stay in your library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.clipsLoading && model.clips.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for clips…")
                            .foregroundStyle(.secondary)
                    }
                } else if model.clips.isEmpty {
                    Text("No clips yet. Turn on Keep video clips, then convert Live Photos.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(model.clips) { item in
                            LivePhotoCell(
                                item: item,
                                selected: model.clipsSelected.contains(item.id),
                                store: thumbnails.store,
                                side: 140 * displayScale,
                                accessibilityPrefix: "Clip"
                            ) {
                                model.toggleClip(item)
                            }
                            .overlay(alignment: .bottomTrailing) {
                                Button {
                                    playing = item.id
                                } label: {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white, .black.opacity(0.45))
                                        .padding(8)
                                }
                                .accessibilityLabel("Play clip")
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable {
            if model.progress == nil {
                await model.loadClips()
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(model.clipsSelected.count.formatted()) selected · \(ByteText.string(model.clipsSelectedBytes))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(model.allClipsSelected ? "Cancel" : "Select All") {
                        model.toggleAllClips()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.clips.isEmpty || model.clipsLoading || model.progress != nil)
                    Button("Delete") {
                        confirming = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.clipsSelected.isEmpty || model.clipsLoading || model.progress != nil)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
        }
        .overlay {
            if let progress = model.progress {
                WorkOverlay(progress: progress)
            }
        }
        .confirmationDialog(
            "Delete \(model.clipsSelected.count.formatted()) clips?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteSelectedClips() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("iOS asks once. The clips stay in Recently Deleted, and about \(ByteText.string(model.clipsSelectedBytes)) stays used until you empty Recently Deleted in Photos.")
        }
        .sheet(item: $model.clipDeletion) { result in
            PostDeleteSummary(
                title: result.deleted ? "In Recently Deleted" : "Nothing deleted",
                message: result.deleted
                    ? "Deleted \(result.count.formatted()) clips. About \(ByteText.string(result.freedBytes)) stays used until you empty Recently Deleted in Photos."
                    : "The clips were not deleted, so their space is still in use.",
                footnote: nil,
                dismiss: { model.clipDeletion = nil }
            )
        }
        .sheet(item: playingBinding) { token in
            AssetPlayerSheet(id: token.id)
        }
        .onAppear {
            guard model.progress == nil, model.clipDeletion == nil else { return }
            Task { await model.loadClips() }
        }
    }

    private var playingBinding: Binding<PlayerToken?> {
        Binding(
            get: { playing.map(PlayerToken.init) },
            set: { playing = $0?.id }
        )
    }
}

private struct LivePhotoCell: View {
    let item: LiveItem
    let selected: Bool
    let store: ThumbnailStore
    let side: CGFloat
    var accessibilityPrefix: String = "Live Photo"
    let onTap: () -> Void
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Button(action: onTap) {
            Color(uiColor: .secondarySystemFill)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? pine : Color.white)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .padding(6)
                }
                .overlay(alignment: .bottomLeading) {
                    Text(item.videoByteCount > 0 ? ByteText.string(item.videoByteCount) : "—")
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
        if item.videoByteCount > 0 {
            return "\(accessibilityPrefix), \(ByteText.string(item.videoByteCount)) of video"
        }
        return accessibilityPrefix
    }

    private func load() {
        guard image == nil, requestID == nil else { return }
        requestID = store.request(id: item.id, side: side) { loaded in
            image = loaded
        }
    }
}

final class ThumbnailKeeper: ObservableObject {
    let store = ThumbnailStore()
}

private struct AccessNotice: View {
    let title: String
    let message: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(pine)
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
            EmptyRecentlyDeletedButton()
                .padding(.top, 8)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorkOverlay: View {
    let progress: WorkProgress
    var onCancel: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(progress.title)
                        .font(.headline)
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .tint(pine)
                    Text("\(progress.completed.formatted()) of \(progress.total.formatted())")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(progress.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(24)
        }
    }
}

struct PostDeleteSummary: View {
    let title: String
    let message: String
    let footnote: String?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.largeTitle)
                .fontWeight(.semibold)
            Text(message)
                .foregroundStyle(.secondary)
            if let footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            EmptyRecentlyDeletedButton()
            Spacer()
            Button("Done", action: dismiss)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .presentationDetents([.medium, .large])
    }
}

private struct OutOfSpaceScreen: View {
    let converted: Int
    let remaining: Int
    let onContinue: () -> Void
    let onStop: () -> Void
    @State private var openFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Your iPhone is out of space. Empty Recently Deleted to keep going")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Deleted photos stay in Recently Deleted and still use space until that album is emptied. Live to Still cannot empty it.")
                        .foregroundStyle(.secondary)
                    if converted > 0 {
                        Text("\(converted.formatted()) converted. \(remaining.formatted()) left. Continue picks up where this left off.")
                            .font(.subheadline)
                    } else {
                        Text("There is not enough room for the next still. Nothing was deleted.")
                            .font(.subheadline)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        guideStep("1", "Open Photos, then tap Albums.")
                        guideStep("2", "Open Recently Deleted.")
                        guideStep("3", "Tap Select, then Delete All.")
                    }
                    if openFailed {
                        Text("Photos did not open. Switch to the Photos app and follow the steps above.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Open Photos") {
                        PhotosApp.open { openFailed = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    Button("Continue", action: onContinue)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    Button("Not now", action: onStop)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
                .padding(24)
            }
            .navigationTitle("Out of space")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func guideStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number)
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(pine.opacity(0.15), in: Circle())
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum PhotosApp {
    static func open(_ onFailure: @escaping () -> Void) {
        guard let url = URL(string: "photos-redirect://") else {
            onFailure()
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened {
                DispatchQueue.main.async(execute: onFailure)
            }
        }
    }
}

struct EmptyRecentlyDeletedButton: View {
    @State private var showingGuide = false

    var body: some View {
        Button {
            showingGuide = true
        } label: {
            Label("Empty Recently Deleted", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityHint("Shows how to empty Recently Deleted in the Photos app. Live to Still cannot empty it.")
        .sheet(isPresented: $showingGuide) {
            RecentlyDeletedGuide()
        }
    }
}

private struct RecentlyDeletedGuide: View {
    @Environment(\.dismiss) private var dismiss
    @State private var openFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Space is not freed until Recently Deleted is emptied. Live to Still cannot empty it. Photos and videos you delete stay there for about 30 days, and you remove them in the Photos app.")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        guideStep("1", "Open Photos, then tap Albums.")
                        guideStep("2", "Open Recently Deleted.")
                        guideStep("3", "Tap Select, then Delete All.")
                    }
                    if openFailed {
                        Text("Photos did not open. Switch to the Photos app and follow the steps above.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Open Photos") {
                        PhotosApp.open { openFailed = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                }
                .padding(24)
            }
            .navigationTitle("Empty Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func guideStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number)
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(pine.opacity(0.15), in: Circle())
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}
