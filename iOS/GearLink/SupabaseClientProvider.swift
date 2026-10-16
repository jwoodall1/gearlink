import Foundation
import Supabase

/// The app's shared Supabase client. Set SUPABASE_URL and
/// SUPABASE_PUBLISHABLE_KEY in the local Xcode configuration before using it.
enum SupabaseClientProvider {
    static let client: SupabaseClient? = {
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

        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: SupabaseClientOptions(
                auth: .init(emitLocalSessionAsInitialSession: true)
            )
        )
    }()
}
