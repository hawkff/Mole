#!/usr/bin/env bats
# Test bodies run in isolated shells; literal scripts expand there.
# shellcheck disable=SC2016,SC2030,SC2031

setup() {
    export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export HOME="$(mktemp -d "$BATS_TEST_TMPDIR/sparkle.XXXXXX")"
    HOME="$(cd "$HOME" && pwd -P)"
    export MOLE_TEST_NO_AUTH=1 MOLE_TEST_MODE=0 MOLE_DRY_RUN=1 NO_COLOR=1
    export MOLE_LSREGISTER_PATH=""
    export TOKEN="$HOME/Library/Caches/com.example.Editor/org.sparkle-project.Sparkle/PersistentDownloads/token"
    export PAYLOAD="$TOKEN/Example 1.0" APP="$HOME/Applications/Example.app"
    export CACHED="$PAYLOAD/Example.app"
    mkdir -p "$HOME/stubs"
    export PATH="$HOME/stubs:$PATH"
    python3 - << 'PY'
import os, pathlib, plistlib
home, app, cached, payload = (pathlib.Path(os.environ[k]) for k in ('HOME', 'APP', 'CACHED', 'PAYLOAD'))
for path, version in ((app, '2.0'), (cached, '1.0')):
    (path / 'Contents/MacOS').mkdir(parents=True)
    (path / 'Contents/Frameworks/Sparkle.framework').mkdir(parents=True)
    (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'com.example.Editor', 'CFBundleVersion': version,
        'CFBundleExecutable': 'Example', 'CFBundleShortVersionString': version,
    }))
    executable = path / 'Contents/MacOS/Example'
    executable.write_text('#!/bin/sh\nexit 0\n')
    executable.chmod(0o755)
(payload / 'Example.zip').write_bytes(b'x' * 4096)
(home / 'mounts.plist').write_bytes(plistlib.dumps({'images': []}))
(home / 'installed-paths').write_text(str(app) + '\n')
PY
    age_payload
    # Only system probes are mocked. Plist parsing, sizing, the clean engine,
    # path/whitelist policy and the final deletion sink remain real.
    cat > "$HOME/stubs/mdfind" << 'SH'
#!/bin/bash
[[ ${MOCK_MDFIND_STATUS:-0} -eq 0 ]] || exit "$MOCK_MDFIND_STATUS"
while IFS= read -r path; do printf '%s\0' "$path"; done < "$HOME/installed-paths"
SH
    cat > "$HOME/stubs/pgrep" << 'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/process-probes"
exit "${MOCK_PROCESS_STATUS:-1}"
SH
    cat > "$HOME/stubs/lsof" << 'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/handle-probes"
if [[ "$*" == *'-p 1'* ]]; then
    [[ ${MOCK_LSOF_VISIBILITY:-0} -eq 0 ]] || exit 1
    printf 'p1\nu0\n'
    exit 0
fi
[[ -z ${MOCK_LSOF_ERROR:-} ]] || printf '%s\n' "$MOCK_LSOF_ERROR" >&2
if [[ ${MOCK_LSOF_STATUS:-1} -eq 0 ]]; then printf 'p123\nf3\nn%s\n' "$PAYLOAD/Example.zip"; fi
# A later candidate remains eligible in the interruption regression.
[[ "$*" != *'/zz-later'* ]] || exit 1
exit "${MOCK_LSOF_STATUS:-1}"
SH
    cat > "$HOME/stubs/hdiutil" << 'SH'
#!/bin/bash
/bin/cat "$HOME/mounts.plist"
exit "${MOCK_MOUNT_STATUS:-0}"
SH
    chmod +x "$HOME/stubs/"*
}

age_payload() {
    python3 - << 'PY'
import os
root = os.environ['TOKEN']
for parent, dirs, files in os.walk(root):
    for path in [parent] + [os.path.join(parent, n) for n in dirs + files]:
        os.utime(path, (1577836800, 1577836800), follow_symlinks=False)
PY
}

run_sparkle() {
    run /bin/bash --noprofile --norc -c '
        set -euo pipefail
        source "$PROJECT_ROOT/bin/clean.sh"
        eval "$1"
    ' bash "$1"
}

@test "Sparkle preview shows owner, versions, whole payload path and estimated size" {
    run_sparkle 'clean_sparkle_downloads; printf "ITEMS=%s SIZE=%s\n" "$files_cleaned" "$total_size_cleaned"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Example.app (cached 1.0, installed 2.0)"* ]] || return 1
    [[ "$output" == *"PersistentDownloads/token"* && "$output" == *"dry"* ]] || return 1
    [[ "$output" == *"ITEMS=1 SIZE="* && "$output" != *"SIZE=0"* ]] || return 1
    [ -f "$PAYLOAD/Example.zip" ]
    [ -f "$CACHED/Contents/Info.plist" ]
    [ -s "$HOME/handle-probes" ]
}

