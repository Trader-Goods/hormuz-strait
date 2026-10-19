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
                                    Button(model.allSelected ? "Clear" : "Select All") {
                                        model.toggleAll()
                                    }
                                    .disabled(model.items.isEmpty || model.scanning || model.progress != nil)
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
                                    Button(model.allClipsSelected ? "Clear" : "Select All") {
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
                        Text(model.scannedCount == 0 ? "Scanning your photo library…" : "Found \(model.scannedCount.formatted()) Live Photos…")
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
            if model.progress == nil {
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
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(model.items.count.formatted()) Live Photos")
                .font(.title2)
                .fontWeight(.semibold)
            Text(summaryLine)
                .foregroundStyle(.secondary)
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
        let shared = "Converting copies the full-size photo file unchanged, including edits, format, and embedded details, plus its date, location, favorite flag, and regular albums. Photos that are not stored on this iPhone are skipped, because nothing is downloaded. iOS then asks once to delete the Live Photos. They stay in Recently Deleted, and that space stays used until you empty Recently Deleted in Photos."
        if model.keepVideoClips {
            return "\(shared) The paired video is also saved in \(LibraryModel.clipsAlbumTitle)."
        }
        return "\(shared) Only the Live Photo video is removed."
    }

    private var confirmMessage: String {
        if model.keepVideoClips {
            return "Still copies and video clips are saved first. iOS then shows one deletion confirmation. Originals stay in Recently Deleted until you empty that album in Photos. About \(ByteText.string(model.selectedBytes)) remains in \(LibraryModel.clipsAlbumTitle)."
        }
        return "Still copies are saved first. iOS then shows one deletion confirmation. Originals stay in Recently Deleted until you empty that album in Photos. About \(ByteText.string(model.selectedBytes)) of paired video can be freed then."
    }

    private func resultTitle(_ result: ConversionResult) -> String {
        if !result.deleted {
            return result.converted == 0 ? "Nothing saved" : "Originals kept"
        }
        return result.keptClips ? "Clips kept" : "In Recently Deleted"
    }

    private func resultMessage(_ result: ConversionResult) -> String {
        if result.deleted && result.keptClips {
            return "Saved \(result.converted.formatted()) still photos and \(result.converted.formatted()) video clips in \(LibraryModel.clipsAlbumTitle). The original Live Photos are in Recently Deleted. About \(ByteText.string(result.retainedClipBytes)) of clip video stays in use until you delete those clips. The originals stay used until you empty Recently Deleted in Photos."
        }
        if result.deleted {
            return "Saved \(result.converted.formatted()) still photos. The Live Photos are in Recently Deleted. About \(ByteText.string(result.freedBytes)) of paired video stays used until you empty Recently Deleted in Photos."
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
                Button(model.allSelected ? "Clear" : "Select All") {
                    model.toggleAll()
                }
                .buttonStyle(.bordered)
                .disabled(model.items.isEmpty || model.scanning || model.progress != nil)
                Button("Convert") {
                    confirming = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selected.isEmpty || model.scanning || model.progress != nil)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
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
                    Button(model.allClipsSelected ? "Clear" : "Select All") {
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

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
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
            .padding(20)
            .frame(maxWidth: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(24)
        }
        .accessibilityElement(children: .combine)
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
                    Button("Open Photos", action: openPhotos)
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

    private func openPhotos() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened {
                DispatchQueue.main.async {
                    openFailed = true
                }
            }
        }
    }
}
