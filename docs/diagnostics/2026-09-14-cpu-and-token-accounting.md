# CPU and token-accounting diagnosis

The installed application is Token Burn 4.4.0 (`com.aiusagemeter`) at
`/Applications/Token Burn.app`. LaunchAgent `com.tokenburn.agent` runs
`~/Library/Application Support/TokenBurn/AIUsageMeter`.

Diagnosis began from upstream main
`36080fcb31e8a972f50031b73f995bba0ccf7d21`, before reading PR #4.
That main revision is newer than the installed 4.4.0 release.

## Findings and changes

| Finding | Proposed behavior |
| --- | --- |
| A consuming service starts a 12 Hz timer that regenerates every menu-bar cell. Live sampling found status-item drawing in `MenuBarIconRenderer`; bounded CPU samples were commonly 12–15%. | A static activity indicator; the production render gate updates only for changed representative-account, usage, load, or appearance inputs. Load sampling remains at 1.5 seconds, with integer-percent display values. |
| The 24h number used today's total, while the 1h number/chart filtered hour-start buckets. | Exact source-event timestamps drive matching rolling 1h, 24h, and 168h numbers and chart buckets. Labels use the same snapshot time. |
| Claude discovery skipped nested subagent/workflow transcripts. Replayed/partial records could double-count or discard final usage. | Recursive regular-file discovery, stable-message reconciliation before aggregation, and consistent event/daily/hourly/provider totals. The original message timestamp is preserved. |
| Claude reread unchanged files and recreated timestamp formatters; independent background refreshes could overlap. | Stream changed files, cache compact per-file usage records, reuse formatters, serialize parsers, and coalesce pending token refreshes. Changed files are read from the beginning; this is not an append-offset cache. |
| Codex missed flat archives and recent events in old session directories, served stale cached results after appends, and returned zero to a concurrent initial caller. Repeated cumulative snapshots could count usage again. | Discover files by modification time, revalidate file metadata, serialize first parses, and suppress unchanged cumulative usage while preserving quota updates. Existing copied-history deduplication is retained. |
| Claude excluded cached input while Codex included it. | Both totals include cached input once, with an explicit label. Cost calculation retains separate uncached/cache rates. |
| A shared 168-entry limit truncated seven-day quota history to hours. | Retain the latest sample per provider/minute within seven days, regardless of refresh frequency. Previously discarded history cannot be reconstructed. |

## Verification

The following commands passed on macOS with Command Line Tools:

```sh
swift build
scripts/verify-token-accounting.sh
scripts/verify-menu-bar.sh
git diff --check
```

The token harnesses exercise the actual parser/model sources and assert recursive
Claude discovery, partial/final reconciliation, cache-inclusive counts and unchanged
pricing, file-change invalidation, Codex archives/resumed sessions/cumulative replay,
concurrent first reads, rolling boundaries, and bounded history retention.

A clean upstream parser run failed the flat-archive regression; the fixed harness
passed. The history fixture retained 30,240 one-minute samples across three providers
for seven days. The rolling harness checks numeric totals against chart sums.

The menu-bar harness uses a synthetic 12 Hz schedule with the real baseline renderer,
then the real fixed renderer and production render gate. In the final recorded
five-second run, unchanged inputs caused **57 baseline renders and 0 fixed renders**.
Additional input transitions produced the expected renders. Images are materialized,
rather than only constructing lazy `NSImage` objects. This is a render-regression
test, not a claim about a fixed whole-application CPU percentage.

The local toolchain lacks the XCTest module, so `swift test` could not run.
Standalone assertion harnesses are checked in and do not need XCTest or private logs.
The menu-bar comparison reads the pinned baseline revision from Git history, so a
checkout running it must contain that revision.

## Limits

Aside-specific amplification has not been reproduced. Aside was running at low CPU
during the original sample. The continuous-rendering mechanism is independently
confirmed. No claim that Aside duplicates logs or causes the parser bugs is made.

The installed application was not replaced or restarted. The earlier full-app runs
using an unsupported demo environment flag were not isolated; their CPU comparisons
are excluded from verification. The final harness uses synthetic models and an
isolated preferences suite, without provider credentials or network access.
