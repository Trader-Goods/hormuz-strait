import PhotosUI
import SwiftUI
import UIKit

enum Shot: String {
    case home, result, score, snap

    static var current: Shot? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-screenshot"), index + 1 < arguments.count {
            return Shot(rawValue: arguments[index + 1])
        }
        if let value = ProcessInfo.processInfo.environment["SCREENSHOT"], !value.isEmpty {
            return Shot(rawValue: value)
        }
        return nil
    }
}

struct RootView: View {
    var body: some View {
        Group {
            switch Shot.current {
            case .result:
                NavigationStack { ProductScreen(product: .sampleCrunch) }
            case .score:
                NavigationStack { ProductScreen(product: .sampleCrunch) }
            case .snap:
                NavigationStack { SnapScreen(previewText: Product.sampleLabel) }
            case .home, .none:
                MainTabs()
            }
        }
        .tint(Air.leafButton)
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            HomeScreen()
                .tabItem { Label("Look", systemImage: "leaf") }
            SearchScreen()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            SavedScreen()
                .tabItem { Label("Saved", systemImage: "heart") }
            MeScreen()
                .tabItem { Label("Me", systemImage: "person") }
        }
    }
}

struct HomeScreen: View {
    @EnvironmentObject private var pantry: Pantry
    @State private var scanning = false
    @State private var product: Product?
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ProducePhoto(name: "citrus", height: 230)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TrueFoods")
                            .airyTitle()
                        Text("Scan a barcode or search a name. See the good and the bad, in plain words.")
                            .airyBody()
                    }
                    Button { scanning = true } label: {
                        BigLabel(title: "Scan a barcode", systemImage: "barcode.viewfinder")
                    }
                    .buttonStyle(FilledButton())
                    NavigationLink {
                        SearchScreen(embedded: true)
                    } label: {
                        BigLabel(title: "Search by name", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(QuietButton())
                    if busy {
                        Text("Looking that up…")
                            .airyBody()
                    }
                    if !message.isEmpty {
                        Text(message)
                            .airyBody()
                    }
                    if !pantry.history.isEmpty {
                        Text("Recent")
                            .airyTitle()
                        ForEach(pantry.history.prefix(4)) { item in
                            NavigationLink {
                                ProductScreen(product: item)
                            } label: {
                                FoodCard(product: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    NavigationLink {
                        SnapScreen()
                    } label: {
                        BigLabel(title: "Snap the label", systemImage: "camera")
                    }
                    .buttonStyle(QuietButton())
                    NavigationLink {
                        ProductScreen(product: .sampleCrunch)
                    } label: {
                        BigLabel(title: "Try a sample food", systemImage: "leaf")
                    }
                    .buttonStyle(QuietButton())
                }
                .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 108)
            }
            .background(Air.canvas)
            .navigationBarHidden(true)
            .sheet(isPresented: $scanning) {
                ScanSheet { code in
                    Task { await lookup(code) }
                }
            }
            .navigationDestination(item: $product) { item in
                ProductScreen(product: item)
            }
        }
    }

    private func lookup(_ code: String) async {
        busy = true
        message = ""
        defer { busy = false }
        do {
            let found = try await FoodAPI.lookup(barcode: code)
            product = found
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "We could not look that up."
        }
    }
}

struct SearchScreen: View {
    var embedded = false
    @State private var query = ""
    @State private var results: [Product] = []
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                NavigationStack { content }
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Search")
                    .airyTitle()
                Text("Type a food name, like oats, yogurt, or salsa.")
                    .airyBody()
                TextField("Food name", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 22))
                    .submitLabel(.search)
                    .onSubmit { Task { await run() } }
                Button { Task { await run() } } label: {
                    BigLabel(title: "Search", systemImage: "magnifyingglass")
                }
                .buttonStyle(FilledButton())
                .disabled(query.trimmingCharacters(in: .whitespaces).count < 2)
                if busy { Text("Searching…").airyBody() }
                if !message.isEmpty { Text(message).airyBody() }
                ForEach(results) { item in
                    NavigationLink {
                        ProductScreen(product: item)
                    } label: {
                        FoodCard(product: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 108)
        }
        .background(Air.canvas)
        .navigationTitle(embedded ? "Search" : "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func run() async {
        busy = true
        message = ""
        defer { busy = false }
        do {
            results = try await FoodAPI.search(name: query)
            if results.isEmpty {
                message = "No foods matched that name. Try fewer words, or snap the label."
            }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "Search did not finish."
        }
    }
}

