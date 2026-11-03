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
let amber = Color(red: 0.96, green: 0.62, blue: 0.16)
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
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.rounded(.headline))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color(red: 0.22, green: 0.55, blue: 0.38), Color(red: 0.10, green: 0.36, blue: 0.24)]
                        : [leafLight, pine],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: pine.opacity(configuration.isPressed ? 0.1 : 0.28), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.22), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.rounded(.subheadline))
            .foregroundStyle(pine)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(pine.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(pine.opacity(0.45), lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.22), value: configuration.isPressed)
    }
}

struct FriendlyEmpty: View {
    var symbol: String
    var title: String
    var button: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.rounded(.title2))
                .foregroundStyle(pine)
                .frame(width: 52, height: 52)
                .background(pine.opacity(0.12), in: Circle())
            Text(title).font(.rounded(.headline))
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
            .font(.rounded(.subheadline))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(amber, in: Capsule())
            .foregroundStyle(Color(red: 0.22, green: 0.12, blue: 0.02))
            .accessibilityLabel("Price \(Money.string(cents: cents))")
    }
}

struct InfoChip: View {
    var text: String
    var symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.rounded(.caption, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(pine.opacity(0.12), in: Capsule())
            .foregroundStyle(pine)
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

    private let titles = ["Booked", "In progress", "Done", "Paid"]
    private let symbols = ["calendar", "wrench.and.screwdriver.fill", "flag.fill", "dollarsign.circle.fill"]

    var body: some View {
        if step >= 0 {
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    VStack(spacing: 6) {
                        Image(systemName: index < step ? "checkmark.circle.fill" : symbols[index])
                            .font(.title3)
                            .foregroundStyle(index <= step ? .white : Color.secondary)
                            .frame(width: 36, height: 36)
                            .background(index <= step ? (index == step ? amber : pine) : Color.primary.opacity(0.08), in: Circle())
                            .symbolEffect(.bounce, value: step)
                        Text(title)
                            .font(.rounded(.caption2, weight: index == step ? .bold : .semibold))
                            .foregroundStyle(index <= step ? ink : Color.secondary)
                            .multilineTextAlignment(.center)
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
    var tint: Color = pine

    var body: some View {
        Text(title)
            .font(.rounded(.caption2, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
            .accessibilityLabel("Status \(title)")
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
            top = Color(red: 0.16, green: 0.48, blue: 0.32)
            bottom = Color(red: 0.05, green: 0.22, blue: 0.14)
        } else {
            top = leafLight
            bottom = Color(red: 0.12, green: 0.48, blue: 0.30)
        }
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "leaf.fill")
                .font((prominent ? Font.title3 : Font.body).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: prominent ? 48 : 32, height: prominent ? 48 : 32)
                .background(.white.opacity(0.18), in: Circle())
            Text("Contractor Pros")
                .font(.rounded(prominent ? .title2 : .title3))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
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
        return amber
    case .canceled, .cancelled:
        return Color.secondary
    default:
        return pine
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
    @State private var tab = ProcessInfo.processInfo.environment["SCREENSHOT"] == "map" ? 1 : 0

    var body: some View {
        TabView(selection: $tab) {
            CustomerHome()
                .tabItem { Label("Jobs", systemImage: "list.bullet.rectangle.fill") }
                .badge(model.unreadTotal > 0 ? Text("\(model.unreadTotal)") : nil)
                .tag(0)
            NearbyPricesPage(readOnly: true)
                .tabItem { Label("Map", systemImage: "map.fill") }
                .tag(1)
        }
    }
}

struct ProShell: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            ProHome()
                .tabItem { Label("Jobs", systemImage: "list.bullet.rectangle.fill") }
                .badge(model.unreadTotal > 0 ? Text("\(model.unreadTotal)") : nil)
            NearbyPricesPage(readOnly: false)
                .tabItem { Label("Map", systemImage: "map.fill") }
        }
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
                .font(.caption2.weight(.bold))
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
    let payout = BookingFee.payoutCents(priceCents: priceCents, percent: percent)
    return "Agreed price \(Money.string(cents: priceCents)). Contractor keeps \(percent)% (\(Money.string(cents: fee))). The contractor receives \(Money.string(cents: payout)), before processing. \(FeeSchedule.launch.processingNote) Status: authorized, not captured."
}
