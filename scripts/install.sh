#!/bin/bash
set -euo pipefail
[[ $# -eq 0 ]] || { printf '%s\n' 'Usage: scripts/install.sh' >&2; exit 2; }
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

SOURCE_APP="${MISTARY_SOURCE_APP:-$PROJECT_DIR/build/Mistary.app}"
# Validate an existing destination before building or asking running applications to quit.
if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then validate_app "$APP_PATH"; fi
"${MISTARY_BUILD_SCRIPT:-$PROJECT_DIR/scripts/build-app.sh}"
validate_app "$SOURCE_APP"
codesign --verify --strict "$SOURCE_APP"
# Stage on the destination volume; copying and signature checks cannot damage the installed app.
STAGING_DIR="$(mktemp -d "$APPLICATIONS_DIR/.Mistary-install.XXXXXX")"
STAGED_APP="$STAGING_DIR/new/Mistary.app"
BACKUP_APP="$STAGING_DIR/previous/Mistary.app"
PRESERVE_STAGING=false
REPLACEMENT_PENDING=false
cleanup_stage() {
    local cleanup_status=$?
    # Error exits and catchable signals share the same recovery path.
    if [[ "$REPLACEMENT_PENDING" == true && -d "$BACKUP_APP" ]]; then
        if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
            PRESERVE_STAGING=true
        elif ! mv "$BACKUP_APP" "$APP_PATH"; then
            PRESERVE_STAGING=true
        fi
    fi
    if [[ "$PRESERVE_STAGING" == true ]]; then
        printf 'Previous app preserved at: %s\n' "$BACKUP_APP" >&2
    elif [[ -d "$STAGING_DIR" ]]; then
        if ! osascript -l JavaScript -e "$(cat <<'JXA'
ObjC.import('Foundation');
function run(argv) {
    if (!$.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError($.NSURL.fileURLWithPath(argv[0]), null, null))
        throw new Error('Cannot move Mistary installation staging to Trash');
}
JXA
)" -- "$STAGING_DIR"; then
            printf 'Installation files preserved at: %s\n' "$STAGING_DIR" >&2
            if [[ $cleanup_status -eq 0 ]]; then cleanup_status=1; fi
        fi
    fi
    exit "$cleanup_status"
}
trap cleanup_stage EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir -p "$STAGING_DIR/new" "$STAGING_DIR/previous"
ditto "$SOURCE_APP" "$STAGED_APP"
validate_app "$STAGED_APP"
codesign --verify --strict "$STAGED_APP"
quit_mistary
# Keep the previous bundle on the same volume until the new bundle has been moved successfully.
REPLACEMENT_PENDING=true
if [[ -e "$APP_PATH" || -L "$APP_PATH" ]]; then
    validate_app "$APP_PATH"
    mv "$APP_PATH" "$BACKUP_APP"
fi
if ! mv "$STAGED_APP" "$APP_PATH"; then
    printf '%s\n' 'Mistary replacement failed.' >&2
    exit 1
fi
REPLACEMENT_PENDING=false
for ((attempt = 1; attempt <= 5; attempt++)); do
    if open "$APP_PATH"; then exit 0; fi
    if ((attempt < 5)); then sleep 1; fi
done
printf '%s\n' 'Mistary could not be opened after 5 attempts.' >&2
exit 1
