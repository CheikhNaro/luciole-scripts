#!/usr/bin/env bash
# =============================================================================
# Project: Luciole Scripts
# Based on: Enhanced File Manager Actions (cfgnunes/nautilus-scripts)
# License: MIT License
# =============================================================================
#
# Hidden category menu used by the launchers generated in the Luciole scripts
# folder. Luciole only scans the first level of that folder and displays at
# most 64 entries, so the actions themselves are stored in the hidden folder
# '.luciole-actions' and exposed through one launcher per category.
#
# For categories with subfolders, the menu first asks which upstream folder to
# open, then lists the actions of that folder. An "Actions" entry opens the
# complete category list. This mirrors the Nautilus folder hierarchy.
#
# Usage:
#   menu.sh CATEGORY [SELECTED_PATHS...]
#   menu.sh --list CATEGORY
#   menu.sh --run CATEGORY ACTION [SELECTED_PATHS...]
#
# The '--list' and '--run' forms are internal helpers used for diagnostics
# and tests; the launchers always use the first form.

set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)
I18N_DIR="$ROOT_DIR/.po"

declare -A I18N_DATA=()

_i18n_load_file() {
    local po_file=$1
    local key=""
    local val=""
    local line=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
        "msgid"*)
            key="${line#msgid }"
            key="${key%\"}"
            key="${key#\"}"
            ;;
        "msgstr"*)
            val="${line#msgstr }"
            val="${val%\"}"
            val="${val#\"}"
            ;;
        "")
            if [[ -n "$key" && -n "$val" ]]; then
                I18N_DATA["$key"]="$val"
                key=""
                val=""
            fi
            ;;
        esac
    done <"$po_file"
}

_i18n_initialize() {
    local lang="${LANG:-${LC_ALL:-}}"
    local lang_full=""
    local lang_base=""
    local po_file=""

    [[ -z "$lang" ]] && return
    lang_full="${lang%%.*}"
    lang_base="${lang_full%%_*}"

    po_file="$I18N_DIR/$lang_full.po"
    if [[ -f "$po_file" ]]; then
        _i18n_load_file "$po_file"
        return
    fi

    po_file="$I18N_DIR/$lang_base.po"
    if [[ -f "$po_file" ]]; then
        _i18n_load_file "$po_file"
    fi
}

_i18n() {
    local msgid=$1
    if [[ -n "${I18N_DATA[$msgid]:-}" ]]; then
        printf "%s" "${I18N_DATA[$msgid]}"
    else
        case "$msgid" in
        "Back")
            [[ "${LANG:-}" =~ ^fr ]] && printf "Retour" || printf "Back"
            ;;
        "Categories")
            [[ "${LANG:-}" =~ ^fr ]] && printf "Catégories" || printf "Categories"
            ;;
        "Category")
            [[ "${LANG:-}" =~ ^fr ]] && printf "Catégorie" || printf "Category"
            ;;
        *)
            printf "%s" "$msgid"
            ;;
        esac
    fi
}

_i18n_initialize

_mode="menu"
case "${1:-}" in
"--list")
    _mode="list"
    shift
    ;;
"--run")
    _mode="run"
    shift
    ;;
esac

_category="${1:-}"
if [[ -z "$_category" ]]; then
    printf "No category specified.\n" >&2
    exit 2
fi
shift

_category_dir="$SCRIPT_DIR/$_category"
if [[ ! -d "$_category_dir" ]]; then
    printf "Unknown category: %s\n" "$_category" >&2
    exit 2
fi

_category_display=$(_i18n "$_category")

_action_display_name() {
    local name=$1
    if [[ "$name" =~ ^[0-9][0-9]\  ]]; then
        name=${name:3}
    fi
    _i18n "$name"
}

_folder_display_name() {
    local folder=$1
    local -a parts=()
    local -a translated=()
    local part=""
    local result=""

    [[ -z "$folder" || "$folder" == "." ]] && return 0

    IFS='/' read -r -a parts <<<"$folder"
    for part in "${parts[@]}"; do
        translated+=("$(_i18n "$part")")
    done

    for part in "${translated[@]}"; do
        if [[ -z "$result" ]]; then
            result="$part"
        else
            result+=" > $part"
        fi
    done
    printf "%s" "$result"
}

