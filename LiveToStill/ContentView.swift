import SwiftUI

private let pine = Color(red: 0.09, green: 0.33, blue: 0.30)

struct ContentView: View {
    @StateObject private var model = LibraryModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                switch model.access {
                case .requesting:
                    ProgressView("Requesting photo access")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .denied:
                    AccessNotice(
                        title: "Photo access is off",
                        message: "Live to Still needs access to find Live Photos, save still copies, and delete the originals after you confirm. Nothing leaves this iPhone.",
                        button: "Open Settings",
                        action: model.openSettings
                    )
                case .restricted:
                    AccessNotice(
                        title: "Photo access is restricted",
                        message: "This iPhone is not allowing Live to Still to use the photo library. Nothing leaves this iPhone.",
                        button: "Open Settings",
                        action: model.openSettings
                    )
                case .limited, .full:
                    LibraryScreen(model: model)
                }
            }
            .navigationTitle("Live to Still")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if model.access == .full || model.access == .limited {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(model.allSelected ? "Clear" : "Select All") {
                            model.toggleAll()
                        }
                        .disabled(model.items.isEmpty || model.scanning || model.progress != nil)
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
                Text("Converting saves the full-quality still photo, including its date, location, favorite flag, and regular albums. iOS then asks once to delete the Live Photos. They stay in Recently Deleted for 30 days. Photos that are not stored on this iPhone are skipped, because nothing is downloaded.")
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
                                side: 140 * displayScale
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
            Text("Still copies are saved first. iOS then shows one deletion confirmation. Originals stay in Recently Deleted for 30 days. About \(ByteText.string(model.selectedBytes)) of paired video can be freed.")
        }
        .sheet(item: $model.result, onDismiss: {
            Task { await model.scan() }
        }) { result in
            ResultView(result: result) {
                model.result = nil
            }
            .presentationDetents([.medium])
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(model.items.count.formatted()) Live Photos")
                .font(.title2)
                .fontWeight(.semibold)
            Text(model.totalBytes > 0
                 ? "About \(ByteText.string(model.totalBytes)) in paired videos"
                 : "Paired video size appears as the library is measured")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(pine.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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

private struct LivePhotoCell: View {
    let item: LiveItem
    let selected: Bool
    let store: ThumbnailStore
    let side: CGFloat
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
            return "Live Photo, \(ByteText.string(item.videoByteCount)) of video"
        }
        return "Live Photo"
    }

    private func load() {
        guard image == nil, requestID == nil else { return }
        requestID = store.request(id: item.id, side: side) { loaded in
            image = loaded
        }
    }
}

private final class ThumbnailKeeper: ObservableObject {
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

private struct ResultView: View {
    let result: ConversionResult
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(result.deleted ? "Freed \(ByteText.string(result.freedBytes))" : "No space freed")
                .font(.largeTitle)
                .fontWeight(.semibold)
            Text(message)
                .foregroundStyle(.secondary)
            if result.skipped > 0 {
                Text("\(result.skipped.formatted()) Live Photos were skipped because the full photo is not on this iPhone. Nothing was downloaded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done", action: done)
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var message: String {
        if result.deleted {
            return "Saved \(result.converted.formatted()) still photos and deleted \(result.converted.formatted()) Live Photos. The originals are in Recently Deleted for 30 days."
        }
        if result.converted == 0 {
            return "No still photos were saved, so nothing was deleted."
        }
        return "Saved \(result.converted.formatted()) still photos, but the Live Photos were not deleted, so their video space is still in use."
    }
}
