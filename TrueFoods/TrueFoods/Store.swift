import SwiftUI

@MainActor
final class Pantry: ObservableObject {
    @Published var history: [Product] = []
    @Published var favorites: [Product] = []
    @Published var flags = PersonalFlags()
    @Published var appearance: AppearanceChoice = .light

    private let folder: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("TrueFoods", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        history = read("history.json")
        favorites = read("favorites.json")
        if let data = try? Data(contentsOf: folder.appendingPathComponent("flags.json")),
           let saved = try? decoder.decode(PersonalFlags.self, from: data) {
            flags = saved
        }
        if let raw = UserDefaults.standard.string(forKey: "truefoods.appearance"),
           let choice = AppearanceChoice(rawValue: raw) {
            appearance = choice
        }
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    func remember(_ product: Product) {
        history.removeAll { $0.id == product.id }
        history.insert(product, at: 0)
        history = Array(history.prefix(30))
        write(history, "history.json")
    }

    func toggleFavorite(_ product: Product) {
        if favorites.contains(where: { $0.id == product.id }) {
            favorites.removeAll { $0.id == product.id }
        } else {
            favorites.insert(product, at: 0)
        }
        write(favorites, "favorites.json")
    }

    func isFavorite(_ product: Product) -> Bool {
        favorites.contains { $0.id == product.id }
    }

    func saveFlags() {
        if let data = try? encoder.encode(flags) {
            try? data.write(to: folder.appendingPathComponent("flags.json"), options: .atomic)
        }
    }

    func saveAppearance() {
        UserDefaults.standard.set(appearance.rawValue, forKey: "truefoods.appearance")
    }

    private func read(_ name: String) -> [Product] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
              let items = try? decoder.decode([Product].self, from: data) else { return [] }
        return items
    }

    private func write(_ items: [Product], _ name: String) {
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}
