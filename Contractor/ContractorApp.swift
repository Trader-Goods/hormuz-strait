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
        tab.configureWithDefaultBackground()
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

let ink = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1)
        : UIColor(red: 0.11, green: 0.14, blue: 0.18, alpha: 1)
})
let pine = Color(red: 0.12, green: 0.42, blue: 0.29)
let clay = Color(red: 0.77, green: 0.40, blue: 0.23)
let paper = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1)
        : UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1)
})

enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

struct PriceChip: View {
    var cents: Int

    var body: some View {
        Text(Money.compact(cents: cents))
            .font(.subheadline.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(pine.opacity(0.14), in: Capsule())
            .foregroundStyle(pine)
            .accessibilityLabel("Price \(Money.string(cents: cents))")
    }
}

struct StatusBadge: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .accessibilityLabel("Status \(title)")
    }
}

struct BrandHeader<Trailing: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var trailing: Trailing

    private var gradient: LinearGradient {
        let top: Color
        let bottom: Color
        if colorScheme == .dark {
            top = Color(red: 0.20, green: 0.52, blue: 0.38)
            bottom = Color(red: 0.07, green: 0.26, blue: 0.18)
        } else {
            top = Color(red: 0.18, green: 0.55, blue: 0.38)
            bottom = pine
        }
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "leaf.fill")
                .font(.body.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.18), in: Circle())
            Text("Contractor Pros")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            gradient.ignoresSafeArea(edges: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

extension BrandHeader where Trailing == EmptyView {
    init() {
        self.init(trailing: { EmptyView() })
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if let session = model.session {
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

struct CustomerShell: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            CustomerHome()
                .tabItem { Label("Jobs", systemImage: "list.bullet") }
                .badge(model.unreadTotal > 0 ? Text("\(model.unreadTotal)") : nil)
            NearbyPricesPage(readOnly: true)
                .tabItem { Label("Map", systemImage: "map") }
        }
    }
}

struct ProShell: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            ProHome()
                .tabItem { Label("Jobs", systemImage: "list.bullet") }
                .badge(model.unreadTotal > 0 ? Text("\(model.unreadTotal)") : nil)
            NearbyPricesPage(readOnly: false)
                .tabItem { Label("Map", systemImage: "map") }
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
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.06), radius: 12, y: 4)
    }
}

func paymentLine(priceCents: Int, percent: Int) -> String {
    let fee = BookingFee.feeCents(priceCents: priceCents, percent: percent)
    let payout = BookingFee.payoutCents(priceCents: priceCents, percent: percent)
    return "Agreed price \(Money.string(cents: priceCents)). Contractor keeps \(percent)% (\(Money.string(cents: fee))). The contractor receives \(Money.string(cents: payout)), before processing. \(FeeSchedule.launch.processingNote) Status: authorized, not captured."
}
