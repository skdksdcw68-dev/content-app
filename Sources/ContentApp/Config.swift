import Foundation

/// Where the app talks to.
///
/// The anon key is meant to be public -- it identifies the project and nothing
/// else. Every row it can reach is decided by row-level security against the
/// signed-in user, not by the key. The keys that would actually matter, the
/// service role key and the token encryption key, exist only on the server and
/// are never compiled into a build that ships to a phone.
enum Config {
    static let supabaseURL = URL(string: "https://dosszkllkassvyprkhrg.supabase.co")!

    static let supabaseAnonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" +
        ".eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRvc3N6a2xsa2Fzc3Z5cHJraHJnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc5NzIzMDEsImV4cCI6MjEwMzU0ODMwMX0" +
        ".JJuOMBv14WCUxeZgw6IjP-n1bvz3DwalpaMdjPezPMU"

    /// The scheme the OAuth round trip comes back on. Declared in project.yml
    /// as CFBundleURLTypes, and handed to ASWebAuthenticationSession so iOS
    /// knows to close the browser sheet and return control here.
    static let callbackScheme = "autocast"

    static let oauthReturnURL = "autocast://oauth/done"
}
