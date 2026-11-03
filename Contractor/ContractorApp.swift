import SwiftUI

@main
struct ContractorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(pine)
                .onOpenURL { url in
                    Task { await model.handleAuthCallback(url) }
                }
        }
    }

    init() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        let green = UIColor(red: 0.18, green: 0.62, blue: 0.36, alpha: 1)
        tab.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.06, green: 0.10, blue: 0.08, alpha: 1)
                : UIColor(red: 0.97, green: 0.98, blue: 0.96, alpha: 1)
        }
        tab.stackedLayoutAppearance.selected.iconColor = green
        tab.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: green]
        UITabBar.appearance().tintColor = green
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.05, green: 0.09, blue: 0.07, alpha: 1)
                : UIColor(red: 0.945, green: 0.965, blue: 0.945, alpha: 1)
        }
        nav.titleTextAttributes = [
            .foregroundColor: UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.93, green: 0.96, blue: 0.93, alpha: 1)
                    : UIColor(red: 0.10, green: 0.16, blue: 0.12, alpha: 1)
            }
        ]
        nav.shadowColor = .clear
        UINavigationBar.appearance().tintColor = green
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }
}

let ink = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.93, green: 0.96, blue: 0.93, alpha: 1)
        : UIColor(red: 0.10, green: 0.16, blue: 0.12, alpha: 1)
})
let pine = Color(red: 0.18, green: 0.62, blue: 0.36)
let leafLight = Color(red: 0.235, green: 0.796, blue: 0.498)
/// Dark enough for white button labels and for text on the light background.
let buttonGreen = Color(red: 0.078, green: 0.42, blue: 0.22)
let buttonGreenDeep = Color(red: 0.05, green: 0.29, blue: 0.16)
let pineText = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.55, green: 0.85, blue: 0.65, alpha: 1)
        : UIColor(red: 0.06, green: 0.35, blue: 0.19, alpha: 1)
})
let inkSoft = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.78, green: 0.84, blue: 0.79, alpha: 1)
        : UIColor(red: 0.22, green: 0.29, blue: 0.25, alpha: 1)
})
let amber = Color(red: 0.96, green: 0.62, blue: 0.16)
let amberText = Color(red: 0.28, green: 0.14, blue: 0.02)
let clay = amber
let paper = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.05, green: 0.09, blue: 0.07, alpha: 1)
        : UIColor(red: 0.945, green: 0.965, blue: 0.945, alpha: 1)
})
let cardFill = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.09, green: 0.16, blue: 0.12, alpha: 1)
        : .white
})

extension Font {
    static func rounded(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .rounded).weight(weight)
    }
}

enum AppFont {
    static func text(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        let scaled = UIFontMetrics(forTextStyle: uiStyle(style)).scaledValue(for: size)
        return .system(size: max(size, scaled), weight: weight, design: .rounded)
    }

    private static func uiStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        if style == .largeTitle { return .largeTitle }
        if style == .title { return .title1 }
        if style == .title2 { return .title2 }
        if style == .title3 { return .title3 }
        if style == .headline { return .headline }
        if style == .body { return .body }
        if style == .callout { return .callout }
        if style == .subheadline { return .subheadline }
        if style == .footnote { return .footnote }
        if style == .caption { return .caption1 }
        if style == .caption2 { return .caption2 }
        return .body
    }
}

private struct AppTextModifier: ViewModifier {
    var size: CGFloat
    var weight: Font.Weight
    var style: Font.TextStyle
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(AppFont.text(size, weight: weight, relativeTo: style))
    }
}

extension View {
    func appText(_ size: CGFloat = 18, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(AppTextModifier(size: size, weight: weight, style: style))
    }
}

func serviceTint(_ job: JobRecord) -> Color {
    switch job.serviceType {
    case "mowing": return Color(red: 0.18, green: 0.62, blue: 0.36)
    case "edging": return Color(red: 0.12, green: 0.55, blue: 0.50)
    case "trimming": return Color(red: 0.36, green: 0.62, blue: 0.28)
    case "hedgeTrim": return Color(red: 0.16, green: 0.42, blue: 0.28)
    case "leafCleanup": return Color(red: 0.86, green: 0.55, blue: 0.16)
    case "mulching": return Color(red: 0.55, green: 0.38, blue: 0.20)
    case "gutters": return Color(red: 0.18, green: 0.48, blue: 0.62)
    case "junkRemoval": return Color(red: 0.90, green: 0.42, blue: 0.22)
    case "moving": return Color(red: 0.93, green: 0.50, blue: 0.16)
    default: return job.category == .moving ? amber : pine
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(pressed: configuration.isPressed) { configuration.label }
    }
}

