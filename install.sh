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
# and displays at most 64 scripts. This installer therefore installs a chosen
# set of action groups, never more than 64 scripts unless --force is used.

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

Options:
  -h, --help              Show this help.
  -l, --list              List the available groups and their script counts.
  -a, --all               Select every group (requires --force above $MAX_SCRIPTS).
  -r, --recommended       Select the default set of groups (under $MAX_SCRIPTS).
  -g, --group PATH        Select one group (repeatable). PATH is an id from --list.
  -c, --category NAME     Select all groups of a top-level category (repeatable).
  -x, --exclude GROUP     Exclude a group id from the selection (repeatable).
      --lang CODE         Name language: auto (default), en, or a .po code (e.g. fr).
      --dry-run           Show what would be installed, change nothing.
  -f, --force             Allow more than $MAX_SCRIPTS scripts.
      --install-deps      Try to install the missing basic dependencies.
      --no-deps           Skip the dependency check.
  -y, --yes               Do not ask for confirmation.

Without a selection option, an interactive menu is shown.

Luciole displays at most $MAX_SCRIPTS scripts. Installing more is not useful:
the menu silently exposes only the first entries it collects. Prefer several
smaller groups, or rerun this installer with another selection.

Destination:
  $SCRIPTS_DIR
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
    rm -f -- "$MANIFEST"
}

_install_files() {
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

    if [[ "$OPT_DRY_RUN" == "true" ]]; then
        printf "%sWould install %d script(s) into:%s\n" "$C_BOLD" "$total" "$C_RESET"
        printf "  %s\n\n" "$SCRIPTS_DIR"
        for i in "${!installed_names[@]}"; do
            printf "  %s\n      <- %s\n" "${installed_names[$i]}" "${sources[$i]}"
        done
        return 0
    fi

    mkdir -p -- "$INSTALL_ROOT" "$SCRIPTS_DIR"
    chmod u+rwx,go-w -- "$INSTALL_ROOT" "$SCRIPTS_DIR"

    _clean_previous_install

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

    for i in "${!installed_names[@]}"; do
        install -m 0755 -- "${sources[$i]}" \
            "$SCRIPTS_DIR/${installed_names[$i]}"
    done

    # Hidden manifest used by the uninstaller and by the next installation.
    if ((${#installed_names[@]} > 0)); then
        printf "%s\n" "${installed_names[@]}" >"$MANIFEST"
        chmod 0644 -- "$MANIFEST"
    fi

    _info "Installed $total script(s) into $SCRIPTS_DIR"
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
        -a | --all)
            OPT_ALL="true"
            ;;
        -r | --recommended)
            OPT_RECOMMENDED="true"
            ;;
        -g | --group)
            if (($# < 2)); then
                _error "$arg requires a value."
                return 2
            fi
            value=$2
            shift
            SELECT_GROUPS+=("$value")
            ;;
        -c | --category)
            if (($# < 2)); then
                _error "$arg requires a value."
                return 2
            fi
            value=$2
            shift
            SELECT_CATEGORIES+=("$value")
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

    if ((${#GROUP_IDS[@]} == 0)); then
        _error "No action found in $SCRIPT_DIR."
        return 1
    fi

    if [[ "$OPT_LIST" == "true" ]]; then
        _print_groups
        local rec_count=0
        local rec_id=""
        for rec_id in "${RECOMMENDED_GROUPS[@]}"; do
            if n=$(_group_index "$rec_id"); then
                rec_count=$((rec_count + GROUP_COUNTS[n]))
            fi
        done
        printf "\nDefault selection (%d scripts): %s\n" \
            "$rec_count" "${RECOMMENDED_GROUPS[*]}"
        return 0
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

    for value in "${EXCLUDE_GROUPS[@]}"; do
        if n=$(_group_index "$value"); then
            SELECTED[$n]="false"
        else
            _warn "Unknown excluded group: $value"
        fi
    done

    # No explicit selection: interactive menu when possible.
    if [[ "$OPT_ALL" != "true" && "$OPT_RECOMMENDED" != "true" &&
        ${#SELECT_GROUPS[@]} -eq 0 && ${#SELECT_CATEGORIES[@]} -eq 0 ]]; then
        if [[ -t 0 && "$OPT_YES" != "true" ]]; then
            _interactive_select || return 1
        else
            _error "No group selected. Use --list, --group, --category, or --all."
            return 2
        fi
    fi

    count=0
    for i in "${!GROUP_IDS[@]}"; do
        [[ "${SELECTED[$i]}" == "true" ]] &&
            count=$((count + GROUP_COUNTS[i]))
    done

    if ((count == 0)); then
        _warn "Nothing selected."
        return 0
    fi

    if ((count > MAX_SCRIPTS)) && [[ "$OPT_FORCE" != "true" ]]; then
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
            printf "\nInstall %d script(s) into %s? [Y/n] " "$count" "$SCRIPTS_DIR"
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

    _install_files
}

_main "$@"
