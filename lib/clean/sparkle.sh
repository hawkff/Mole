#!/bin/bash
# Obsolete Sparkle download payloads. Installation staging and app data stay out
# of scope; a token is removable only with one unambiguous, older app payload.
set -euo pipefail

_sparkle_plain_path() {
    local path="$1"
    [[ "$path" == /* && "$path" != *\\* && ! "$path" =~ [[:cntrl:]] ]] || return 1
    case "$path" in
        *'/../'* | */.. | *'/./'* | */. | *'//'*) return 1 ;;
    esac
    while [[ "$path" != / ]]; do
        [[ -e "$path" && ! -L "$path" ]] || return 1
        path="${path%/*}"
        [[ -n "$path" ]] || path=/
    done
}

# All external evidence shares the section deadline. Probe failure retains the
# payload; signals still stop the clean command.
_sparkle_probe() {
    local timeout
    timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$_MOLE_SPARKLE_DEADLINE") || return 1
    local rc=0
    run_with_timeout "$timeout" "$@" < /dev/null || rc=$?
    [[ $rc -lt 128 ]] || return "$rc"
    [[ $rc -eq 0 ]]
}

_sparkle_plist_value() {
    _sparkle_plain_path "$1" || return 1
    _sparkle_probe plutil -extract "$2" raw -o - "$1" 2> /dev/null
}

_sparkle_installed_app() {
    local bundle_id="$1" app_name="$2" candidate id
    local inventory
    inventory=$(create_temp_file) || return 1
    _sparkle_probe mdfind -0 "kMDItemCFBundleIdentifier == '$bundle_id'" \
        > "$inventory" 2> /dev/null || return $?
    # Spotlight may not index a freshly installed app. Same-name fallback
    # paths still have to prove their bundle ID, never just their filename.
    printf '%s\0' "/Applications/$app_name" "$HOME/Applications/$app_name" >> "$inventory"
    _sparkle_app=""
    while IFS= read -r -d '' candidate; do
        [[ $SECONDS -lt $_MOLE_SPARKLE_DEADLINE ]] || return 1
        case "$candidate" in
            "$HOME/Library/Caches/"*) continue ;;
        esac
        [[ -d "$candidate" && "$candidate" == *.app ]] || continue
        id=$(_sparkle_plist_value "$candidate/Contents/Info.plist" CFBundleIdentifier) || return $?
        [[ "$id" == "$bundle_id" ]] || continue
        # Do not identify a mounted installer or a backup as the installed app.
        case "$candidate" in
            /Applications/* | "$HOME/Applications/"*) ;;
            *) return 1 ;;
        esac
        if [[ -n "$_sparkle_app" && ! "$candidate" -ef "$_sparkle_app" ]]; then
            return 1
        fi
        _sparkle_app="$candidate"
    done < "$inventory"
    [[ -n "$_sparkle_app" && -d "$_sparkle_app/Contents/Frameworks/Sparkle.framework" ]] || return 1
    local executable
    executable=$(_sparkle_plist_value "$_sparkle_app/Contents/Info.plist" CFBundleExecutable) || return $?
    [[ -n "$executable" && "$executable" != */* && ! "$executable" =~ [[:cntrl:]] ]] || return 1
    _sparkle_plain_path "$_sparkle_app/Contents/MacOS/$executable" || return 1
    [[ -f "$_sparkle_app/Contents/MacOS/$executable" && -x "$_sparkle_app/Contents/MacOS/$executable" ]] || return 1
    _sparkle_installed=$(_sparkle_plist_value "$_sparkle_app/Contents/Info.plist" CFBundleVersion)
}

