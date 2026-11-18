import SwiftUI
import UIKit

struct CleaningScreen: View {
    var onFinish: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var end = Date().addingTimeInterval(CleaningClock.duration)
    @State private var savedBrightness: CGFloat?
    @State private var finished = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let remaining = CleaningClock.remaining(at: context.date, end: end)
            let elapsed = CleaningClock.duration - end.timeIntervalSince(context.date)
            ZStack {
                Color.black
                VStack(spacing: 0) {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.white.opacity(0.16))
                            .frame(width: max(2, geo.size.width * CGFloat(remaining) / 60), height: 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 2)
                    .padding(.top, 10)
                    .padding(.horizontal, 16)
                    .accessibilityHidden(true)
                    Spacer()
                    if elapsed < 4 {
                        Text("Hold to stop")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.28))
                            .padding(.bottom, 8)
                    }
                    Text(CleaningClock.label(remaining))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.22))
                        .monospacedDigit()
                        .padding(.bottom, 22)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: remaining) { _, value in
                if value == 0 {
                    finish()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Cleaning")
            .accessibilityValue("\(remaining) seconds left")
            .accessibilityHint("Hold to stop early")
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .contentShape(Rectangle())
        .highPriorityGesture(
            LongPressGesture(minimumDuration: CleaningClock.holdToExit)
                .onEnded { _ in finish() }
        )
        .onAppear(perform: begin)
        .onDisappear(perform: restore)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                finish()
            }
        }
    }

    private func begin() {
        UIApplication.shared.isIdleTimerDisabled = true
        if savedBrightness == nil {
            savedBrightness = UIScreen.main.brightness
        }
        UIScreen.main.brightness = CleaningClock.panelBrightness
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        restore()
        onFinish()
    }

    private func restore() {
        UIApplication.shared.isIdleTimerDisabled = false
        if let savedBrightness {
            UIScreen.main.brightness = savedBrightness
            self.savedBrightness = nil
        }
    }
}
