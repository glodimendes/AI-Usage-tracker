# AI-Usage tracker

A tiny macOS menu-bar app that shows your AI usage limits at a glance: completion bars with exact values, one account on top of the other.

**Supported**
- Claude Code: 5h and weekly limits (reads the existing CLI login)
- Codex CLI: 5h and weekly limits
- Antigravity CLI (`agy`): Gemini and Claude quota pools
- Anthropic API and OpenAI API: month-to-date spend vs. a budget you set (needs an admin key)

Add as many accounts as you like in Settings (gear icon). Names default to the login email.

## Build

Requires macOS 14+ and the Swift toolchain.

```sh
./build.sh           # builds build/AIUsage.app
./build.sh install   # also installs to ~/Applications and launches it
```

The app launches at login (toggle in Settings). Credentials are never copied: CLI logins are read from where each CLI stores them, and API keys are kept in your macOS Keychain.

The Claude, Codex and Antigravity usage endpoints are undocumented and may change.