@test "Sparkle real cleanup deletes the archive and extracted app together and logs one item" {
    run_sparkle 'DRY_RUN=false; MOLE_DRY_RUN=0; clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ITEMS=1"* ]] || return 1
    [ ! -e "$TOKEN" ]
    [ -f "$APP/Contents/Info.plist" ]
    run python3 -c 'import os, pathlib; s=(pathlib.Path(os.environ["HOME"])/"Library/Logs/mole/operations.log").read_text(); assert "REMOVED " + os.environ["TOKEN"] in s'
    [ "$status" -eq 0 ]
}

@test "Sparkle keeps equal, newer, nonnumeric and missing cached versions at any age" {
    for version in 2.0 3.0 1.0-beta '' 1.99999999999999; do
        plutil -replace CFBundleVersion -string "$version" "$CACHED/Contents/Info.plist"
        age_payload
        run_sparkle 'DRY_RUN=false; MOLE_DRY_RUN=0; clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
        [ "$status" -eq 0 ]
        [[ "$output" == *"ITEMS=0"* ]] || return 1
        [ -d "$TOKEN" ]
    done
}

@test "dotted version comparison is numeric, treats missing components as zero and rejects corrupt suffixes" {
    run_sparkle '
        mole_version_is_older 1.9 1.10 || exit 1
        mole_version_is_older 001.08 1.9 || exit 1
        ! mole_version_is_older 2.0 2 || exit 1
        ! mole_version_is_older 2 2.0 || exit 1
        ! mole_version_is_older 1.9999999999999 2.0 || exit 1
        ! mole_version_is_older 1.2rc1 1.3 || exit 1
    '
    [ "$status" -eq 0 ]
}

@test "Sparkle retains unknown, conflicting and channel-mismatched owners" {
    plutil -replace CFBundleIdentifier -string com.example.Other "$CACHED/Contents/Info.plist"
    age_payload
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    plutil -replace CFBundleIdentifier -string com.example.Editor "$CACHED/Contents/Info.plist"
    age_payload
    cp -R "$APP" "$HOME/Applications/Other.app"
    printf '%s\n' "$HOME/Applications/Other.app" >> "$HOME/installed-paths"
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    export MOCK_MDFIND_STATUS=1
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    [ -d "$TOKEN" ]
}

@test "Sparkle same-name filesystem fallback verifies identity when Spotlight is empty" {
    : > "$HOME/installed-paths"
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=1"* ]] || return 1
    plutil -replace CFBundleIdentifier -string com.example.Other "$APP/Contents/Info.plist"
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]]
}

@test "Sparkle keeps incomplete generic apps and unversioned archive-only downloads" {
    rm "$CACHED/Contents/Info.plist"
    run_sparkle 'DRY_RUN=false; MOLE_DRY_RUN=0; clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    mv "$CACHED" "$HOME/extracted"
    age_payload
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    [ -f "$PAYLOAD/Example.zip" ]
}

@test "Sparkle recognizes incomplete Brave Nightly from the matching framework version" {
    local brave_root="$HOME/Library/Caches/com.brave.Browser.nightly/org.sparkle-project.Sparkle/PersistentDownloads"
    mkdir -p "$brave_root"
    mv "$TOKEN" "$brave_root/token"
    export TOKEN="$brave_root/token" PAYLOAD="$brave_root/token/Brave Browser Nightly 196.35"
    mv "$TOKEN/Example 1.0" "$PAYLOAD"
    mv "$APP" "$HOME/Applications/Brave Browser Nightly.app"
    export APP="$HOME/Applications/Brave Browser Nightly.app"
    mv "$PAYLOAD/Example.app" "$PAYLOAD/Brave Browser Nightly.app"
    export CACHED="$PAYLOAD/Brave Browser Nightly.app"
    mv "$PAYLOAD/Example.zip" "$PAYLOAD/Brave-Browser-Nightly-arm64.dmg"
    rm "$CACHED/Contents/Info.plist"
    mkdir -p "$CACHED/Contents/Frameworks/Brave Browser Framework.framework/Versions/152.1.96.35"
    mkdir -p "$APP/Contents/Frameworks/Brave Browser Framework.framework/Versions/153.1.97.31"
    plutil -replace CFBundleIdentifier -string com.brave.Browser.nightly "$APP/Contents/Info.plist"
    plutil -replace CFBundleVersion -string 153.1.97.31 "$APP/Contents/Info.plist"
    printf '%s\n' "$APP" > "$HOME/installed-paths"
    age_payload
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=1"* ]] || return 1
    [[ "$output" == *"cached 152.1.96.35, installed 153.1.97.31"* ]] || return 1
    [ -d "$TOKEN" ]
    local versions="$CACHED/Contents/Frameworks/Brave Browser Framework.framework/Versions"
    mv "$versions/152.1.96.35" "$versions/154.1.98.1"
    age_payload
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    mv "$versions/154.1.98.1" "$versions/152.1.96.35"
    ln -s 154.1.98.1 "$versions/Current"
    age_payload
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    rm "$versions/Current"
    age_payload
    run_sparkle 'DRY_RUN=false; MOLE_DRY_RUN=0; clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=1"* ]] || return 1
    [ ! -e "$TOKEN" ]
    [ -d "$APP" ]
}

