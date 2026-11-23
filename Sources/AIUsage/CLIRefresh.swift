import Foundation

/// Wakes an expired CLI login by running the CLI itself, so the CLI refreshes its own token.
/// We never read refresh tokens or write credentials. Output is discarded, never logged.
/// Only started from the reload button.
enum CLIRefresh {
    struct Step {
        let exe: String
        let args: [String]
        let env: [String: String]
    }

    private static let prompt = "Reply with: ok"

    /// Steps to try in order, cheapest first (nil-safe: empty when the CLI or its config folder can't be found).
    /// Checked by hand: `claude auth status` does NOT refresh, a one-shot prompt does; agy has no status command.
    /// Codex: `login status` is free; the `exec` prompt is the fallback (expired case not verified yet).
    static func steps(for a: Account) -> [Step] {
        switch a.kind {
        case .claudeCode:
            guard let exe = find("claude") else { return [] }
            var env: [String: String] = [:]
            if a.source != "Claude Code-credentials" {
                guard let dir = claudeFolder(forService: a.source) else { return [] }
                env["CLAUDE_CONFIG_DIR"] = dir
            }
            return [Step(exe: exe, args: ["-p", prompt, "--model", "haiku"], env: env)]
        case .codex:
            guard let exe = find("codex") else { return [] }
            var env: [String: String] = [:]
            if a.source != Providers.codexDefaultPath, !a.source.isEmpty {
                env["CODEX_HOME"] = (a.source as NSString).deletingLastPathComponent
            }
            return [Step(exe: exe, args: ["login", "status"], env: env),
                    Step(exe: exe, args: ["exec", "--skip-git-repo-check", prompt], env: env)]
        case .antigravity:
            guard let exe = find("agy") else { return [] }
            return [Step(exe: exe, args: ["-p", prompt], env: [:])]
        case .anthropicAPI, .openAIAPI:
            return []
        }
    }

    /// Runs one step with a 45 s limit. True when it exited with status 0.
    static func run(_ s: Step) async -> Bool {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: s.exe)
            p.arguments = s.args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (searchDirs + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
            for (k, v) in s.env { env[k] = v }
            p.environment = env
            // Scratch folder: no project context is loaded and no trust prompt appears.
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            let deadline = Date().addingTimeInterval(45)
            while p.isRunning && Date() < deadline { usleep(200_000) }
            if p.isRunning { p.terminate(); return false }
            return p.terminationStatus == 0
        }.value
    }

    // MARK: Lookup

    /// GUI apps get a minimal PATH, so check the usual install folders ourselves.
    private static let searchDirs: [String] = {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin"]
    }()

    private static func find(_ name: String) -> String? {
        let fm = FileManager.default
        if let hit = searchDirs.map({ "\($0)/\(name)" }).first(where: fm.isExecutableFile) { return hit }
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v \(name)"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && fm.isExecutableFile(atPath: path) ? path : nil
    }

    /// The config folder whose path hash is in the Keychain service name (see AddAccountForm.claudeService).
    private static func claudeFolder(forService service: String) -> String? {
        let home = NSHomeDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []
        return names.filter { $0.hasPrefix(".claude") }
            .map { "\(home)/\($0)" }
            .first { AddAccountForm.claudeService(forFolder: $0) == service }
    }
}
