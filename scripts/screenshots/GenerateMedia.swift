import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RGB {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
}

@main
struct GenerateMedia {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "SampleMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let photoSize = (width: 1080, height: 1440)
        let videoSize = (width: 1080, height: 1920)
        for index in 1...6 {
            let image = render(style: index, edited: false, width: photoSize.width, height: photoSize.height)
            try writeJPEG(image, to: output.appendingPathComponent("live-\(index).jpg"))
            try writeVideo(
                to: output.appendingPathComponent("live-\(index).mov"),
                width: photoSize.width,
                height: photoSize.height,
                frames: 8,
                codec: .h264
            ) { frame in
                render(style: index, edited: false, width: photoSize.width, height: photoSize.height, shift: CGFloat(frame) * 6)
            }
        }
        let original = render(style: 0, edited: false, width: videoSize.width, height: videoSize.height)
        let edited = render(style: 0, edited: true, width: videoSize.width, height: videoSize.height)
        try writeVideo(to: output.appendingPathComponent("original.mov"), width: videoSize.width, height: videoSize.height, frames: 24, codec: .jpeg) { _ in original }
        try writeVideo(to: output.appendingPathComponent("edited.mov"), width: videoSize.width, height: videoSize.height, frames: 24, codec: .jpeg) { _ in edited }
        fputs("wrote sample media to \(output.path)\n", stdout)
    }
}

private func render(style: Int, edited: Bool, width: Int, height: Int, shift: CGFloat = 0) -> CGImage {
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    let palettes: [[RGB]] = [
        [RGB(r: 0.13, g: 0.45, b: 0.82), RGB(r: 0.96, g: 0.78, b: 0.22), RGB(r: 0.18, g: 0.62, b: 0.34), RGB(r: 0.93, g: 0.95, b: 0.90)],
        [RGB(r: 0.95, g: 0.45, b: 0.20), RGB(r: 0.99, g: 0.82, b: 0.35), RGB(r: 0.18, g: 0.28, b: 0.55), RGB(r: 0.98, g: 0.55, b: 0.42)],
        [RGB(r: 0.05, g: 0.55, b: 0.62), RGB(r: 0.55, g: 0.86, b: 0.78), RGB(r: 0.98, g: 0.97, b: 0.92), RGB(r: 0.16, g: 0.35, b: 0.42)],
        [RGB(r: 0.36, g: 0.22, b: 0.62), RGB(r: 0.93, g: 0.45, b: 0.55), RGB(r: 0.98, g: 0.86, b: 0.55), RGB(r: 0.18, g: 0.16, b: 0.32)],
        [RGB(r: 0.75, g: 0.22, b: 0.24), RGB(r: 0.96, g: 0.86, b: 0.62), RGB(r: 0.22, g: 0.45, b: 0.28), RGB(r: 0.35, g: 0.22, b: 0.16)],
        [RGB(r: 0.10, g: 0.16, b: 0.32), RGB(r: 0.95, g: 0.78, b: 0.28), RGB(r: 0.18, g: 0.45, b: 0.72), RGB(r: 0.86, g: 0.90, b: 0.94)],
        [RGB(r: 0.20, g: 0.62, b: 0.48), RGB(r: 0.12, g: 0.36, b: 0.58), RGB(r: 0.95, g: 0.62, b: 0.22), RGB(r: 0.96, g: 0.94, b: 0.88)],
    ]
    let colors = palettes[style % palettes.count]
    context.setFillColor(fill(colors[0]))
    context.fill(canvas)
    let cellW = CGFloat(width) / 4
    let cellH = CGFloat(height) / 4
    for row in 0..<4 {
        for column in 0..<4 {
            let rect = CGRect(x: CGFloat(column) * cellW, y: CGFloat(row) * cellH, width: cellW, height: cellH)
            let primary = colors[(row + column) % colors.count]
            let secondary = colors[(row + column + 2) % colors.count]
            context.setFillColor(fill(primary))
            context.fill(rect)
            context.setFillColor(fill(secondary))
            context.fill(CGRect(x: rect.midX, y: rect.minY, width: cellW / 2, height: cellH))
            context.setFillColor(fill(colors[3]))
            let blob = rect.insetBy(dx: cellW * 0.28, dy: cellH * 0.28).offsetBy(dx: shift, dy: 0)
            context.fillEllipse(in: blob)
        }
    }
    context.setFillColor(fill(colors[1]))
    let sun = CGRect(x: CGFloat(width) * 0.18 + shift, y: CGFloat(height) * 0.16, width: CGFloat(width) * 0.22, height: CGFloat(width) * 0.22)
    context.fillEllipse(in: sun)
    context.setFillColor(fill(colors[2]))
    context.move(to: CGPoint(x: 0, y: CGFloat(height) * 0.72))
    context.addLine(to: CGPoint(x: CGFloat(width) * 0.32, y: CGFloat(height) * 0.48))
    context.addLine(to: CGPoint(x: CGFloat(width) * 0.58, y: CGFloat(height) * 0.70))
    context.addLine(to: CGPoint(x: CGFloat(width), y: CGFloat(height) * 0.40))
    context.addLine(to: CGPoint(x: CGFloat(width), y: CGFloat(height)))
    context.addLine(to: CGPoint(x: 0, y: CGFloat(height)))
    context.closePath()
    context.fillPath()
    if edited {
        let sticker = CGRect(x: CGFloat(width) * 0.78, y: CGFloat(height) * 0.045, width: CGFloat(width) * 0.16, height: CGFloat(width) * 0.16)
        context.setFillColor(CGColor(red: 0.95, green: 0.22, blue: 0.28, alpha: 1))
        context.fillEllipse(in: sticker)
        context.setFillColor(CGColor(red: 1, green: 0.92, blue: 0.35, alpha: 1))
        star(in: context, rect: sticker.insetBy(dx: sticker.width * 0.22, dy: sticker.height * 0.22))
    }
    return context.makeImage()!
}

