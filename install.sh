#!/usr/bin/env bash
# =============================================================================
# Project: Luciole Scripts
# Based on: Enhanced File Manager Actions (cfgnunes/nautilus-scripts)
# License: MIT License
# =============================================================================
#
# Installs the actions into the Luciole scripts directory:
#
#   ${XDG_DATA_HOME:-$HOME/.local/share}/luciole/scripts/
#
# Luciole scans only the first level of that directory, ignores hidden files
# and displays at most 64 scripts. The default "categories" mode therefore
# installs one launcher per category and keeps the actions in a hidden folder:
# each launcher opens a menu with the actions of its category, so the whole
# collection stays available despite the 64-entry limit.
#
# The "flat" mode installs the selected actions directly in the scripts folder
# and enforces the 64-script limit.

set -u

APP_NAME="Luciole Scripts"
APP_VERSION="1.0.0"
MAX_SCRIPTS=64

# Use the home directory from the passwd database if '$HOME' is undefined.
HOME=${HOME:-$(eval echo ~)}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
PO_DIR="$SCRIPT_DIR/.po"

# -----------------------------------------------------------------------------
# SECTION: Paths
# -----------------------------------------------------------------------------

_get_data_home() {
    local dir="${XDG_DATA_HOME:-}"
    # Luciole requires an absolute XDG data directory.
    if [[ -z "$dir" || "$dir" != /* ]]; then
        dir="$HOME/.local/share"
    fi
    printf "%s" "${dir%/}"
}

INSTALL_ROOT="$(_get_data_home)/luciole"
SCRIPTS_DIR="$INSTALL_ROOT/scripts"
MANIFEST="$SCRIPTS_DIR/.luciole-scripts-manifest"
STORE_DIR="$SCRIPTS_DIR/.luciole-actions"
CATEGORY_MENU_SOURCE="$SCRIPT_DIR/.category-menu.sh"

# Groups proposed by default (62 scripts). They cover everyday file handling
# without reaching the Luciole limit of 64 entries.
RECOMMENDED_GROUPS=(
    "Archive"
    "Checksum"
    "Clipboard"
    "Directories and Files"
    "Open with"
    "Rename files"
    "Security and Backup"
)

# -----------------------------------------------------------------------------
# SECTION: Output helpers
# -----------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_INFO=$'\033[0;32m'
    C_WARN=$'\033[0;33m'
    C_ERROR=$'\033[0;31m'
    C_BOLD=$'\033[1m'
else
    C_RESET=""
    C_INFO=""
    C_WARN=""
    C_ERROR=""
    C_BOLD=""
fi

_info() { printf "%s[INFO]%s %s\n" "$C_INFO" "$C_RESET" "$*"; }
_warn() { printf "%s[WARN]%s %s\n" "$C_WARN" "$C_RESET" "$*" >&2; }
_error() { printf "%s[FAIL]%s %s\n" "$C_ERROR" "$C_RESET" "$*" >&2; }

_usage() {
    cat <<EOF
$APP_NAME $APP_VERSION

Install actions for the Luciole file manager.

Usage:
  $0 [options]

Usage modes:
  categories   (default) Install one launcher per category. Each launcher
               opens a dialog with the actions of that category, grouped by
               their upstream subfolder. The actions are kept in a hidden
               folder, so Luciole's $MAX_SCRIPTS-entry limit no longer forces a
               subset: the whole collection stays available.
  flat         Install the selected actions directly in the scripts folder.
               Luciole displays at most $MAX_SCRIPTS entries in this mode.

Options:
  -h, --help              Show this help.
  -l, --list              List categories and groups with their script counts.
  -m, --mode MODE         Layout: categories (default) or flat.
  -a, --all               Select every group.
  -r, --recommended       Select the default set of groups (62 actions).
  -g, --group PATH        Select one group (repeatable). PATH is an id from --list.
  -c, --category NAME     Select all groups of a top-level category (repeatable).
  -x, --exclude NAME      Exclude a group id or a category (repeatable).
      --lang CODE         Name language: auto (default), en, or a .po code (e.g. fr).
      --dry-run           Show what would be installed, change nothing.
  -f, --force             Allow more than $MAX_SCRIPTS scripts in flat mode, and
                          overwrite existing scripts that are not ours.
      --install-deps      Try to install the missing basic dependencies.
      --no-deps           Skip the dependency check.
  -y, --yes               Do not ask for confirmation.

Without a selection option, an interactive menu is shown. In categories mode
the default choice is every category; in flat mode it is the recommended set.

Destination:
  $SCRIPTS_DIR

Examples:
  $0                              # category menus, interactive
  $0 --all                        # every category and every action
  $0 --recommended                # everyday actions, still grouped by category
  $0 --group "Image/Image: Convert"
  $0 --mode flat --recommended    # old flat layout (62 scripts)
EOF
}

# -----------------------------------------------------------------------------
# SECTION: Internationalization (names only)
# -----------------------------------------------------------------------------

I18N_FILE=""

_i18n_init() {
    local lang=$1
    local candidate=""

    I18N_FILE=""

    case "$lang" in
    "en") return 0 ;;
    "auto" | "") lang="${LANG:-${LC_ALL:-}}" ;;
    esac

    lang="${lang%%.*}"
    [[ -z "$lang" ]] && return 0

    candidate="$PO_DIR/$lang.po"
    if [[ -f "$candidate" ]]; then
        I18N_FILE="$candidate"
        return 0
    fi

    lang="${lang%%_*}"
    candidate="$PO_DIR/$lang.po"
    if [[ -f "$candidate" ]]; then
        I18N_FILE="$candidate"
    fi
}

_i18n() {
    local msgid=$1
    local msgstr=""

    if [[ -n "$I18N_FILE" && -f "$I18N_FILE" && -n "$msgid" ]]; then
        msgstr=$(grep -F -A1 -- "msgid \"$msgid\"" "$I18N_FILE" 2>/dev/null |
            sed -n '2s/^msgstr "\(.*\)"$/\1/p')
    fi

    if [[ -n "$msgstr" ]]; then
        printf "%s" "$msgstr"
    else
        printf "%s" "$msgid"
    fi
}

# -----------------------------------------------------------------------------
# SECTION: Group discovery
# -----------------------------------------------------------------------------

declare -a GROUP_IDS=()
declare -a GROUP_LABELS=()
declare -a GROUP_COUNTS=()

_count_scripts_in() {
    local dir=$1
    local count=""
    count=$(find "$dir" -mindepth 1 -maxdepth 1 -type f ! -name '.*' \
        -printf '.' 2>/dev/null | wc -c)
    printf "%s" "${count//[[:space:]]/}"
}

_group_label() {
    local id=$1
    local -a parts=()
    local component=""
    local label=""

    IFS='/' read -r -a parts <<<"$id"
    for component in "${parts[@]}"; do
        component=$(_i18n "$component")
        if [[ -z "$label" ]]; then
            label="$component"
        else
            label+=" > $component"
        fi
    done
    printf "%s" "$label"
}

_discover_groups() {
    local catdir=""
    local groupdir=""
    local id=""
    local count=0

    while IFS= read -r -d '' catdir; do
        while IFS= read -r -d '' groupdir; do
            count=$(_count_scripts_in "$groupdir")
            ((count == 0)) && continue
            id="${groupdir#"$SCRIPT_DIR"/}"
            GROUP_IDS+=("$id")
            GROUP_LABELS+=("$(_group_label "$id")")
            GROUP_COUNTS+=("$count")
        done < <(find "$catdir" -type d -print0 2>/dev/null | sort -z)
    done < <(find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 -type d \
        ! -name '.*' -print0 2>/dev/null | sort -z)
}

# -----------------------------------------------------------------------------
# SECTION: Category discovery
# -----------------------------------------------------------------------------

declare -a CATEGORY_IDS=()
declare -a CATEGORY_LABELS=()
declare -a CATEGORY_COUNTS=()
declare -a CATEGORY_GROUP_COUNTS=()

_discover_categories() {
    local i=0
    local cat=""
    local cat_idx=0
    local -A seen=()

    for i in "${!GROUP_IDS[@]}"; do
        cat="${GROUP_IDS[$i]%%/*}"
        if [[ -z "${seen[$cat]:-}" ]]; then
            cat_idx=${#CATEGORY_IDS[@]}
            seen["$cat"]="$cat_idx"
            CATEGORY_IDS+=("$cat")
            CATEGORY_LABELS+=("$(_i18n "$cat")")
            CATEGORY_COUNTS+=("0")
            CATEGORY_GROUP_COUNTS+=("0")
        fi
        cat_idx="${seen[$cat]}"
        CATEGORY_COUNTS[$cat_idx]=$((CATEGORY_COUNTS[cat_idx] + GROUP_COUNTS[i]))
        CATEGORY_GROUP_COUNTS[$cat_idx]=$((CATEGORY_GROUP_COUNTS[cat_idx] + 1))
    done
}

_print_categories() {
    local i=0
    local total=0
    local total_groups=0

    printf "%sAvailable categories:%s\n" "$C_BOLD" "$C_RESET"
    printf "%4s  %-32s %8s %7s\n" "#" "Category" "Actions" "Groups"
    for i in "${!CATEGORY_IDS[@]}"; do
        printf "%4d  %-32s %8d %7d\n" \
            "$((i + 1))" "${CATEGORY_LABELS[$i]}" \
            "${CATEGORY_COUNTS[$i]}" "${CATEGORY_GROUP_COUNTS[$i]}"
        total=$((total + CATEGORY_COUNTS[i]))
        total_groups=$((total_groups + CATEGORY_GROUP_COUNTS[i]))
    done
    printf "%4s  %-32s %8d %7d\n" "" "TOTAL" "$total" "$total_groups"

    printf "\nCategory ids for --category:\n"
    for i in "${!CATEGORY_IDS[@]}"; do
        printf "  %s\n" "${CATEGORY_IDS[$i]}"
    done
}

_print_groups() {
    local i=0
    local total=0

    printf "%sAvailable groups:%s\n" "$C_BOLD" "$C_RESET"
    printf "%4s  %-58s %5s\n" "#" "Group" "Count"
    for i in "${!GROUP_IDS[@]}"; do
        printf "%4d  %-58s %5d\n" \
            "$((i + 1))" "${GROUP_LABELS[$i]}" "${GROUP_COUNTS[$i]}"
        total=$((total + GROUP_COUNTS[i]))
    done
    printf "%4s  %-58s %5d\n" "" "TOTAL" "$total"
    printf "\nGroup ids for --group:\n"
    for i in "${!GROUP_IDS[@]}"; do
        printf "  %s\n" "${GROUP_IDS[$i]}"
    done
}

# -----------------------------------------------------------------------------
# SECTION: Filename generation
# -----------------------------------------------------------------------------

_sanitize_filename() {
    local name=$1

    name=${name//$'\n'/ }
    name=${name//$'\r'/ }
    name=${name//$'\t'/ }
    name=${name//\//-}

    # Trim leading and trailing whitespace.
    name="${name#"${name%%[![:space:]]*}"}"
    name="${name%"${name##*[![:space:]]}"}"

    # Luciole hides filenames starting with a dot.
    while [[ "$name" == .* ]]; do
        name=${name#.}
    done

    [[ -z "$name" ]] && name="script"
    printf "%s" "$name"
}

_installed_name() {
    local category=$1
    local script=$2
    local category_name=""
    local script_name=""
    local prefix=""

    category_name=$(_i18n "$category")
    script_name=$(_i18n "$script")

    # Avoid "Image - Image: Convert to PNG" when the action already carries
    # its category, e.g. "Image: Convert to PNG".
    prefix="$category_name: "
    if [[ "$script_name" == "$prefix"* ]]; then
        script_name=${script_name#"$prefix"}
    fi

    _sanitize_filename "$category_name - $script_name"
}

_hub_name() {
    local category=$1
    _sanitize_filename "$(_i18n "$category")"
}

# -----------------------------------------------------------------------------
# SECTION: Collision checks
# -----------------------------------------------------------------------------

declare -A OLD_MANIFEST=()

_load_manifest_names() {
    OLD_MANIFEST=()
    local name=""

    if [[ -f "$MANIFEST" ]]; then
        while IFS= read -r name || [[ -n "$name" ]]; do
            [[ -n "$name" ]] && OLD_MANIFEST["$name"]="true"
        done <"$MANIFEST"
    fi
}

_check_name_collisions() {
    local -a names=("$@")
    local -a conflicts=()
    local name=""

    _load_manifest_names

    for name in "${names[@]}"; do
        [[ -e "$SCRIPTS_DIR/$name" ]] || continue
        [[ -n "${OLD_MANIFEST[$name]:-}" ]] && continue
        conflicts+=("$name")
    done

    ((${#conflicts[@]} == 0)) && return 0

    if [[ "$OPT_FORCE" == "true" ]]; then
        _warn "Overwriting existing script(s) because --force is in effect:"
        printf "  %s\n" "${conflicts[@]}"
        return 0
    fi

    _error "These existing scripts are not managed by $APP_NAME:"
    printf "  %s\n" "${conflicts[@]}" >&2
    _error "Move them away, or pass --force to overwrite them."
    return 1
}

# -----------------------------------------------------------------------------
# SECTION: Dependencies
# -----------------------------------------------------------------------------

_missing_basic_commands() {
    local -a missing=()
    local cmd=""

    for cmd in basename find grep sed sort mktemp xargs; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    command -v "file" &>/dev/null || missing+=("file")
    command -v "pstree" &>/dev/null || missing+=("pstree")
    command -v "pgrep" &>/dev/null || missing+=("pgrep")
    command -v "xdg-open" &>/dev/null || missing+=("xdg-open")
    command -v "bwrap" &>/dev/null || missing+=("bwrap")

    if ! command -v "zenity" &>/dev/null && ! command -v "yad" &>/dev/null; then
        missing+=("zenity-or-yad")
    fi

    if ((${#missing[@]} > 0)); then
        printf "%s\n" "${missing[@]}"
    fi
}

_run_admin() {
    if command -v "sudo" &>/dev/null; then
        sudo "$@"
    else
        "$@"
    fi
}

_install_dependencies() {
    local -a missing=()
    local -a packages=()
    local cmd=""
    local pkg=""
    local manager=""

    mapfile -t missing < <(_missing_basic_commands)
    ((${#missing[@]} == 0)) && return 0

    if command -v "apt-get" &>/dev/null; then
        manager="apt-get"
    elif command -v "dnf" &>/dev/null; then
        manager="dnf"
    elif command -v "pacman" &>/dev/null; then
        manager="pacman"
    elif command -v "zypper" &>/dev/null; then
        manager="zypper"
    elif command -v "xbps-install" &>/dev/null; then
        manager="xbps-install"
    else
        _warn "No supported package manager found. Install these commands manually:"
        printf "  %s\n" "${missing[@]}"
        return 1
    fi

    for cmd in "${missing[@]}"; do
        case "$cmd" in
        "pstree") pkg="psmisc" ;;
        "pgrep")
            case "$manager" in
            "apt-get" | "zypper" | "xbps-install") pkg="procps" ;;
            *) pkg="procps-ng" ;;
            esac
            ;;
        "xdg-open") pkg="xdg-utils" ;;
        "bwrap") pkg="bubblewrap" ;;
        "file") pkg="file" ;;
        "zenity-or-yad") pkg="zenity" ;;
        *) continue ;;
        esac
        packages+=("$pkg")
    done

    ((${#packages[@]} == 0)) && return 0

    case "$manager" in
    "apt-get")
        _run_admin apt-get update && _run_admin apt-get install -y "${packages[@]}"
        ;;
    "dnf")
        _run_admin dnf install -y "${packages[@]}"
        ;;
    "pacman")
        _run_admin pacman -S --needed --noconfirm "${packages[@]}"
        ;;
    "zypper")
        _run_admin zypper --non-interactive install "${packages[@]}"
        ;;
    "xbps-install")
        _run_admin xbps-install -Sy "${packages[@]}"
        ;;
    esac
}

_check_dependencies() {
    local -a missing=()
    local cmd=""

    mapfile -t missing < <(_missing_basic_commands)
    ((${#missing[@]} == 0)) && return 0

    _warn "Some basic commands are missing:"
    printf "  %s\n" "${missing[@]}"
    _warn "Actions may fail until they are installed. Use --install-deps to try an automatic install."

    for cmd in "${missing[@]}"; do
        case "$cmd" in
        "zenity-or-yad")
            _warn "Install zenity or yad: Luciole starts scripts without a terminal, so dialogs are required."
            ;;
        "bwrap")
            _warn "Install bubblewrap to keep the optional command sandbox. Actions still run without it."
            ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# SECTION: Selection
# -----------------------------------------------------------------------------

declare -a SELECT_GROUPS=()
declare -a SELECT_CATEGORIES=()
declare -a EXCLUDE_GROUPS=()
declare -a SELECTED_CATEGORIES=()
MODE="categories"
OPT_ALL="false"
OPT_RECOMMENDED="false"
OPT_LIST="false"
OPT_DRY_RUN="false"
OPT_FORCE="false"
OPT_INSTALL_DEPS="false"
OPT_SKIP_DEPS="false"
OPT_YES="false"
LANG_OPTION="auto"

_group_exists() {
    local wanted=$1
    local id=""
    for id in "${GROUP_IDS[@]}"; do
        [[ "$id" == "$wanted" ]] && return 0
    done
    return 1
}

_group_index() {
    local wanted=$1
    local i=0
    for i in "${!GROUP_IDS[@]}"; do
        if [[ "${GROUP_IDS[$i]}" == "$wanted" ]]; then
            printf "%s" "$i"
            return 0
        fi
    done
    return 1
}

_add_group_id() {
    local id=$1
    local i=""
    if ! i=$(_group_index "$id"); then
        _error "Unknown group: $id"
        return 1
    fi
    SELECTED[$i]="true"
    return 0
}

_add_category() {
    local category=$1
    local id=""
    local found="false"

    for id in "${GROUP_IDS[@]}"; do
        if [[ "$id" == "$category" || "$id" == "$category/"* ]]; then
            _add_group_id "$id" || return 1
            found="true"
        fi
    done

    if [[ "$found" == "false" ]]; then
        _error "Unknown category: $category"
        return 1
    fi
    return 0
}

_add_recommended() {
    local id=""
    for id in "${RECOMMENDED_GROUPS[@]}"; do
        if _group_exists "$id"; then
            _add_group_id "$id" || return 1
        fi
    done
    return 0
}

_category_index() {
    local wanted=$1
    local i=0
    for i in "${!CATEGORY_IDS[@]}"; do
        if [[ "${CATEGORY_IDS[$i]}" == "$wanted" ]]; then
            printf "%s" "$i"
            return 0
        fi
    done
    return 1
}

_select_category_index() {
    local idx=$1
    local category=${CATEGORY_IDS[$idx]}
    local i=0

    for i in "${!GROUP_IDS[@]}"; do
        if [[ "${GROUP_IDS[$i]}" == "$category" ||
            "${GROUP_IDS[$i]}" == "$category/"* ]]; then
            SELECTED[$i]="true"
        fi
    done
}

_collect_selected_categories() {
    local -A seen=()
    local i=0
    local category=""

    SELECTED_CATEGORIES=()
    for i in "${!GROUP_IDS[@]}"; do
        [[ "${SELECTED[$i]}" == "true" ]] || continue
        category="${GROUP_IDS[$i]%%/*}"
        if [[ -z "${seen[$category]:-}" ]]; then
            seen["$category"]="true"
            SELECTED_CATEGORIES+=("$category")
        fi
    done
}

# Parse a category selection expression such as "1 3 5-7 all recommended none".
_apply_category_selection_expression() {
    local expression=$1
    local -a tokens=()
    local token=""
    local low=0
    local high=0
    local n=0

    read -r -a tokens <<<"$expression"
    for token in "${tokens[@]}"; do
        case "$token" in
        "all")
            for n in "${!GROUP_IDS[@]}"; do SELECTED[$n]="true"; done
            ;;
        "none")
            for n in "${!GROUP_IDS[@]}"; do SELECTED[$n]="false"; done
            ;;
        "recommended" | "default")
            for n in "${!GROUP_IDS[@]}"; do SELECTED[$n]="false"; done
            _add_recommended || return 1
            ;;
        *)
            if [[ "$token" =~ ^[0-9]+$ ]]; then
                n=$((token - 1))
                if ((n < 0 || n >= ${#CATEGORY_IDS[@]})); then
                    _error "Number out of range: $token"
                    return 1
                fi
                _select_category_index "$n"
            elif [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                low=${BASH_REMATCH[1]}
                high=${BASH_REMATCH[2]}
                for ((n = low; n <= high; n++)); do
                    if ((n < 1 || n > ${#CATEGORY_IDS[@]})); then
                        _error "Number out of range: $n"
                        return 1
                    fi
                    _select_category_index "$((n - 1))"
                done
            else
                _error "Invalid selection: $token"
                return 1
            fi
            ;;
        esac
    done
    return 0
}

# Parse a selection expression such as "1 3 5-7 all recommended none".
_apply_selection_expression() {
    local expression=$1
    local -a tokens=()
    local token=""
    local low=0
    local high=0
    local n=0

    read -r -a tokens <<<"$expression"
    for token in "${tokens[@]}"; do
        case "$token" in
        "all")
            for n in "${!GROUP_IDS[@]}"; do SELECTED[$n]="true"; done
            ;;
        "none")
            for n in "${!GROUP_IDS[@]}"; do SELECTED[$n]="false"; done
            ;;
        "recommended" | "default")
            for n in "${!GROUP_IDS[@]}"; do SELECTED[$n]="false"; done
            _add_recommended || return 1
            ;;
        *)
            if [[ "$token" =~ ^[0-9]+$ ]]; then
                n=$((token - 1))
                if ((n < 0 || n >= ${#GROUP_IDS[@]})); then
                    _error "Number out of range: $token"
                    return 1
                fi
                SELECTED[$n]="true"
            elif [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                low=${BASH_REMATCH[1]}
                high=${BASH_REMATCH[2]}
                for ((n = low; n <= high; n++)); do
                    if ((n < 1 || n > ${#GROUP_IDS[@]})); then
                        _error "Number out of range: $n"
                        return 1
                    fi
                    SELECTED[$((n - 1))]="true"
                done
            else
                _error "Invalid selection: $token"
                return 1
            fi
            ;;
        esac
    done
    return 0
}

_interactive_select() {
    local answer=""
    local n=0
    local count=0

    _print_groups
    printf "\n"
    printf "Select groups by number (example: 1 3 5-7).\n"
    printf "Use 'recommended' or press Enter for the default set, 'all', or 'none': "
    read -r answer || return 1

    [[ "$answer" == "q" || "$answer" == "quit" ]] && return 1
    [[ -z "$answer" ]] && answer="recommended"

    _apply_selection_expression "$answer" || return 1

    printf "\nSelected:\n"
    for n in "${!GROUP_IDS[@]}"; do
        if [[ "${SELECTED[$n]}" == "true" ]]; then
            printf "  - %s (%d)\n" "${GROUP_LABELS[$n]}" "${GROUP_COUNTS[$n]}"
            count=$((count + GROUP_COUNTS[n]))
        fi
    done
    printf "Total: %d script(s)\n" "$count"
}

_interactive_select_categories() {
    local answer=""
    local category=""
    local cat_count=0
    local g=0
    local count=0

    _print_categories
    printf "\n"
    printf "Select categories by number (example: 1 3 5-7).\n"
    printf "Press Enter for all categories, or type 'none': "
    read -r answer || return 1

    [[ "$answer" == "q" || "$answer" == "quit" ]] && return 1
    [[ -z "$answer" ]] && answer="all"

    _apply_category_selection_expression "$answer" || return 1

    _collect_selected_categories
    printf "\nSelected categories:\n"
    for category in "${SELECTED_CATEGORIES[@]}"; do
        cat_count=0
        for g in "${!GROUP_IDS[@]}"; do
            [[ "${SELECTED[$g]}" == "true" ]] || continue
            if [[ "${GROUP_IDS[$g]}" == "$category" ||
                "${GROUP_IDS[$g]}" == "$category/"* ]]; then
                cat_count=$((cat_count + GROUP_COUNTS[g]))
            fi
        done
        printf "  - %s (%d actions)\n" "$(_i18n "$category")" "$cat_count"
        count=$((count + cat_count))
    done
    printf "Total: %d action(s) in %d category menu(s)\n" \
        "$count" "${#SELECTED_CATEGORIES[@]}"
}

# -----------------------------------------------------------------------------
# SECTION: Installation
# -----------------------------------------------------------------------------

_clean_previous_install() {
    local name=""

    if [[ -f "$MANIFEST" ]]; then
        while IFS= read -r name || [[ -n "$name" ]]; do
            [[ -z "$name" || "$name" == */* ]] && continue
            rm -f -- "$SCRIPTS_DIR/$name"
        done <"$MANIFEST"
    fi

    rm -f -- "$SCRIPTS_DIR/.common-functions.sh"
    rm -f -- "$SCRIPTS_DIR/.pkg-map.sh"
    rm -rf -- "$SCRIPTS_DIR/.po"
    rm -rf -- "$STORE_DIR"
    rm -f -- "$MANIFEST"
}

