#!/bin/zsh
# ==============================================================================
# Jellyfin 12.x Docker -> Native macOS Migration
#
# macOS / zsh only.
#
# WHAT IT DOES
#   Your old Docker Jellyfin stored file locations as the container saw them
#   (for example /media/Movies/film.mkv). A native Mac install needs the real
#   Mac locations (for example /Volumes/NAS/Movies/film.mkv). This script
#   rewrites those stored paths in jellyfin.db and in Jellyfin's small text
#   config/metadata files.
#
# HOW TO USE
#   1. Copy your Docker Jellyfin data into the native data directory
#      (DATADIR below), so it contains data/jellyfin.db.
#   2. Edit ONLY the "USER CONFIGURATION" section below.
#   3. Quit Jellyfin completely.
#   4. Run:  ./migrate_jellyfin_12.zsh
#      The script always does a dry run first and changes nothing until you
#      type APPLY at the very end.
#
# NOTES
#   - Intentionally limited to Jellyfin 12.x. It does NOT do Docker -> Docker.
#   - /cache is intentionally ignored (Jellyfin rebuilds it).
#   - Before APPLY changes anything, a safety copy of jellyfin.db and of every
#     text file it will change is written next to DATADIR
#     (see MAKE_SAFETY_COPY). This is NOT a full backup of your data
#     directory: use Time Machine or copy DATADIR yourself if you want one.
# ==============================================================================

set -u
set -o pipefail

# ------------------------------------------------------------------------------
# 1. USER CONFIGURATION  --  the ONLY section you normally need to edit
# ------------------------------------------------------------------------------

# 1a. Jellyfin data directory on THIS Mac (the folder that contains
#     data/jellyfin.db, plugins/, root/, metadata/ ...).
#     The default is where the native macOS Jellyfin Server app keeps it.
DATADIR="${HOME}/Library/Application Support/jellyfin"

# 1b. PATH_MAPPINGS -- one line per media location Jellyfin uses.
#
#     Each line has the form:    "DOCKER_PATH|MAC_PATH"
#
#     You need exactly as many lines as you had library folders / Docker
#     volume mounts. One is fine. Five is fine. Twenty is fine.
#
#     DOCKER_PATH = the path INSIDE the old container. This is the RIGHT-hand
#                   side of a Docker volume mount:
#                       -v /host/folder:/media      <-- "/media" is DOCKER_PATH
#                   or in docker-compose.yml:
#                       volumes:
#                         - /mnt/nas/anime:/anime   <-- "/anime" is DOCKER_PATH
#                   You can list them from a running container with:
#                       docker inspect jellyfin --format '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}'
#                   or read them in the OLD server's Dashboard > Libraries.
#                   The names are yours ("/media", "/tv", "/anime", "/data/cartoons"...).
#                   Rules: starts with "/", no trailing "/", exactly as Jellyfin
#                   saw it (upper/lower case matters).
#                   Do NOT list /config or /cache: /config is handled
#                   automatically (see 1c) and /cache is ignored.
#
#     MAC_PATH    = where those same files are on THIS Mac right now.
#                   - Internal / external drive:   /Users/you/Movies   or   /Volumes/MyDrive/Movies
#                   - Network share (SMB/AFP/NFS): it must be MOUNTED first
#                     (Finder > Go > Connect to Server, or your NFS mount).
#                     Mounted shares appear under /Volumes, e.g.
#                     smb://nas/video mounted becomes /Volumes/video.
#                     Run  ls /Volumes  in Terminal to see the exact names.
#                     (Use the /Volumes/... path, NOT the smb://... URL.)
#                   Rules: starts with "/", no trailing "/", the folder must
#                   exist right now, and its structure below that point must
#                   be the same as the container saw (the folder that was
#                   mounted as DOCKER_PATH).
#
#     EXAMPLES (delete these and put your own below):
#
#       One library:
#           "/media|/Volumes/video"
#
#       Custom labels:
#           "/anime|/Volumes/NAS/Anime"
#           "/cartoons|/Users/me/Movies/Cartoons"
#           "/data/tvshows|/Volumes/DiskA/TV"
#
#       Five locations:
#           "/media|/Volumes/video"
#           "/music|/Volumes/music"
#           "/audiobooks|/Volumes/Books/Audiobooks"
#           "/books|/Volumes/Books/eBooks"
#           "/backups|/Volumes/DeviceBackups/Jellyfin"
#
#     Mappings whose two sides are identical are fine (nothing to convert).
#     Overlapping Docker paths (for example "/data" and "/data/tv") are fine:
#     the longest match wins.
#
PATH_MAPPINGS=(
    "/media|/Volumes/CHANGE-ME"
)

# 1c. Convert Docker "/config/..." paths stored INSIDE the database to
#     DATADIR? (Images, collections and user pictures that Jellyfin stored
#     under the container's /config folder.)
#       true  = convert them (recommended if the dry run reports /config rows)
#       false = leave them alone (they will be reported as a warning)
#     Plugin files are handled separately and always as before.
CONVERT_CONFIG_PATHS_IN_DB=false

# 1d. Optional: path to an untouched copy of the ORIGINAL Docker jellyfin.db.
#     Used only to verify/repair manually-created collection relationships.
#     Leave empty if not needed.
ORIGINAL_DB_PATH=""

# 1e. Write a safety copy (jellyfin.db + every text file that will change)
#     before APPLY changes anything. Strongly recommended.
MAKE_SAFETY_COPY=true

# 1f. How many example rows to print per database column in the dry run.
SAMPLE_ROWS=3

# ------------------------------------------------------------------------------
# 2. DISPLAY / STATE
# ------------------------------------------------------------------------------

APPLY_MODE=false
HAD_ERRORS=false
WARNINGS=0
TEMP_DB=""
TEMP_DIR=""
DB_STAMP=""
BACKUP_DIR=""
CONVERTED_ROWS=0
typeset -a APPLIED_FILES
APPLIED_FILES=()

# ANSI colours. Text remains readable without colour.
RESET=$'\033[0m'
BOLD=$'\033[1m'
CYAN=$'\033[36m'
BLUE=$'\033[34m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
MAGENTA=$'\033[35m'
WHITE=$'\033[37m'

# ------------------------------------------------------------------------------
# 3. FIXED INTERNAL CONSTANTS (not user configuration)
# ------------------------------------------------------------------------------

DOCKER_CONFIG="/config"
DOCKER_CACHE="/cache"
SUPPORTED_MAJOR="12"

# Database columns that can hold file paths: "table|column|mode".
#   plain = the whole column is a path
#   json  = the column holds JSON text with quoted paths inside
# Tables/columns that do not exist in a given database are skipped.
typeset -a PATH_TARGETS
PATH_TARGETS=(
    "BaseItems|Path|plain"
    "BaseItems|Data|json"
    "BaseItemImageInfos|Path|plain"
    "ImageInfos|Path|plain"
    "MediaStreamInfos|Path|plain"
    "Chapters|ImagePath|plain"
)

