import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var role: UserRole?
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            BrandHeader()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = model.errorMessage, error != "Check your email" {
                        Text(error).foregroundStyle(.red)
                    }
                    if model.pendingConfirmation != nil {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Check your email")
                                    .font(.headline)
                                ConfirmSignInButton()
                            }
                        }
                    }
                    Button {
                        Haptic.tap()
                        role = .customer
                    } label: {
                        roleRow("I need work done", symbol: "house.fill", tint: pine)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("I need work done")
                    Button {
                        Haptic.tap()
                        role = .pro
                    } label: {
                        roleRow("I'm a pro", symbol: "wrench.and.screwdriver.fill", tint: clay)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("I'm a pro")
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Sign in").font(.headline)
                            TextField("Email", text: $email)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                .textContentType(.username)
                                .autocorrectionDisabled()
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                            Button(model.busy ? "Signing in…" : "Sign in") {
                                Haptic.tap()
                                Task { await model.signIn(email: email, password: password) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || email.isEmpty || password.isEmpty)
                        }
                    }
                    if !model.live {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Try the demo").font(.headline)
                                Text("Password for both is demo1234.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Button("Open as Maya, a customer") {
                                    Task { await model.signIn(email: "maya@contractor.demo", password: "demo1234") }
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Open as Greenline Lawn, a pro") {
                                    Task { await model.signIn(email: "greenline@contractor.demo", password: "demo1234") }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    HelpLinks()
                }
                .padding(20)
            }
            }
            .background(paper)
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                if email.isEmpty {
                    email = UserDefaults.standard.string(forKey: "contractor.lastEmail") ?? ""
                }
            }
            .navigationDestination(item: $role) { selected in
                SignUpView(role: selected, email: email, password: password)
            }
        }
    }
}

private func roleRow(_ title: String, symbol: String, tint: Color) -> some View {
    Card {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title)
                .font(.headline)
                .foregroundStyle(ink)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
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
                    .font(.title2.weight(.semibold))
                TextField("Your name", text: $name)
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                TextField("ZIP code", text: $zip)
                    .keyboardType(.numberPad)
                if !zip.isEmpty && !USAddress.isValidZip(zip) {
                    Text("Enter a 5-digit US ZIP.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if role == .pro {
                    TextField("Mobile phone", text: $phone)
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    if !phone.isEmpty && USPhone.e164(phone) == nil {
                        Text("Enter a US phone number.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    TextField("Business name", text: $business)
                    Stepper("Service radius: \(radius) miles", value: $radius, in: 5...200, step: 5)
                    Text("Services").font(.headline)
                    ForEach(ServiceCatalog.active) { service in
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
                    .buttonStyle(.bordered)
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
                .buttonStyle(.borderedProminent)
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

struct ConfirmSignInButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.pendingConfirmation != nil {
            Button(model.busy ? "Signing in…" : "I confirmed, sign in") {
                Task { await model.signInAfterConfirm() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy)
        }
    }
}

struct VerifyPhoneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm your phone")
                .font(.largeTitle.weight(.bold))
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            Button("Verify phone") {
                Task { await model.verifyPhone() }
            }
            .buttonStyle(.borderedProminent)
            Button("Sign out") {
                Task { await model.signOut() }
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(paper)
    }
}
