import Foundation

enum Providers {
    static let codexDefaultPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath

    static func fetch(_ a: Account) async throws -> Snapshot {
        switch a.kind {
        case .claudeCode: return try await claude(a)
        case .codex: return try await codex(a)
        case .antigravity: return try await antigravity(a)
        case .anthropicAPI: return try await anthropicAPI(a)
        case .openAIAPI: return try await openAIAPI(a)
        }
    }

    // MARK: Claude Code (subscription limits)

    private static func claude(_ a: Account) async throws -> Snapshot {
        let data = try await readKeychain(service: a.source)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw UsageError("No Claude Code login found") }

        if let exp = (oauth["expiresAt"] as? NSNumber)?.doubleValue, exp / 1000 < Date().timeIntervalSince1970 {
            throw LoginExpired(cli: "Claude Code")
        }
        let json: [String: Any]
        do {
            json = try await getJSON("https://api.anthropic.com/api/oauth/usage", headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
            ])
        } catch let e as HTTPError where e.status == 401 || e.status == 403 {
            throw LoginExpired(cli: "Claude Code")
        }
        var rows: [UsageRow] = []
        for (key, title) in [("five_hour", "5h"), ("seven_day", "Week")] {
            guard let w = json[key] as? [String: Any], let used = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
            let reset = (w["resets_at"] as? String).flatMap(parseISO)
            rows.append(percentRow(title, used: used, reset: reset))
        }
        guard !rows.isEmpty else { throw UsageError("No usage data returned") }
        let profile = try? await getJSON("https://api.anthropic.com/api/oauth/profile", headers: [
            "Authorization": "Bearer \(token)",
            "anthropic-beta": "oauth-2025-04-20",
        ])
        let email = (profile?["account"] as? [String: Any])?["email"] as? String
        return Snapshot(plan: (oauth["subscriptionType"] as? String)?.capitalized, email: email, rows: rows)
    }

    // MARK: Codex CLI (ChatGPT plan limits)

    private static func codex(_ a: Account) async throws -> Snapshot {
        let path = a.source.isEmpty ? codexDefaultPath : a.source
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String
        else { throw UsageError("Codex isn't logged in with ChatGPT") }

        var headers = ["Authorization": "Bearer \(token)"]
        if let id = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = id }
        let json: [String: Any]
        do { json = try await getJSON("https://chatgpt.com/backend-api/wham/usage", headers: headers) }
        catch let e as HTTPError where e.status == 401 || e.status == 403 {
            throw LoginExpired(cli: "Codex")
        }
        guard let limits = json["rate_limit"] as? [String: Any] else { throw UsageError("No usage data returned") }
        var rows: [UsageRow] = []
        for key in ["primary_window", "secondary_window"] {
            guard let w = limits[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let secs = (w["limit_window_seconds"] as? NSNumber)?.doubleValue ?? 0
            let reset = (w["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            rows.append(percentRow(windowTitle(secs), used: used, reset: reset))
        }
        guard !rows.isEmpty else { throw UsageError("No usage data returned") }
        return Snapshot(plan: (json["plan_type"] as? String)?.capitalized, email: json["email"] as? String, rows: rows)
    }

    // MARK: Antigravity CLI (per-model-pool quota)

    static let antigravityDefaultSource = "gemini|antigravity"

    private static func antigravity(_ a: Account) async throws -> Snapshot {
        let parts = a.source.split(separator: "|").map(String.init)
        let data = try await readKeychain(service: parts.first ?? "gemini", account: parts.count > 1 ? parts[1] : "antigravity")
        var raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "go-keyring-base64:"
        if raw.hasPrefix(prefix) {
            guard let d = Data(base64Encoded: String(raw.dropFirst(prefix.count))) else { throw UsageError("Unreadable Antigravity login") }
            raw = String(decoding: d, as: UTF8.self)
        }
        guard let root = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let tok = root["token"] as? [String: Any],
              let token = tok["access_token"] as? String
        else { throw UsageError("No Antigravity login found") }
        if let exp = (tok["expiry"] as? String).flatMap(parseISO), exp < Date() {
            throw LoginExpired(cli: "agy")
        }
        let json: [String: Any]
        do {
            json = try await request("https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
                                     method: "POST", body: Data("{}".utf8),
                                     headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json", "User-Agent": "antigravity"])
        } catch let e as HTTPError where e.status == 401 || e.status == 403 {
            throw LoginExpired(cli: "agy")
        }
        // Models share quota pools; show the most-used model of each pool.
        var pools: [String: (remaining: Double, reset: Date?)] = [:]
        for (id, v) in json["models"] as? [String: Any] ?? [:] {
            guard let q = (v as? [String: Any])?["quotaInfo"] as? [String: Any],
                  let rem = (q["remainingFraction"] as? NSNumber)?.doubleValue else { continue }
            let pool = id.hasPrefix("gemini") ? "Gemini" : (id.hasPrefix("claude") || id.hasPrefix("gpt-oss")) ? "Claude" : nil
            guard let pool else { continue }
            let reset = (q["resetTime"] as? String).flatMap(parseISO)
            if pools[pool] == nil || rem < pools[pool]!.remaining { pools[pool] = (rem, reset) }
        }
        let rows = ["Gemini", "Claude"].compactMap { name in
            pools[name].map { percentRow(name, used: (1 - $0.remaining) * 100, reset: $0.reset) }
        }
        guard !rows.isEmpty else { throw UsageError("No usage data returned") }
        return Snapshot(plan: nil, email: root["id_token_email"] as? String, rows: rows)
    }

    // MARK: Anthropic API (month-to-date spend, needs an Admin key)

    private static func anthropicAPI(_ a: Account) async throws -> Snapshot {
        guard let key = Keychain.get(a.id.uuidString) else { throw UsageError("API key missing") }
        let start = monthStart()
        let f = ISO8601DateFormatter()
        var comps = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        comps.queryItems = [
            .init(name: "starting_at", value: f.string(from: start)),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "limit", value: "31"),
        ]
        let json: [String: Any]
        do {
            json = try await getJSON(comps.url!.absoluteString, headers: ["x-api-key": key, "anthropic-version": "2023-06-01"])
        } catch let e as HTTPError where e.status == 401 || e.status == 403 {
            throw UsageError("Needs an Admin API key (sk-ant-admin…)")
        }
        var cents = 0.0
        for bucket in json["data"] as? [[String: Any]] ?? [] {
            for r in bucket["results"] as? [[String: Any]] ?? [] {
                if let s = r["amount"] as? String, let v = Double(s) { cents += v }
                else if let v = (r["amount"] as? NSNumber)?.doubleValue { cents += v }
            }
        }
        return Snapshot(plan: nil, email: nil, rows: [spendRow(cents / 100, budget: a.budget)])
    }

    // MARK: OpenAI API (month-to-date spend, needs an Admin key)

    private static func openAIAPI(_ a: Account) async throws -> Snapshot {
        guard let key = Keychain.get(a.id.uuidString) else { throw UsageError("API key missing") }
        var comps = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        comps.queryItems = [
            .init(name: "start_time", value: String(Int(monthStart().timeIntervalSince1970))),
            .init(name: "bucket_width", value: "1d"),
            .init(name: "limit", value: "31"),
        ]
        let json: [String: Any]
        do { json = try await getJSON(comps.url!.absoluteString, headers: ["Authorization": "Bearer \(key)"]) }
        catch let e as HTTPError where e.status == 401 || e.status == 403 {
            throw UsageError("Needs an Admin API key (sk-admin-…)")
        }
        var dollars = 0.0
        for bucket in json["data"] as? [[String: Any]] ?? [] {
            for r in bucket["results"] as? [[String: Any]] ?? [] {
                if let amount = r["amount"] as? [String: Any], let v = (amount["value"] as? NSNumber)?.doubleValue { dollars += v }
            }
        }
        return Snapshot(plan: nil, email: nil, rows: [spendRow(dollars, budget: a.budget)])
    }

    // MARK: Helpers

    private static func percentRow(_ title: String, used: Double, reset: Date?) -> UsageRow {
        UsageRow(title: title,
                 fraction: min(max(used / 100, 0), 1),
                 value: "\(Int(used.rounded()))%",
                 detail: reset.map { countdown(to: $0) } ?? "")
    }

    private static func spendRow(_ spent: Double, budget: Double) -> UsageRow {
        let cal = Calendar(identifier: .gregorian)
        let end = cal.date(byAdding: .month, value: 1, to: monthStart())!
        return UsageRow(title: "Month",
                        fraction: budget > 0 ? min(spent / budget, 1) : 0,
                        value: String(format: "$%.2f / $%.0f", spent, budget),
                        detail: countdown(to: end))
    }

    private static func windowTitle(_ secs: Double) -> String {
        secs >= 6 * 86400 ? "Week" : "\(max(Int((secs / 3600).rounded()), 1))h"
    }

    private static func monthStart() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
    }

    static func countdown(to date: Date) -> String {
        let s = Int(date.timeIntervalSinceNow)
        if s <= 0 { return "now" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)min" }
        return "\(max(m, 1))min"
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    struct HTTPError: Error { let status: Int }

    private static let session = URLSession(configuration: .ephemeral)

    private static func getJSON(_ url: String, headers: [String: String]) async throws -> [String: Any] {
        try await request(url, method: "GET", body: nil, headers: headers)
    }

    private static func request(_ url: String, method: String, body: Data?, headers: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 || status == 403 { throw HTTPError(status: status) }
            throw UsageError("Request failed (HTTP \(status))")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError("Unexpected response")
        }
        return obj
    }

    /// Uses /usr/bin/security (the tool these CLIs store logins with), so macOS doesn't prompt.
    private static func readKeychain(service: String, account: String? = nil) async throws -> Data {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-generic-password", "-s", service] + (account.map { ["-a", $0] } ?? []) + ["-w"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw UsageError("Couldn't read the saved login") }
            return data
        }.value
    }
}
