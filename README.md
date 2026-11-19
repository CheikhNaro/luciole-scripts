# Luciole Scripts

A collection of custom actions for the [Luciole](https://github.com/noctalia-dev/luciole)
file manager, adapted from
[Enhanced File Manager Actions](https://github.com/cfgnunes/nautilus-scripts)
by Cristiano Fraga G. Nunes.

The actions cover archives, audio and video, checksums, clipboard, files and
directories, documents and PDFs, encryption, images, links, network tools,
renaming and security/backup tasks. They use the same interface as the upstream
project: dialog boxes, parallel processing, progress display, optional
Bubblewrap sandboxing and per-action dependency checks.

Unlike a flat list, the default installation keeps the upstream **category and
subfolder organisation**. Each category becomes one entry in the Luciole
**Scripts** menu, and choosing it opens a second dialog with the actions of
that category, grouped by their original subfolder. This is the closest
equivalent to the Nautilus folder layout that Luciole can provide.

## Why an installer?

Luciole custom actions have a few strict rules:

- They live in `${XDG_DATA_HOME:-$HOME/.local/share}/luciole/scripts/`.
- Only the **first level** of that folder is scanned: nested folders are
  ignored.
- Hidden files, non-executable files and `.desktop` launchers are excluded.
- The menu displays **at most 64 scripts**.
- A script must have an interpreter line and must not be writable by group or
  others.

The upstream project contains **290 actions** in 13 categories, which Luciole
cannot display as-is. The installer therefore uses a two-level design:

1. It installs one small visible launcher per category in the Luciole scripts
   folder. That is only **13 entries**, well below the limit.
2. It stores the real actions in the hidden folder `.luciole-actions/`. Luciole
   ignores hidden names, so the actions are invisible to its scanner but fully
   available to the launchers.

Choosing a category launcher opens its actions. Categories with upstream
subfolders first show a folder picker (plus an `Actions` entry for the complete
list), then the actions of the chosen folder. Categories without subfolders
show their actions directly. This mirrors the Nautilus folder hierarchy.
The chosen action runs with the paths Luciole passed to the launcher, exactly
as if it had been clicked directly.

A flat mode is still available for users who prefer the old behaviour. It
installs the selected actions directly in the scripts folder and enforces the
64-script limit.

## Requirements

Required:

- Luciole
- `bash`, coreutils, findutils, `grep`, `sed`
- `zenity` **or** `yad` for the dialogs. This is needed twice: by the category
  launcher to show the action list, and by the actions themselves to ask for
  input. Luciole starts scripts without a terminal, so there is no other way to
  interact.

Recommended:

- `bubblewrap` for the optional command sandbox
- `file`, `psmisc` (`pstree`), `procps` (`pgrep`), `xdg-utils` (`xdg-open`)

Each action also checks the tools it needs at runtime (FFmpeg, ImageMagick,
Poppler, OCR, archive tools, etc.) and offers to install what is missing.

## Installation

```sh
git clone https://github.com/CheikhNaro/luciole-scripts.git
cd luciole-scripts
./install.sh
```

Without arguments, `install.sh` shows the list of categories and installs
**all categories** by default. The result is 13 category menus containing all
290 actions.

Install a smaller everyday set (62 actions in 7 category menus):

```sh
./install.sh --recommended
```

After installation, reopen **Scripts** in Luciole (or restart Luciole) to
refresh the menu.

### Selecting categories

List categories, groups and counts:

```sh
./install.sh --list
```

Pick categories by number in the interactive prompt:

```text
1 3 5-7
```

Select categories directly:

```sh
./install.sh --category "Image"
./install.sh --category "Archive" --category "Checksum"
```

Exclude a category or a group:

```sh
./install.sh --exclude "Image"                  # all Image groups
./install.sh --recommended --exclude "Checksum"
```

### Selecting actions

`--group` selects one upstream group. The matching category menu is created
and lists only the selected actions:

```sh
./install.sh --group "Archive" --group "Checksum"
./install.sh --group "Image/Image: Convert"
./install.sh --group "Document/PDF: Tools"
```

Group ids are printed by `./install.sh --list`.

### Flat mode

To install actions directly in the scripts folder, without category menus:

```sh
./install.sh --mode flat --recommended
./install.sh --mode flat --group "Archive"
```

Flat mode is limited to 64 visible scripts. The installer refuses to go above
that unless `--force` is used, because Luciole would silently expose only an
arbitrary subset of the files.

### Options

```text
-h, --help              Show help.
-l, --list              List categories, groups and counts.
-m, --mode MODE         Layout: categories (default) or flat.
-a, --all               Select every group (all 290 actions).
-r, --recommended       Select the default set (62 actions).
-g, --group PATH        Select one group (repeatable).
-c, --category NAME     Select every group of a top-level category (repeatable).
-x, --exclude NAME      Exclude a group id or a category (repeatable).
    --lang CODE         Name language: auto (default), en, or a .po code.
    --dry-run           Show what would be installed, change nothing.
-f, --force             Allow more than 64 scripts in flat mode, and overwrite
                        existing scripts that are not managed by this project.
    --install-deps      Try to install the missing basic dependencies.
    --no-deps           Skip the dependency check.
-y, --yes               Do not ask for confirmation.
```

The destination is always:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/luciole/scripts/
```

## Categories

| Category                | Actions | Groups |
| ----------------------- | ------: | -----: |
| Archive                 |       8 |      1 |
| Audio and Video         |      59 |     14 |
| Checksum                |      13 |      1 |
| Clipboard               |       6 |      1 |
| Directories and Files   |      15 |      1 |
| Document                |      65 |     13 |
| Encryption              |      12 |      1 |
| Image                   |      76 |     12 |
| Links                   |       9 |      1 |
| Network and Internet    |       7 |      1 |
| Open with               |       4 |      1 |
| Rename files            |      11 |      1 |
| Security and Backup     |       5 |      1 |
| **Total**               | **290** | **49** |

In categories mode, `Document` and `Image` are no longer a problem: they simply
get their own menu with all their actions. In flat mode they exceed the
64-script limit on their own, so select their sub-groups individually.

## How category menus work

Installed layout:

```text
scripts/
  Archive                         visible launcher -> .luciole-actions/menu.sh
  Audio et Vidéo                  visible launcher
  ...
  .common-functions.sh            shared helper (hidden, sourced by actions)
  .pkg-map.sh                     runtime dependency map (hidden)
  .po/                            translations (hidden)
  .luciole-actions/
    menu.sh                       category dialog implementation
    Archive/                      real actions, still executable
    Image/
      Image: Convert/
      Image: Color/
      ...
```

The launcher itself is tiny:

```sh
#!/usr/bin/env bash
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
exec "$SCRIPT_DIR/.luciole-actions/menu.sh" "Archive" "$@"
```

The menu dialog shows translated names. For a category with subfolders, the
first dialog asks which folder to open and offers an `Actions` entry that lists
the whole category with the translated subfolder in a second column. Choosing a
folder shows only its actions. The menu forwards the positional arguments
unchanged to the selected action. The action's working directory remains the
folder of the originating Luciole pane.

## The 64-script limit

Luciole reads the scripts folder in filesystem order and stops after collecting
64 entries, then sorts them for display. In flat mode, installing more than 64
scripts is not only useless, it can make some actions disappear unpredictably.

Categories mode avoids the problem entirely: only 13 launchers are visible, and
the 290 actions live in a hidden folder that Luciole never scans. The limit
applies to the visible launchers, not to the actions inside a category dialog.

If you change your selection, run `install.sh` again. The previous installation
is replaced automatically using a hidden manifest, so no stale launcher or
action is left behind. Your own scripts are never listed in that manifest and
are preserved. If a target name belongs to one of your scripts, the installer
stops and asks you to move it or to use `--force`.

## How actions receive files

Luciole passes the selected native paths as separate positional arguments and
sets the working directory to the folder of the originating pane. Running an
action from the background menu supplies no arguments; actions then use the
current folder or ask you to select files/directories.

In categories mode, the launcher forwards those arguments unchanged to the
chosen action, so actions behave exactly as in flat mode.

The shared helper is installed as the hidden file `.common-functions.sh` next to
the launchers. The `.po` translation files are installed in a hidden `.po`
folder. Luciole ignores both.

## Action names and language

In flat mode, installed file names are generated as:

```text
<Category> - <Action>
```

Names are translated using the project `.po` files when a matching locale is
found (`LANG`). For example, with `LANG=fr_FR.UTF-8`:

```text
Archive - Extraire ici
Somme de contrôle - Calculer SHA256
```

In categories mode, the visible launcher names are the translated category
names, and the dialog translates each action and subfolder at runtime. With a
French locale:

```text
Archive
Audio et Vidéo
Somme de contrôle
...
```

Use `--lang en` to force English launcher names at install time, or `--lang fr`
to force French names regardless of the current locale. The dialog still
follows the runtime `LANG` of the Luciole session.

## Updating

```sh
git pull
./install.sh                 # categories, interactive
# or
./install.sh --recommended   # your usual selection
```

The installer replaces the previous installation and refreshes the shared
helper, the category menu and the translations.

## Uninstalling

Remove only what this project installed (launchers, hidden category folder,
helper files and manifest):

```sh
./uninstall.sh
```

Remove the whole scripts folder, including scripts you added yourself:

```sh
./uninstall.sh --purge
```

Package dependencies installed at runtime are not removed.

## Adding your own action

Place an executable script in
`${XDG_DATA_HOME:-$HOME/.local/share}/luciole/scripts/`. It must:

- start with an interpreter line such as `#!/bin/sh` or `#!/usr/bin/env bash`;
- be executable;
- be owned by you or root and not writable by group or others;
- not start with a dot, and not be a `.desktop` launcher.

Luciole passes selected paths as separate arguments. Quote `"$@"` to preserve
names with spaces.

Your own scripts appear next to the category launchers and are not touched by
reinstall or uninstall, unless you use `--purge`.

## Notes and limitations

- Nested folders in the scripts directory are not scanned by Luciole. The
  installer works around this with the category launchers.
- Custom scripts currently require a native browse folder and native selected
  items outside Trash.
- A launch accepts at most 4096 selected paths and 1 MiB of path arguments.
- Actions that need a terminal require `xdg-terminal-exec` and a suitable
  installed terminal.
- Icons declared in upstream comments (`install_icon_kde=...`) are not used by
  Luciole.
- The upstream "Accessed recently" feature is disabled: it relied on a nested
  folder that Luciole cannot display.
- If neither `zenity` nor `yad` is installed, a category launcher cannot show
  its action list. Install one of them before using the scripts.

## Project layout

```text
Archive/                  Upstream action folders (source of truth).
Audio and Video/          One file per action; used to build the hidden store.
Checksum/
...
.common-functions.sh      Shared helper, adapted for Luciole.
.pkg-map.sh               Runtime dependency map used by the actions.
.po/                      Translation files (installed names and dialogs).
.category-menu.sh         Category dialog used by the installed launchers.
install.sh                Builds the visible launchers and the hidden store.
uninstall.sh              Removes the installed launchers and helpers.
```

## Credits and license

This project is based on
[cfgnunes/nautilus-scripts](https://github.com/cfgnunes/nautilus-scripts),
Copyright (c) 2020 Cristiano Fraga G. Nunes, released under the MIT License.

The Luciole-specific installer, category menu, flat-menu adaptation and
documentation are distributed under the same MIT License. See
[LICENSE.txt](LICENSE.txt).