private struct PrimaryButtonBody<Label: View>: View {
    var pressed: Bool
    @ViewBuilder var label: Label
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        label
            .font(AppFont.text(20, weight: .semibold, relativeTo: .headline))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                LinearGradient(colors: [buttonGreen, buttonGreenDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: buttonGreen.opacity(pressed ? 0.1 : 0.28), radius: 10, y: 4)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(.spring(duration: 0.22), value: pressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(pressed: configuration.isPressed) { configuration.label }
    }
}

private struct SecondaryButtonBody<Label: View>: View {
    var pressed: Bool
    @ViewBuilder var label: Label
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        label
            .font(AppFont.text(20, weight: .semibold, relativeTo: .headline))
            .multilineTextAlignment(.center)
            .foregroundStyle(pineText)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.001), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(pineText, lineWidth: 2))
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(.spring(duration: 0.22), value: pressed)
    }
}

func yardPhoto(for serviceID: String) -> String? {
    switch serviceID {
    case "mowing": return "yard-mow"
    case "hedgeTrim", "trimming": return "yard-hedge"
    case "leafCleanup", "junkRemoval": return "yard-leaves"
    case "mulching": return "yard-mulch"
    case "moving": return "yard-move"
    case "landscaping", "yardOther": return "yard-beds"
    default: return nil
    }
}

struct PhotoTile: View {
    var name: String
    var title: String
    var selected: Bool

    var body: some View {
        VStack(spacing: 0) {
            Image(name)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 112)
                .clipped()
                .accessibilityHidden(true)
            Text(title)
                .appText(18, weight: .bold)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(Color(red: 0.05, green: 0.08, blue: 0.06))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(selected ? Color.white : Color.clear, lineWidth: 3)
        )
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

struct FriendlyEmpty: View {
    var symbol: String
    var title: String
    var photo: String? = nil
    var button: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let photo {
                Image(photo)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 200)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: symbol)
                    .appText(28, weight: .bold, relativeTo: .title)
                    .foregroundStyle(pineText)
                    .frame(width: 64, height: 64)
                    .background(pine.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)
            }
            Text(title).appText(22, weight: .bold, relativeTo: .title2)
            if let button, let action {
                Button(button, action: action)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

struct PriceChip: View {
    var cents: Int

    var body: some View {
        Text(Money.compact(cents: cents))
            .appText(20, weight: .bold, relativeTo: .headline)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(amber, in: Capsule())
            .foregroundStyle(amberText)
            .accessibilityLabel("Price \(Money.string(cents: cents))")
    }
}

struct InfoChip: View {
    var text: String
    var symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .appText(18, weight: .semibold)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(pine.opacity(0.14), in: Capsule())
            .foregroundStyle(pineText)
    }
}

struct JobProgress: View {
    var status: JobStatus

    private var step: Int {
        switch status {
        case .booked: return 0
        case .inProgress: return 1
        case .awaitingReview, .disputed: return 2
        case .completed, .approved, .payoutProcessing: return 3
        default: return -1
        }
    }

    private let titles = ["Booked", "Working", "Done", "Paid"]
    private let symbols = ["calendar", "wrench.and.screwdriver.fill", "flag.fill", "dollarsign.circle.fill"]

    var body: some View {
        if step >= 0 {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    VStack(spacing: 6) {
                        Image(systemName: index < step ? "checkmark.circle.fill" : symbols[index])
                            .appText(22, weight: .bold, relativeTo: .title2)
                            .foregroundStyle(index <= step ? .white : inkSoft)
                            .frame(width: 48, height: 48)
                            .background(index <= step ? (index == step ? buttonGreen : pineText) : Color.primary.opacity(0.08), in: Circle())
                            .accessibilityHidden(true)
                        Text(title)
                            .appText(18, weight: index == step ? .bold : .semibold)
                            .foregroundStyle(ink)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(index == step ? "\(title), current step" : (index < step ? "\(title), done" : title))
                }
            }
            .animation(.spring(duration: 0.35), value: step)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Job progress, \(titles[step])")
        }
    }
}

struct StatusBadge: View {
    var title: String
    var symbol: String = "circle.fill"
    var tint: Color = pineText

    init(title: String, symbol: String = "circle.fill", tint: Color = pineText) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }

    init(status: JobStatus) {
        title = status.title
        symbol = status.symbol
        tint = statusTint(status)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appText(18, weight: .semibold)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.16), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status \(title)")
    }
}

struct NextStepBar: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(pineText)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appText(18, weight: .semibold)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(pine.opacity(0.14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("What happens next. \(text)")
    }
}