struct SavedScreen: View {
    @EnvironmentObject private var pantry: Pantry

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ProducePhoto(name: "greens", height: 180)
                    Text("Saved")
                        .airyTitle()
                    if pantry.favorites.isEmpty && pantry.history.isEmpty {
                        Text("Foods you save, and foods you look up, stay on this phone.")
                            .airyBody()
                    }
                    if !pantry.favorites.isEmpty {
                        Text("Favorites")
                            .airyTitle()
                        ForEach(pantry.favorites) { item in
                            NavigationLink { ProductScreen(product: item) } label: { FoodCard(product: item) }
                                .buttonStyle(.plain)
                        }
                    }
                    if !pantry.history.isEmpty {
                        Text("History")
                            .airyTitle()
                        ForEach(pantry.history) { item in
                            NavigationLink { ProductScreen(product: item) } label: { FoodCard(product: item) }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 108)
            }
            .background(Air.canvas)
            .navigationBarHidden(true)
        }
    }
}

struct MeScreen: View {
    @EnvironmentObject private var pantry: Pantry

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Me")
                        .airyTitle()
                    Text("These choices stay on this phone. There is no account.")
                        .airyBody()
                    SoftCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Flag foods that conflict")
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                                .foregroundStyle(Air.ink)
                            ForEach(Allergen.allCases) { allergen in
                                Toggle(allergen.title, isOn: allergyBinding(allergen))
                            }
                            Toggle("Watch sugar", isOn: $pantry.flags.lowSugar)
                            Toggle("Watch sodium", isOn: $pantry.flags.lowSodium)
                            Toggle("Vegan", isOn: $pantry.flags.vegan)
                            Toggle("Keep kids in mind", isOn: $pantry.flags.kids)
                            Toggle("Pregnancy", isOn: $pantry.flags.pregnancy)
                        }
                        .font(.title3)
                        .tint(Air.leafButton)
                    }
                    .onChange(of: pantry.flags) { _, _ in pantry.saveFlags() }
                    SoftCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Look")
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                            Picker("Look", selection: $pantry.appearance) {
                                ForEach(AppearanceChoice.allCases) { choice in
                                    Text(choice.title).tag(choice)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .onChange(of: pantry.appearance) { _, _ in pantry.saveAppearance() }
                    AboutBlock()
                }
                .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 108)
            }
            .background(Air.canvas)
            .navigationBarHidden(true)
        }
    }

    private func allergyBinding(_ allergen: Allergen) -> Binding<Bool> {
        Binding(
            get: { pantry.flags.allergies.contains(allergen.rawValue) },
            set: { on in
                if on {
                    if !pantry.flags.allergies.contains(allergen.rawValue) {
                        pantry.flags.allergies.append(allergen.rawValue)
                    }
                } else {
                    pantry.flags.allergies.removeAll { $0 == allergen.rawValue }
                }
            }
        )
    }
}

struct ProductScreen: View {
    var product: Product
    @EnvironmentObject private var pantry: Pantry
    @State private var shown: Product
    @State private var swaps: [Product] = []
    @State private var recall: RecallNote?
    @State private var recallChecked = false

    init(product: Product) {
        self.product = product
        _shown = State(initialValue: product)
    }

