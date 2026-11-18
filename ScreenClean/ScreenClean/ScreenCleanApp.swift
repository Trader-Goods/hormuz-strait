import SwiftUI

@main
struct ScreenCleanApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

enum Shot: String {
    case home, clean

    static var current: Shot? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-screenshot"), index + 1 < arguments.count {
            return Shot(rawValue: arguments[index + 1])
        }
        return nil
    }
}

struct RootView: View {
    @State private var cleaning = Shot.current == .clean

    var body: some View {
        ZStack {
            if cleaning {
                CleaningScreen {
                    cleaning = false
                }
            } else {
                HomeScreen {
                    cleaning = true
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: cleaning)
    }
}
