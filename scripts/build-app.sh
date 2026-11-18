#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$ROOT/dist}"
FINAL_APP_PATH="$OUTPUT_DIR/昨天今天明天.app"
LEGACY_APP_PATH="$OUTPUT_DIR/予安.app"
SCRATCH_PATH="$ROOT/.build/app-release"
export SWIFTPM_CACHE_PATH="${SWIFTPM_CACHE_PATH:-$ROOT/.build/swiftpm-cache}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/module-cache}"

# Never replace the executable of an active process. Fail closed when the
# process inventory is unavailable rather than invalidating a live signature.
ensure_app_stopped() {
  local process_list executable
  if ! process_list=$(/bin/ps -axo comm= 2>/dev/null); then
    echo "Cannot check running applications; installation has been stopped safely." >&2
    exit 1
  fi
  while IFS= read -r executable; do
    if [[ "$executable" == "$FINAL_APP_PATH/Contents/MacOS/PersonalAssistant" || "$executable" == "$LEGACY_APP_PATH/Contents/MacOS/PersonalAssistant" || "$executable" == "$FINAL_APP_PATH/Contents/Library/Helpers/"* ]]; then
      echo "Quit 昨天今天明天 before building: an active application will not be overwritten." >&2
      exit 1
    fi
  done <<< "$process_list"
}

cd "$ROOT"
ensure_app_stopped
mkdir -p "$OUTPUT_DIR" "$SWIFTPM_CACHE_PATH" "$CLANG_MODULE_CACHE_PATH"
STAGING_ROOT=$(mktemp -d "$OUTPUT_DIR/.yuan-build.XXXXXX")
APP_PATH="$STAGING_ROOT/昨天今天明天.app"
PREVIOUS_APP_PATH="$STAGING_ROOT/previous.app"
cleanup() {
  # Restore the last complete bundle if publication failed between renames.
  if [[ -d "$PREVIOUS_APP_PATH" && ! -e "$FINAL_APP_PATH" ]]; then
    mv "$PREVIOUS_APP_PATH" "$FINAL_APP_PATH"
  fi
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

swift build --disable-sandbox -c release --scratch-path "$SCRATCH_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$APP_PATH/Contents/Library/LaunchAgents"
cp "$SCRATCH_PATH/release/PersonalAssistant" "$APP_PATH/Contents/MacOS/PersonalAssistant"
cp "$ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
mkdir -p "$APP_PATH/Contents/Resources/Avatars"
for avatar_id in warm blue green peach; do
  cp "$ROOT/Resources/Avatars/avatar-${avatar_id}-v1.png" "$APP_PATH/Contents/Resources/Avatars/"
done
ICONSET_PATH="$ROOT/.build/branding/AppIcon.iconset"
mkdir -p "$ICONSET_PATH"
cp "$ROOT/Resources/Branding/app-icon-v1.png" "$APP_PATH/Contents/Resources/AppIconArtwork.png"
swift "$ROOT/scripts/generate-app-icon.swift" "$ICONSET_PATH" "$APP_PATH/Contents/Resources/AppIcon.icns" "$ROOT/Resources/Branding/app-icon-v1.png"
cp "$ROOT/Resources/com.yuan.personal-assistant.message-receiver.plist" "$APP_PATH/Contents/Library/LaunchAgents/com.yuan.personal-assistant.message-receiver.plist"
cp "$ROOT/Resources/com.yuan.personal-assistant.daily-plan.plist" "$APP_PATH/Contents/Library/LaunchAgents/com.yuan.personal-assistant.daily-plan.plist"
# Separate LaunchServices identity prevents the persistent receiver from
# intercepting a later foreground app launch. Mirror the release metadata.
HELPER_PATH="$APP_PATH/Contents/Library/Helpers/DingTalkEventWorker.app"
mkdir -p "$HELPER_PATH/Contents/MacOS"
cp "$SCRATCH_PATH/release/PersonalAssistant" "$HELPER_PATH/Contents/MacOS/PersonalAssistant"
cp "$ROOT/Resources/Info.plist" "$HELPER_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.yuan.personal-assistant.event-worker' "$HELPER_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName 昨天今天明天后台消息服务' "$HELPER_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName 昨天今天明天后台消息服务' "$HELPER_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSBackgroundOnly bool true' "$HELPER_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' "$HELPER_PATH/Contents/Info.plist"
printf 'APPL????'  > "$APP_PATH/Contents/PkgInfo"

# A certificate identity provides continuity across releases. An ad-hoc
# signature is suitable for local builds but cannot promise persistent trust
# for an existing login-keychain ACL after every binary update.
SIGNING_IDENTITY="${YUAN_CODE_SIGN_IDENTITY:-}"
SIGNING_CONFIG="$ROOT/Resources/Signing.local.json"
if [[ -z "$SIGNING_IDENTITY" && -f "$SIGNING_CONFIG" ]]; then
  SIGNING_IDENTITY=$(/usr/bin/plutil -extract identity raw -o - "$SIGNING_CONFIG")
  if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == "-" ]]; then
    echo "The configured signing identity is invalid; refusing an ad-hoc fallback." >&2
    exit 1
  fi
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
codesign --force --sign "$SIGNING_IDENTITY" "$HELPER_PATH"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - --identifier com.yuan.personal-assistant \
    --requirements '=designated => identifier "com.yuan.personal-assistant"' "$APP_PATH"
else
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_PATH"
fi
EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")
[[ -x "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" ]]
codesign --verify --deep --strict "$APP_PATH"
ensure_app_stopped
if [[ -e "$FINAL_APP_PATH" ]]; then mv "$FINAL_APP_PATH" "$PREVIOUS_APP_PATH"; fi
mv "$APP_PATH" "$FINAL_APP_PATH"
echo "Built: $FINAL_APP_PATH"
echo "Launch with: open \"$FINAL_APP_PATH\""