    var body: some View {
        let notes = IngredientBook.matches(in: shown.ingredients, tags: shown.additiveTags)
        let report = ScoreEngine.score(shown, notes: notes)
        let banners = FlagEngine.banners(for: shown, notes: notes, flags: pantry.flags)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if shown.isSample {
                    Text("Sample food, so you can see this screen. Not a real product.")
                        .airySecondary()
                }
                Text(shown.displayName)
                    .airyTitle()
                if !shown.brand.isEmpty {
                    Text(shown.brand)
                        .airySecondary()
                }
                Text(shown.source)
                    .airySecondary()
                SoftCard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(report.value)")
                            .font(.system(size: 64, weight: .semibold, design: .rounded))
                            .foregroundStyle(Air.ink)
                            .accessibilityLabel("Score \(report.value) out of 100")
                        Text("out of 100")
                            .airyBody()
                    }
                }
                ForEach(banners, id: \.self) { line in
                    ToneRow(title: "Check this", detail: line, tone: .avoid)
                }
                if let recall {
                    ToneRow(title: "Recall notice", detail: recall.summary + " " + recall.detail, tone: .avoid)
                    if let link = recall.link {
                        Link("Open FDA recall alerts", destination: link)
                            .font(.system(size: 18, weight: .semibold))
                    }
                } else if recallChecked {
                    Text("No openFDA notice matched this name. That is not a promise the food is safe.")
                        .airySecondary()
                }
                Button {
                    pantry.toggleFavorite(shown)
                } label: {
                    BigLabel(
                        title: pantry.isFavorite(shown) ? "Saved on this phone" : "Save this food",
                        systemImage: pantry.isFavorite(shown) ? "heart.fill" : "heart"
                    )
                }
                .buttonStyle(QuietButton())
                let good = Array(report.reasons.filter { $0.tone == .good }.prefix(4))
                let watch = Array(report.reasons.filter { $0.tone == .limit || $0.tone == .avoid }.prefix(4))
                if !good.isEmpty {
                    Text("Good things")
                        .airyTitle()
                    ForEach(good) { reason in
                        Bullet(title: reason.title, tone: .good)
                    }
                }
                if !watch.isEmpty {
                    Text("Worth a look")
                        .airyTitle()
                    ForEach(watch) { reason in
                        Bullet(title: reason.title, tone: reason.tone)
                    }
                }
                nutrition
                if !swaps.isEmpty {
                    Text("Higher-scoring foods in a similar group")
                        .airyTitle()
                    Text("A higher score is not a promise that a food is healthy. Same rules, similar group.")
                        .airySecondary()
                    ForEach(swaps) { item in
                        NavigationLink { ProductScreen(product: item) } label: { FoodCard(product: item) }
                            .buttonStyle(.plain)
                    }
                }
                Text(Copy.disclaimer)
                    .airySecondary()
                Text(shown.sourceDetail)
                    .airySecondary()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 108)
        }
        .background(Air.canvas)
        .navigationTitle("Food")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { pantry.remember(shown) }
        .task {
            if shown.ingredients.isEmpty && !shown.barcode.isEmpty && !shown.isSample {
                if let full = try? await FoodAPI.lookup(barcode: shown.barcode) {
                    shown = full
                    pantry.remember(full)
                }
            }
            if !shown.isSample {
                recall = await FoodAPI.recall(for: shown)
                swaps = await FoodAPI.swaps(for: shown)
            }
            recallChecked = true
        }
    }

    private var nutrition: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("On the label")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(shown.basis + (shown.serving.isEmpty ? "" : " · " + shown.serving))
                    .airySecondary()
                line("Calories", shown.kcal, "kcal")
                line("Added sugar", shown.addedSugar, "g")
                line("Total sugar", shown.sugar, "g")
                line("Sodium", shown.sodiumMg, "mg")
                line("Saturated fat", shown.saturatedFat, "g")
                line("Fiber", shown.fiber, "g")
                line("Protein", shown.protein, "g")
                if !shown.ingredients.isEmpty {
                    Text("Ingredients")
                        .font(.system(size: 18, weight: .semibold))
                        .padding(.top, 8)
                    Text(shown.ingredients)
                        .airySecondary()
                }
            }
        }
    }

    private func line(_ title: String, _ value: Double?, _ unit: String) -> some View {
        Text(value.map { "\(title): \(ScoreEngine.format($0)) \(unit)" } ?? "\(title): not listed")
            .airyBody()
    }
}

struct FoodCard: View {
    var product: Product

    var body: some View {
        let notes = IngredientBook.matches(in: product.ingredients, tags: product.additiveTags)
        let score = ScoreEngine.score(product, notes: notes).value
        SoftCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(product.displayName)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Air.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !product.brand.isEmpty {
                    Text(product.brand)
                        .airySecondary()
                }
                Text("Score \(score) out of 100")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Air.leaf)
            }
        }
    }
}

struct Bullet: View {
    var title: String
    var tone: ScoreTone
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 18

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ink)
                .accessibilityHidden(true)
            Text(word + " · " + title)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(wash)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var word: String {
        switch tone {
        case .good: return "Good"
        case .limit: return "Limit"
        case .avoid: return "Avoid"
        case .note: return "Note"
        }
    }

    private var symbol: String {
        switch tone {
        case .good: return "checkmark.circle.fill"
        case .limit: return "minus.circle.fill"
        case .avoid: return "exclamationmark.circle.fill"
        case .note: return "info.circle.fill"
        }
    }

    private var wash: Color {
        switch tone {
        case .good: return Air.goodWash
        case .limit: return Air.citrusWash
        case .avoid: return Air.tomatoWash
        case .note: return Air.canvas
        }
    }

    private var ink: Color {
        switch tone {
        case .good: return Air.goodInk
        case .limit: return Air.citrusInk
        case .avoid: return Air.tomatoInk
        case .note: return Air.ink
        }
    }
}

struct SnapScreen: View {
    var previewText: String? = nil
    @State private var text = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var reading = false

