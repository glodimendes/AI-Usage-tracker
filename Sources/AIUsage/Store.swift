import Foundation
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var accounts: [Account] = [] { didSet { persist() } }
    @Published var snapshots: [UUID: Snapshot] = [:]
    @Published var errors: [UUID: String] = [:]
    @Published var loading: Set<UUID> = []
    @Published var lastUpdated: Date?

    private var lastRefresh = Date.distantPast
    private let key = "accounts.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let a = try? JSONDecoder().decode([Account].self, from: d) { accounts = a }
        else { accounts = detected() }
        if !UserDefaults.standard.bool(forKey: "loginSeeded") {
            LoginItem.set(true)
            UserDefaults.standard.set(true, forKey: "loginSeeded")
        }
        if !UserDefaults.standard.bool(forKey: "antigravitySeeded") {
            UserDefaults.standard.set(true, forKey: "antigravitySeeded")
            if Keychain.exists(service: "gemini", account: "antigravity"),
               !accounts.contains(where: { $0.kind == .antigravity }) {
                accounts.append(Account(kind: .antigravity, label: "Antigravity", source: Providers.antigravityDefaultSource))
            }
        }
        refresh()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(d, forKey: key) }
    }

    // MARK: Detection of existing CLI logins

    func detectedClaudeServices() -> [String] {
        Keychain.claudeCodeServices().filter { s in !accounts.contains { $0.kind == .claudeCode && $0.source == s } }
    }

    private func detected() -> [Account] {
        var out: [Account] = []
        let services = Keychain.claudeCodeServices()
        for (i, s) in services.enumerated() {
            out.append(Account(kind: .claudeCode, label: services.count > 1 ? "Claude Code \(i + 1)" : "Claude Code", source: s))
        }
        if FileManager.default.fileExists(atPath: Providers.codexDefaultPath) {
            out.append(Account(kind: .codex, label: "Codex", source: Providers.codexDefaultPath))
        }
        if Keychain.exists(service: "gemini", account: "antigravity") {
            out.append(Account(kind: .antigravity, label: "Antigravity", source: Providers.antigravityDefaultSource))
        }
        return out
    }

    // MARK: Editing

    func add(_ a: Account, key: String? = nil) {
        if let key { Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: a.id.uuidString) }
        accounts.append(a)
        refresh(a)
    }

    func has(kind: Kind, source: String) -> Bool {
        accounts.contains { $0.kind == kind && $0.source == source }
    }

    func remove(_ a: Account) {
        Keychain.delete(a.id.uuidString)
        accounts.removeAll { $0.id == a.id }
        snapshots[a.id] = nil
        errors[a.id] = nil
    }

    func move(_ a: Account, by delta: Int) {
        guard let i = accounts.firstIndex(of: a), accounts.indices.contains(i + delta) else { return }
        accounts.swapAt(i, i + delta)
    }

    // MARK: Refreshing

    func refreshIfStale() {
        if Date().timeIntervalSince(lastRefresh) > 60 { refresh() }
    }

    func refresh() {
        lastRefresh = Date()
        accounts.forEach(refresh)
    }

    func refresh(_ a: Account) {
        guard !loading.contains(a.id) else { return }
        loading.insert(a.id)
        Task {
            do {
                let snap = try await Providers.fetch(a)
                snapshots[a.id] = snap
                errors[a.id] = nil
                if let email = snap.email, let i = accounts.firstIndex(where: { $0.id == a.id }), accounts[i].email != email {
                    accounts[i].email = email
                }
            } catch {
                errors[a.id] = error.localizedDescription
            }
            loading.remove(a.id)
            lastUpdated = Date()
        }
    }
}