_prepare_dirs() {
    mkdir -p -- "$INSTALL_ROOT" "$SCRIPTS_DIR"
    chmod u+rwx,go-w -- "$INSTALL_ROOT" "$SCRIPTS_DIR"
}

_install_helpers() {
    local src=""

    install -m 0644 -- "$SCRIPT_DIR/.common-functions.sh" \
        "$SCRIPTS_DIR/.common-functions.sh"
    install -m 0644 -- "$SCRIPT_DIR/.pkg-map.sh" \
        "$SCRIPTS_DIR/.pkg-map.sh"

    mkdir -p -- "$SCRIPTS_DIR/.po"
    chmod u+rwx,go-w -- "$SCRIPTS_DIR/.po"
    for src in "$PO_DIR"/*.po; do
        [[ -f "$src" ]] || continue
        install -m 0644 -- "$src" "$SCRIPTS_DIR/.po/$(basename -- "$src")"
    done
}

_write_manifest() {
    local -a names=("$@")

    if ((${#names[@]} > 0)); then
        printf "%s\n" "${names[@]}" >"$MANIFEST"
        chmod 0644 -- "$MANIFEST"
    fi
}

_write_hub() {
    local target=$1
    local category=$2
    local tmp=""

    tmp=$(mktemp --tmpdir "luciole-hub.XXXXXX") || return 1
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '# Luciole Scripts category menu: %s\n' "$category"
        printf '%s\n' \
            'SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)'
        printf 'exec "$SCRIPT_DIR/.luciole-actions/menu.sh" "%s" "$@"\n' \
            "$category"
    } >"$tmp"
    install -m 0755 -- "$tmp" "$target"
    rm -f -- "$tmp"
}

_install_flat() {
    local -a sources=()
    local -a installed_names=()
    local -A name_taken=()
    local src=""
    local group=""
    local category=""
    local base=""
    local name=""
    local suffix=0
    local i=0
    local group_idx=0
    local total=0

    # Build the flat list of files to copy.
    for group_idx in "${!GROUP_IDS[@]}"; do
        [[ "${SELECTED[$group_idx]}" == "true" ]] || continue
        group="${GROUP_IDS[$group_idx]}"
        category="${group%%/*}"

        while IFS= read -r -d '' src; do
            base=$(basename -- "$src")
            name=$(_installed_name "$category" "$base")

            if [[ -n "${name_taken["$name"]:-}" ]]; then
                suffix=2
                while [[ -n "${name_taken["$name ($suffix)"]:-}" ]]; do
                    suffix=$((suffix + 1))
                done
                name="$name ($suffix)"
            fi

            name_taken["$name"]="true"
            sources+=("$src")
            installed_names+=("$name")
        done < <(find "$SCRIPT_DIR/$group" -mindepth 1 -maxdepth 1 \
            -type f ! -name '.*' -print0 2>/dev/null | sort -z)
    done

    total=${#installed_names[@]}
    if ((total == 0)); then
        _warn "Nothing selected."
        return 1
    fi

    if ((total > MAX_SCRIPTS)) && [[ "$OPT_FORCE" != "true" ]]; then
        _error "$total scripts selected, but Luciole displays at most $MAX_SCRIPTS."
        _error "Select fewer groups (see --list) or pass --force to install anyway."
        _error "With --force, Luciole may expose only an arbitrary subset of the files."
        return 1
    fi

    if ((total > MAX_SCRIPTS)); then
        _warn "$total scripts selected. Luciole displays at most $MAX_SCRIPTS; --force is in effect."
    fi

    if ! _check_name_collisions "${installed_names[@]}"; then
        return 1
    fi

    if [[ "$OPT_DRY_RUN" == "true" ]]; then
        printf "%sWould install %d script(s) into:%s\n" "$C_BOLD" "$total" "$C_RESET"
        printf "  %s\n\n" "$SCRIPTS_DIR"
        for i in "${!installed_names[@]}"; do
            printf "  %s\n      <- %s\n" "${installed_names[$i]}" "${sources[$i]}"
        done
        return 0
    fi

    _prepare_dirs
    _clean_previous_install
    _install_helpers

    for i in "${!installed_names[@]}"; do
        install -m 0755 -- "${sources[$i]}" \
            "$SCRIPTS_DIR/${installed_names[$i]}"
    done

    _write_manifest "${installed_names[@]}"

    _info "Installed $total script(s) into $SCRIPTS_DIR"
    _info "Reopen Scripts in Luciole (or restart Luciole) to refresh the menu."
    return 0
}

_install_categories() {
    local -a hub_names=()
    local -a hub_categories=()
    local -a hub_counts=()
    local -A hub_taken=()
    local group=""
    local category=""
    local src=""
    local target=""
    local total=0
    local count=0
    local group_idx=0
    local i=0
    local suffix=0
    local hub=""

    _collect_selected_categories
    if ((${#SELECTED_CATEGORIES[@]} == 0)); then
        _warn "Nothing selected."
        return 1
    fi

    # Build the visible launchers and their action counts.
    for category in "${SELECTED_CATEGORIES[@]}"; do
        count=0
        for group_idx in "${!GROUP_IDS[@]}"; do
            [[ "${SELECTED[$group_idx]}" == "true" ]] || continue
            group="${GROUP_IDS[$group_idx]}"
            [[ "${group%%/*}" == "$category" ]] || continue
            count=$((count + GROUP_COUNTS[group_idx]))
        done

        hub=$(_hub_name "$category")
        hub_names+=("$hub")
        hub_categories+=("$category")
        hub_counts+=("$count")
        total=$((total + count))
    done

    # Translation collisions are unlikely, but keep the menu unambiguous.
    for i in "${!hub_names[@]}"; do
        hub="${hub_names[$i]}"
        if [[ -n "${hub_taken[$hub]:-}" ]]; then
            suffix=2
            while [[ -n "${hub_taken["$hub ($suffix)"]:-}" ]]; do
                suffix=$((suffix + 1))
            done
            hub="$hub ($suffix)"
            hub_names[$i]="$hub"
        fi
        hub_taken["$hub"]="true"
    done

    if ((${#hub_names[@]} > MAX_SCRIPTS)) && [[ "$OPT_FORCE" != "true" ]]; then
        _error "${#hub_names[@]} category menus selected, but Luciole displays at most $MAX_SCRIPTS."
        _error "Select fewer categories (see --list) or pass --force to install anyway."
        return 1
    fi

    if ! _check_name_collisions "${hub_names[@]}"; then
        return 1
    fi

    if [[ "$OPT_DRY_RUN" == "true" ]]; then
        printf "%sWould install %d category menu(s) with %d action(s) into:%s\n" \
            "$C_BOLD" "${#hub_names[@]}" "$total" "$C_RESET"
        printf "  %s\n" "$SCRIPTS_DIR"
        printf "Actions are stored in the hidden folder:\n  %s\n\n" "$STORE_DIR"
        for i in "${!hub_names[@]}"; do
            category="${hub_categories[$i]}"
            printf "  %s  (%d actions)\n" "${hub_names[$i]}" "${hub_counts[$i]}"
            for group_idx in "${!GROUP_IDS[@]}"; do
                [[ "${SELECTED[$group_idx]}" == "true" ]] || continue
                group="${GROUP_IDS[$group_idx]}"
                [[ "${group%%/*}" == "$category" ]] || continue
                printf "      %s\n" "${GROUP_LABELS[$group_idx]}"
            done
        done
        return 0
    fi

    _prepare_dirs
    _clean_previous_install
    _install_helpers

    mkdir -p -- "$STORE_DIR"
    chmod u+rwx,go-w -- "$STORE_DIR"
    install -m 0755 -- "$CATEGORY_MENU_SOURCE" "$STORE_DIR/menu.sh"

    # Build and install the native Noctalia/Wayland dialog
    if [[ -d "$SCRIPT_DIR/.dialog" ]]; then
        if [[ ! -x "$SCRIPT_DIR/.dialog/luciole-dialog" ]]; then
            _info "Compiling native Noctalia UI dialog (luciole-dialog)..."
            make -C "$SCRIPT_DIR/.dialog" &>/dev/null || _warn "Could not compile luciole-dialog; zenity/yad fallback will be used."
        fi
        if [[ -x "$SCRIPT_DIR/.dialog/luciole-dialog" ]]; then
            install -m 0755 -- "$SCRIPT_DIR/.dialog/luciole-dialog" "$STORE_DIR/luciole-dialog"
            mkdir -p -- "$HOME/.local/bin"
            install -m 0755 -- "$SCRIPT_DIR/.dialog/luciole-dialog" "$HOME/.local/bin/luciole-dialog"
        fi
    fi

    # Preserve the upstream group subfolders in the hidden store. The menu
    # script uses them as the second column of the category dialog.
    for group_idx in "${!GROUP_IDS[@]}"; do
        [[ "${SELECTED[$group_idx]}" == "true" ]] || continue
        group="${GROUP_IDS[$group_idx]}"
        target="$STORE_DIR/$group"
        mkdir -p -- "$target"
        chmod u+rwx,go-w -- "$target"
        while IFS= read -r -d '' src; do
            install -m 0755 -- "$src" "$target/$(basename -- "$src")"
        done < <(find "$SCRIPT_DIR/$group" -mindepth 1 -maxdepth 1 \
            -type f ! -name '.*' -print0 2>/dev/null | sort -z)
    done

    for i in "${!hub_names[@]}"; do
        if ! _write_hub "$SCRIPTS_DIR/${hub_names[$i]}" "${hub_categories[$i]}"; then
            _error "Could not write launcher: ${hub_names[$i]}"
            return 1
        fi
    done

    _write_manifest "${hub_names[@]}"

    _info "Installed ${#hub_names[@]} category menu(s) with $total action(s) into $SCRIPTS_DIR"
    _info "Reopen Scripts in Luciole (or restart Luciole) to refresh the menu."
    return 0
}

# -----------------------------------------------------------------------------
# SECTION: Main
# -----------------------------------------------------------------------------

_main() {
    local arg=""
    local value=""
    local i=0
    local n=0
    local count=0
    local answer=""
    local explicit_selection="false"
    local rec_count=0
    local rec_id=""
    local exclude_category=""

    while (($# > 0)); do
        arg=$1
        case "$arg" in
        -h | --help)
            _usage
            return 0
            ;;
        -l | --list)
            OPT_LIST="true"
            ;;
        -m | --mode)
            if (($# < 2)); then
                _error "$arg requires a value."
                return 2
            fi
            value=$2
            shift
            case "$value" in
            "categories" | "category" | "menus" | "hubs")
                MODE="categories"
                ;;
            "flat" | "files")
                MODE="flat"
                ;;
            *)
                _error "Unknown mode: $value (use categories or flat)."
                return 2
                ;;
            esac
            ;;
        -a | --all)
            OPT_ALL="true"
            explicit_selection="true"
            ;;
        -r | --recommended)
            OPT_RECOMMENDED="true"
            explicit_selection="true"
            ;;
        -g | --group)
            if (($# < 2)); then
                _error "$arg requires a value."
                return 2
            fi
            value=$2
            shift
            SELECT_GROUPS+=("$value")
            explicit_selection="true"
            ;;
        -c | --category)
            if (($# < 2)); then
                _error "$arg requires a value."
                return 2
            fi
            value=$2
            shift
            SELECT_CATEGORIES+=("$value")
            explicit_selection="true"
            ;;
        -x | --exclude)
            if (($# < 2)); then
                _error "$arg requires a value."
                return 2
            fi
            value=$2
            shift
            EXCLUDE_GROUPS+=("$value")
            ;;
        --lang)
            if (($# < 2)); then
                _error "$arg requires a value."
                return 2
            fi
            LANG_OPTION=$2
            shift
            ;;
        --dry-run) OPT_DRY_RUN="true" ;;
        -f | --force) OPT_FORCE="true" ;;
        --install-deps) OPT_INSTALL_DEPS="true" ;;
        --no-deps) OPT_SKIP_DEPS="true" ;;
        -y | --yes) OPT_YES="true" ;;
        *)
            _error "Unknown option: $arg"
            _usage
            return 2
            ;;
        esac
        shift
    done

    _i18n_init "$LANG_OPTION"
    _discover_groups
    _discover_categories

    if ((${#GROUP_IDS[@]} == 0)); then
        _error "No action found in $SCRIPT_DIR."
        return 1
    fi

    if [[ "$OPT_LIST" == "true" ]]; then
        _print_categories
        printf "\n"
        _print_groups
        for rec_id in "${RECOMMENDED_GROUPS[@]}"; do
            if n=$(_group_index "$rec_id"); then
                rec_count=$((rec_count + GROUP_COUNTS[n]))
            fi
        done
        printf "\nDefault selection (%d actions): %s\n" \
            "$rec_count" "${RECOMMENDED_GROUPS[*]}"
        printf "Default mode: categories (one menu per category, all actions available).\n"
        printf "Use --mode flat to install actions directly (limit: %d).\n" "$MAX_SCRIPTS"
        return 0
    fi

    if [[ "$MODE" == "categories" && ! -f "$CATEGORY_MENU_SOURCE" ]]; then
        _error "Missing file: $CATEGORY_MENU_SOURCE"
        return 1
    fi

    declare -a SELECTED=()
    for i in "${!GROUP_IDS[@]}"; do
        SELECTED[$i]="false"
    done

    if [[ "$OPT_ALL" == "true" ]]; then
        for i in "${!GROUP_IDS[@]}"; do
            SELECTED[$i]="true"
        done
    fi

    if [[ "$OPT_RECOMMENDED" == "true" ]]; then
        _add_recommended || return 1
    fi

    for value in "${SELECT_CATEGORIES[@]}"; do
        _add_category "$value" || return 1
    done

    for value in "${SELECT_GROUPS[@]}"; do
        _add_group_id "$value" || return 1
    done

    # No explicit selection: use a sensible default.
    if [[ "$explicit_selection" != "true" ]]; then
        if [[ "$MODE" == "categories" ]]; then
            if [[ -t 0 && "$OPT_YES" != "true" ]]; then
                _interactive_select_categories || return 1
            else
                _info "No selection given; selecting every category."
                for i in "${!GROUP_IDS[@]}"; do
                    SELECTED[$i]="true"
                done
            fi
        else
            if [[ -t 0 && "$OPT_YES" != "true" ]]; then
                _interactive_select || return 1
            else
                _error "No group selected. Use --list, --group, --category, or --all."
                return 2
            fi
        fi
    fi

    # Apply exclusions after the default selection so that '--exclude' alone
    # still starts from the default set.
    for value in "${EXCLUDE_GROUPS[@]}"; do
        if n=$(_group_index "$value"); then
            SELECTED[$n]="false"
        elif n=$(_category_index "$value"); then
            exclude_category="${CATEGORY_IDS[$n]}"
            for i in "${!GROUP_IDS[@]}"; do
                if [[ "${GROUP_IDS[$i]}" == "$exclude_category" ||
                    "${GROUP_IDS[$i]}" == "$exclude_category/"* ]]; then
                    SELECTED[$i]="false"
                fi
            done
        else
            _warn "Unknown excluded group or category: $value"
        fi
    done

    count=0
    for i in "${!GROUP_IDS[@]}"; do
        [[ "${SELECTED[$i]}" == "true" ]] &&
            count=$((count + GROUP_COUNTS[i]))
    done

    if ((count == 0)); then
        _warn "Nothing selected."
        return 0
    fi

    _collect_selected_categories

    if [[ "$MODE" == "categories" ]]; then
        if ((${#SELECTED_CATEGORIES[@]} > MAX_SCRIPTS)) &&
            [[ "$OPT_FORCE" != "true" ]]; then
            _error "${#SELECTED_CATEGORIES[@]} category menus selected, but Luciole displays at most $MAX_SCRIPTS."
            _error "Select fewer categories (see --list) or pass --force to install anyway."
            return 1
        fi
    elif ((count > MAX_SCRIPTS)) && [[ "$OPT_FORCE" != "true" ]]; then
        _error "$count scripts selected, but Luciole displays at most $MAX_SCRIPTS."
        _error "Select fewer groups (see --list) or pass --force to install anyway."
        _error "With --force, Luciole may expose only an arbitrary subset of the files."
        return 1
    fi

    if [[ "$OPT_DRY_RUN" != "true" ]]; then
        if [[ "$OPT_SKIP_DEPS" != "true" ]]; then
            _check_dependencies
            if [[ "$OPT_INSTALL_DEPS" == "true" ]]; then
                _install_dependencies || _warn "Dependency installation failed."
            fi
        fi

        if [[ "$OPT_YES" != "true" && -t 0 ]]; then
            if [[ "$MODE" == "categories" ]]; then
                printf "\nInstall %d category menu(s) with %d action(s) into %s? [Y/n] " \
                    "${#SELECTED_CATEGORIES[@]}" "$count" "$SCRIPTS_DIR"
            else
                printf "\nInstall %d script(s) into %s? [Y/n] " \
                    "$count" "$SCRIPTS_DIR"
            fi
            read -r answer || answer="n"
            case "$answer" in
            "" | "y" | "Y" | "yes" | "YES") ;;
            *)
                _info "Cancelled."
                return 0
                ;;
            esac
        fi
    fi

    if [[ "$MODE" == "categories" ]]; then
        _install_categories
    else
        _install_flat
    fi
}

_main "$@"
