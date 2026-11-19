#!/usr/bin/env bash
# =============================================================================
# Project: Luciole Scripts
# Based on: Enhanced File Manager Actions (cfgnunes/nautilus-scripts)
# License: MIT License
# =============================================================================

set -u

HOME=${HOME:-$(eval echo ~)}

_get_data_home() {
    local dir="${XDG_DATA_HOME:-}"
    if [[ -z "$dir" || "$dir" != /* ]]; then
        dir="$HOME/.local/share"
    fi
    printf "%s" "${dir%/}"
}

INSTALL_ROOT="$(_get_data_home)/luciole"
SCRIPTS_DIR="$INSTALL_ROOT/scripts"
MANIFEST="$SCRIPTS_DIR/.luciole-scripts-manifest"

OPT_PURGE="false"
OPT_YES="false"

_usage() {
    cat <<EOF
Luciole Scripts - uninstaller

Usage:
  $0 [options]

Options:
  -h, --help    Show this help.
  -p, --purge   Remove the whole scripts folder, including scripts that were
                not installed by this project. Asks for confirmation.
  -y, --yes     Do not ask for confirmation.

By default, only the entries listed in the installation manifest and the
shared helper files (including the hidden category menu folder) are removed.
Other scripts are left untouched.
EOF
}

while (($# > 0)); do
    case "$1" in
    -h | --help)
        _usage
        exit 0
        ;;
    -p | --purge) OPT_PURGE="true" ;;
    -y | --yes) OPT_YES="true" ;;
    *)
        echo "Unknown option: $1" >&2
        exit 2
        ;;
    esac
    shift
done

if [[ ! -d "$SCRIPTS_DIR" ]]; then
    echo "Nothing to remove: $SCRIPTS_DIR does not exist."
    exit 0
fi

if [[ "$OPT_YES" != "true" ]]; then
    if [[ "$OPT_PURGE" == "true" ]]; then
        printf "Remove %s entirely, including scripts not installed by this project? [y/N] " \
            "$SCRIPTS_DIR"
    else
        printf "Remove the scripts installed by Luciole Scripts from %s? [y/N] " \
            "$SCRIPTS_DIR"
    fi
    read -r answer || answer="n"
    case "$answer" in
    "y" | "Y" | "yes" | "YES") ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
    esac
fi

if [[ "$OPT_PURGE" == "true" ]]; then
    rm -rf -- "$SCRIPTS_DIR"
    rmdir -- "$INSTALL_ROOT" 2>/dev/null
    echo "Removed $SCRIPTS_DIR"
    exit 0
fi

removed=0
if [[ -f "$MANIFEST" ]]; then
    while IFS= read -r name || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" == */* ]] && continue
        if [[ -e "$SCRIPTS_DIR/$name" ]]; then
            rm -f -- "$SCRIPTS_DIR/$name" && removed=$((removed + 1))
        fi
    done <"$MANIFEST"
fi

rm -f -- "$SCRIPTS_DIR/.common-functions.sh"
rm -f -- "$SCRIPTS_DIR/.pkg-map.sh"
rm -rf -- "$SCRIPTS_DIR/.po"
rm -rf -- "$SCRIPTS_DIR/.luciole-actions"
rm -f -- "$MANIFEST"

if rmdir -- "$SCRIPTS_DIR" 2>/dev/null; then
    rmdir -- "$INSTALL_ROOT" 2>/dev/null
fi

echo "Removed $removed installed item(s) from $SCRIPTS_DIR"
