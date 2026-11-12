import SwiftUI
import UIKit

enum Air {
    static let canvas = dynamic(light: (0.980, 0.988, 0.976), dark: (0.07, 0.09, 0.08))
    static let card = dynamic(light: (1, 1, 1), dark: (0.11, 0.15, 0.13))
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
