import AVFoundation
import SwiftUI
import UIKit
import Vision
import VisionKit

struct ScanSheet: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var useCamera = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Point the camera at a barcode, or type the numbers.")
                        .airyBody()
                    if useCamera {
                        camera
                            .frame(height: 280)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    } else if DataScannerViewController.isSupported || UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            useCamera = true
                        } label: {
                            BigLabel(title: "Use the camera", systemImage: "barcode.viewfinder")
                        }
                        .buttonStyle(FilledButton())
                    } else {
                        Text("This phone’s camera is not available here. Type the barcode instead.")
                            .airySecondary()
                    }
                    Text("Barcode numbers")
                        .airyTitle()
                    TextField("For example 012345678905", text: $typed)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 22, design: .rounded))
                    Button {
                        submit(typed)
                    } label: {
                        BigLabel(title: "Look up this barcode", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(FilledButton())
                    .disabled(typed.filter(\.isNumber).count < 8)
                }
                .padding(24)
            }
            .background(Air.canvas)
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .font(.system(size: 18, weight: .semibold))
                }
            }
        }
    }

    @ViewBuilder
    private var camera: some View {
        if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
            DataScannerRepresentable { code in
                submit(code)
            }
        } else {
            BarcodeCameraRepresentable { code in
                submit(code)
            }
        }
    }

    private func submit(_ raw: String) {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 8 else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onCode(digits)
        dismiss()
    }
}

struct DataScannerRepresentable: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128, .code39])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard !controller.isScanning else { return }
        try? controller.startScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        private var fired = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !fired else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    fired = true
                    onCode(value)
                    return
                }
            }
        }
    }
}

struct BarcodeCameraRepresentable: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> BarcodeCameraController {
        let controller = BarcodeCameraController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: BarcodeCameraController, context: Context) {}
}

final class BarcodeCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (String) -> Void = { _ in }
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var fired = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.ean8, .ean13, .upce, .code128, .code39]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !fired,
              let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue
        else { return }
        fired = true
        onCode(code)
    }
}

enum LabelReader {
    static func read(_ image: UIImage) async -> String {
        guard let cgImage = image.cgImage ?? rendered(image) else { return "" }
        return await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string } ?? []
                gate.resume(lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: cgOrientation(image.imageOrientation))
            do {
                try handler.perform([request])
            } catch {
                gate.resume("")
            }
        }
    }

    private static func rendered(_ image: UIImage) -> CGImage? {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }

    private final class ResumeOnce: @unchecked Sendable {
        private var continuation: CheckedContinuation<String, Never>?

        init(_ continuation: CheckedContinuation<String, Never>) {
            self.continuation = continuation
        }

        func resume(_ text: String) {
            continuation?.resume(returning: text)
            continuation = nil
        }
    }

    private static func cgOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
