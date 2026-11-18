import SwiftUI

struct HomeScreen: View {
    var start: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var buttonSide = 228

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 36)
                    Button(action: start) {
                        ZStack {
                            Circle()
                                .fill(
                                    RadialGradient(
                                        colors: [
                                            Color(white: 0.22),
                                            Color(white: 0.07),
                                            Color.black
                                        ],
                                        center: UnitPoint(x: 0.32, y: 0.28),
                                        startRadius: 8,
                                        endRadius: buttonSide * 0.62
                                    )
                                )
                            Circle()
                                .stroke(Color.white.opacity(0.42), lineWidth: 1.5)
                            VStack(spacing: 4) {
                                Text("Clean")
                                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                                Text("1 minute")
                                    .font(.system(.title3, design: .rounded, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.72))
                            }
                            .foregroundStyle(.white)
                        }
                        .frame(width: min(buttonSide, 280), height: min(buttonSide, 280))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clean the screen")
                    .accessibilityHint("Turns the glass black for one minute. Wiping will not tap or swipe anything. Hold the black screen to stop early.")

                    VStack(spacing: 10) {
                        Text("Screen Clean")
                            .font(.system(.title, design: .rounded, weight: .bold))
                        Text("The glass goes black so fingerprints and dust show up. Wipe with a soft cloth. Tilt the phone under a lamp.")
                            .font(.body)
                            .foregroundStyle(Color.white.opacity(0.78))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)

                    Text("Nothing leaves this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.55))
                        .padding(.bottom, 28)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
    }
}
