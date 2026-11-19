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

## Why an installer?

Luciole custom actions have a few strict rules:

- They live in `${XDG_DATA_HOME:-$HOME/.local/share}/luciole/scripts/`.
- Only the **first level** of that folder is scanned: nested folders are
  ignored.
- Hidden files, non-executable files and `.desktop` launchers are excluded.
- The menu displays **at most 64 scripts**.
- A script must have an interpreter line and must not be writable by group or
  others.

The upstream project contains 290 actions organised in category folders, which
Luciole cannot display as-is. This repository keeps the upstream category tree
as the source of truth, and `install.sh` flattens a **selected set** into the
Luciole scripts folder. The installer refuses to install more than 64 scripts
unless `--force` is used, because Luciole would silently expose only an
arbitrary subset.

## Requirements

Required:

- Luciole
- `bash`, coreutils, findutils, `grep`, `sed`
- `zenity` **or** `yad` for the dialogs. Luciole starts scripts without a
  terminal, so actions that need input have no other way to ask.

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

Without arguments, `install.sh` shows an interactive list of groups.

The default non-interactive selection installs 62 everyday actions:

```sh
./install.sh --recommended
```

After installation, reopen **Scripts** in Luciole (or restart Luciole) to
refresh the menu.

### Selecting groups

List every group with its id and script count:

```sh
./install.sh --list
```

Install specific groups:

```sh
./install.sh --group "Archive" --group "Checksum"
./install.sh --group "Image/Image: Convert"
./install.sh --group "Document/PDF: Tools"
```

Install a whole top-level category when it fits under the limit:

```sh
./install.sh --category "Audio and Video"   # 59 scripts
```

Exclude a group from a selection:

```sh
./install.sh --recommended --exclude "Checksum"
```

### Options

```text
-h, --help              Show help.
-l, --list              List groups, counts and group ids.
-a, --all               Select every group (requires --force above 64).
-r, --recommended       Select the default set (62 scripts).
-g, --group PATH        Select one group (repeatable).
-c, --category NAME     Select every group of a top-level category (repeatable).
-x, --exclude GROUP     Exclude a group id (repeatable).
    --lang CODE         Name language: auto (default), en, or a .po code.
    --dry-run           Show what would be installed, change nothing.
-f, --force             Allow more than 64 scripts.
    --install-deps      Try to install the missing basic dependencies.
    --no-deps           Skip the dependency check.
-y, --yes               Do not ask for confirmation.
```

The destination is always:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/luciole/scripts/
```

### Categories

| Category                | Scripts |
| ----------------------- | ------: |
| Archive                 |       8 |
| Audio and Video         |      59 |
| Checksum                |      13 |
| Clipboard               |       6 |
| Directories and Files   |      15 |
| Document                |      65 |
| Encryption              |      12 |
| Image                   |      76 |
| Links                   |       9 |
| Network and Internet    |       7 |
| Open with               |       4 |
| Rename files            |      11 |
| Security and Backup     |       5 |
| **Total**               | **290** |

`Document` and `Image` exceed the 64-script limit on their own. Select their
sub-groups individually (for example `Document/PDF: Tools`).

## The 64-script limit

Luciole reads the scripts folder in filesystem order and stops after collecting
64 entries, then sorts them for display. Installing more than 64 scripts is
therefore not only useless, it can make some actions disappear unpredictably.

Use `--list` to build a selection that fits. If you need another set of
actions, run `install.sh` again: the previous selection is replaced
automatically using a hidden installation manifest, so no stale action is left
behind. Your own scripts are never listed in that manifest and are preserved.

## How actions receive files

Luciole passes the selected native paths as separate positional arguments and
sets the working directory to the folder of the originating pane. Running an
action from the background menu supplies no arguments; actions then use the
current folder or ask you to select files/directories.

The shared helper is installed as the hidden file `.common-functions.sh` next to
the actions. Luciole ignores hidden files. The `.po` translation files are
installed in a hidden `.po` folder, which Luciole does not scan.

## Custom action names and language

Installed file names are generated as:

```text
<Category> - <Action>
```

Names are translated using the project `.po` files when a matching locale is
found (`LANG`). For example, with `LANG=fr_FR.UTF-8`:

```text
Archive - Extraire ici
Somme de contrôle - Calculer SHA256
```

Use `--lang en` to force English names, or `--lang fr` to force French names
regardless of the current locale.

## Updating

```sh
git pull
./install.sh --recommended     # or your usual selection
```

The installer replaces the previous selection and refreshes the shared helper
and translations.

## Uninstalling

Remove only the scripts installed by this project:

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

## Notes and limitations

- Nested folders in the scripts directory are not scanned.
- Custom scripts currently require a native browse folder and native selected
  items outside Trash.
- A launch accepts at most 4096 selected paths and 1 MiB of path arguments.
- Actions that need a terminal require `xdg-terminal-exec` and a suitable
  installed terminal.
- Icons declared in upstream comments (`install_icon_kde=...`) are not used by
  Luciole.

## Credits and license

This project is based on
[cfgnunes/nautilus-scripts](https://github.com/cfgnunes/nautilus-scripts),
Copyright (c) 2020 Cristiano Fraga G. Nunes, released under the MIT License.

The Luciole-specific installer, flat-menu adaptation and documentation are
distributed under the same MIT License. See [LICENSE.txt](LICENSE.txt).
