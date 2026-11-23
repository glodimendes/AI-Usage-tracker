import Foundation

enum Kind: String, Codable, CaseIterable {
    case claudeCode, codex, antigravity, anthropicAPI, openAIAPI

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .antigravity: "Antigravity CLI"
        case .anthropicAPI: "Anthropic API"
        case .openAIAPI: "OpenAI API"
        }
    }
    var isAPI: Bool { self == .anthropicAPI || self == .openAIAPI }
}

struct Account: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: Kind
    var label: String
    /// claudeCode: Keychain service name · codex: path to auth.json · antigravity: "service|account" in Keychain · API: unused (key lives in Keychain under `id`)
    var source: String = ""
    /// API accounts only: monthly budget in USD that the bar is measured against.
    var budget: Double = 100
    /// Login email, filled in from the provider. Used as the default display name.
    var email: String?
    /// True once the user typed their own name; until then the email is shown.
    var customName: Bool?

    var displayName: String { customName == true ? label : (email ?? label) }
}

struct UsageRow: Identifiable {
    let id = UUID()
    var title: String
    var fraction: Double   // 0...1
    var value: String      // exact value shown on the right
    var detail: String     // e.g. "resets in 2h 14m"
}

struct Snapshot {
    var plan: String?
    var email: String?
    var rows: [UsageRow]
}

/// A CLI login whose access token has expired. Reload can wake it by running the CLI (see CLIRefresh).
struct LoginExpired: LocalizedError {
    let cli: String
    var pressReload = false
    var errorDescription: String? {
        pressReload ? "Login expired. Press reload to refresh it." : "Login expired. Use \(cli) once to refresh it."
    }
}

struct UsageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
