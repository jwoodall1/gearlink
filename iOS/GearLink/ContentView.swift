import SwiftUI
import Supabase

struct ContentView: View {
    @StateObject private var auth = AccountSession()
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: LoginField?

    private enum LoginField: Hashable {
        case email, password
    }

    var body: some View {
        Group {
            if let user = auth.user {
                DashboardView(userID: user.id, username: AccountSession.displayName(for: user),
                              signingOut: auth.isWorking, signOutError: auth.errorMessage) {
                    Task { await auth.signOut() }
                }.id(user.id)
            } else {
                loginScreen
            }
        }
        .task { await auth.observeSession() }
    }

    private var loginScreen: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    Image("GearLinkLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 300)
                        .accessibilityLabel("GearLink")

                    if !auth.isConfigured {
                        Text("Sign-in is not configured")
                            .font(.title2.bold())
                        Text("Please contact your GearLink administrator to finish setting up this app.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else if auth.isRestoring {
                        ProgressView("Restoring your session…")
                    } else {
                        loginForm
                    }

                    if let errorMessage = auth.errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .accessibilityLabel("Error: \(errorMessage)")
                    }
                }
                .frame(maxWidth: 380)
                .padding(28)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var loginForm: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Welcome back")
                    .font(.title2.bold())
                Text("Sign in with your GearLink account.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Email").font(.subheadline.bold())
                TextField("you@example.com", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .accessibilityLabel("Email")

                Text("Password").font(.subheadline.bold()).padding(.top, 8)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { signIn() }
            }
            .disabled(auth.isWorking)

            Button(action: signIn) {
                HStack {
                    if auth.isWorking { ProgressView().tint(.white) }
                    Text(auth.isWorking ? "Signing in…" : "Sign in")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSignIn)

            Text("Ask your organization administrator for an account.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var canSignIn: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty && !auth.isWorking
    }

    private func signIn() {
        guard canSignIn else { return }
        focusedField = nil
        Task {
            await auth.signIn(email: email, password: password)
            password = ""
        }
    }
}

/// Owns authentication state; credentials and session storage are handled by Supabase Auth.
@MainActor
private final class AccountSession: ObservableObject {
    @Published private(set) var user: User?
    @Published private(set) var isRestoring = true
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private let client = SupabaseClientProvider.client
    var isConfigured: Bool { client != nil }

    func observeSession() async {
        guard let client else {
            isRestoring = false
            return
        }
        for await (_, session) in client.auth.authStateChanges {
            guard !Task.isCancelled else { return }
            user = session.flatMap { $0.isExpired ? nil : $0.user }
            isRestoring = false
        }
    }

    func signIn(email: String, password: String) async {
        guard let client, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let session = try await client.auth.signIn(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password
            )
            user = session.user
        } catch {
            if error is URLError {
                errorMessage = "Unable to connect. Check your internet connection and try again."
            } else {
                errorMessage = "Unable to sign in. Check your email and password, then try again."
            }
        }
    }

    func signOut() async {
        guard let client, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            // Sign out this app without ending the user's web dashboard session.
            try await client.auth.signOut(scope: .local)
            user = nil
        } catch {
            errorMessage = "Unable to sign out. Please try again."
        }
    }

    static func displayName(for user: User) -> String {
        // Metadata is for display only, never for deciding permissions.
        for key in ["username", "display_name", "full_name", "name"] {
            if let name = user.userMetadata[key]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
        }
        return user.email ?? "GearLink user"
    }
}

#Preview {
    ContentView()
}
