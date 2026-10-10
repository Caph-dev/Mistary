#!/bin/bash
set -euo pipefail
WITH_DATA=false
case "${1:-}" in
    '') [[ $# -eq 0 ]] || exit 2 ;;
    --with-data) [[ $# -eq 1 ]] || exit 2; WITH_DATA=true ;;
    *) printf '%s\n' 'Usage: scripts/uninstall.sh [--with-data]' >&2; exit 2 ;;
esac
BUNDLE_ID=me.caph.mistary
APPLICATIONS_DIR="${MISTARY_APPLICATIONS_DIR:-/Applications}"
[[ "$APPLICATIONS_DIR" == /* && -d "$APPLICATIONS_DIR" && ! -L "$APPLICATIONS_DIR" ]] || { printf '%s\n' 'Invalid applications directory.' >&2; exit 1; }
APP_PATH="$APPLICATIONS_DIR/Mistary.app"
validate_app() {
    [[ ! -L "$1" && -d "$1" && ! -L "$1/Contents" && ! -L "$1/Contents/Info.plist" ]] || { printf '%s\n' 'Refusing an invalid or linked application.' >&2; return 1; }
    local identity
    identity="$(plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist")"
    [[ "$identity" == "$BUNDLE_ID" ]] || { printf '%s\n' 'Refusing an application with a different bundle identity.' >&2; return 1; }
}
PROCESS_SCRIPT="$(cat <<'JXA'
// Resolve by bundle identifier, never by executable name or Launch Services.
ObjC.import('AppKit');
function run(argv) {
    var apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('me.caph.mistary');
    var pids = [];
    for (var i = 0; i < apps.count; i++) {
        var app = apps.objectAtIndex(i);
        if (argv[0] === 'quit' && !app.terminate) throw new Error('Mistary refused to quit');
        pids.push(String(app.processIdentifier));
    }
    return pids.join(' ');
}
JXA
)"
quit_mistary() {
    local pids
    pids="$(osascript -l JavaScript -e "$PROCESS_SCRIPT" -- list)"
    [[ -n "$pids" ]] || return 0
    osascript -l JavaScript -e "$PROCESS_SCRIPT" -- quit >/dev/null
    for ((attempt = 0; attempt < 50; attempt++)); do
        pids="$(osascript -l JavaScript -e "$PROCESS_SCRIPT" -- list)"
        [[ -n "$pids" ]] || return 0
        sleep 0.1
    done
    printf '%s\n' 'Mistary did not quit within 5 seconds.' >&2
    return 1
}

DATA_PATH="$HOME/Library/Application Support/Mistary"
if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then validate_app "$APP_PATH"; fi
if [[ "$WITH_DATA" == true ]]; then
    for directory in "$HOME/Library" "$HOME/Library/Application Support" "$DATA_PATH" "$HOME/Library/Preferences" "$HOME/.Trash"; do
        [[ ! -L "$directory" ]] || { printf '%s\n' 'Refusing a linked data directory.' >&2; exit 1; }
    done
fi
printf 'Move to Trash: %s\n' "$APP_PATH"
if [[ "$WITH_DATA" == true ]]; then
    printf 'Move data to Trash: %s\nBack up and clear settings: %s\n' "$DATA_PATH" "$BUNDLE_ID"
else
    printf '%s\n' 'Mistary data and settings will be kept.'
fi
read -r -p 'Continue? [y/N] ' confirmation || exit 0
[[ "$confirmation" == y ]] || exit 0
quit_mistary
trash_path() {
    [[ -e "$1" ]] || return 0
    ls -ld "$1"
    osascript -l JavaScript -e "$(cat <<'JXA'
ObjC.import('Foundation');
function run(argv) {
    if (!$.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError($.NSURL.fileURLWithPath(argv[0]), null, null))
        throw new Error('Cannot move Mistary to Trash');
}
JXA
)" -- "$1"
}
# A failure to move the application stops all subsequent data changes.
trash_path "$APP_PATH"
if [[ "$WITH_DATA" == true ]]; then
    if defaults read "$BUNDLE_ID" >/dev/null 2>&1; then
        mkdir -p "$HOME/.Trash"
        BACKUP_DIR="$(mktemp -d "$HOME/.Trash/Mistary-settings.XXXXXX")"
        defaults export "$BUNDLE_ID" "$BACKUP_DIR/$BUNDLE_ID.plist"
        # Use the preferences service after making a recoverable backup to avoid cached values.
        defaults delete "$BUNDLE_ID"
    fi
    trash_path "$DATA_PATH"
fi
