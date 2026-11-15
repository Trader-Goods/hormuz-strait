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

/// One color for every score. 95–100 is gold. 94 is bright green, then the hue falls straight toward red. The worst scores are pure red and get brighter, never purple or pink.
enum ScoreColor {
    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        var color: Color {
            Color(red: red, green: green, blue: blue)
        }
    }

    struct HSB: Equatable {
        /// 0...1 around the wheel. 0 is red.
        var hue: Double
        var saturation: Double
        var brightness: Double
    }

    static let goldMinimum = 95
    static let redCeiling = 45
    /// Darkened #D4A017 so a gold number can stay readable if it sits on a light gold card.
    static let gold = RGB(red: 140.0 / 255, green: 106.0 / 255, blue: 16.0 / 255)
    static let goldRich = RGB(red: 212.0 / 255, green: 160.0 / 255, blue: 23.0 / 255)
    static let goldHighlight = RGB(red: 232.0 / 255, green: 196.0 / 255, blue: 74.0 / 255)
    static let unknownGray = RGB(red: 0.42, green: 0.45, blue: 0.48)

    struct Fill: Equatable {
        var top: RGB
        var bottom: RGB
        var border: RGB
    }

    /// Solid saturated fill. Gold stays a rich gold. Every other score uses its vivid hue, not a pale tint.
    static func fill(for score: Int) -> Fill {
        let value = min(100, max(0, score))
        if value >= goldMinimum {
            return Fill(top: goldHighlight, bottom: goldRich, border: gold)
        }
        let solid = rgb(for: value)
        return Fill(top: solid, bottom: solid, border: solid)
    }

    /// A flagged ingredient paints the card bright red even when the number is high.
    static func colorScore(numeric: Int, notes: [IngredientNote]) -> Int {
        if notes.contains(where: { $0.level == "avoid" || $0.level == "limit" }) {
            return 0
        }
        return min(100, max(0, numeric))
    }

    static func inkIsWhite(for colorScore: Int) -> Bool {
        relativeLuminance(fill(for: colorScore).bottom) < 0.35
    }

    private static func relativeLuminance(_ color: RGB) -> Double {
        func channel(_ value: Double) -> Double {
            let clamped = min(1, max(0, value))
            return clamped <= 0.04045 ? clamped / 12.92 : pow((clamped + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    static func rgb(for score: Int) -> RGB {
        let value = min(100, max(0, score))
        if value >= goldMinimum {
            return goldRich
        }
        return rgb(from: hsb(for: value))
    }

    /// Hue, saturation, and brightness for a score. Below 95, saturation and brightness stay high.
    static func hsb(for score: Int) -> HSB {
        let value = min(100, max(0, score))
        if value >= goldMinimum {
            return HSB(hue: 43.5 / 360.0, saturation: 0.89, brightness: 0.83)
        }
        if value <= redCeiling {
            let lighter = Double(value) / Double(redCeiling)
            return HSB(hue: clampedHue(2), saturation: 1, brightness: 0.40 + 0.55 * lighter)
        }
        let t = Double(value - redCeiling) / Double(94 - redCeiling)
        let degrees = 2 + (120 - 2) * t
        return HSB(hue: clampedHue(degrees), saturation: 1, brightness: 0.98)
    }

    /// Keeps every score hue on the green-to-red side. Nothing can wrap into 300–360 (pink, magenta, purple).
    private static func clampedHue(_ degrees: Double) -> Double {
        var wrapped = degrees.truncatingRemainder(dividingBy: 360)
        if wrapped < 0 { wrapped += 360 }
        if wrapped >= 300 { return 0 }
        if wrapped > 120 { return 120.0 / 360.0 }
        return wrapped / 360.0
    }

    private static func rgb(from hsb: HSB) -> RGB {
        let hue = hsb.hue - floor(hsb.hue)
        let saturation = min(1, max(0, hsb.saturation))
        let brightness = min(1, max(0, hsb.brightness))
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - Double(Int(sector))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - fraction * saturation)
        let t = brightness * (1 - (1 - fraction) * saturation)
        switch index {
        case 0: return RGB(red: brightness, green: t, blue: p)
        case 1: return RGB(red: q, green: brightness, blue: p)
        case 2: return RGB(red: p, green: brightness, blue: t)
        case 3: return RGB(red: p, green: q, blue: brightness)
        case 4: return RGB(red: t, green: p, blue: brightness)
        default: return RGB(red: brightness, green: p, blue: q)
        }
    }
}

struct ScoreBadge: View {
    var score: Int
    var colorScore: Int? = nil
    var unknown: Bool = false
    var diameter: CGFloat = 120

    private var paint: Int { colorScore ?? score }

    var body: some View {
        let ring = unknown ? ScoreColor.unknownGray.color : ScoreColor.rgb(for: paint).color
        ZStack {
            Circle()
                .stroke(ring, lineWidth: max(5, diameter * 0.08))
            Text(unknown ? "- -" : "\(score)")
                .font(.system(size: diameter * (unknown ? 0.28 : 0.32), weight: .bold, design: .rounded))
                .scoreInk(paint, unknown: unknown)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel(unknown ? "Score not available, out of 100" : "Score \(score) out of 100")
    }
}

struct ScoreInk: ViewModifier {
    var colorScore: Int
    var unknown: Bool = false

    func body(content: Content) -> some View {
        let white = unknown || ScoreColor.inkIsWhite(for: colorScore)
        if white {
            content
                .foregroundStyle(Color.white)
                .shadow(color: Color.black.opacity(0.45), radius: 1.5, y: 1)
        } else {
            content.foregroundStyle(Color(red: 0.07, green: 0.07, blue: 0.07))
        }
    }
}

extension View {
    func scoreInk(_ colorScore: Int, unknown: Bool = false) -> some View {
        modifier(ScoreInk(colorScore: colorScore, unknown: unknown))
    }
}

struct ScoreCard<Content: View>: View {
    var score: Int
    var unknown: Bool = false
    var content: Content

    init(score: Int, unknown: Bool = false, @ViewBuilder content: () -> Content) {
        self.score = score
        self.unknown = unknown
        self.content = content()
    }

    var body: some View {
        let fill = unknown
            ? ScoreColor.Fill(top: ScoreColor.unknownGray, bottom: ScoreColor.unknownGray, border: ScoreColor.unknownGray)
            : ScoreColor.fill(for: score)
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
