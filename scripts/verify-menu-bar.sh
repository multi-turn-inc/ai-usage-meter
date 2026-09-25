#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/menu-bar-regression.XXXXXX")"
trap 'rm -rf "$work"' EXIT

swiftc -parse-as-library -O -module-name AIUsageMeterCore \
  "$repo"/Sources/AIUsageMeterCore/ServiceType.swift \
  -emit-module -emit-module-path "$work/AIUsageMeterCore.swiftmodule"
swiftc -parse-as-library -O -module-name AIUsageMeterCore -c \
  "$repo"/Sources/AIUsageMeterCore/ServiceType.swift -o "$work/service.o"

run_case() {
  local label="$1" define="$2" source="$3" out="$work/$1"
  swiftc -parse-as-library -O -D "$define" -I "$work" -L "$work" \
    "$repo/Tests/RegressionSupport/MenuBar/main.swift" \
    "$repo/Sources/AIUsageMeter/MenuBar/MenuBarRenderGate.swift" "$source" "$work/service.o" \
    -o "$out"
  "$out" | tee "$work/$label.log"
}

baseline="$work/MenuBarIconRenderer-baseline.swift"
git -C "$repo" show 36080fc:Sources/AIUsageMeter/MenuBar/MenuBarIconRenderer.swift > "$baseline"
run_case baseline BASELINE "$baseline"
run_case fixed FIXED "$repo/Sources/AIUsageMeter/MenuBar/MenuBarIconRenderer.swift"

baseline_count=$(sed -n 's/.*consuming5s=\([0-9][0-9]*\).*/\1/p' "$work/baseline.log")
fixed_count=$(sed -n 's/.*consuming5s=\([0-9][0-9]*\).*/\1/p' "$work/fixed.log")
[[ -n "$baseline_count" && -n "$fixed_count" ]] || { echo "FAIL: missing render counts" >&2; exit 1; }
# The old heartbeat redrew at 12 Hz; the pulse ticks at 5 Hz and skips
# identical frames, so it must stay well under half of that.
(( baseline_count > 40 )) || { echo "FAIL: baseline renders=$baseline_count (expected >40)" >&2; exit 1; }
(( fixed_count * 2 < baseline_count )) || { echo "FAIL: pulse renders=$fixed_count vs baseline $baseline_count" >&2; exit 1; }
echo "PASS menu-bar regression baseline_consuming_renders=$baseline_count pulse_consuming_renders=$fixed_count"
