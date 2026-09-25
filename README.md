<div align="center">

# Token Burn

**Every Claude and ChatGPT plan you can reach — and which one to burn right now.**

Remaining quota and reset times for each plan, across accounts, orgs and workspaces, with a pick for what to use next.

[![macOS](https://img.shields.io/badge/macOS-26%2B-000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/multi-turn-inc/ai-usage-meter?include_prereleases)](../../releases)
[![Downloads](https://img.shields.io/github/downloads/multi-turn-inc/ai-usage-meter/total)](../../releases)

<br>
<img src="docs/screenshot-panel.png" width="300" alt="Token Burn Panel">

</div>

<br>

## Why

A personal Max plan, a Team seat at work, a ChatGPT Business workspace or two — each with its own 5-hour, weekly and credit limits, each resetting on its own clock. Quota you don't use before a reset is simply gone, and you usually find out which plan still had room only after you hit the wall on another.

Token Burn lists every plan the machine can reach, shows what's left of each and when it refills, and tells you which one to spend now.

## Which plan now

**Use the plan whose quota resets first.** Whatever is left in it disappears at that reset; the others keep. Spending the first-expiring plan first — first-expiring, first-out — never leaves you with less usable quota than any other order, and it needs only reset times, so a Max plan and a Team seat compare fairly even though their percentages mean different amounts.

On top of that rule:

- A plan stuck on its 5-hour window is skipped for now, and the advice says when to come back to it
- A plan with almost nothing left (under 5%) isn't worth starting a session on
- Credit allowances (ChatGPT Business spend controls) count as limits — a workspace can have most of its rate limit left and almost none of its credits
- Near-ties don't flip the pick on every refresh
- The pick comes with the pace behind it: *"~40% would expire unused at this pace"*, or *"runs out 1d before reset"*

The plan you're on now sits at the top of the panel with a verdict: *keep going*, or *switch to X* — with a button that copies the command to start a session on X. "On now" means the plan whose usage rose most recently, else the login your CLI uses. The menu bar shows that plan too; right-click any plan to pin it instead.

## Every plan, not every login

- **One person, several orgs.** The same email in a personal org and a team org is two plans, billed and limited separately — both are listed.
- **One login, several ChatGPT workspaces.** A single ChatGPT login is shown every workspace it belongs to. Codex tokens only read the workspace they were issued in, so each workspace is connected with one browser sign-in, pinned to that workspace.
- **Two logins, one plan.** Logins into the same plan are folded into one row, judged by what the credential proves (token claims, the account's own profile), never by a name written beside it.

## In the Menu Bar

<img src="docs/menubar-live.gif" width="240" alt="Menu bar cells pulsing while agents burn tokens">

Each service cell encodes two things at once:

- **Horizontal fill** → 5-hour quota remaining
- **Bar height** → 7-day quota remaining

While an agent is actively calling APIs, the bars pulse with a heartbeat animation. Each cell shows the plan you're on for that provider.

## In the Panel

- **In use** — the plan each provider is on now, its windows, and whether to keep going or switch (with the command to switch)
- **Other plans** — every other plan with its account email, remaining share and time-to-reset for each window (5h, 7d, credits), plan tier (*Max 20x*, *Team 5x*, *Business*), the recommended one marked, and a one-click fix for any plan that needs a sign-in
- **Workspaces to connect** — ChatGPT workspaces your login can reach but Token Burn can't read yet, one click from connected

## Install

```bash
brew install --cask multi-turn-inc/tap/token-burn
```

Or grab the latest `.dmg` from [Releases](../../releases).

**Requirements:** macOS 26 (Tahoe) or later, with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) or [Codex CLI](https://github.com/openai/codex) installed and authenticated.

## How It Works

Token Burn reuses the OAuth credentials your CLI tools already have. **It never asks for API keys or passwords.**

| Service | Credential source | Token source |
|---------|-------------------|--------------|
| Claude | Keychain / `~/.claude/.credentials.json`, plus any `CLAUDE_CONFIG_DIR` logins | `~/.claude/projects/**/*.jsonl` |
| Codex | `~/.codex/auth.json`, plus any `CODEX_HOME` logins | `~/.codex/sessions/**/*.jsonl` |

- Quota comes from each provider's usage API; token counts come from parsing local session logs in a single streaming pass
- Plan identity comes from the credential: Claude's `oauth/profile`, the claims inside a Codex token, and ChatGPT's account list for the workspaces a login can reach
- Replayed and resumed history is deduplicated (ccusage-style accounting) — counts `input + output` tokens, matching Claude's `/stats`
- Expired tokens are refreshed via the standard OAuth flow; deleted credential files are restored from Keychain
- Everything stays local — logs are parsed on your machine and never uploaded

## Privacy & Security

This app is a **read-only viewer**, built to be paranoid about your tokens:

- OAuth tokens are only ever sent to each provider's own API hosts (hard allowlist — a tampered config file can't redirect them)
- Logins Token Burn didn't create are never refreshed — refreshing rotates the token and would sign the owning CLI out. Only logins it created itself are kept alive
- Credential files are written with `0600` permissions; the app never stores secrets of its own
- Auto-update is triple-checked: Ed25519-signed Sparkle feed, notarization assessment, and Developer ID pinning — with downgrade protection

## More

- Auto-refresh every 1 / 5 / 15 / 30 minutes
- Auto-update via GitHub Releases
- 10 languages — EN, KO, JA, ZH, ES, FR, DE, PT, RU, IT
- Native SwiftUI with Liquid Glass on macOS Tahoe

<details>
<summary>Settings</summary>
<br>
<img src="docs/screenshot-settings.png" width="300" alt="Settings">
</details>

## Development

```bash
git clone https://github.com/multi-turn-inc/ai-usage-meter.git
cd ai-usage-meter
swift build            # debug build
swift test             # parser regression suite
./scripts/build-app.sh <version>   # signed .app + DMG + local install
```

Parsing logic lives in the `AIUsageMeterCore` library target so it stays testable in isolation. Third-party licenses are listed in [docs/THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).

## License

[MIT](LICENSE)