# Working mapping tables (filled by load_path_mappings).
#   MAP_*  = validated user mappings, longest Docker path first
#   DB_*   = MAP_* plus /config -> DATADIR when CONVERT_CONFIG_PATHS_IN_DB=true
typeset -a MAP_OLD MAP_NEW IDENTITY_PATHS DB_OLD DB_NEW
MAP_OLD=()
MAP_NEW=()
IDENTITY_PATHS=()
DB_OLD=()
DB_NEW=()

# ------------------------------------------------------------------------------
# 4. BASIC UI
# ------------------------------------------------------------------------------

clear_screen() {
    printf '\033[2J\033[H'
}

header() {
    local title="$1"
    local number="${2:-}"
    printf '\n'
    printf '%b\n' "${CYAN}${BOLD}============================================================${RESET}"
    if [[ -n "$number" ]]; then
        printf '%b\n' "${CYAN}${BOLD}  [$number] $title${RESET}"
    else
        printf '%b\n' "${CYAN}${BOLD}  $title${RESET}"
    fi
    printf '%b\n' "${CYAN}${BOLD}============================================================${RESET}"
}

info() {
    printf '%b\n' "${BLUE}INFO${RESET}  $1"
}

ok() {
    printf '%b\n' "${GREEN} OK ${RESET}  $1"
}

warn() {
    WARNINGS=$((WARNINGS + 1))
    printf '%b\n' "${YELLOW}WARN${RESET}  $1"
}

error() {
    HAD_ERRORS=true
    printf '%b\n' "${RED} ERR ${RESET}  $1" >&2
}

detail() {
    printf '       %s\n' "$1"
}

hard_abort_hint() {
    detail "Press Ctrl-C at any time to abort."
}

pause_here() {
    local prompt="${1:-Press ENTER to continue, or Q to abort.}"
    printf '\n%b' "${MAGENTA}${BOLD}$prompt${RESET} "
    local response
    IFS= read -r response || exit 130
    case "${response:l}" in
        q|quit|abort|x)
            printf '\n'
            warn "Aborted by user."
            exit 130
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 5. CLEANUP
# ------------------------------------------------------------------------------

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT
trap 'printf "\n"; printf "%s\n" "Migration interrupted. No dry-run temporary data will be retained."; exit 130' INT TERM

# ------------------------------------------------------------------------------
# 6. ARGUMENTS
# ------------------------------------------------------------------------------

for arg in "$@"; do
    case "$arg" in
        --apply)
            APPLY_MODE=true
            ;;
        --help|-h)
            cat <<'HELP'
Jellyfin 12.x Docker -> Native macOS Migration

Usage:
  ./migrate_jellyfin_12.zsh
      Dry run first (nothing is modified), then an optional APPLY prompt.

  ./migrate_jellyfin_12.zsh --apply
      Same dry run; the final prompt is worded as an apply confirmation.

Before running, edit only the USER CONFIGURATION section near the top of the
script: the data directory and the "DOCKER_PATH|MAC_PATH" mappings (one line
per library location; any number, any names).

The script is intentionally limited to Jellyfin 12.x.
HELP
            exit 0
            ;;
        *)
            error "Unknown argument: $arg"
            exit 2
            ;;
    esac
done

# ------------------------------------------------------------------------------
# 7. GENERIC HELPERS
# ------------------------------------------------------------------------------

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        error "Required command not found: $1"
        return 1
    fi
}

# Print $1 with leading/trailing whitespace removed.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Quote a value as a SQL string literal.
sql_quote() {
    local value="$1" q="'"
    value="${value//$q/$q$q}"
    printf "'%s'" "$value"
}

db_table_exists() {
    local db="$1"
    local table="$2"
    [[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=$(sql_quote "$table");" 2>/dev/null)" == "1" ]]
}

db_column_exists() {
    local db="$1" table="$2" column="$3"
    [[ "$(sqlite3 "$db" "SELECT COUNT(*) FROM pragma_table_info($(sql_quote "$table")) WHERE name=$(sql_quote "$column");" 2>/dev/null)" == "1" ]]
}

# Fingerprint of the real database files, used to detect changes between the
# dry run and APPLY.
db_stamp() {
    local db="$DATADIR/data/jellyfin.db" f out=""
    for f in "$db" "$db-wal"; do
        if [[ -e "$f" ]]; then
            out+="$(stat -f '%m:%z' "$f" 2>/dev/null);"
        fi
    done
    printf '%s' "$out"
}

# ------------------------------------------------------------------------------
# 8. SQL GENERATORS
#
# All conversions are ANCHORED: a stored path is converted only if it IS the
# Docker path or STARTS WITH "<docker path>/". A Docker path such as /music is
# therefore never matched inside /Volumes/music/..., comparisons are
# case-sensitive, and running the script twice cannot double-convert.
# Every mapping is applied in ONE pass (CASE), so one mapping's output can
# never be re-converted by another.
# ------------------------------------------------------------------------------

# sql_prefix_cond <column-expression> <path>
sql_prefix_cond() {
    local col="$1" old_sql
    old_sql="$(sql_quote "$2")"
    printf "(%s = %s COLLATE BINARY OR substr(%s, 1, length(%s) + 1) = (%s || '/') COLLATE BINARY)" \
        "$col" "$old_sql" "$col" "$old_sql" "$old_sql"
}

# sql_any_cond <column-expression> <path>...   (true if ANY path matches)
sql_any_cond() {
    local col="$1"
    shift
    local p out=""
    for p in "$@"; do
        [[ -n "$out" ]] && out+=" OR "
        out+="$(sql_prefix_cond "$col" "$p")"
    done
    [[ -z "$out" ]] && out="0"
    printf '(%s)' "$out"
}

