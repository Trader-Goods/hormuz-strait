import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var role: UserRole?
    @State private var email = ""
    @State private var password = ""
    @State private var page = ProcessInfo.processInfo.environment["SCREENSHOT"] == "preview" ? 1 : 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            TabView(selection: $page) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "leaf.fill")
                            .appText(22, weight: .bold, relativeTo: .title2)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(buttonGreen, in: Circle())
                            .accessibilityHidden(true)
                        Text("Contractor Pros")
                            .appText(22, weight: .bold, relativeTo: .title2)
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 8)
                    Text("Yard work, done right.")
                        .appText(40, weight: .bold, relativeTo: .largeTitle)
                        .tracking(-0.6)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
                        .accessibilityAddTraits(.isHeader)
                    if let error = model.errorMessage, error != "Check your email" {
                        Text(error)
                            .appText()
                            .foregroundStyle(Color(red: 0.55, green: 0.08, blue: 0.08))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if model.pendingConfirmation != nil {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Check your email")
                                    .appText(20, weight: .semibold, relativeTo: .headline)
                                ConfirmSignInButton()
                            }
                        }
                    }
                    Button {
                        Haptic.tap()
                        role = .customer
                    } label: {
                        roleRow("I need help with a job", symbol: "house.fill", tint: pine)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("I need help with a job")
                    Button {
                        Haptic.tap()
                        role = .pro
                    } label: {
                        roleRow("I'm a pro, I want work", symbol: "wrench.and.screwdriver.fill", tint: clay)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("I'm a pro, I want work")
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Sign in").appText(22, weight: .bold, relativeTo: .title2)
                            TextField("Email", text: $email)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .autocorrectionDisabled()
                                .softField()
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .softField()
                            Button(model.busy ? "Signing in…" : "Sign in") {
                                Haptic.tap()
                                Task { await model.signIn(email: email, password: password) }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.busy || email.isEmpty || password.isEmpty)
                        }
                    }
                    if !model.live {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Try the demo").appText(20, weight: .semibold, relativeTo: .headline)
                                Text("Password for both is demo1234.")
                                    .appText()
                                    .foregroundStyle(.secondary)
                                Button("Open as Maya, a customer") {
                                    Task { await model.signIn(email: "maya@contractor.demo", password: "demo1234") }
                                }
                                .buttonStyle(PrimaryButtonStyle())
                                Button("Open as Greenline Lawn, a pro") {
                                    Task { await model.signIn(email: "greenline@contractor.demo", password: "demo1234") }
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                    Button {
                        Haptic.tap()
                        withAnimation(.spring(duration: 0.35)) { page = 1 }
                    } label: {
                        Text("Swipe to see jobs near you →")
                            .appText(20, weight: .semibold, relativeTo: .headline)
                            .foregroundStyle(ink)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .padding(.horizontal, 12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("See jobs near you")
                    Card {
                        HelpLinks()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                GeometryReader { geo in
                    ZStack {
                        Image("yard-mow")
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                        LinearGradient(
                            colors: [
                                .black.opacity(0.62),
                                .black.opacity(0.38),
                                .black.opacity(0.86)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
                .ignoresSafeArea()
            }
            .background(Color.black)
            .tag(0)
            GuestJobPreview(onCustomer: { role = .customer }, onPro: { role = .pro })
                .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            HStack(spacing: 12) {
                pageChip("Welcome", index: 0)
                pageChip("Jobs near you", index: 1)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                if email.isEmpty {
                    email = UserDefaults.standard.string(forKey: "contractor.lastEmail") ?? ""
                }
            }
            .navigationDestination(item: $role) { selected in
                HowItWorksView(role: selected, email: email, password: password)
            }
        }
    }
}

private extension WelcomeView {
    func pageChip(_ title: String, index: Int) -> some View {
        let on = page == index
        return Button {
            Haptic.tap()
            withAnimation(.spring(duration: 0.35)) { page = index }
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .appText(18, weight: on ? .bold : .semibold)
                    .foregroundStyle(on ? pineText : ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Capsule()
                    .fill(on ? pineText : Color.clear)
                    .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }
}

private func roleRow(_ title: String, symbol: String, tint: Color) -> some View {
    Card {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .appText(28, weight: .bold, relativeTo: .title)
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(buttonGreen, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
                .appText(22, weight: .bold, relativeTo: .title2)
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Image(systemName: "chevron.right")
                .appText(weight: .semibold)
                .foregroundStyle(pineText)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 72)
    }
}

extension UserRole: Identifiable {
    var id: String { rawValue }
}

struct SignUpView: View {
    @EnvironmentObject private var model: AppModel
    var role: UserRole
    @State var email: String
    @State var password: String
    @State private var name = ""
    @State private var zip = ""
    @State private var radius = 25
    @State private var business = ""
    @State private var selectedServices: Set<String> = ["mowing"]
    @State private var phone = ""
    @State private var acceptedTerms = false
    @State private var showTerms = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(role == .customer ? "Customer sign up" : "Pro sign up")
                    .appText(28, weight: .bold, relativeTo: .title)
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .softField()
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                    .softField()
                SecureField("Password", text: $password)
                    .textContentType(.newPassword)
                    .softField()
                TextField("ZIP code", text: $zip)
                    .keyboardType(.numberPad)
                    .softField()
                if !zip.isEmpty && !USAddress.isValidZip(zip) {
                    Text("Enter a 5-digit US ZIP.")
                        .appText()
                        .foregroundStyle(.red)
                }
                if role == .pro {
                    TextField("Mobile phone", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                        .softField()
                    if !phone.isEmpty && USPhone.e164(phone) == nil {
                        Text("Enter a US phone number.")
                            .appText()
                            .foregroundStyle(.red)
                    }
                    TextField("Business name", text: $business)
                        .softField()
                    Text("How far I'll travel")
                        .appText(22, weight: .bold, relativeTo: .title2)
                    Text("You'll see jobs inside this distance.")
                        .appText()
                        .foregroundStyle(inkSoft)
                    Stepper("\(radius) miles", value: $radius, in: 5...200, step: 5)
                        .accessibilityLabel("How far I'll travel, \(radius) miles")
                    Text("Services").appText(22, weight: .bold, relativeTo: .title2)
                    ForEach(ServiceCatalog.featured + ServiceCatalog.more) { service in
                        Toggle(isOn: Binding(
                            get: { selectedServices.contains(service.id) },
                            set: { on in
                                if on { selectedServices.insert(service.id) } else { selectedServices.remove(service.id) }
                            }
                        )) {
                            Label(service.title, systemImage: service.symbol)
                        }
                    }
                }
                Toggle("I agree to the Terms", isOn: $acceptedTerms)
                Button("Read Terms") { showTerms = true }
                    .buttonStyle(SecondaryButtonStyle())
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                ConfirmSignInButton()
                Button(model.busy ? "Saving…" : "Create account") {
                    let types = ServiceCatalog.active.map(\.id).filter { selectedServices.contains($0) }
                    let categories = ServiceCatalog.categories(in: types)
                    Task {
                        await model.signUp(role: role, name: name, email: email, password: password, zip: zip, business: business, categories: categories, serviceZips: [zip], acceptedTerms: acceptedTerms, radiusMiles: radius, serviceTypes: types, phone: phone)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.busy || !acceptedTerms || (role == .pro && USPhone.e164(phone) == nil))
                .sheet(isPresented: $showTerms) {
                    NavigationStack {
                        ScrollView {
                            Text(Terms.body).padding(20)
                        }
                        .navigationTitle(Terms.title)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showTerms = false }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(paper)
        .navigationTitle("Sign up")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HowItWorksView: View {
    var role: UserRole
    var email: String
    var password: String
    @State private var page = 0
    @State private var skipped = false

    private let pages: [(String, String, String)] = [
        ("yard-home", "Tell us the job", "Pick the work, add a photo, choose when, and set your price."),
        ("yard-pro", "A pro nearby accepts", "You confirm and pay in the app. That books them."),
        ("yard-mow", "Approve when it's done", "The pro marks it done. You approve it, or it approves itself after 48 hours."),
    ]

    var body: some View {
        Group {
            if skipped {
                SignUpView(role: role, email: email, password: password)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Spacer()
                        Button("Skip") {
                            Haptic.tap()
                            skipped = true
                        }
                        .appText(20, weight: .semibold, relativeTo: .headline)
                        .foregroundStyle(pineText)
                        .frame(minHeight: 56)
                    }
                    FitPhoto(name: pages[page].0, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    Text(pages[page].1)
                        .tracking(-0.4)
                        .appText(34, weight: .bold, relativeTo: .largeTitle)
                        .foregroundStyle(ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(pages[page].2)
                        .appText(20, weight: .regular, relativeTo: .title3)
                        .foregroundStyle(inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(page + 1) of 3")
                        .appText(18, weight: .semibold)
                        .foregroundStyle(pineText)
                        .accessibilityLabel("Screen \(page + 1) of 3")
                    Spacer()
                    Button(page == 2 ? "Create my account" : "Next") {
                        Haptic.tap()
                        if page == 2 { skipped = true } else { page += 1 }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(paper)
                .animation(.spring(duration: 0.3), value: page)
            }
        }
        .navigationTitle("How it works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AccountView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                BrandHeader()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(model.session?.displayName.isEmpty == false ? (model.session?.displayName ?? "Me") : "Me")
                            .appText(34, weight: .bold, relativeTo: .largeTitle)
                            .foregroundStyle(ink)
                        if model.session?.role == .pro {
                            NavigationLink("My profile") { ProProfileView() }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                        NavigationLink("How it works") { HowItWorksReplay() }
                            .buttonStyle(SecondaryButtonStyle())
                        HelpLinks()
                        Button("Sign out") {
                            Haptic.tap()
                            Task { await model.signOut() }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(20)
                }
            }
            .background(paper)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct HowItWorksReplay: View {
    @State private var page = 0
    private let pages: [(String, String, String)] = [
        ("yard-home", "Tell us the job", "Pick the work, add a photo, choose when, and set your price."),
        ("yard-pro", "A pro nearby accepts", "You confirm and pay in the app. That books them."),
        ("yard-mow", "Approve when it's done", "The pro marks it done. You approve it, or it approves itself after 48 hours."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FitPhoto(name: pages[page].0, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            Text(pages[page].1)
                .appText(34, weight: .bold, relativeTo: .largeTitle)
                .foregroundStyle(ink)
            Text(pages[page].2)
                .appText()
                .foregroundStyle(inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(page + 1) of 3")
                .appText(18, weight: .semibold)
                .foregroundStyle(pineText)
            Spacer()
            if page < 2 {
                Button("Next") {
                    Haptic.tap()
                    page += 1
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .background(paper)
        .navigationTitle("How it works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ConfirmSignInButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.pendingConfirmation != nil {
            Button(model.busy ? "Signing in…" : "I confirmed, sign in") {
                Task { await model.signInAfterConfirm() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.busy)
        }
    }
}

struct VerifyPhoneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm your phone")
                .appText(34, weight: .bold, relativeTo: .largeTitle)
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            Button("Verify phone") {
                Task { await model.verifyPhone() }
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Sign out") {
                Task { await model.signOut() }
            }
            .buttonStyle(SecondaryButtonStyle())
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(paper)
    }
}
