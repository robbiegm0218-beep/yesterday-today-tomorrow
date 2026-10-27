#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR="$(xcode-select -p)"
FRAMEWORKS_PATH="$DEVELOPER_DIR/Library/Developer/Frameworks"
TESTING_RUNTIME="$DEVELOPER_DIR/Library/Developer/usr/lib"
export SWIFTPM_CACHE_PATH="${SWIFTPM_CACHE_PATH:-$ROOT/.build/swiftpm-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/module-cache}"
mkdir -p "$SWIFTPM_CACHE_PATH" "$CLANG_MODULE_CACHE_PATH"

if [[ ! -d "$FRAMEWORKS_PATH/Testing.framework" ]]; then
  FRAMEWORKS_PATH="$DEVELOPER_DIR/Library/Frameworks"
fi
if [[ ! -e "$TESTING_RUNTIME/lib_TestingInterop.dylib" ]]; then
  TOOLCHAIN_TESTING_RUNTIME="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib"
  if [[ -e "$TOOLCHAIN_TESTING_RUNTIME/lib_TestingInterop.dylib" ]]; then
    TESTING_RUNTIME="$TOOLCHAIN_TESTING_RUNTIME"
  fi
fi

cd "$ROOT"
swift test --disable-sandbox --scratch-path "$ROOT/.build/test" \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS_PATH" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS_PATH" \
  -Xlinker -rpath -Xlinker "$TESTING_RUNTIME"
