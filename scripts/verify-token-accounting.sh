#!/bin/zsh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT
cp "$ROOT/Tests/RegressionSupport/Codex/main.swift" "$BUILD_DIR/main.swift"
swiftc "$ROOT"/Sources/AIUsageMeterCore/*.swift "$BUILD_DIR/main.swift" -o "$BUILD_DIR/codex-parser-harness"
"$BUILD_DIR/codex-parser-harness"
cp "$ROOT/Tests/RegressionSupport/Rolling/main.swift" "$BUILD_DIR/main.swift"
swiftc "$ROOT"/Sources/AIUsageMeterCore/*.swift "$BUILD_DIR/main.swift" -o "$BUILD_DIR/rolling-harness"
"$BUILD_DIR/rolling-harness"
cp "$ROOT/Tests/RegressionSupport/History/main.swift" "$BUILD_DIR/main.swift"
swiftc -emit-module -emit-library -module-name AIUsageMeterCore "$ROOT"/Sources/AIUsageMeterCore/*.swift -o "$BUILD_DIR/libAIUsageMeterCore.dylib"
swiftc -module-name AIUsageMeter -emit-executable -I "$BUILD_DIR" -L "$BUILD_DIR" -lAIUsageMeterCore "$ROOT"/Sources/AIUsageMeter/Models/UsageHistory.swift "$BUILD_DIR/main.swift" -o "$BUILD_DIR/history-harness"
"$BUILD_DIR/history-harness"
cp "$ROOT/Tests/RegressionSupport/Claude/main.swift" "$BUILD_DIR/main.swift"
swiftc "$ROOT"/Sources/AIUsageMeterCore/*.swift "$BUILD_DIR/main.swift" -o "$BUILD_DIR/claude-harness"
"$BUILD_DIR/claude-harness"
