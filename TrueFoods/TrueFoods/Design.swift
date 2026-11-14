import SwiftUI
import UIKit

enum Air {
    static let canvas = dynamic(light: (0.925, 0.955, 0.925), dark: (0.07, 0.09, 0.08))
    static let card = dynamic(light: (0.975, 0.988, 0.976), dark: (0.11, 0.15, 0.13))
    static let ink = dynamic(light: (0.10, 0.16, 0.12), dark: (0.95, 0.97, 0.96))
    static let secondary = dynamic(light: (0.24, 0.33, 0.27), dark: (0.76, 0.83, 0.78))
    static let leaf = dynamic(light: (0.122, 0.420, 0.227), dark: (0.56, 0.80, 0.66))
    static let leafButton = Color(red: 0.122, green: 0.420, blue: 0.227)
    static let goodWash = dynamic(light: (0.925, 0.965, 0.935), dark: (0.12, 0.22, 0.16))
    static let goodInk = dynamic(light: (0.10, 0.36, 0.20), dark: (0.78, 0.93, 0.84))
    static let citrusWash = dynamic(light: (1.0, 0.965, 0.91), dark: (0.24, 0.18, 0.10))
    static let citrusInk = dynamic(light: (0.48, 0.33, 0.06), dark: (0.98, 0.86, 0.62))
    static let tomatoWash = dynamic(light: (0.992, 0.925, 0.918), dark: (0.24, 0.12, 0.12))
    static let tomatoInk = dynamic(light: (0.557, 0.184, 0.157), dark: (0.98, 0.78, 0.74))
    static let line = dynamic(light: (0.90, 0.93, 0.91), dark: (1, 1, 1), darkAlpha: 0.12)

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double), darkAlpha: Double = 1) -> Color {
        Color(uiColor: UIColor { trait in
            let pick = trait.userInterfaceStyle == .dark ? dark : light
            let alpha = trait.userInterfaceStyle == .dark ? darkAlpha : 1
            return UIColor(red: pick.0, green: pick.1, blue: pick.2, alpha: alpha)
        })
    }
}

struct AiryTitle: ViewModifier {
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 34

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(Air.ink)
            .lineSpacing(4)
    }
}

struct AiryBody: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .regular, design: .default))
            .foregroundStyle(Air.ink)
            .lineSpacing(6)
    }
}

struct AirySecondary: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .font(.system(size: size, weight: .regular, design: .default))
            .foregroundStyle(Air.secondary)
            .lineSpacing(6)
    }
}

extension View {
    func airyTitle() -> some View { modifier(AiryTitle()) }
    func airyBody() -> some View { modifier(AiryBody()) }
    func airySecondary() -> some View { modifier(AirySecondary()) }
}

struct BigLabel: View {
    var title: String
    var systemImage: String
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
    }
}

struct FilledButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white)
            .background(Air.leafButton)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Air.leafButton)
            .background(Air.card)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Air.leafButton.opacity(0.45), lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.88 : 1)
    }
}

struct SoftCard<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Air.card)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Air.line, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 14, y: 6)
    }
}

struct ProducePhoto: View {
    var name: String
    var height: CGFloat = 220

    var body: some View {
        Color.clear
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background {
                Image(name)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct ToneRow: View {
    var title: String
    var detail: String
    var tone: ScoreTone
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ink)
                .accessibilityHidden(true)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(word + " · " + title)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: size, weight: .regular))
                    .foregroundStyle(ink)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wash)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var word: String {
        switch tone {
        case .good: return "Good"
        case .limit: return "Limit"
        case .avoid: return "Avoid"
        case .note: return "Note"
        }
    }

    private var symbol: String {
        switch tone {
        case .good: return "checkmark.circle.fill"
        case .limit: return "minus.circle.fill"
        case .avoid: return "exclamationmark.circle.fill"
        case .note: return "info.circle.fill"
        }
    }

    private var wash: Color {
        switch tone {
        case .good: return Air.goodWash
        case .limit: return Air.citrusWash
        case .avoid: return Air.tomatoWash
        case .note: return Air.canvas
        }
    }

    private var ink: Color {
        switch tone {
        case .good: return Air.goodInk
        case .limit: return Air.citrusInk
        case .avoid: return Air.tomatoInk
        case .note: return Air.ink
        }
    }
}

