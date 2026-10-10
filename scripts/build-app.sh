#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION=release
APP_PATH="$PROJECT_DIR/build/Mistary.app"
case "${1:-}" in
    '') [[ $# -eq 0 ]] || exit 2 ;;
    --debug) [[ $# -eq 1 ]] || exit 2; CONFIGURATION=debug; APP_PATH="$PROJECT_DIR/build/debug/Mistary.app" ;;
    *) printf '%s\n' 'Usage: scripts/build-app.sh [--debug]' >&2; exit 2 ;;
esac
if [[ "${MISTARY_SIGN_IDENTITY:-}" == "Oil Find Self-Signed" || ( "$CONFIGURATION" == release && "${MISTARY_SIGN_IDENTITY:-}" == - ) ]]; then
    printf '%s\n' 'Refusing an upstream or ad-hoc release signing identity.' >&2
    exit 1
fi
OILFIND_FREE=1 swift build -c "$CONFIGURATION"
BINARY_DIR="$(OILFIND_FREE=1 swift build -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY_DIR/OilFind" "$APP_PATH/Contents/MacOS/Mistary"
if [[ "$CONFIGURATION" == release ]]; then
    # Release bundles omit debug symbols containing local source paths.
    strip -S "$APP_PATH/Contents/MacOS/Mistary"
fi
cp "Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi
SELF_SIGNED="Mistary Self-Signed"
if [[ -n "${MISTARY_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$MISTARY_SIGN_IDENTITY" --identifier me.caph.mistary --options runtime --timestamp "$APP_PATH"
elif security find-identity -v -p codesigning | grep -q "\"$SELF_SIGNED\""; then
    # Stable identity; permission persistence still requires manual verification.
    codesign --force --sign "$SELF_SIGNED" --identifier me.caph.mistary "$APP_PATH"
elif [[ "$CONFIGURATION" == debug ]]; then
    printf '%s\n' 'Debug ad-hoc signature: permission persistence across rebuilds is not verified.' >&2
    codesign --force --sign - --identifier me.caph.mistary "$APP_PATH"
else
    printf '%s\n' 'Release requires MISTARY_SIGN_IDENTITY or an existing Mistary Self-Signed certificate.' >&2
    exit 1
fi
printf '%s\n' "$APP_PATH"