_run_action() {
    local target=$1
    shift

    case "$target" in
    "$_category_dir"/*) ;;
    *)
        printf "Invalid action path: %s\n" "$target" >&2
        return 1
        ;;
    esac

    if [[ ! -f "$target" ]]; then
        printf "Action not found: %s\n" "$target" >&2
        return 1
    fi

    if [[ ! -x "$target" ]]; then
        printf "Action is not executable: %s\n" "$target" >&2
        return 1
    fi

    exec "$target" "$@"
}

if [[ "$_mode" == "run" ]]; then
    target="${1:-}"
    shift || true
    _run_action "$target" "$@"
    exit $?
fi

declare -a ROW_FOLDER=()
declare -a ROW_DISPLAY=()
declare -a ROW_PATH=()

_collect_rows() {
    local root=$1
    local show_folder=$2
    local file=""
    local rel=""
    local folder=""
    local base=""

    ROW_FOLDER=()
    ROW_DISPLAY=()
    ROW_PATH=()

    while IFS= read -r -d '' file; do
        [[ -f "$file" ]] || continue
        [[ -x "$file" ]] || continue

        rel=${file#"$_category_dir"/}
        folder=$(dirname -- "$rel")
        [[ "$folder" == "." ]] && folder=""
        [[ "$show_folder" != "true" ]] && folder=""
        base=$(basename -- "$file")

        ROW_FOLDER+=("$(_folder_display_name "$folder")")
        ROW_DISPLAY+=("$(_action_display_name "$base")")
        ROW_PATH+=("$file")
    done < <(find "$root" -name '.*' -prune -o -type f -print0 2>/dev/null |
        LC_ALL=C sort -z)
}

_get_dialog_bin() {
    if [[ -x "$SCRIPT_DIR/luciole-dialog" ]]; then
        printf "%s" "$SCRIPT_DIR/luciole-dialog"
    elif [[ -x "$ROOT_DIR/.dialog/luciole-dialog" ]]; then
        printf "%s" "$ROOT_DIR/.dialog/luciole-dialog"
    elif command -v "luciole-dialog" &>/dev/null; then
        command -v "luciole-dialog"
    fi
}

_choose_category() {
    local cat_dir=""
    local cat_name=""
    local cat_display=""
    local count=0
    local dialog_bin=""
    local user_selection=""
    local -a items=()

    while IFS= read -r -d '' cat_dir; do
        cat_name=$(basename -- "$cat_dir")
        cat_display=$(_i18n "$cat_name")
        count=$(find "$cat_dir" -name '.*' -prune -o -type f -printf '.' 2>/dev/null | wc -c)
        count=${count//[[:space:]]/}
        items+=("$cat_display ($count)"$'\t'""$'\t'"$cat_name")
    done < <(find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 2>/dev/null | LC_ALL=C sort -z)

    ((${#items[@]} == 0)) && return 1

    dialog_bin=$(_get_dialog_bin)
    if [[ -n "$dialog_bin" ]]; then
        user_selection=$(printf "%s\n" "${items[@]}" | "$dialog_bin" --title "$(_i18n 'Categories')" --width 450 --height 490 2>/dev/null) || return 1
    elif command -v "zenity" &>/dev/null; then
        local -a dialog=(--title "$(_i18n 'Categories')" --list --no-markup --width=450 --height=490)
        dialog+=(--column "$(_i18n 'Category')" --column "Name" --hide-column=2 --print-column=2)
        for cat_dir in "${items[@]}"; do
            local disp="" val=""
            disp="${cat_dir%%$'\t'*}"
            val="${cat_dir##*$'\t'}"
            dialog+=("$disp" "$val")
        done
        user_selection=$(GDK_BACKEND=x11 zenity "${dialog[@]}" --ok-label "$(_i18n 'OK')" --cancel-label "$(_i18n 'Cancel')" 2>/dev/null) || return 1
    elif command -v "yad" &>/dev/null; then
        local -a dialog=(--title "$(_i18n 'Categories')" --list --no-markup --width=450 --height=490)
        dialog+=(--column "$(_i18n 'Category')" --column "Name" --hide-column=2 --print-column=2)
        for cat_dir in "${items[@]}"; do
            local disp="" val=""
            disp="${cat_dir%%$'\t'*}"
            val="${cat_dir##*$'\t'}"
            dialog+=("$disp" "$val")
        done
        user_selection=$(GDK_BACKEND=x11 yad "${dialog[@]}" --button="$(_i18n 'Cancel'):1" --button="$(_i18n 'OK'):0" 2>/dev/null) || return 1
        user_selection=${user_selection%|}
    else
        printf "A dialog tool is required: luciole-dialog, zenity, or yad.\n" >&2
        return 1
    fi

    user_selection=${user_selection%$'\n'}
    [[ -z "$user_selection" ]] && return 1
    printf "%s" "$user_selection"
    return 0
}

_show_action_dialog() {
    local title=$1
    local has_back=${2:-false}
    local i=0
    local user_selection=""
    local dialog_bin=""
    local -a items=()

    if [[ "$has_back" == "true" ]]; then
        items+=("← $(_i18n 'Back')"$'\t'""$'\t'"__BACK__")
    else
        items+=("← $(_i18n 'Categories')"$'\t'""$'\t'"__ALL_CATEGORIES__")
    fi

    for i in "${!ROW_PATH[@]}"; do
        if [[ -n "${ROW_FOLDER[$i]}" ]]; then
            items+=("${ROW_DISPLAY[$i]}"$'\t'"${ROW_FOLDER[$i]}"$'\t'"${ROW_PATH[$i]}")
        else
            items+=("${ROW_DISPLAY[$i]}"$'\t'""$'\t'"${ROW_PATH[$i]}")
        fi
    done

    dialog_bin=$(_get_dialog_bin)
    if [[ -n "$dialog_bin" ]]; then
        user_selection=$(printf "%s\n" "${items[@]}" | "$dialog_bin" --title "$title" --width 450 --height 490 2>/dev/null) || return 1
    elif command -v "zenity" &>/dev/null; then
        local -a dialog=(--title "$title" --list --no-markup --width=450 --height=490)
        dialog+=(--column "Action" --column "$(_i18n 'Directory')" --column "Path" --hide-column=3 --print-column=3)
        if [[ "$has_back" == "true" ]]; then
            dialog+=("← $(_i18n 'Back')" "" "__BACK__")
        else
            dialog+=("← $(_i18n 'Categories')" "" "__ALL_CATEGORIES__")
        fi
        for i in "${!ROW_PATH[@]}"; do
            dialog+=("${ROW_DISPLAY[$i]}" "${ROW_FOLDER[$i]}" "${ROW_PATH[$i]}")
        done
        user_selection=$(GDK_BACKEND=x11 zenity "${dialog[@]}" --ok-label "$(_i18n 'OK')" --cancel-label "$(_i18n 'Cancel')" 2>/dev/null) || return 1
    elif command -v "yad" &>/dev/null; then
        local -a dialog=(--title "$title" --list --no-markup --width=450 --height=490)
        dialog+=(--column "Action" --column "$(_i18n 'Directory')" --column "Path" --hide-column=3 --print-column=3)
        if [[ "$has_back" == "true" ]]; then
            dialog+=("← $(_i18n 'Back')" "" "__BACK__")
        else
            dialog+=("← $(_i18n 'Categories')" "" "__ALL_CATEGORIES__")
        fi
        for i in "${!ROW_PATH[@]}"; do
            dialog+=("${ROW_DISPLAY[$i]}" "${ROW_FOLDER[$i]}" "${ROW_PATH[$i]}")
        done
        user_selection=$(GDK_BACKEND=x11 yad "${dialog[@]}" --button="$(_i18n 'Cancel'):1" --button="$(_i18n 'OK'):0" 2>/dev/null) || return 1
        user_selection=${user_selection%|}
    else
        printf "A dialog tool is required: luciole-dialog, zenity, or yad.\n" >&2
        return 1
    fi

    user_selection=${user_selection%$'\n'}
    [[ -z "$user_selection" ]] && return 1
    printf "%s" "$user_selection"
    return 0
}

_choose_subdir() {
    local dir=""
    local name=""
    local display=""
    local count=0
    local total=0
    local i=0
    local user_selection=""
    local dialog_bin=""
    local -a subdirs=()
    local -a labels=()
    local -a counts=()
    local -a items=()

    while IFS= read -r -d '' dir; do
        subdirs+=("$dir")
        name=$(basename -- "$dir")
        display=$(_i18n "$name")
        count=$(find "$dir" -name '.*' -prune -o -type f -printf '.' \
            2>/dev/null | wc -c)
        count=${count//[[:space:]]/}
        labels+=("$display")
        counts+=("$count")
        total=$((total + count))
    done < <(find "$_category_dir" -mindepth 1 -maxdepth 1 -type d \
        ! -name '.*' -print0 2>/dev/null | LC_ALL=C sort -z)

    ((${#subdirs[@]} == 0)) && return 1

    items+=("$(_i18n 'Actions') ($total)"$'\t'""$'\t'"__ALL__")
    for i in "${!subdirs[@]}"; do
        items+=("${labels[$i]} (${counts[$i]})"$'\t'""$'\t'"${subdirs[$i]}")
    done
    items+=("← $(_i18n 'Categories')"$'\t'""$'\t'"__ALL_CATEGORIES__")

    dialog_bin=$(_get_dialog_bin)
    if [[ -n "$dialog_bin" ]]; then
        user_selection=$(printf "%s\n" "${items[@]}" | "$dialog_bin" --title "$_category_display" --width 450 --height 490 2>/dev/null) || return 1
    elif command -v "zenity" &>/dev/null; then
        local -a dialog=(--title "$_category_display" --list --no-markup --width=450 --height=490)
        dialog+=(--column "$(_i18n 'Directory')" --column "Path" --hide-column=2 --print-column=2)
        dialog+=("$(_i18n 'Actions') ($total)" "__ALL__")
        for i in "${!subdirs[@]}"; do
            dialog+=("${labels[$i]} (${counts[$i]})" "${subdirs[$i]}")
        done
        dialog+=("← $(_i18n 'Categories')" "__ALL_CATEGORIES__")
        user_selection=$(GDK_BACKEND=x11 zenity "${dialog[@]}" --ok-label "$(_i18n 'OK')" --cancel-label "$(_i18n 'Cancel')" 2>/dev/null) || return 1
    elif command -v "yad" &>/dev/null; then
        local -a dialog=(--title "$_category_display" --list --no-markup --width=450 --height=490)
        dialog+=(--column "$(_i18n 'Directory')" --column "Path" --hide-column=2 --print-column=2)
        dialog+=("$(_i18n 'Actions') ($total)" "__ALL__")
        for i in "${!subdirs[@]}"; do
            dialog+=("${labels[$i]} (${counts[$i]})" "${subdirs[$i]}")
        done
        dialog+=("← $(_i18n 'Categories')" "__ALL_CATEGORIES__")
        user_selection=$(GDK_BACKEND=x11 yad "${dialog[@]}" --button="$(_i18n 'Cancel'):1" --button="$(_i18n 'OK'):0" 2>/dev/null) || return 1
        user_selection=${user_selection%|}
    else
        printf "A dialog tool is required: luciole-dialog, zenity, or yad.\n" >&2
        return 1
    fi

    user_selection=${user_selection%$'\n'}
    [[ -z "$user_selection" ]] && return 1
    printf "%s" "$user_selection"
    return 0
}

if [[ "$_mode" == "list" ]]; then
    _collect_rows "$_category_dir" "true"
    for row_index in "${!ROW_PATH[@]}"; do
        printf "%s\t%s\t%s\n" \
            "${ROW_FOLDER[$row_index]}" \
            "${ROW_DISPLAY[$row_index]}" \
            "${ROW_PATH[$row_index]}"
    done
    exit 0
fi

while true; do
    _category_dir="$SCRIPT_DIR/$_category"
    _category_display=$(_i18n "$_category")

    subdir_count=$(find "$_category_dir" -mindepth 1 -maxdepth 1 -type d \
        ! -name '.*' -printf '.' 2>/dev/null | wc -c)
    subdir_count=${subdir_count//[[:space:]]/}
    direct_count=$(find "$_category_dir" -mindepth 1 -maxdepth 1 -type f \
        ! -name '.*' -printf '.' 2>/dev/null | wc -c)
    direct_count=${direct_count//[[:space:]]/}

    if ((subdir_count > 1)) ||
        { ((subdir_count == 1)) && ((direct_count > 0)); }; then
        while true; do
            choice=$(_choose_subdir)
            status=$?
            if [[ $status -ne 0 || -z "$choice" ]]; then
                exit 0
            fi

            if [[ "$choice" == "__ALL_CATEGORIES__" ]]; then
                new_cat=$(_choose_category) || continue
                [[ -n "$new_cat" ]] && _category="$new_cat"
                break
            fi

            if [[ "$choice" == "__ALL__" ]]; then
                _collect_rows "$_category_dir" "true"
                title="$_category_display (${#ROW_PATH[@]})"
            else
                _collect_rows "$choice" "false"
                title="$(_i18n "$(basename -- "$choice")") (${#ROW_PATH[@]})"
            fi

            selected=$(_show_action_dialog "$title" "true")
            status=$?
            if [[ $status -ne 0 || "$selected" == "__BACK__" || -z "$selected" ]]; then
                continue
            fi

            _run_action "$selected" "$@"
            exit $?
        done
    else
        if ((subdir_count == 1)); then
            choice=$(find "$_category_dir" -mindepth 1 -maxdepth 1 -type d \
                ! -name '.*' -print -quit 2>/dev/null)
            _collect_rows "$choice" "false"
            title="$(_i18n "$(basename -- "$choice")") (${#ROW_PATH[@]})"
        else
            _collect_rows "$_category_dir" "false"
            title="$_category_display (${#ROW_PATH[@]})"
        fi

        selected=$(_show_action_dialog "$title" "false")
        status=$?
        if [[ $status -ne 0 || -z "$selected" ]]; then
            exit 0
        fi

        if [[ "$selected" == "__ALL_CATEGORIES__" ]]; then
            new_cat=$(_choose_category) || continue
            [[ -n "$new_cat" ]] && _category="$new_cat"
            continue
        fi

        _run_action "$selected" "$@"
        exit $?
    fi
done