private func star(in context: CGContext, rect: CGRect) {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let outer = min(rect.width, rect.height) / 2
    let inner = outer * 0.42
    context.beginPath()
    for point in 0..<10 {
        let radius = point.isMultiple(of: 2) ? outer : inner
        let angle = CGFloat(point) * .pi / 5 - .pi / 2
        let location = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        if point == 0 {
            context.move(to: location)
        } else {
            context.addLine(to: location)
        }
    }
    context.closePath()
    context.fillPath()
}

private func fill(_ color: RGB) -> CGColor {
    CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
}

private func writeJPEG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

private enum MovieCodec {
    case h264
    case jpeg
}

private func writeVideo(to url: URL, width: Int, height: Int, frames: Int, codec: MovieCodec, frame: (Int) -> CGImage) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let codecKey: AVVideoCodecType = codec == .jpeg ? .jpeg : .h264
    var settings: [String: Any] = [
        AVVideoCodecKey: codecKey,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ]
    if codec == .jpeg {
        settings[AVVideoQualityKey] = 0.92
    } else {
        settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 6_000_000]
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ])
    guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)
    for index in 0..<frames {
        let deadline = Date().addingTimeInterval(15)
        while !input.isReadyForMoreMediaData {
            if Date() > deadline { throw CocoaError(.fileWriteUnknown) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let buffer = try pixelBuffer(from: frame(index), width: width, height: height)
        let time = CMTime(value: CMTimeValue(index), timescale: 8)
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
    input.markAsFinished()
    let finished = DispatchSemaphore(value: 0)
    writer.finishWriting { finished.signal() }
    finished.wait()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

private func pixelBuffer(from image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ] as CFDictionary,
        &buffer
    )
    guard status == kCVReturnSuccess, let buffer else { throw CocoaError(.fileWriteUnknown) }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw CocoaError(.fileWriteUnknown) }
    let context = CGContext(
        data: base,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    )
    guard let context else { throw CocoaError(.fileWriteUnknown) }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
}
