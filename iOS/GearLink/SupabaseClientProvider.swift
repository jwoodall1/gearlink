import Foundation
import Supabase

/// The app's shared Supabase client. Set SUPABASE_URL and
/// SUPABASE_PUBLISHABLE_KEY in the local Xcode configuration before using it.
enum SupabaseClientProvider {
    private static let configuration: (url: URL, key: String)? = {
        guard
            let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let url = URL(string: urlString),
            url.scheme == "https",
            let host = url.host,
            !host.isEmpty,
            host != "your-project.supabase.co",
            let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String,
            !key.isEmpty,
            !key.contains("your_key"),
            !urlString.isEmpty
        else {
            return nil
        }

        return (url, key)
    }()

    static let client: SupabaseClient? = {
        guard let configuration else { return nil }
        return SupabaseClient(
            supabaseURL: configuration.url,
            supabaseKey: configuration.key,
            options: SupabaseClientOptions(
                auth: .init(emitLocalSessionAsInitialSession: true)
            )
        )
    }()

    /// Reuses the shared auth session while binding each outbound registration
    /// request to its originating user, including SDK token refresh/retry paths.
    static func registrationClient(userID: UUID) -> SupabaseClient? {
        guard let configuration, let client else { return nil }
        return SupabaseClient(supabaseURL: configuration.url, supabaseKey: configuration.key,
            options: SupabaseClientOptions(auth: .init(accessToken: {
                let session = try await client.auth.session
                guard session.user.id == userID else { throw RegistrationError.sessionChanged }
                return session.accessToken
            })))
    }
}