_sparkle_download_evidence() {
    local token="$1" root="${1%/*}" owner payload="" cached_app="" entry
    local GLOBIGNORE=""
    owner="${root%/org.sparkle-project.Sparkle/PersistentDownloads}"
    owner="${owner##*/}"
    mole_is_reverse_dns_bundle_id "$owner" || return 1
    [[ "$root" == "$HOME/Library/Caches/$owner/org.sparkle-project.Sparkle/PersistentDownloads" ]] || return 1
    should_protect_data "$owner" && return 1
    _sparkle_plain_path "$token" || return 1
    [[ -d "$token" && -O "$token" ]] || return 1
    is_path_whitelisted "$token" && return 1

    # Sparkle creates a random token, then one desired-filename directory.
    # Refuse extra siblings rather than infer that they belong to this update.
    for entry in "$token"/* "$token"/.[!.]* "$token"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        [[ -z "$payload" && -d "$entry" ]] || return 1
        _sparkle_plain_path "$entry" || return 1
        payload="$entry"
    done
    [[ -n "$payload" ]] || return 1
    local archives=0
    for entry in "$payload"/* "$payload"/.[!.]* "$payload"/..?*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        _sparkle_plain_path "$entry" || return 1
        is_path_whitelisted "$entry" && return 1
        case "$entry" in
            *.app)
                [[ -d "$entry" && -z "$cached_app" ]] || return 1
                cached_app="$entry"
                ;;
            *.dmg | *.zip)
                [[ -f "$entry" ]] || return 1
                archives=$((archives + 1))
                ;;
            */.DS_Store) [[ -f "$entry" ]] || return 1 ;;
            *) return 1 ;;
        esac
    done
    [[ -n "$cached_app" && $archives -le 1 ]] || return 1
    _sparkle_installed_app "$owner" "${cached_app##*/}" || return $?

    local info="$cached_app/Contents/Info.plist" id
    if [[ -e "$info" || -L "$info" ]]; then
        id=$(_sparkle_plist_value "$info" CFBundleIdentifier) || return $?
        [[ "$id" == "$owner" ]] || return 1
        _sparkle_cached=$(_sparkle_plist_value "$info" CFBundleVersion) || return $?
    else
        # Incomplete Brave Nightly extraction can lose the top-level plist.
        # Only this known layout may use the framework version directory, and
        # only against the same framework/version in the verified installation.
        [[ "$owner" == com.brave.Browser.nightly &&
            "${cached_app##*/}" == 'Brave Browser Nightly.app' &&
            "${_sparkle_app##*/}" == 'Brave Browser Nightly.app' ]] || return 1
        local framework='Contents/Frameworks/Brave Browser Framework.framework/Versions'
        _sparkle_plain_path "$_sparkle_app/$framework/$_sparkle_installed" || return 1
        local version=""
        for entry in "$cached_app/$framework"/*; do
            [[ -e "$entry" || -L "$entry" ]] || continue
            [[ "${entry##*/}" == Current && -L "$entry" ]] && continue
            [[ -z "$version" && -d "$entry" && "${entry##*/}" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1
            _sparkle_plain_path "$entry" || return 1
            version="${entry##*/}"
        done
        if [[ -L "$cached_app/$framework/Current" ]]; then
            [[ "$(readlink "$cached_app/$framework/Current")" == "$version" ]] || return 1
        fi
        _sparkle_cached="$version"
    fi
    mole_version_is_older "$_sparkle_cached" "$_sparkle_installed"
}

_sparkle_download_process_state() {
    mole_pgrep_any \
        -f 'org[.]sparkle-project[.]' \
        -f 'Sparkle[.]framework/.*/(Autoupdate|Installer|Downloader|Updater)' \
        -f "$(_mole_regex_escape "$_sparkle_app/")"
}

_sparkle_download_unmounted() {
    local token="$1" info count i image entities j mountpoint
    info=$(create_temp_file) || return 1
    _sparkle_probe hdiutil info -plist > "$info" 2> /dev/null || return $?
    count=$(_sparkle_probe plutil -extract images raw -expect array -o - "$info") || return $?
    [[ "$count" =~ ^[0-9]+$ && ${#count} -le 4 ]] || return 1
    for ((i = 0; i < count; i++)); do
        image=$(_sparkle_probe plutil -extract "images.$i.image-path" raw -o - "$info") || return $?
        [[ "$image" == /* && ! "$image" =~ [[:cntrl:]] ]] || return 1
        [[ "$image" != "$token"/* ]] || return 1
        # Resolve an image opened through a symlink outside the cache too.
        if [[ -e "$image" ]]; then
            local resolved
            # shellcheck disable=SC2016 # Perl variables, not shell expansions.
            resolved=$(_sparkle_probe /usr/bin/perl -MCwd=abs_path -e 'my $p = abs_path($ARGV[0]); defined $p or exit 1; print $p' "$image") || return $?
            [[ "$resolved" != "$token"/* ]] || return 1
        fi
        entities=$(_sparkle_probe plutil -extract "images.$i.system-entities" raw -expect array -o - "$info") || return $?
        [[ "$entities" =~ ^[0-9]+$ && ${#entities} -le 4 ]] || return 1
        for ((j = 0; j < entities; j++)); do
            # Unmounted entities have no mount-point key.
            local mount_rc=0
            mountpoint=$(_sparkle_probe plutil -extract "images.$i.system-entities.$j.mount-point" raw -o - "$info" 2> /dev/null) || mount_rc=$?
            [[ $mount_rc -lt 128 ]] || return "$mount_rc"
            [[ "$mountpoint" != "$token" && "$mountpoint" != "$token"/* ]] || return 1
        done
    done
}

_sparkle_download_delete_guard() {
    local token="$1" rc=0
    local _sparkle_app="" _sparkle_cached="" _sparkle_installed=""
    [[ "$token" == "$_MOLE_SPARKLE_APPROVED_PAYLOAD" ]] || return 1
    _sparkle_download_evidence "$token" || return $?
    [[ "$_sparkle_app" == "$_MOLE_SPARKLE_EXPECTED_APP" &&
        "$_sparkle_cached" == "$_MOLE_SPARKLE_EXPECTED_CACHED" &&
        "$_sparkle_installed" == "$_MOLE_SPARKLE_EXPECTED_INSTALLED" ]] || return 1
    local _MOLE_CLEAN_GUARD_REASON=""
    mole_clean_process_guard _sparkle_download_process_state "Sparkle owner active" || return 1
    _sparkle_download_unmounted "$token" || return $?

    # Refuse recent activity anywhere, unreadable walks, foreign ownership,
    # special files and nested mounts. File::Find does not follow symlinks.
    # The grace period is an extra guard, never evidence of obsolescence.
    # shellcheck disable=SC2016 # Perl variables, not shell expansions.
    _sparkle_probe /usr/bin/perl -MFile::Find -e '
        use strict; use warnings;
        $SIG{__WARN__} = sub { exit 1 };
        my ($root, $days) = @ARGV;
        my @root = lstat($root); exit 1 unless @root;
        my $cutoff = time - $days * 86400;
        File::Find::find({no_chdir => 1, wanted => sub {
            my @s = lstat($File::Find::name); exit 1 unless @s;
            exit 1 if $s[0] != $root[0] || $s[4] != $> || $s[9] > $cutoff;
            exit 1 unless -f _ || -d _ || -l _;
            exit 1 if /\/com\.apple\.e5rt\.e5bundlecache(?:\/|$)/;
        }}, $root);
    ' "$token" "$MOLE_TEMP_FILE_AGE_DAYS" 2> /dev/null || return $?

    local _MOLE_CONTAINER_CACHE_PROBE_DEADLINE="$_MOLE_SPARKLE_DEADLINE"
    _mole_container_cache_has_open_handle "$token" || rc=$?
    [[ $rc -lt 128 ]] || return "$rc"
    [[ $rc -eq 1 ]] || return 1
    # An update can finish, or a disk image can mount, during the tree walk.
    _sparkle_download_evidence "$token" || return $?
    [[ "$_sparkle_app" == "$_MOLE_SPARKLE_EXPECTED_APP" &&
        "$_sparkle_cached" == "$_MOLE_SPARKLE_EXPECTED_CACHED" &&
        "$_sparkle_installed" == "$_MOLE_SPARKLE_EXPECTED_INSTALLED" ]] || return 1
    _sparkle_download_unmounted "$token" || return $?
    mole_clean_process_guard _sparkle_download_process_state "Sparkle owner active" || return 1
    _mole_path_matches_identity "$token" "$_MOLE_SPARKLE_PARENT" \
        "$_MOLE_SPARKLE_PARENT_ID" "$_MOLE_SPARKLE_TARGET_ID" || return 1
    _MOLE_SAFE_CLEAN_BOUND_PATH="$token"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT="$_MOLE_SPARKLE_PARENT"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID="$_MOLE_SPARKLE_PARENT_ID"
    _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID="$_MOLE_SPARKLE_TARGET_ID"
}

clean_sparkle_downloads() {
    # Timeout settings may be fractional; SECONDS deadlines use whole seconds.
    local budget="${MOLE_TIMEOUT_DISK_VERIFY_SEC%%.*}"
    [[ "$budget" =~ ^[0-9]+$ && ${#budget} -le 9 ]] || budget=30
    budget=$((10#$budget + 1))
    [[ $budget -ge 2 ]] || budget=2
    local _MOLE_SPARKLE_DEADLINE=$((SECONDS + budget))
    local _MOLE_CLEAN_SECTION_DEADLINE="$_MOLE_SPARKLE_DEADLINE"
    local token rc before
    local _sparkle_app="" _sparkle_cached="" _sparkle_installed=""
    for token in "$HOME/Library/Caches"/*/org.sparkle-project.Sparkle/PersistentDownloads/*; do
        if [[ $SECONDS -ge $_MOLE_SPARKLE_DEADLINE ]]; then
            debug_log "Sparkle download scan budget exhausted; remaining payloads kept"
            break
        fi
        [[ -d "$token" && ! -L "$token" ]] || continue
        local _MOLE_SPARKLE_APPROVED_PAYLOAD="$token"
        local _MOLE_SAFE_REMOVE_FINAL_GUARD=_sparkle_download_delete_guard
        should_protect_path "$token" && continue
        rc=0
        _sparkle_download_evidence "$token" || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ $rc -eq 0 ]] || continue
        _mole_snapshot_path_identity "$token" || continue
        local _MOLE_SPARKLE_PARENT="$_MOLE_PATH_SNAPSHOT_PARENT"
        local _MOLE_SPARKLE_PARENT_ID="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
        local _MOLE_SPARKLE_TARGET_ID="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
        local _MOLE_SPARKLE_EXPECTED_APP="$_sparkle_app"
        local _MOLE_SPARKLE_EXPECTED_CACHED="$_sparkle_cached"
        local _MOLE_SPARKLE_EXPECTED_INSTALLED="$_sparkle_installed"
        rc=0
        _sparkle_download_delete_guard "$token" || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ $rc -eq 0 ]] || {
            debug_log "Sparkle download retained: $token"
            continue
        }
        before="${files_cleaned:-0}"
        rc=0
        safe_clean_guarded _sparkle_download_delete_guard "$token" \
            "Obsolete updater download: ${_sparkle_app##*/} (cached $_sparkle_cached, installed $_sparkle_installed)" || rc=$?
        [[ $rc -ne 124 && $rc -lt 128 ]] || return "$rc"
        if [[ "${files_cleaned:-0}" -gt "$before" ]]; then
            printf '    %s\n' "${token/#$HOME/~}"
        fi
    done
    return 0
}
