<div align="center">

# Token Burn

**See what your AI agents are burning. Right from the menu bar.**

Claude Code and Codex usage — remaining quota, token consumption, reset timers — at a glance.

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/multi-turn-inc/ai-usage-meter?include_prereleases)](../../releases)

</div>

<br>

## What It Does

**Menu bar icon** encodes two things at once:
- Horizontal fill → 5-hour remaining quota
- Bar height → 7-day remaining quota

When an AI agent is actively calling APIs, the bars pulse with a heartbeat animation.

**Click to open the panel:**
- Circular gauges per service (Claude, Codex)
- 5h / 7d remaining percentage with reset countdown
- Token Burn chart — 1h, 24h, 7d scope, switch by trackpad scroll

**Token tracking** parses local logs directly:
- Claude Code: `~/.claude/projects/**/*.jsonl`
- Codex: `~/.codex/logs_2.sqlite`
- Counts `input_tokens + output_tokens` (matches Claude `/stats`)
- Everything stays local. Nothing is sent to any server.

## Install

Grab the latest `.dmg` from [Releases](../../releases).

```bash
# Or build from source
git clone https://github.com/multi-turn-inc/ai-usage-meter.git
cd ai-usage-meter
swift build -c release
./scripts/build-app.sh 4.2.0
```

### Requirements

- macOS 14.0 (Sonoma) or later
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) or [Codex CLI](https://github.com/openai/codex) installed and authenticated

## How It Works

Token Burn reads existing OAuth credentials from your local CLI tools. **No API keys or passwords are stored by the app.**

| Service | Credential Source | Token Source |
|---------|-----------------|--------------|
| Claude | Keychain / `~/.claude/.credentials.json` | JSONL session logs |
| Codex | Keychain / `~/.codex/auth.json` | SQLite logs |

The app queries each provider's usage API and parses local token logs. Token refresh is handled automatically.

## Features

- **Remaining-first view** — shows how much is left, not how much you used
- **Token Burn chart** — 1h / 24h / 7d scope with trackpad scroll
- **Real-time detection** — heartbeat animation when AI is actively calling APIs
- **Reset countdown** — "3h 38m until reset"
- **Auto-refresh** — configurable interval (1m / 5m / 15m / 30m)
- **Auto-update** — checks GitHub releases, downloads and applies automatically
- **Credential recovery** — restores credential file from Keychain when deleted
- **10 languages** — EN, KO, JA, ZH, ES, FR, DE, PT, RU, IT
- **macOS native** — SwiftUI with Liquid Glass on macOS Tahoe

## Security

This app is a **read-only viewer**. It:
- Reads existing OAuth tokens from CLI tools' Keychain entries
- Calls usage API endpoints (read-only)
- Parses local log files (read-only)
- Refreshes expired tokens via standard OAuth flow
- Never stores credentials outside the system Keychain

## License

[MIT](LICENSE)
