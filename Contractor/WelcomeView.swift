import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var role: UserRole?
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Contractor")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(ink)
                    Text("Lawn care and moving in Richland County. Pros quote for free and pay a small fee only when you book them.")
                        .foregroundStyle(.secondary)
                    DemoBanner()
                    if let error = model.errorMessage {
                        Text(error).foregroundStyle(.red)
                    }
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
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Create an account").font(.headline)
                            TextField("Email", text: $email)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                .autocorrectionDisabled()
                            SecureField("Password", text: $password)
                            Button("I'm a customer") { role = .customer }
                                .buttonStyle(.borderedProminent)
                            Button("I'm a pro") { role = .pro }
                                .buttonStyle(.bordered)
                        }
                    }
                    Text("Each job goes to at most 3 pros. Customers confirm a phone so the leads are real.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .background(paper)
            .navigationDestination(item: $role) { selected in
                SignUpView(role: selected, email: email, password: password)
            }
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
    @State private var zip = "44903"
    @State private var business = ""
    @State private var lawn = true
    @State private var moving = false
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
                if !zip.isEmpty && !RichlandCounty.contains(zip) {
                    Text("Contractor is launching in Richland County, Ohio.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if role == .pro {
                    TextField("Business name", text: $business)
                    Toggle("Lawn care", isOn: $lawn)
                    Toggle("Moving", isOn: $moving)
                }
                Toggle("I agree to the Terms", isOn: $acceptedTerms)
                Button("Read Terms") { showTerms = true }
                    .buttonStyle(.bordered)
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
                Button(model.busy ? "Saving…" : "Create account") {
                    let categories = [lawn ? ServiceCategory.lawn : nil, moving ? ServiceCategory.moving : nil].compactMap { $0 }
                    Task {
                        await model.signUp(role: role, name: name, email: email, password: password, zip: zip, business: business, categories: categories, serviceZips: [zip], acceptedTerms: acceptedTerms)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || !acceptedTerms)
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

struct VerifyPhoneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm your phone")
                .font(.largeTitle.weight(.bold))
            Text("Verified customers keep leads real. This demo does not send a text. Tap verify to continue. A live build will use a texted code.")
                .foregroundStyle(.secondary)
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