@test "Sparkle refuses mixed payloads and extra token siblings" {
    touch "$PAYLOAD/keep.txt"
    age_payload
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    rm "$PAYLOAD/keep.txt"
    mkdir "$TOKEN/another-payload"
    age_payload
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]]
}

@test "Sparkle keeps recently modified descendants even in an old token" {
    touch "$CACHED/Contents/MacOS/Example"
    run_sparkle 'DRY_RUN=false; MOLE_DRY_RUN=0; clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    [ -d "$TOKEN" ]
}

@test "Sparkle preserves whitelisted owner roots, tokens and individual descendants" {
    for protected in "${TOKEN%/org.sparkle-project.Sparkle/*}" "$TOKEN" "$PAYLOAD/Example.zip"; do
        export PROTECTED="$protected"
        run_sparkle 'WHITELIST_PATTERNS=("$PROTECTED"); clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
        [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    done
    [ -d "$TOKEN" ]
}

@test "generic cache cleanup cannot bypass the Sparkle guard or count the same bytes twice" {
    run_sparkle '
        clean_user_essentials
        [[ -d "$TOKEN" ]] || exit 1
        for path in "${TOKEN%/*}" "${TOKEN%/PersistentDownloads/*}" "$TOKEN" "$PAYLOAD/Example.zip"; do
            should_protect_path "$path" || exit 1
            safe_clean "$path" "Unverified download"
        done
        [[ $files_cleaned -eq 0 ]] || exit 1
        clean_sparkle_downloads
        [[ $files_cleaned -eq 1 ]] || exit 1
        echo GUARDED
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *GUARDED* ]]
}

@test "Sparkle keeps payloads while owner or updater process state is active or unknown" {
    for state in 0 2; do
        export MOCK_PROCESS_STATUS="$state"
        run_sparkle 'DRY_RUN=false; MOLE_DRY_RUN=0; clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
        [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
        [ -d "$TOKEN" ]
    done
    [ -s "$HOME/process-probes" ]
}

@test "Sparkle fails closed on open handles, diagnostic output, incomplete visibility and timeout" {
    for state in 0 2 124; do
        export MOCK_LSOF_STATUS="$state"
        run_sparkle 'DRY_RUN=false; MOLE_DRY_RUN=0; clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
        [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
        [ -d "$TOKEN" ]
    done
    export MOCK_LSOF_STATUS=1 MOCK_LSOF_ERROR='cannot inspect directory'
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    unset MOCK_LSOF_ERROR
    export MOCK_LSOF_VISIBILITY=1
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]]
}

@test "Sparkle preserves mounted images and rejects a failed mount inventory" {
    python3 - << 'PY'
import os, pathlib, plistlib
p = pathlib.Path(os.environ['HOME']) / 'mounts.plist'
p.write_bytes(plistlib.dumps({'images': [{'image-path': os.environ['PAYLOAD'] + '/Example.zip', 'system-entities': []}]}))
PY
    run_sparkle 'DRY_RUN=false; MOLE_DRY_RUN=0; clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>images</key><array/></dict></plist>' > "$HOME/mounts.plist"
    export MOCK_MOUNT_STATUS=1
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    [ -d "$TOKEN" ]
}

@test "Sparkle rejects symlinked cache ancestors and metadata" {
    mv "$CACHED/Contents/Info.plist" "$HOME/info.plist"
    ln -s "$HOME/info.plist" "$CACHED/Contents/Info.plist"
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    rm "$CACHED/Contents/Info.plist"
    mv "$HOME/info.plist" "$CACHED/Contents/Info.plist"
    local root="${TOKEN%/PersistentDownloads/*}"
    mv "$root" "$HOME/elsewhere"
    ln -s "$HOME/elsewhere" "$root"
    run_sparkle 'DRY_RUN=false; MOLE_DRY_RUN=0; clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    [ -d "$TOKEN" ]
}

