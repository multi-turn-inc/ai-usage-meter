<div align="center">

# AI Usage Meter

**Real-time AI service quota tracker for your macOS menu bar.**

Keep tabs on Claude and Codex usage without leaving your workflow.

[![macOS](https://img.shields.io/badge/macOS-26.0%2B-000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub release](https://img.shields.io/github/v/release/multi-turn-inc/ai-usage-meter?include_prereleases)](../../releases)

<br>
<img src="docs/screenshot-settings.png" width="320" alt="AI Usage Meter - Settings">

</div>

<br>

## Features

- **Menu Bar at a Glance** — Per-service bar charts show remaining quota directly in the menu bar
- **Circular Gauges** — Animated dual-ring gauges: outer ring for 5-hour, inner for 7-day window
- **Real-time Detection** — Network-based consumption detection with heartbeat animations
- **Detailed Breakdown** — Remaining percentage, reset countdown, and plan tier for each service
- **Usage History** — 24-hour and 7-day usage charts to spot trends
- **Auto Refresh** — Configurable polling interval (1m / 5m / 15m / 30m)
- **Account Switch Detection** — Instantly picks up credential changes when you switch accounts
- **macOS Native** — Built with SwiftUI and Liquid Glass on macOS Tahoe
- **10 Languages** — English, Korean, Japanese, Chinese, Spanish, French, German, Portuguese, Russian, Italian

## Supported Services

| Service | Auth Method | Metrics |
|---------|------------|---------|
| **Claude** | OAuth via Claude Code Keychain | 5-hour window, 7-day window, plan tier |
| **Codex** | OAuth via Codex CLI Keychain | 5-hour window, 7-day window, plan tier |

> Gemini support is available but disabled by default. Enable it in Settings.

## Install

### Download

Grab the latest `.dmg` from the [Releases](../../releases) page.

### Manual

1. Open the DMG and drag **AI Usage Meter** to Applications
2. The app is signed and notarized — it should open normally

## How It Works

AI Usage Meter reads existing OAuth credentials from your local CLI tools. **No API keys or passwords are stored by the app.**

| Service | Credential Source |
|---------|-----------------|
| Claude | macOS Keychain (`Claude Code-credentials`) |
| Codex | macOS Keychain (`Codex-credentials`) / `~/.codex/auth.json` |

The app queries each provider's usage/quota API and displays the results. Token refresh is handled automatically.

## Requirements

- macOS 26.0 (Tahoe) or later
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) or [Codex CLI](https://github.com/openai/codex) installed and authenticated

## Build from Source

```bash
git clone https://github.com/multi-turn-inc/ai-usage-meter.git
cd ai-usage-meter
swift build
.build/debug/AIUsageMonitor
```

> Requires Xcode 16+ and macOS 26.0 (Tahoe) SDK.

## Security

This app is a **read-only quota viewer**. It:
- Reads existing OAuth tokens from your CLI tools' Keychain entries
- Calls usage/quota API endpoints (read-only, no token consumption)
- Refreshes expired tokens using the standard OAuth refresh flow
- Never stores credentials — all tokens remain in the system Keychain

## License

[MIT](LICENSE)
