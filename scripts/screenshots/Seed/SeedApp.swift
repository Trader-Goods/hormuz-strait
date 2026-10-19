import CoreLocation
import Photos
import SwiftUI

@main
struct SeedApp: App {
    var body: some Scene {
        WindowGroup {
            SeedRoot()
        }
    }
}

private struct SeedRoot: View {
    @State private var message = "Adding sample photos"

    var body: some View {
        Text(message)
            .task {
                Task.detached(priority: .userInitiated) {
                    await Seed.run()
                }
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let report = documents.appendingPathComponent("seed-result.txt")
                while !FileManager.default.fileExists(atPath: report.path) {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                let text = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
                message = text.hasPrefix("ok") ? "Seeded" : String(text.prefix(180))
            }
    }
}

private enum Seed {
    static func run() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let report = documents.appendingPathComponent("seed-result.txt")
        try? "started".write(to: documents.appendingPathComponent("seed-started.txt"), atomically: true, encoding: .utf8)
        let initial = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try? "status \(initial.rawValue)".write(to: documents.appendingPathComponent("seed-status.txt"), atomically: true, encoding: .utf8)
        do {
            let status = await authorize(initial)
            guard status == .authorized else {
                try "authorization \(status.rawValue)".write(to: report, atomically: true, encoding: .utf8)
                exit(1)
            }
            let media = Bundle.main.url(forResource: "SampleMedia", withExtension: nil)
                ?? Bundle.main.resourceURL?.appendingPathComponent("SampleMedia")
            guard let media, FileManager.default.fileExists(atPath: media.path) else {
                try "missing SampleMedia bundle folder".write(to: report, atomically: true, encoding: .utf8)
                exit(1)
            }
            let (originalDate, editedDate) = sampleDates()
            var livePairs: [(Data, Data, Int)] = []
            for index in 1...6 {
                let photo = try Data(contentsOf: media.appendingPathComponent("live-\(index).jpg"))
                let video = try Data(contentsOf: media.appendingPathComponent("live-\(index).mov"))
                livePairs.append((photo, video, index))
            }
            let originalVideo = try Data(contentsOf: media.appendingPathComponent("original.mov"))
            let editedVideo = try Data(contentsOf: media.appendingPathComponent("edited.mov"))
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges {
                for (photo, video, index) in livePairs {
                    let request = PHAssetCreationRequest.forAsset()
                    let still = PHAssetResourceCreationOptions()
                    still.originalFilename = String(format: "IMG_%04d.JPG", 1200 + index)
                    request.addResource(with: .photo, data: photo, options: still)
                    let motion = PHAssetResourceCreationOptions()
                    motion.originalFilename = String(format: "IMG_%04d.MOV", 1200 + index)
                    request.addResource(with: .pairedVideo, data: video, options: motion)
                    request.creationDate = editedDate.addingTimeInterval(TimeInterval(-index * 90))
                    request.location = CLLocation(latitude: 37.8199, longitude: -122.4783)
                }
                addVideo(originalVideo, filename: "IMG_2041.MOV", date: originalDate, location: CLLocation(latitude: 37.8199, longitude: -122.4783))
                addVideo(editedVideo, filename: "SNAP_edit.MOV", date: editedDate, location: nil)
                }
            completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: CocoaError(.userCancelled))
                }
            }
            }
            let summary = inventory()
            print(summary)
            try summary.write(to: report, atomically: true, encoding: .utf8)
            exit(0)
        } catch {
            let message = "failed \(error)"
            print(message)
            try? message.write(to: report, atomically: true, encoding: .utf8)
            exit(1)
        }
    }

    static func addVideo(_ data: Data, filename: String, date: Date, location: CLLocation?) {
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = filename
        request.addResource(with: .video, data: data, options: options)
        request.creationDate = date
        request.location = location
    }

    static func sampleDates() -> (Date, Date) {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let edited: Date
        if hour == 0 && minute < 20 {
            edited = calendar.date(byAdding: .hour, value: -3, to: now) ?? now
        } else {
            edited = now.addingTimeInterval(-180)
        }
        return (edited.addingTimeInterval(-300), edited)
    }

    static func authorize(_ current: PHAuthorizationStatus) async -> PHAuthorizationStatus {
        if current != .notDetermined { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func inventory() -> String {
        var lines = ["ok"]
        let images = PHAsset.fetchAssets(with: .image, options: nil)
        lines.append("images \(images.count)")
        images.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let names = resources.map { "\($0.type.rawValue):\($0.originalFilename)" }.joined(separator: ",")
            lines.append("image \(asset.mediaSubtypes.rawValue) \(names)")
        }
        let videos = PHAsset.fetchAssets(with: .video, options: nil)
        videos.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let name = resources.first?.originalFilename ?? "?"
            lines.append("video \(name) loc=\(asset.location != nil) \(asset.pixelWidth)x\(asset.pixelHeight) dur=\(String(format: "%.2f", asset.duration))")
        }
        return lines.joined(separator: "\n")
    }
}