@test "Sparkle rechecks installed version and process state after sizing in preview and real mode" {
    for mode in true false; do
        export MODE="$mode"
        run_sparkle '
            DRY_RUN="$MODE"; [[ "$MODE" == true ]] || MOLE_DRY_RUN=0
            get_cleanup_path_size_kb() { plutil -replace CFBundleVersion -string 0.5 "$APP/Contents/Info.plist"; echo 100; }
            clean_sparkle_downloads; echo "ITEMS=$files_cleaned"
        '
        [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
        [ -d "$TOKEN" ]
        plutil -replace CFBundleVersion -string 2.0 "$APP/Contents/Info.plist"
        run_sparkle '
            DRY_RUN="$MODE"; [[ "$MODE" == true ]] || MOLE_DRY_RUN=0
            get_cleanup_path_size_kb() { touch "$HOME/started"; echo 100; }
            _sparkle_download_process_state() { [[ -e "$HOME/started" ]]; }
            clean_sparkle_downloads; echo "ITEMS=$files_cleaned"
        '
        [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
        [ -d "$TOKEN" ]
        rm "$HOME/started"
    done
}

@test "Sparkle refuses a token replacement during sizing" {
    run_sparkle '
        DRY_RUN=false; MOLE_DRY_RUN=0
        get_cleanup_path_size_kb() { mv "$TOKEN" "$HOME/original"; cp -Rp "$HOME/original" "$TOKEN"; echo 100; }
        clean_sparkle_downloads; echo "ITEMS=$files_cleaned"
    '
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    [ -d "$TOKEN" ]
    [ -d "$HOME/original" ]
}

@test "Sparkle final sink guard rejects changes after safe_clean authorization" {
    run_sparkle '
        DRY_RUN=false; MOLE_DRY_RUN=0
        validate_path_for_deletion() { plutil -replace CFBundleVersion -string 0.5 "$APP/Contents/Info.plist"; return 0; }
        clean_sparkle_downloads; echo "ITEMS=$files_cleaned"
    '
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    [ -d "$TOKEN" ]
}

@test "Sparkle propagates interruption without examining a later eligible token" {
    cp -Rp "$TOKEN" "${TOKEN%/*}/zz-later"
    export MOCK_LSOF_STATUS=130
    run_sparkle 'clean_sparkle_downloads'
    [ "$status" -eq 130 ]
    [ -d "$TOKEN" ]
    [ -d "${TOKEN%/*}/zz-later" ]
    run python3 -c 'import os, pathlib; s=(pathlib.Path(os.environ["HOME"])/"handle-probes").read_text(); assert "zz-later" not in s; assert "+D " in s'
    [ "$status" -eq 0 ]
}

@test "Sparkle payload enumeration ignores caller GLOBIGNORE" {
    touch "$PAYLOAD/keep.txt"
    age_payload
    run_sparkle 'GLOBIGNORE="keep.txt"; clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0"* ]] || return 1
    [ -f "$PAYLOAD/keep.txt" ]
}

@test "Sparkle compares binary plist metadata without parsing display output" {
    plutil -convert binary1 "$APP/Contents/Info.plist" "$CACHED/Contents/Info.plist"
    age_payload
    run_sparkle 'clean_sparkle_downloads; echo "ITEMS=$files_cleaned"'
    [[ "$status" -eq 0 && "$output" == *"ITEMS=1"* ]]
}

@test "Sparkle never counts failed deletions as reclaimed space" {
    run_sparkle '
        DRY_RUN=false; MOLE_DRY_RUN=0
        rm() { return 1; }
        clean_sparkle_downloads
        echo "ITEMS=$files_cleaned SIZE=$total_size_cleaned"
    '
    [[ "$status" -eq 0 && "$output" == *"ITEMS=0 SIZE=0"* ]] || return 1
    [ -d "$TOKEN" ]
}

@test "Sparkle accepts fractional probe budgets without shell arithmetic errors" {
    export MOLE_TIMEOUT_DISK_VERIFY_SEC=0.5
    run_sparkle 'clean_sparkle_downloads; echo SCANNED'
    [[ "$status" -eq 0 && "$output" == *SCANNED* ]]
}

@test "mo clean invokes Sparkle cleanup through the normal command flow" {
    run_sparkle '
        declare -f clean_sparkle_downloads > /dev/null || exit 1
        # Stub every cleanup family, leaving orchestration and preview real.
        while read -r _ _ fn; do
            case "$fn" in
                clean_* | _clean_*) eval "$fn() { :; }" ;;
            esac
        done < <(declare -F)
        check_tcc_permissions() { :; }
        check_large_file_candidates() { :; }
        show_project_artifact_hint_notice() { :; }
        show_user_launch_agent_hint_notice() { :; }
        clean_sparkle_downloads() { echo SPARKLE_STEP_CALLED; }
        main --dry-run
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *SPARKLE_STEP_CALLED* ]] || return 1
    [[ "$output" == *"Dry run complete"* ]] || return 1
    [ -d "$TOKEN" ]
}
