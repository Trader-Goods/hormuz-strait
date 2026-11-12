import SwiftUI

@main
struct TrueFoodsApp: App {
    @StateObject private var pantry = Pantry()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(pantry)
                .preferredColorScheme(pantry.colorScheme)
        }
    }
}
