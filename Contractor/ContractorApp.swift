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
}

let ink = Color(red: 0.11, green: 0.14, blue: 0.18)
let pine = Color(red: 0.12, green: 0.42, blue: 0.29)
let clay = Color(red: 0.77, green: 0.40, blue: 0.23)
let paper = Color(red: 0.96, green: 0.94, blue: 0.90)

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
                        CustomerHome()
                    } else {
                        ProHome()
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

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

func paymentLine(priceCents: Int, percent: Int) -> String {
    let fee = BookingFee.feeCents(priceCents: priceCents, percent: percent)
    let payout = BookingFee.payoutCents(priceCents: priceCents, percent: percent)
    return "Agreed price \(Money.string(cents: priceCents)). Contractor keeps \(percent)% (\(Money.string(cents: fee))). The contractor receives \(Money.string(cents: payout)), before processing. \(FeeSchedule.launch.processingNote) Status: authorized, not captured."
}
