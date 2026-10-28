import SwiftUI

@main
struct ContractorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .tint(pine)
        }
    }
}

let ink = Color(red: 0.11, green: 0.14, blue: 0.18)
let pine = Color(red: 0.12, green: 0.42, blue: 0.29)
let clay = Color(red: 0.77, green: 0.40, blue: 0.23)
let paper = Color(red: 0.96, green: 0.94, blue: 0.90)

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