/// One color for every score number. Low scores are red, the middle moves through orange and yellow, 94 is green, and 95–100 is gold.
enum ScoreColor {
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        var color: Color {
            Color(red: red, green: green, blue: blue)
        }
    }

    static let goldMinimum = 95
    /// Darkened #D4A017 so the digits stay readable on a light gold card.
    static let gold = RGB(red: 140.0 / 255, green: 106.0 / 255, blue: 16.0 / 255)
    static let goldRich = RGB(red: 212.0 / 255, green: 160.0 / 255, blue: 23.0 / 255)
    static let goldWash = RGB(red: 247.0 / 255, green: 224.0 / 255, blue: 138.0 / 255)
    static let goldHighlight = RGB(red: 232.0 / 255, green: 196.0 / 255, blue: 74.0 / 255)

    struct Fill: Equatable {
        var top: RGB
        var bottom: RGB
        var border: RGB
    }

    /// Light tint of the score color, or the rich gold gradient from 95 up.
    static func fill(for score: Int) -> Fill {
        let value = min(100, max(0, score))
        if value >= goldMinimum {
            return Fill(top: goldWash, bottom: goldRich, border: gold)
        }
        let ink = rgb(for: value)
        let white = RGB(red: 1, green: 1, blue: 1)
        return Fill(
            top: mix(ink, white, 0.86),
            bottom: mix(ink, white, 0.70),
            border: ink
        )
    }

    static func rgb(for score: Int) -> RGB {
        let value = min(100, max(0, score))
        if value >= goldMinimum {
            return gold
        }
        let stops: [(Int, RGB)] = [
            (0, RGB(red: 180.0 / 255, green: 35.0 / 255, blue: 24.0 / 255)),
            (50, RGB(red: 161.0 / 255, green: 78.0 / 255, blue: 0)),
            (72, RGB(red: 122.0 / 255, green: 104.0 / 255, blue: 0)),
            (94, RGB(red: 31.0 / 255, green: 107.0 / 255, blue: 58.0 / 255))
        ]
        for index in 0..<(stops.count - 1) {
            let left = stops[index]
            let right = stops[index + 1]
            if value <= right.0 {
                let span = Double(right.0 - left.0)
                let t = span == 0 ? 0 : Double(value - left.0) / span
                return mix(left.1, right.1, t)
            }
        }
        return stops[stops.count - 1].1
    }

    private static func mix(_ start: RGB, _ end: RGB, _ t: Double) -> RGB {
        RGB(
            red: start.red + (end.red - start.red) * t,
            green: start.green + (end.green - start.green) * t,
            blue: start.blue + (end.blue - start.blue) * t
        )
    }
}

struct ScoreBadge: View {
    var score: Int
    var diameter: CGFloat = 120

    private var onGold: Bool { score >= ScoreColor.goldMinimum }

    var body: some View {
        let ink = onGold ? Air.ink : ScoreColor.rgb(for: score).color
        ZStack {
            Circle()
                .stroke(ring, lineWidth: max(4, diameter * 0.07))
            Text("\(score)")
                .font(.system(size: diameter * 0.34, weight: .bold, design: .rounded))
                .foregroundStyle(ink)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("Score \(score) out of 100")
    }

    private var ring: AnyShapeStyle {
        if onGold {
            return AnyShapeStyle(Air.ink)
        }
        return AnyShapeStyle(ScoreColor.rgb(for: score).color)
    }
}

struct ScoreCard<Content: View>: View {
    var score: Int
    var content: Content

    init(score: Int, @ViewBuilder content: () -> Content) {
        self.score = score
        self.content = content()
    }

    var body: some View {
        let fill = ScoreColor.fill(for: score)
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    LinearGradient(
                        colors: [fill.top.color, fill.bottom.color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    if score >= ScoreColor.goldMinimum {
                        LinearGradient(
                            colors: [Color.white.opacity(0.38), Color.white.opacity(0)],
                            startPoint: .top,
                            endPoint: .center
                        )
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(fill.border.color, lineWidth: score >= ScoreColor.goldMinimum ? 2 : 1.5)
            )
            .shadow(color: fill.border.color.opacity(0.18), radius: 12, y: 6)
    }
}