    var body: some View {
        let notes = IngredientBook.matches(in: text, tags: [])
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ProducePhoto(name: "garden", height: 180)
                Text("Snap the label")
                    .airyTitle()
                Text("Take a photo of the ingredient list. We read it on this phone. The photo is not uploaded.")
                    .airyBody()
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showCamera = true } label: {
                        BigLabel(title: "Take a photo", systemImage: "camera")
                    }
                    .buttonStyle(FilledButton())
                }
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    BigLabel(title: "Choose a photo", systemImage: "photo")
                }
                .buttonStyle(QuietButton())
                Button {
                    text = Product.sampleLabel
                } label: {
                    BigLabel(title: "See a sample reading", systemImage: "text.alignleft")
                }
                .buttonStyle(QuietButton())
                if reading {
                    Text("Reading the label…")
                        .airyBody()
                }
                if !text.isEmpty {
                    Text("Words we read")
                        .airyTitle()
                    Text(text)
                        .airyBody()
                    if previewText != nil {
                        Text("This sample is filled in so you can see the screen. On your iPhone, the camera reads your label.")
                            .airySecondary()
                    }
                    let flagged = notes.filter { $0.level != "fine" }
                    if flagged.isEmpty {
                        Text("No limit or avoid ingredients matched these words. The camera can miss a line, so glance at the package too.")
                            .airyBody()
                    } else {
                        ForEach(flagged.prefix(4)) { note in
                            Bullet(title: note.title, tone: note.tone)
                        }
                    }
                    Text(Copy.disclaimer)
                        .airySecondary()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 108)
        }
        .background(Air.canvas)
        .navigationTitle("Label")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if text.isEmpty, let previewText { text = previewText }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                reading = true
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    text = await LabelReader.read(image)
                    if text.isEmpty { text = "We could not read words in that photo. Try a brighter, closer picture." }
                }
                reading = false
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraCapture { image in
                Task {
                    reading = true
                    text = await LabelReader.read(image)
                    if text.isEmpty { text = "We could not read words in that photo. Try a brighter, closer picture." }
                    reading = false
                }
            }
        }
    }
}

struct AboutBlock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProducePhoto(name: "greens", height: 160)
            Text("About")
                .airyTitle()
            Text(Copy.disclaimer)
                .airyBody()
            Text("There is no account and no ads. Allergies, history, and saved foods stay on this phone. A label photo is read on this phone and is not uploaded by TrueFoods. We do not sell your information.")
                .airyBody()
            Text("Barcode and name lookups use Open Food Facts, then USDA FoodData Central if needed. Recall notices come from openFDA. The USDA demo key is built in for trying the app. A free USDA key of your own raises the rate limit. We do not call a paid AI service.")
                .airyBody()
            Text("Product facts from Open Food Facts are © Open Food Facts contributors and available under the Open Database License. https://openfoodfacts.org")
                .airyBody()
            Text("Ingredient notes cite public pages from the FDA, EFSA, and WHO.")
                .airyBody()
            if let fda = URL(string: "https://www.fda.gov/food/food-additives-petitions/food-additive-status-list") {
                Link("FDA food additives", destination: fda)
                    .font(.system(size: 18, weight: .semibold))
            }
            if let efsa = URL(string: "https://www.efsa.europa.eu/en/topics/topic/food-additives") {
                Link("EFSA food additives", destination: efsa)
                    .font(.system(size: 18, weight: .semibold))
            }
            if let who = URL(string: "https://www.who.int/news-room/fact-sheets/detail/healthy-diet") {
                Link("WHO healthy diet", destination: who)
                    .font(.system(size: 18, weight: .semibold))
            }
            Text("Photos are real pictures of fresh fruit, vegetables, and greens. Pexels License, free for commercial use. Attribution is not required. We credit the photographers anyway.")
                .airyBody()
            credit("Citrus and pomegranate", "engin akyurt", "https://www.pexels.com/photo/1435735/")
            credit("Tomatoes, peppers, and mushrooms", "engin akyurt", "https://www.pexels.com/photo/1435904/")
            credit("Leafy greens", "Karolina Grabowska", "https://www.pexels.com/photo/4198024/")
            credit("Garden vegetables", "Magda Ehlers", "https://www.pexels.com/photo/1300972/")
            credit("App icon background, green hills", "Sergio Zhukov", "https://www.pexels.com/photo/scenic-green-hills-and-blue-skies-landscape-28578392/")
            if let mail = URL(string: "mailto:\(Copy.support)") {
                Link("Email \(Copy.support)", destination: mail)
                    .font(.system(size: 18, weight: .semibold))
            }
        }
    }

    private func credit(_ what: String, _ who: String, _ link: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(what), photo by \(who) on Pexels.")
                .airySecondary()
            if let url = URL(string: link) {
                Link(link, destination: url)
                    .font(.system(size: 16))
            }
        }
    }
}

struct CameraCapture: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: CameraCapture

        init(_ parent: CameraCapture) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