func nextStepText(_ job: JobRecord, role: UserRole) -> String {
    switch (role, job.status) {
    case (.customer, .posted), (.customer, .open), (.customer, .awaitingAcceptance), (.customer, .draft):
        return "A pro near you can accept this price."
    case (.customer, .awaitingPayment):
        return "Confirm and pay to book this pro."
    case (.customer, .booked):
        return "The pro starts when they arrive."
    case (.customer, .inProgress):
        return "The pro is working. You approve it when they finish."
    case (.customer, .awaitingReview):
        return "Look it over, then approve the job."
    case (.customer, .disputed):
        return "You reported a problem. The pro can see your note."
    case (.customer, .completed), (.customer, .approved), (.customer, .payoutProcessing):
        return "This job is finished. No card was charged in this test version."
    case (.pro, .posted), (.pro, .open), (.pro, .awaitingAcceptance):
        return "Accept this job if the price and place work for you."
    case (.pro, .awaitingPayment):
        return "Wait for the customer to confirm. You are not booked yet."
    case (.pro, .booked):
        return "Start the job when you arrive."
    case (.pro, .inProgress):
        return "When you finish, send it for approval."
    case (.pro, .awaitingReview):
        return "The customer has 48 hours to approve. This test version does not send money."
    case (.pro, .disputed):
        return "The customer reported a problem. Read their note."
    case (.pro, .completed), (.pro, .approved), (.pro, .payoutProcessing):
        return "The customer approved this job. This test version does not send money yet."
    default:
        return "This job is closed."
    }
}

struct ConfirmChoice: View {
    var title: String
    var yes: String
    var no: String = "No"
    var onYes: () -> Void
    var onNo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .appText(28, weight: .bold, relativeTo: .title)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
            Button(yes) {
                Haptic.tap()
                onYes()
            }
            .buttonStyle(PrimaryButtonStyle())
            Button(no) {
                Haptic.tap()
                onNo()
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(paper)
    }
}

struct SuccessCover: View {
    var symbol: String
    var title: String
    var line: String
    var button: String
    var photo: String? = nil
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let photo {
                Image(photo)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 220)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: symbol)
                    .appText(48, weight: .bold, relativeTo: .largeTitle)
                    .foregroundStyle(pineText)
                    .frame(width: 88, height: 88)
                    .background(pine.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)
            }
            Text(title)
                .appText(34, weight: .bold, relativeTo: .largeTitle)
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(line)
                .appText()
                .foregroundStyle(inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Button(button, action: action)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(paper)
    }
}

struct SelectTabAction {
    var call: (Int) -> Void
    func callAsFunction(_ tab: Int) { call(tab) }
}

private struct SelectTabKey: EnvironmentKey {
    static let defaultValue = SelectTabAction { _ in }
}

extension EnvironmentValues {
    var selectTab: SelectTabAction {
        get { self[SelectTabKey.self] }
        set { self[SelectTabKey.self] = newValue }
    }
}

struct AppTab: Identifiable {
    var id: Int
    var title: String
    var symbol: String
    var selectedSymbol: String
}

struct AppTabBar: View {
    @Binding var selection: Int
    var tabs: [AppTab]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(tabs) { tab in
                    let on = selection == tab.id
                    Button {
                        Haptic.tap()
                        selection = tab.id
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: on ? tab.selectedSymbol : tab.symbol)
                                .appText(20, weight: .bold, relativeTo: .headline)
                                .accessibilityHidden(true)
                            Text(tab.title)
                                .appText(18, weight: on ? .bold : .semibold)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: true, vertical: true)
                            Capsule()
                                .fill(on ? pineText : Color.clear)
                                .frame(height: 4)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(on ? pineText : ink)
                        .frame(minWidth: dynamicTypeSize.isAccessibilitySize ? 120 : 76, minHeight: 56)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
    }
}

struct BrandHeader<Trailing: View>: View {
    var prominent = false
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var trailing: Trailing