# sql_map_expr <column-expression>
# Expression returning the converted path (uses DB_OLD/DB_NEW, longest first).
sql_map_expr() {
    local col="$1" i out="CASE"
    if (( ${#DB_OLD} == 0 )); then
        printf '%s' "$col"
        return 0
    fi
    for (( i=1; i<=${#DB_OLD}; i++ )); do
        out+=" WHEN $(sql_prefix_cond "$col" "${DB_OLD[$i]}") THEN $(sql_quote "${DB_NEW[$i]}") || substr($col, length($(sql_quote "${DB_OLD[$i]}")) + 1)"
    done
    out+=" ELSE $col END"
    printf '%s' "$out"
}

# sql_json_any_cond <column>  (true if any quoted "<old>" or "<old>/..." exists)
sql_json_any_cond() {
    local col="$1" i out=""
    for (( i=1; i<=${#DB_OLD}; i++ )); do
        [[ -n "$out" ]] && out+=" OR "
        out+="instr($col, $(sql_quote "\"${DB_OLD[$i]}/")) > 0 OR instr($col, $(sql_quote "\"${DB_OLD[$i]}\"")) > 0"
    done
    [[ -z "$out" ]] && out="0"
    printf '(%s)' "$out"
}

# sql_json_map_expr <column>
# Two phases with unique tokens so conversions can never cascade.
sql_json_map_expr() {
    local col="$1" expr="$1" i old
    for (( i=1; i<=${#DB_OLD}; i++ )); do
        old="${DB_OLD[$i]}"
        expr="REPLACE(REPLACE($expr, $(sql_quote "\"$old/"), $(sql_quote "\"@@JFMIG${i}@@/")), $(sql_quote "\"$old\""), $(sql_quote "\"@@JFMIG${i}@@\""))"
    done
    for (( i=1; i<=${#DB_OLD}; i++ )); do
        expr="REPLACE($expr, $(sql_quote "@@JFMIG${i}@@"), $(sql_quote "${DB_NEW[$i]}"))"
    done
    printf '%s' "$expr"
}

# ------------------------------------------------------------------------------
# 9. ENVIRONMENT CHECKS
# ------------------------------------------------------------------------------

check_environment() {
    header "Environment checks" "1"

    [[ "$(uname -s)" == "Darwin" ]] || {
        error "This script is for macOS only."
        return 1
    }

    [[ -n "${ZSH_VERSION:-}" ]] || {
        error "This script must be run by zsh."
        return 1
    }

    require_command sqlite3 || return 1
    require_command perl || return 1
    require_command find || return 1
    require_command grep || return 1
    require_command diff || return 1
    require_command cmp || return 1
    require_command stat || return 1
    require_command lsof || return 1
    require_command pgrep || return 1

    ok "macOS / zsh environment detected."
    ok "Required tools are available."

    if [[ ! -d "$DATADIR" ]]; then
        error "Native Jellyfin data directory does not exist:"
        detail "$DATADIR"
        return 1
    fi

    if [[ ! -f "$DATADIR/data/jellyfin.db" ]]; then
        error "Native Jellyfin database was not found:"
        detail "$DATADIR/data/jellyfin.db"
        return 1
    fi

    # sqlite3's ".backup 'file'" cannot take a file name containing an apostrophe.
    if [[ "$DATADIR" == *"'"* ]]; then
        error "DATADIR contains an apostrophe (') which this script cannot handle."
        detail "$DATADIR"
        return 1
    fi

    ok "Native Jellyfin data directory found."
    detail "$DATADIR"

    hard_abort_hint
    pause_here
}

# ------------------------------------------------------------------------------
# 10. JELLYFIN VERSION CHECK
#
# __EFMigrationsHistory.ProductVersion is the Entity Framework Core library
# version, NOT the Jellyfin version, so it cannot be used as a 12.x gate.
# Instead: (1) require the modern schema, (2) if a native Jellyfin app is
# installed, require it to be 12.x.
# ------------------------------------------------------------------------------

check_jellyfin_version() {
    header "Jellyfin 12.x compatibility check" "2"

    local db="$DATADIR/data/jellyfin.db"

    if ! db_table_exists "$db" "BaseItems" || ! db_column_exists "$db" "BaseItems" "Path"; then
        error "The expected Jellyfin 12.x BaseItems table/Path column was not found."
        detail "This database does not look like a Jellyfin 12.x database."
        detail "No migration changes have been made."
        return 1
    fi
    ok "Database schema looks like Jellyfin 12.x (BaseItems.Path present)."

    local latest
    latest="$(sqlite3 -separator ' / ' "$db" \
        "SELECT MigrationId, ProductVersion FROM __EFMigrationsHistory ORDER BY MigrationId DESC LIMIT 1;" \
        2>/dev/null)"
    if [[ -n "$latest" ]]; then
        info "Latest database migration (informational): $latest"
        detail "The second value is the EF Core library version, not the Jellyfin version."
    fi

    local app="" app_version="" candidate
    for candidate in \
        "/Applications/Jellyfin Server.app" \
        "${HOME}/Applications/Jellyfin Server.app" \
        "/Applications/Jellyfin.app" \
        "${HOME}/Applications/Jellyfin.app"
    do
        if [[ -d "$candidate" ]]; then
            app="$candidate"
            break
        fi
    done

    if [[ -n "$app" ]]; then
        app_version="$(mdls -raw -name CFBundleShortVersionString "$app" 2>/dev/null || true)"
        if [[ -z "$app_version" || "$app_version" == "(null)" ]]; then
            app_version="$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
        fi

        if [[ -n "$app_version" ]]; then
            info "Native macOS application version: $app_version"

            if [[ "${app_version%%.*}" != "$SUPPORTED_MAJOR" ]]; then
                error "The installed native Jellyfin application is not $SUPPORTED_MAJOR.x."
                detail "$app"
                detail "Detected version: $app_version"
                detail "No migration changes have been made."
                return 1
            fi

            ok "Native macOS application is $SUPPORTED_MAJOR.x."
        else
            warn "Native Jellyfin application was found, but its version could not be read."
            detail "Make sure the installed Jellyfin Server is $SUPPORTED_MAJOR.x."
        fi
    else
        warn "No standard native Jellyfin application bundle was found."
        detail "The application version could not be verified."
        detail "Make sure the Jellyfin Server you will run is $SUPPORTED_MAJOR.x."
    fi

    pause_here
}

# ------------------------------------------------------------------------------
# 11. PROCESS CHECK
# ------------------------------------------------------------------------------

check_jellyfin_stopped() {
    header "Jellyfin process check" "3"

    local name running=false
    for name in jellyfin Jellyfin "Jellyfin Server" jellyfin-server; do
        if pgrep -x "$name" >/dev/null 2>&1; then
            running=true
        fi
    done

    # Definitive test: does any process hold the database open?
    if lsof "$DATADIR/data/jellyfin.db" >/dev/null 2>&1; then
        running=true
    fi

    if [[ "$running" == true ]]; then
        error "Jellyfin appears to be running (or the database is open)."
        detail "Quit Jellyfin completely before running this migration."
        detail "The script will not modify the database while Jellyfin is running."
        return 1
    fi

    ok "No Jellyfin server process is running and the database is not open."
    pause_here
}

# ------------------------------------------------------------------------------
# 12. PATH MAPPING VALIDATION
# ------------------------------------------------------------------------------

load_path_mappings() {
    header "Path mapping validation" "4"

    local entry old new prev i dup problems=0 _len
    local -a cand cand_old

    cand=()
    cand_old=()

    if (( ${#PATH_MAPPINGS} == 0 )); then
        error "PATH_MAPPINGS is empty."
        detail "Add at least one \"DOCKER_PATH|MAC_PATH\" line in the USER CONFIGURATION section."
        return 1
    fi

    for entry in "${PATH_MAPPINGS[@]}"; do
        entry="$(trim "$entry")"
        [[ -z "$entry" ]] && continue

        if [[ "$entry" != *"|"* ]]; then
            error "Mapping is missing the '|' separator: $entry"
            detail "Expected:  \"/path/inside/docker|/path/on/this/mac\""
            problems=$((problems + 1))
            continue
        fi

        old="$(trim "${entry%%|*}")"
        new="$(trim "${entry#*|}")"
        while [[ "$old" == */ && "$old" != "/" ]]; do old="${old%/}"; done
        while [[ "$new" == */ && "$new" != "/" ]]; do new="${new%/}"; done

        if [[ "$old$new" == *$'\t'* || "$old$new" == *$'\n'* || "$old$new" == *'\'* || \
              "$old$new" == *'"'* || "$new" == *"|"* ]]; then
            error "Mapping contains an unsupported character (tab, newline, backslash, double quote or extra '|'):"
            detail "$entry"
            problems=$((problems + 1))
            continue
        fi

        if [[ "$old" != /* || "$old" == "/" ]]; then
            error "DOCKER_PATH must be an absolute path such as /media (and not just /):"
            detail "$entry"
            problems=$((problems + 1))
            continue
        fi

        if [[ "$old" == "$DOCKER_CONFIG" || "$old" == "$DOCKER_CONFIG"/* ]]; then
            error "Do not map $DOCKER_CONFIG. It is handled automatically (see CONVERT_CONFIG_PATHS_IN_DB):"
            detail "$entry"
            problems=$((problems + 1))
            continue
        fi

        if [[ "$old" == "$DOCKER_CACHE" || "$old" == "$DOCKER_CACHE"/* ]]; then
            warn "$DOCKER_CACHE is intentionally ignored; this mapping is skipped: $entry"
            continue
        fi

        if [[ "$new" != /* || "$new" == "/" ]]; then
            error "MAC_PATH must be an absolute path such as /Volumes/video (and not just /):"
            detail "$entry"
            detail "For a network share use its mounted /Volumes/... path, not smb://..."
            problems=$((problems + 1))
            continue
        fi

        dup=0
        for prev in "${cand_old[@]}"; do
            [[ "$prev" == "$old" ]] && dup=1
        done
        for prev in "${IDENTITY_PATHS[@]}"; do
            [[ "$prev" == "$old" ]] && dup=1
        done
        if (( dup )); then
            error "The same DOCKER_PATH is listed twice: $old"
            problems=$((problems + 1))
            continue
        fi

        if [[ "$old" == "$new" ]]; then
            info "$old maps to itself; nothing to convert for it."
            IDENTITY_PATHS+=("$old")
            continue
        fi

        if [[ ! -d "$new" ]]; then
            error "MAC_PATH does not exist (for $old):"
            detail "$new"
            detail "If it is a network share or external drive, mount/connect it first."
            detail "Run  ls /Volumes  to see the exact names of mounted volumes."
            problems=$((problems + 1))
            continue
        fi

        if [[ "$new" == "$old"/* ]]; then
            warn "MAC_PATH $new starts with DOCKER_PATH $old."
            detail "Running this script a second time on the same database would convert it again."
        fi

        cand_old+=("$old")
        cand+=("${#old}"$'\t'"$old"$'\t'"$new")
        ok "$new"
    done

    if (( problems > 0 )); then
        detail "Correct PATH_MAPPINGS in the USER CONFIGURATION section and run again."
        return 1
    fi

    # Longest Docker path first, so nested paths convert correctly.
    if (( ${#cand} > 0 )); then
        while IFS=$'\t' read -r _len old new; do
            [[ -z "$old" ]] && continue
            MAP_OLD+=("$old")
            MAP_NEW+=("$new")
        done < <(printf '%s\n' "${cand[@]}" | sort -t $'\t' -k1,1nr -k2,2)
    fi

    DB_OLD=("${MAP_OLD[@]}")
    DB_NEW=("${MAP_NEW[@]}")
    if [[ "$CONVERT_CONFIG_PATHS_IN_DB" == true ]]; then
        DB_OLD+=("$DOCKER_CONFIG")
        DB_NEW+=("$DATADIR")
    fi

    if (( ${#MAP_OLD} == 0 && ${#IDENTITY_PATHS} == 0 )); then
        error "PATH_MAPPINGS contains no usable mapping."
        return 1
    fi

    info "Stored Docker paths will be converted to:"
    for (( i=1; i<=${#MAP_OLD}; i++ )); do
        detail "${MAP_OLD[$i]}  ->  ${MAP_NEW[$i]}"
    done
    if [[ "$CONVERT_CONFIG_PATHS_IN_DB" == true ]]; then
        detail "$DOCKER_CONFIG  ->  $DATADIR   (database only, plus plugin files)"
    else
        detail "$DOCKER_CONFIG  ->  not converted in the database; plugin files only"
    fi
    detail "$DOCKER_CACHE  ->  intentionally ignored"

    pause_here
}

# ------------------------------------------------------------------------------
# 13. TEMPORARY DATABASE
# ------------------------------------------------------------------------------

create_temp_database() {
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jellyfin-migration.XXXXXX")"
    TEMP_DB="$TEMP_DIR/jellyfin.db"

    if ! sqlite3 "$DATADIR/data/jellyfin.db" ".backup '$TEMP_DB'" >/dev/null 2>&1; then
        error "Could not create temporary SQLite working database."
        return 1
    fi

    if [[ ! -s "$TEMP_DB" ]]; then
        error "Temporary database was created but is empty."
        return 1
    fi

    # Remember what the real database looked like when the snapshot was taken.
    DB_STAMP="$(db_stamp)"
}

# ------------------------------------------------------------------------------
# 14. DATABASE DIAGNOSTICS (run on the pristine snapshot)
# ------------------------------------------------------------------------------

# Warn about stored absolute paths whose top-level folder is not covered by any
# mapping (for example a library you forgot to list in PATH_MAPPINGS).
report_unmapped_roots() {
    local db="$1"

    header "Unmapped path check" "5"

    local -a covered
    covered=("${MAP_OLD[@]}" "${IDENTITY_PATHS[@]}" "${MAP_NEW[@]}" "$DOCKER_CONFIG" "$DOCKER_CACHE" "$DATADIR")

    local cond sql root cnt found=0
    cond="$(sql_any_cond "Path" "${covered[@]}")"
    sql="SELECT root, COUNT(*) FROM (
            SELECT CASE WHEN instr(substr(Path, 2), '/') = 0 THEN Path
                        ELSE substr(Path, 1, instr(substr(Path, 2), '/')) END AS root
            FROM BaseItems
            WHERE Path IS NOT NULL AND substr(Path, 1, 1) = '/' AND NOT $cond
         ) GROUP BY root ORDER BY 2 DESC LIMIT 20;"

    while IFS=$'\t' read -r root cnt; do
        [[ -z "$root" ]] && continue
        if (( found == 0 )); then
            warn "Stored paths were found that no mapping covers:"
        fi
        found=$((found + 1))
        detail "$root   ($cnt item(s))"
    done < <(sqlite3 -separator $'\t' "$db" "$sql" 2>/dev/null)

    if (( found > 0 )); then
        detail "If these are your Docker library paths, add a \"DOCKER_PATH|MAC_PATH\" line"
        detail "for each in PATH_MAPPINGS and run again (Ctrl-C now to stop)."
    else
        ok "Every stored absolute path is covered by a mapping."
    fi

    pause_here
}

# Report /config rows when they are NOT going to be converted.
report_config_rows() {
    local db="$1"

    [[ "$CONVERT_CONFIG_PATHS_IN_DB" == true ]] && return 0

    local pair table column cnt total=0 cond
    cond=""
    for pair in "BaseItems|Path" "BaseItemImageInfos|Path" "ImageInfos|Path"; do
        table="${pair%%|*}"
        column="${pair#*|}"
        db_table_exists "$db" "$table" || continue
        db_column_exists "$db" "$table" "$column" || continue
        cnt="$(sqlite3 "$db" "SELECT COUNT(*) FROM $table WHERE $(sql_prefix_cond "$column" "$DOCKER_CONFIG");" 2>/dev/null || echo 0)"
        if [[ "$cnt" -gt 0 ]]; then
            detail "$table.$column: $cnt row(s) under $DOCKER_CONFIG"
            total=$((total + cnt))
        fi
    done

    if (( total > 0 )); then
        warn "$total database row(s) point into the Docker $DOCKER_CONFIG folder and will NOT be converted."
        detail "Images/collections stored there may show as missing on the Mac."
        detail "Set CONVERT_CONFIG_PATHS_IN_DB=true to convert them to:"
        detail "$DATADIR"
    fi
}

# ------------------------------------------------------------------------------
# 15. DATABASE PATH CONVERSION
# ------------------------------------------------------------------------------

convert_plain_column() {
    local db="$1" table="$2" column="$3"
    local i idx cnt anymatch idxcase mapexpr rid before after
    local rows_total=0

    anymatch="$(sql_any_cond "$column" "${DB_OLD[@]}")"
    mapexpr="$(sql_map_expr "$column")"

    idxcase="CASE"
    for (( i=1; i<=${#DB_OLD}; i++ )); do
        idxcase+=" WHEN $(sql_prefix_cond "$column" "${DB_OLD[$i]}") THEN $i"
    done
    idxcase+=" END"

    while IFS=$'\t' read -r idx cnt; do
        [[ -z "$idx" ]] && continue
        info "$table.$column: $cnt row(s):  ${DB_OLD[$idx]}  ->  ${DB_NEW[$idx]}"
        rows_total=$((rows_total + cnt))
    done < <(sqlite3 -separator $'\t' "$db" \
        "SELECT idx, COUNT(*) FROM (SELECT $idxcase AS idx FROM $table WHERE $column IS NOT NULL)
         WHERE idx IS NOT NULL GROUP BY idx ORDER BY idx;" 2>/dev/null)

    if (( rows_total > 0 )); then
        detail "Examples (up to $SAMPLE_ROWS):"
        while IFS=$'\t' read -r rid before after; do
            [[ -z "$rid" ]] && continue
            detail "  row $rid: $before"
            detail "         -> $after"
        done < <(sqlite3 -separator $'\t' "$db" \
            "SELECT rowid, $column, $mapexpr FROM $table WHERE $anymatch LIMIT $SAMPLE_ROWS;" 2>/dev/null)

        if ! sqlite3 "$db" "UPDATE $table SET $column = $mapexpr WHERE $anymatch;" >/dev/null 2>&1; then
            error "Failed updating $table.$column."
            return 1
        fi
    fi

    CONVERTED_ROWS=$rows_total
}

convert_json_column() {
    local db="$1" table="$2" column="$3"
    local cond mapexpr cnt

    cond="$(sql_json_any_cond "$column")"
    mapexpr="$(sql_json_map_expr "$column")"

    cnt="$(sqlite3 "$db" "SELECT COUNT(*) FROM $table WHERE $column IS NOT NULL AND $cond;" 2>/dev/null || echo 0)"
    [[ -z "$cnt" ]] && cnt=0

    if (( cnt > 0 )); then
        info "$table.$column (JSON): $cnt row(s) contain Docker paths."
        if ! sqlite3 "$db" "UPDATE $table SET $column = $mapexpr WHERE $column IS NOT NULL AND $cond;" >/dev/null 2>&1; then
            error "Failed updating $table.$column."
            return 1
        fi
    fi

    CONVERTED_ROWS=$cnt
}

update_db_paths() {
    local db="$1"
    local target rest table column mode total=0

    header "Database path migration" "6"

    if (( ${#DB_OLD} == 0 )); then
        info "No database path conversions are configured."
        return 0
    fi

    for target in "${PATH_TARGETS[@]}"; do
        table="${target%%|*}"
        rest="${target#*|}"
        column="${rest%%|*}"
        mode="${rest#*|}"

        if ! db_table_exists "$db" "$table"; then
            info "$table: table not present in this database; skipped."
            continue
        fi
        if ! db_column_exists "$db" "$table" "$column"; then
            info "$table.$column: column not present; skipped."
            continue
        fi

        CONVERTED_ROWS=0
        if [[ "$mode" == "json" ]]; then
            convert_json_column "$db" "$table" "$column" || return 1
        else
            convert_plain_column "$db" "$table" "$column" || return 1
        fi
        total=$((total + CONVERTED_ROWS))
    done

    if (( total == 0 )); then
        ok "No Docker-era paths were found in the database path columns."
    else
        ok "$total database path occurrence(s) migrated in the working database."
    fi
}

# ------------------------------------------------------------------------------
# 16. LINKED CHILDREN
#
# Both ParentId and ChildId are mapped from the original database by path,
# using the same anchored path conversion as everything else. ChildType and
# SortOrder are preserved.
# ------------------------------------------------------------------------------

repair_linked_children() {
    local db="$1"

    header "Manual collection / linked-child check" "7"

    if [[ -z "$ORIGINAL_DB_PATH" ]]; then
        info "No ORIGINAL_DB_PATH configured."
        detail "Existing LinkedChildren records will be preserved."
        detail "No old-database relationship repair will be attempted."
        pause_here
        return 0
    fi

    if [[ ! -f "$ORIGINAL_DB_PATH" ]]; then
        warn "ORIGINAL_DB_PATH was configured but the file does not exist."
        detail "$ORIGINAL_DB_PATH"
        return 0
    fi

    if ! db_table_exists "$db" "LinkedChildren"; then
        warn "Current database has no LinkedChildren table; skipping relationship repair."
        return 0
    fi

    local parent_expr child_expr sql err
    parent_expr="$(sql_map_expr "old_parent.Path")"
    child_expr="$(sql_map_expr "old_child.Path")"

    sql="ATTACH DATABASE $(sql_quote "$ORIGINAL_DB_PATH") AS olddb;

INSERT OR IGNORE INTO LinkedChildren (ParentId, ChildId, ChildType, SortOrder)
SELECT new_parent.Id,
       new_child.Id,
       lc.ChildType,
       lc.SortOrder
FROM olddb.LinkedChildren lc
JOIN olddb.BaseItems old_parent
  ON old_parent.Id = lc.ParentId
JOIN olddb.BaseItems old_child
  ON old_child.Id = lc.ChildId
JOIN BaseItems new_parent
  ON new_parent.Path = $parent_expr
JOIN BaseItems new_child
  ON new_child.Path = $child_expr
WHERE NOT EXISTS (
    SELECT 1
    FROM LinkedChildren existing
    WHERE existing.ParentId = new_parent.Id
      AND existing.ChildId = new_child.Id
);

DETACH DATABASE olddb;"

    local before_count after_count added
    before_count="$(sqlite3 "$db" "SELECT COUNT(*) FROM LinkedChildren;" 2>/dev/null || echo 0)"

    if ! err="$(sqlite3 "$db" "$sql" 2>&1 >/dev/null)"; then
        error "LinkedChildren repair SQL failed."
        [[ -n "$err" ]] && detail "$err"
        return 1
    fi

    after_count="$(sqlite3 "$db" "SELECT COUNT(*) FROM LinkedChildren;" 2>/dev/null || echo 0)"
    added=$((after_count - before_count))

    if (( added > 0 )); then
        ok "$added missing linked-child relationship(s) were restored in the working database."
    else
        ok "No missing linked-child relationships were found."
    fi

    pause_here
}

# ------------------------------------------------------------------------------
# 17. AVATAR / IMAGE EXTENSION REPAIR
# ------------------------------------------------------------------------------

repair_image_extensions() {
    local db="$1"

    header "Profile image check" "8"

    if ! db_table_exists "$db" "ImageInfos"; then
        warn "ImageInfos table was not found; skipping profile image check."
        pause_here
        return 0
    fi

    local repairs=0
    local id imgpath base ext alt

    while IFS=$'\t' read -r id imgpath; do
        [[ -z "$id" || -z "$imgpath" ]] && continue

        if [[ ! -f "$imgpath" ]]; then
            base="${imgpath%.*}"
            for ext in png jpg jpeg webp; do
                alt="${base}.${ext}"
                if [[ -f "$alt" ]]; then
                    info "ImageInfos $id:"
                    detail "$imgpath"
                    detail "-> $alt"

                    sqlite3 "$db" \
                        "UPDATE ImageInfos
                         SET Path=$(sql_quote "$alt")
                         WHERE Id=$(sql_quote "$id");" \
                        >/dev/null 2>&1 || {
                            error "Failed updating ImageInfos ID $id."
                            return 1
                        }

                    repairs=$((repairs + 1))
                    break
                fi
            done
        fi
    done < <(sqlite3 -separator $'\t' "$db" \
        "SELECT Id, Path FROM ImageInfos;" 2>/dev/null)

    if (( repairs == 0 )); then
        ok "No broken profile image extensions were found."
    else
        ok "$repairs profile image path(s) repaired in the working database."
    fi

    pause_here
}

# ------------------------------------------------------------------------------
# 18. TEXT FILES
#
# Converted with ONE perl pass per file (no sed chain), so a converted path is
# never re-scanned. A Docker path is converted only when it is not glued to a
# preceding path character (so /music is not matched inside /Volumes/music)
# and is followed by "/" or a non-path character.
# ------------------------------------------------------------------------------

PERL_COMMON='
my (%map, @olds);
for my $line (split /\n/, $ENV{JFMIG_MAP}) {
    my ($o, $n) = split /\t/, $line, 2;
    next unless defined $n && length $o;
    $map{$o} = $n;
    push @olds, $o;
}
@olds = sort { length($b) <=> length($a) } @olds;
my $alt = join("|", map { quotemeta($_) } @olds);
my $re = qr{(?<![A-Za-z0-9_.~%/-])($alt)(?=/|[^A-Za-z0-9_.-]|\z)};
'
PERL_REPLACE="${PERL_COMMON}"'s/$re/$map{$1}/g;'
PERL_CHECK="${PERL_COMMON}"'$found = 1 if /$re/; END { $? = $found ? 0 : 1 }'

# build_text_map <include_config: true|false>  -> "old<TAB>new" lines
build_text_map() {
    local include_config="${1:-false}" i
    for (( i=1; i<=${#MAP_OLD}; i++ )); do
        printf '%s\t%s\n' "${MAP_OLD[$i]}" "${MAP_NEW[$i]}"
    done
    if [[ "$include_config" == true ]]; then
        printf '%s\t%s\n' "$DOCKER_CONFIG" "$DATADIR"
    fi
    return 0
}

replace_in_temp_copy() {
    local source="$1"
    local destination="$2"
    local include_config="${3:-false}"

    cp -p "$source" "$destination" || return 1

    local map
    map="$(build_text_map "$include_config")"
    [[ -z "$map" ]] && return 0

    JFMIG_MAP="$map" perl -0777 -pi -e "$PERL_REPLACE" "$destination"
}

show_text_file_diff() {
    local file="$1"
    local temp="$2"

    if cmp -s "$file" "$temp"; then
        return 1
    fi

    printf '\n%b\n' "${YELLOW}--- $file${RESET}"
    diff -u "$file" "$temp" || true
    return 0
}

process_text_tree() {
    local root="$1"
    local label="$2"

    [[ -d "$root" ]] || return 0

    local workroot="$TEMP_DIR/files"
    mkdir -p "$workroot"

    local changed=0
    local file relative temp

    while IFS= read -r -d '' file; do
        relative="${file#"$root/"}"
        temp="$workroot/${label// /_}/$relative"

        if ! grep -Iq . "$file" 2>/dev/null; then
            continue
        fi

        mkdir -p "${temp:h}"

        if ! replace_in_temp_copy "$file" "$temp" false; then
            error "Could not prepare text-file migration:"
            detail "$file"
            continue
        fi

        if show_text_file_diff "$file" "$temp"; then
            changed=$((changed + 1))
        else
            rm -f "$temp"
        fi
    done < <(find "$root" -type f -print0)

    if (( changed == 0 )); then
        ok "$label: no text-file changes required."
    else
        ok "$label: $changed text file(s) would change."
    fi
}

process_plugin_metadata() {
    local root="$DATADIR/plugins"
    [[ -d "$root" ]] || return 0

    local workroot="$TEMP_DIR/plugin-files"
    mkdir -p "$workroot"

    local changed=0
    local file relative temp include_config

    while IFS= read -r -d '' file; do
        if ! grep -Iq . "$file" 2>/dev/null; then
            continue
        fi

        relative="${file#"$root/"}"
        temp="$workroot/$relative"
        mkdir -p "${temp:h}"

        # /config is migrated only when the plugin file contains a
        # path-bearing imagePath/XML Path entry. The mapped library paths are
        # always handled.
        include_config=false
        if grep -Eq '"imagePath"[[:space:]]*:[[:space:]]*"/config/|<[^>]*(Path|path)[^>]*>/config/' "$file" 2>/dev/null; then
            include_config=true
        fi

        if ! replace_in_temp_copy "$file" "$temp" "$include_config"; then
            error "Could not prepare plugin metadata migration:"
            detail "$file"
            continue
        fi

        if show_text_file_diff "$file" "$temp"; then
            changed=$((changed + 1))
        else
            rm -f "$temp"
        fi
    done < <(find "$root" -type f \
        \( -name '*.json' -o -name '*.xml' -o -name '*.config' -o -name '*.conf' -o -name '*.mblink' \) \
        -print0)

    if (( changed == 0 )); then
        ok "Plugin metadata/config: no text-file changes required."
    else
        ok "Plugin metadata/config: $changed text file(s) would change."
    fi
}

prepare_text_changes() {
    header "Configuration and metadata files" "9"

    process_text_tree "$DATADIR/root/default" "root-default"
    process_text_tree "$DATADIR/data/collections" "collections"
    process_text_tree "$DATADIR/data/playlists" "playlists"
    process_plugin_metadata

    hard_abort_hint
    pause_here
}

# ------------------------------------------------------------------------------
# 19. VERIFICATION
#
# Anchored, case-sensitive checks (no false positives from "/Volumes/music"
# or "/Volumes/Books/..."). Used on the dry-run copies AND on the real files
# after APPLY.
# ------------------------------------------------------------------------------

leftover_check_db() {
    local db="$1" label="$2"
    local target rest table column mode cond n found=0

    header "Verification: database ($label)" "10"

    if (( ${#DB_OLD} == 0 )); then
        ok "Nothing to verify in the database."
        return 0
    fi

    for target in "${PATH_TARGETS[@]}"; do
        table="${target%%|*}"
        rest="${target#*|}"
        column="${rest%%|*}"
        mode="${rest#*|}"

        db_table_exists "$db" "$table" || continue
        db_column_exists "$db" "$table" "$column" || continue

        if [[ "$mode" == "json" ]]; then
            cond="$(sql_json_any_cond "$column")"
        else
            cond="$(sql_any_cond "$column" "${DB_OLD[@]}")"
        fi

        n="$(sqlite3 "$db" "SELECT COUNT(*) FROM $table WHERE $column IS NOT NULL AND $cond;" 2>/dev/null || echo 0)"
        [[ -z "$n" ]] && n=0

        if (( n > 0 )); then
            warn "$table.$column still contains $n Docker-era path(s)."
            found=$((found + n))
        fi
    done

    local check
    check="$(sqlite3 "$db" "PRAGMA quick_check;" 2>/dev/null | head -n 1)"
    if [[ "$check" == "ok" ]]; then
        ok "SQLite quick_check: ok."
    else
        warn "SQLite quick_check reported: ${check:-no result}"
    fi

    if (( found == 0 )); then
        ok "No relevant Docker-era paths remain in the database."
    else
        warn "$found database occurrence(s) require review."
    fi
}

leftover_check_text() {
    local label="$1"
    shift
    local root file found=0 map

    header "Verification: text files ($label)" "11"

    map="$(build_text_map false)"

    for root in "$@"; do
        [[ -d "$root" ]] || continue

        while IFS= read -r -d '' file; do
            grep -Iq . "$file" 2>/dev/null || continue

            if [[ -n "$map" ]] && JFMIG_MAP="$map" perl -0777 -ne "$PERL_CHECK" "$file"; then
                warn "Docker-era path remains in text file: $file"
                found=$((found + 1))
            fi

            if [[ "$file" == */plugins/* || "$file" == */plugin-files/* ]] && \
               grep -Eq '"imagePath"[[:space:]]*:[[:space:]]*"/config/|<[^>]*(Path|path)[^>]*>/config/' "$file" 2>/dev/null; then
                warn "Plugin path metadata still contains /config/: $file"
                found=$((found + 1))
            fi
        done < <(find "$root" -type f -print0)
    done

    if (( found == 0 )); then
        ok "No relevant Docker-era paths remain in the checked text files."
    else
        warn "$found text-file occurrence(s) require review."
    fi
}

# ------------------------------------------------------------------------------
# 20. SAFETY COPY / APPLY
# ------------------------------------------------------------------------------

make_safety_copy() {
    if [[ "$MAKE_SAFETY_COPY" != true ]]; then
        warn "MAKE_SAFETY_COPY is false: no safety copy will be written."
        return 0
    fi

    BACKUP_DIR="${DATADIR}.premigration-$(date +%Y%m%d-%H%M%S)"

    if ! mkdir -p "$BACKUP_DIR/files"; then
        error "Could not create safety-copy folder:"
        detail "$BACKUP_DIR"
        return 1
    fi

    if ! sqlite3 "$DATADIR/data/jellyfin.db" ".backup '$BACKUP_DIR/jellyfin.db'" >/dev/null 2>&1 || \
       [[ ! -s "$BACKUP_DIR/jellyfin.db" ]]
    then
        error "Could not write the database safety copy."
        return 1
    fi

    ok "Safety copy folder created:"
    detail "$BACKUP_DIR"
}

# apply_prepared <real-root> <prepared-root>
apply_prepared() {
    local root="$1" prepared="$2"
    [[ -d "$prepared" ]] || return 0

    local temp relative destination stage rel_to_data
    while IFS= read -r -d '' temp; do
        relative="${temp#"$prepared/"}"
        destination="$root/$relative"

        [[ -f "$destination" ]] || continue
        cmp -s "$destination" "$temp" && continue

        if [[ "$MAKE_SAFETY_COPY" == true ]]; then
            rel_to_data="${destination#"$DATADIR/"}"
            mkdir -p "$BACKUP_DIR/files/${rel_to_data:h}" || return 1
            cp -p "$destination" "$BACKUP_DIR/files/$rel_to_data" || return 1
        fi

        # Stage next to the target, then rename: never leaves a half-written file.
        stage="${destination}.jfmig-tmp"
        cp -p "$temp" "$stage" || return 1
        if ! mv -f "$stage" "$destination"; then
            rm -f "$stage"
            return 1
        fi
        APPLIED_FILES+=("$destination")
    done < <(find "$prepared" -type f -print0)
}

apply_file_changes() {
    header "Applying file changes" "13"

    apply_prepared "$DATADIR/root/default"      "$TEMP_DIR/files/root-default"  || { error "Failed applying root/default changes."; return 1; }
    apply_prepared "$DATADIR/data/collections"  "$TEMP_DIR/files/collections"   || { error "Failed applying collection XML changes."; return 1; }
    apply_prepared "$DATADIR/data/playlists"    "$TEMP_DIR/files/playlists"     || { error "Failed applying playlist XML changes."; return 1; }
    apply_prepared "$DATADIR/plugins"           "$TEMP_DIR/plugin-files"        || { error "Failed applying plugin metadata/config changes."; return 1; }

    ok "Text configuration and metadata changes applied (${#APPLIED_FILES} file(s))."
}

rollback_files() {
    [[ "$MAKE_SAFETY_COPY" == true && -n "$BACKUP_DIR" ]] || return 0
    (( ${#APPLIED_FILES} > 0 )) || return 0

    warn "Restoring the ${#APPLIED_FILES} text file(s) already changed from the safety copy..."
    local f rel
    for f in "${APPLIED_FILES[@]}"; do
        rel="${f#"$DATADIR/"}"
        if [[ -f "$BACKUP_DIR/files/$rel" ]]; then
            cp -p "$BACKUP_DIR/files/$rel" "$f" || error "Could not restore: $f"
        fi
    done
    APPLIED_FILES=()
}

# The dry-run database already contains the reviewed changes. It is installed
# by an atomic rename of a copy staged in the SAME directory as the real
# database, so the real database is never left half-written.
apply_database_changes() {
    local db="$DATADIR/data/jellyfin.db"

    header "Applying database changes" "12"

    local replacement="$db.jfmig-new"
    rm -f "$replacement"

    if ! sqlite3 "$db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1; then
        error "Could not checkpoint the real Jellyfin database."
        return 1
    fi

    if ! sqlite3 "$TEMP_DB" ".backup '$replacement'" >/dev/null 2>&1 || [[ ! -s "$replacement" ]]; then
        error "Could not prepare the final database image."
        rm -f "$replacement"
        return 1
    fi

    if [[ "$(sqlite3 "$replacement" "PRAGMA quick_check;" 2>/dev/null | head -n 1)" != "ok" ]]; then
        error "The migrated database failed its integrity check; the real database was NOT replaced."
        rm -f "$replacement"
        return 1
    fi

    local mode
    mode="$(stat -f '%Lp' "$db" 2>/dev/null || echo 600)"
    chmod "$mode" "$replacement" 2>/dev/null || true

    rm -f "$db-wal" "$db-shm"

    if ! mv -f "$replacement" "$db"; then
        error "Could not install the migrated database."
        rm -f "$replacement"
        return 1
    fi

    ok "Migrated database installed."
}

# ------------------------------------------------------------------------------
# 21. DRY RUN
# ------------------------------------------------------------------------------

run_simulation() {
    header "Preparing dry-run database" "5A"

    create_temp_database || return 1
    ok "Disposable SQLite working database created."

    report_unmapped_roots "$TEMP_DB" || return 1
    report_config_rows "$TEMP_DB"

    update_db_paths "$TEMP_DB" || return 1
    repair_linked_children "$TEMP_DB" || return 1
    repair_image_extensions "$TEMP_DB" || return 1

    ok "Dry-run database simulation completed."
}

# ------------------------------------------------------------------------------
# 22. MAIN
# ------------------------------------------------------------------------------

main() {
    clear_screen

    header "Jellyfin 12.x Migration"
    printf '  %bDocker -> Native macOS%b\n' "${WHITE}${BOLD}" "${RESET}"
    printf '  Dry run first. No real files are modified until you type APPLY.\n\n'
    printf '  Native data: %s\n' "$DATADIR"
    printf '  Mappings (Docker path -> Mac path):\n'
    local entry
    for entry in "${PATH_MAPPINGS[@]}"; do
        printf '    %s\n' "${entry/\|/  ->  }"
    done
    printf '\n'
    hard_abort_hint
    pause_here "Press ENTER to begin, or Q to abort."

    check_environment || exit 1
    check_jellyfin_version || exit 1
    check_jellyfin_stopped || exit 1
    load_path_mappings || exit 1

    run_simulation || exit 1

    prepare_text_changes || exit 1

    leftover_check_db "$TEMP_DB" "dry-run copy" || exit 1
    leftover_check_text "dry-run copies" "$TEMP_DIR/files" "$TEMP_DIR/plugin-files" || exit 1

    header "Dry run complete" "14"

    if [[ "$HAD_ERRORS" == true ]]; then
        printf '%b\n' "${RED}${BOLD}Errors were detected during the dry run.${RESET}"
        printf 'Review them before applying.\n\n'
    elif (( WARNINGS > 0 )); then
        printf '%b\n' "${YELLOW}${BOLD}$WARNINGS warning(s) were reported.${RESET}"
        printf 'Review them before applying.\n\n'
    else
        printf '%b\n' "${GREEN}${BOLD}Dry run completed without errors or warnings.${RESET}"
        printf '\n'
    fi

    printf 'No real Jellyfin files have been changed.\n'
    if [[ "$MAKE_SAFETY_COPY" == true ]]; then
        printf 'If you APPLY, a safety copy is written first to:\n  %s.premigration-<timestamp>\n' "$DATADIR"
    fi
    printf 'The dry-run database is disposable and will be removed if you exit.\n\n'

    local response=""
    if [[ "$APPLY_MODE" == true ]]; then
        printf '%b' "${YELLOW}${BOLD}Type APPLY to continue: ${RESET}"
    else
        printf '%b' "${MAGENTA}${BOLD}Type APPLY to continue, or anything else to exit: ${RESET}"
    fi
    IFS= read -r response || exit 130

    if [[ "$response" != "APPLY" ]]; then
        ok "No changes were made. Exiting."
        exit 0
    fi

    if [[ "$HAD_ERRORS" == true ]]; then
        printf '\n%b\n' "${RED}${BOLD}WARNING: The dry run reported errors.${RESET}"
        printf 'Applying despite those errors may leave the migration incomplete.\n'
        printf '%b' "${RED}${BOLD}Type APPLY AGAIN to confirm: ${RESET}"
        IFS= read -r response || exit 130

        if [[ "$response" != "APPLY AGAIN" ]]; then
            ok "Apply cancelled. No changes were made."
            exit 0
        fi
    fi

    # Refuse to apply if the real database changed after the dry-run snapshot.
    if [[ "$(db_stamp)" != "$DB_STAMP" ]]; then
        error "The real Jellyfin database changed after the dry-run snapshot was taken."
        detail "Nothing was modified. Run the script again."
        exit 1
    fi

    header "Safety copy" "12A"
    make_safety_copy || exit 1

    if ! apply_file_changes; then
        rollback_files
        [[ -n "$BACKUP_DIR" ]] && detail "Safety copy: $BACKUP_DIR"
        exit 1
    fi

    if ! apply_database_changes; then
        rollback_files
        detail "The real database was not replaced."
        [[ -n "$BACKUP_DIR" ]] && detail "Safety copy: $BACKUP_DIR"
        exit 1
    fi

    leftover_check_db "$DATADIR/data/jellyfin.db" "real database" || exit 1
    leftover_check_text "real files" \
        "$DATADIR/root/default" \
        "$DATADIR/data/collections" \
        "$DATADIR/data/playlists" \
        "$DATADIR/plugins" || exit 1

    header "Migration finished" "15"

    if [[ "$HAD_ERRORS" == true ]]; then
        printf '%b\n' "${RED}${BOLD}Migration finished with errors. Review the messages above.${RESET}"
        exit 1
    fi

    printf '%b\n' "${GREEN}${BOLD}Jellyfin 12.x migration completed successfully.${RESET}"
    printf '\n'
    printf 'Native Jellyfin data directory:\n'
    printf '  %s\n\n' "$DATADIR"
    if [[ -n "$BACKUP_DIR" ]]; then
        printf 'Safety copy (jellyfin.db and every changed text file):\n'
        printf '  %s\n\n' "$BACKUP_DIR"
        printf 'To roll back: quit Jellyfin, copy jellyfin.db from the safety copy over\n'
        printf '%s/data/jellyfin.db, and copy the files/ tree back over %s.\n\n' "$DATADIR" "$DATADIR"
    fi
    printf 'Start Jellyfin only after reviewing the final verification above.\n'
}

main "$@"
