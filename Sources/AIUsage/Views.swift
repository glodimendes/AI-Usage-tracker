import SwiftUI
import CryptoKit

struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var showSettings = false

    var body: some View {
        Group {
            if showSettings { SettingsView(done: { showSettings = false }) }
            else { UsageList(openSettings: { showSettings = true }) }
        }
        .frame(width: 320)
        .tint(.hunter)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            store.refreshIfStale()
        }
    }
}

struct UsageList: View {
    @EnvironmentObject var store: Store
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if store.accounts.isEmpty {
                Text("No accounts yet. Open Settings to add one.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(24)
            } else {
                VStack(spacing: 16) {
                    ForEach(store.accounts) { AccountSection(account: $0) }
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            }
            HStack(spacing: 12) {
                Text(store.lastUpdated.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }
}

struct AccountSection: View {
    @EnvironmentObject var store: Store
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(account.displayName).font(.system(size: 12, weight: .semibold))
                if let plan = store.snapshots[account.id]?.plan {
                    Text(plan.uppercased()).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                }
                Spacer()
                if store.loading.contains(account.id) { ProgressView().controlSize(.mini) }
            }
            if let snap = store.snapshots[account.id] {
                ForEach(snap.rows) { RowView(row: $0) }
            }
            if let err = store.errors[account.id] {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct RowView: View {
    let row: UsageRow
    var body: some View {
        HStack(spacing: 8) {
            Text(row.title).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Bar(fraction: row.fraction)
            Text(row.value).font(.system(size: 11, weight: .medium)).monospacedDigit()
                .frame(width: 74, alignment: .trailing)
            Text(row.detail).font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)
        }
        .help(row.detail.isEmpty ? "" : "Resets in \(row.detail)")
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    var done: () -> Void

    @State private var launchAtLogin = LoginItem.enabled
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done", action: done).buttonStyle(.plain).foregroundStyle(Color.hunter)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            VStack(spacing: 10) {
                ForEach($store.accounts) { $a in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Name", text: Binding(
                                get: { a.displayName },
                                set: { a.label = $0; a.customName = true }
                            )).textFieldStyle(.plain).font(.system(size: 13))
                            Text(subtitle(a)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if a.kind.isAPI {
                            Text("$").font(.caption).foregroundStyle(.secondary)
                            TextField("", value: $a.budget, format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 56).multilineTextAlignment(.trailing)
                                .help("Monthly budget")
                        }
                        Button { store.move(a, by: -1) } label: { Image(systemName: "chevron.up") }
                        Button { store.move(a, by: 1) } label: { Image(systemName: "chevron.down") }
                        Button { store.remove(a) } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.plain)
                }
                if store.accounts.isEmpty {
                    Text("No accounts").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()

            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .onChange(of: launchAtLogin) { _, on in LoginItem.set(on) }
            Divider()

            if adding {
                AddAccountForm(close: { adding = false })
            } else {
                Button { adding = true } label: { Label("Add account", systemImage: "plus") }
                    .buttonStyle(.plain).foregroundStyle(Color.hunter)
                    .font(.system(size: 12, weight: .medium))
                    .padding(16)
            }
        }
    }

    private func short(_ service: String) -> String {
        service == "Claude Code-credentials" ? "default" : String(service.suffix(8))
    }

    private func subtitle(_ a: Account) -> String {
        a.kind == .claudeCode ? "\(a.kind.title) · \(short(a.source))" : a.kind.title
    }
}

struct AddAccountForm: View {
    @EnvironmentObject var store: Store
    var close: () -> Void

    @State private var kind: Kind = .claudeCode
    @State private var name = ""
    @State private var login = ""              // Claude: detected Keychain service, "" = other folder
    @State private var folder = "~/.claude-"   // Claude / Codex config folder
    @State private var key = ""
    @State private var budget = "100"

    private var detected: [String] { store.detectedClaudeServices() }

    private var claudeService: String {
        login.isEmpty ? Self.claudeService(forFolder: folder) : login
    }
    private var codexPath: String {
        NSString(string: folder).expandingTildeInPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? Providers.codexDefaultPath
            : NSString(string: (NSString(string: folder).expandingTildeInPath as NSString).appendingPathComponent("auth.json")).standardizingPath
    }

    /// Why the form can't be submitted yet (nil = ready).
    private var problem: String? {
        switch kind {
        case .claudeCode:
            if !Keychain.claudeCodeServices().contains(claudeService) { return "No Claude Code login found for this folder yet. Run claude there and sign in." }
            if store.has(kind: .claudeCode, source: claudeService) { return "Already added." }
        case .codex:
            if !FileManager.default.fileExists(atPath: codexPath) { return "No Codex login found in this folder." }
            if store.has(kind: .codex, source: codexPath) { return "Already added." }
        case .antigravity:
            if !Keychain.exists(service: "gemini", account: "antigravity") { return "No Antigravity login found. Run agy and sign in." }
            if store.has(kind: .antigravity, source: Providers.antigravityDefaultSource) { return "Already added." }
        case .anthropicAPI, .openAIAPI:
            if key.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Provider", selection: $kind) {
                ForEach(Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .onChange(of: kind) { _, k in reset(for: k) }

            switch kind {
            case .claudeCode:
                Picker("Login", selection: $login) {
                    ForEach(detected, id: \.self) { Text(Self.shortName($0)).tag($0) }
                    Text("Other folder…").tag("")
                }
                if login.isEmpty {
                    TextField("Config folder (CLAUDE_CONFIG_DIR)", text: $folder).textFieldStyle(.roundedBorder)
                }
            case .codex:
                TextField("Codex folder (CODEX_HOME)", text: $folder).textFieldStyle(.roundedBorder)
            case .antigravity:
                EmptyView()
            case .anthropicAPI, .openAIAPI:
                SecureField("Admin API key", text: $key).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Monthly budget $").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $budget).textFieldStyle(.roundedBorder).frame(width: 70)
                }
            }
            TextField(kind.isAPI ? "Name (optional)" : "Name (optional, defaults to login email)", text: $name)
                .textFieldStyle(.roundedBorder)

            if let p = problem, !p.isEmpty { Text(p).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel", action: close)
                Button("Add") { add() }.disabled(problem != nil)
            }
        }
        .controlSize(.small)
        .padding(16)
        .onAppear { reset(for: kind) }
    }

    private func reset(for k: Kind) {
        name = ""; key = ""; budget = "100"
        switch k {
        case .claudeCode: login = detected.first ?? ""; folder = "~/.claude-"
        case .codex: folder = "~/.codex"
        default: break
        }
    }

    private func add() {
        let label = name.trimmingCharacters(in: .whitespaces)
        var a = Account(kind: kind, label: label.isEmpty ? kind.title : label)
        a.customName = label.isEmpty ? nil : true
        switch kind {
        case .claudeCode: a.source = claudeService
        case .codex: a.source = codexPath
        case .antigravity: a.source = Providers.antigravityDefaultSource
        case .anthropicAPI, .openAIAPI: a.budget = Double(budget) ?? 100
        }
        store.add(a, key: kind.isAPI ? key : nil)
        close()
    }

    static func shortName(_ service: String) -> String {
        service == "Claude Code-credentials" ? "Default (~/.claude)" : "Folder …" + service.suffix(8)
    }

    /// Claude Code keeps one Keychain item per config folder: "Claude Code-credentials-" + first 8 hex of SHA-256(path).
    static func claudeService(forFolder folder: String) -> String {
        var path = NSString(string: folder.trimmingCharacters(in: .whitespaces)).expandingTildeInPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
        return "Claude Code-credentials-\(hash)"
    }
}