    private var gradient: LinearGradient {
        let top: Color
        let bottom: Color
        if colorScheme == .dark {
            top = Color(red: 0.10, green: 0.32, blue: 0.22)
            bottom = Color(red: 0.04, green: 0.16, blue: 0.11)
        } else {
            top = Color(red: 0.55, green: 0.86, blue: 0.64)
            bottom = Color(red: 0.32, green: 0.72, blue: 0.48)
        }
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "leaf.fill")
                .appText(prominent ? 28 : 20, weight: .bold, relativeTo: .title2)
                .foregroundStyle(.white)
                .frame(width: prominent ? 56 : 40, height: prominent ? 56 : 40)
                .background(buttonGreen, in: Circle())
                .accessibilityHidden(true)
            Text("Contractor Pros")
                .appText(prominent ? 28 : 22, weight: .bold, relativeTo: prominent ? .title : .title2)
                .foregroundStyle(colorScheme == .dark ? Color.white : ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            trailing
                .appText(18, weight: .semibold)
                .foregroundStyle(colorScheme == .dark ? Color.white : ink)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, prominent ? 22 : 10)
        .background {
            gradient.ignoresSafeArea(edges: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

extension BrandHeader where Trailing == EmptyView {
    init(prominent: Bool = false) {
        self.init(prominent: prominent, trailing: { EmptyView() })
    }
}

extension View {
    func softField() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(duration: 0.22), value: configuration.isPressed)
    }
}

func statusTint(_ status: JobStatus) -> Color {
    switch status {
    case .awaitingPayment, .awaitingReview, .disputed:
        return amberText
    case .canceled, .cancelled:
        return inkSoft
    default:
        return pineText
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    private var screenshot: String? {
        ProcessInfo.processInfo.environment["SCREENSHOT"]
    }

    var body: some View {
        Group {
            if let screenshot {
                ScreenshotHost(name: screenshot)
            } else if let session = model.session {
                if session.phoneVerified {
                    if session.role == .customer {
                        CustomerShell()
                    } else {
                        ProShell()
                    }
                } else {
                    VerifyPhoneView()
                }
            } else {
                WelcomeView()
            }
        }
        .background(paper)
    }
}

private struct ScreenshotHost: View {
    var name: String

    var body: some View {
        switch name {
        case "post":
            NavigationStack { PostJobView() }
        case "pay":
            NavigationStack { JobDetailView(jobID: UUID(uuidString: "30000000-0000-0000-0000-0000000000a2")!) }
        default:
            RootTabs()
        }
    }
}

private struct RootTabs: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let session = model.session {
                if session.role == .customer {
                    CustomerShell()
                } else {
                    ProShell()
                }
            } else {
                WelcomeView()
            }
        }
    }
}

struct CustomerShell: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = CustomerShell.startingTab

    private static var startingTab: Int {
        switch ProcessInfo.processInfo.environment["SCREENSHOT"] {
        case "map": return 2
        case "post": return 0
        default: return 1
        }
    }

    private var tabs: [AppTab] {
        [
            AppTab(id: 0, title: "Post a Job", symbol: "plus.circle", selectedSymbol: "plus.circle.fill"),
            AppTab(id: 1, title: "My Jobs", symbol: "list.bullet.rectangle", selectedSymbol: "list.bullet.rectangle.fill"),
            AppTab(id: 2, title: "Prices Near Me", symbol: "map", selectedSymbol: "map.fill"),
            AppTab(id: 3, title: "Me", symbol: "person", selectedSymbol: "person.fill"),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case 0: PostJobView()
                case 2: NearbyPricesPage(readOnly: true)
                case 3: AccountView()
                default: CustomerHome()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            AppTabBar(selection: $tab, tabs: tabs)
        }
        .environment(\.selectTab, SelectTabAction { tab = $0 })
    }
}

struct ProShell: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = 0

    private var tabs: [AppTab] {
        [
            AppTab(id: 0, title: "Jobs Near Me", symbol: "mappin.and.ellipse", selectedSymbol: "mappin.circle.fill"),
            AppTab(id: 1, title: "My Jobs", symbol: "list.bullet.rectangle", selectedSymbol: "list.bullet.rectangle.fill"),
            AppTab(id: 2, title: "Money", symbol: "dollarsign.circle", selectedSymbol: "dollarsign.circle.fill"),
            AppTab(id: 3, title: "Me", symbol: "person", selectedSymbol: "person.fill"),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case 1: ProHome(lane: 1)
                case 2: EarningsView()
                case 3: AccountView()
                default: ProHome(lane: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            AppTabBar(selection: $tab, tabs: tabs)
        }
        .environment(\.selectTab, SelectTabAction { tab = $0 })
    }
}

struct SkeletonList: View {
    var body: some View {
        ForEach(0..<2, id: \.self) { _ in
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Capsule().fill(Color.primary.opacity(0.1)).frame(width: 120, height: 12)
                    Capsule().fill(Color.primary.opacity(0.1)).frame(height: 16)
                    Capsule().fill(Color.primary.opacity(0.1)).frame(width: 80, height: 12)
                }
            }
            .accessibilityLabel("Loading")
        }
    }
}

struct UnreadBadge: View {
    var count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .appText(18, weight: .bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(clay, in: Capsule())
                .accessibilityLabel("\(count) unread")
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08), radius: 14, y: 6)
    }
}

func paymentLine(priceCents: Int, percent: Int) -> String {
    let fee = BookingFee.feeCents(priceCents: priceCents, percent: percent)
    let keep = BookingFee.payoutCents(priceCents: priceCents, percent: percent)
    return "Price \(Money.string(cents: priceCents)). Contractor Pros keeps \(percent)% (\(Money.string(cents: fee))). The pro gets \(Money.string(cents: keep)) before card fees. \(FeeSchedule.launch.processingNote) The card is held, not charged, in this test version."
}
