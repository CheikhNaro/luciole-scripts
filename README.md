# Luciole Scripts

Custom actions for the [Luciole](https://github.com/noctalia-dev/luciole) file manager, adapted from [nautilus-scripts](https://github.com/cfgnunes/nautilus-scripts).

**290 actions** in **13 categories** (Archive, Audio & Video, Checksum, Clipboard, Files, Document, Encryption, Image, Links, Network, Open with, Rename, Security).


## DEMO

https://github.com/user-attachments/assets/f2b56156-21d1-4b29-80f7-5a4443038cd7


## How it works

Luciole only scans the first level of the scripts folder and caps the display at **64 entries**. The installer works around this with a two-level design:

- **13 visible category launchers** in the scripts folder.
- **290 real actions** hidden in `.luciole-actions/` (Luciole ignores hidden names).

Clicking a launcher opens a **native Wayland dialog** (no GTK, no Qt) listing the actions of that category. The dialog follows Noctalia theme colors automatically.

## Install

```sh
git clone https://github.com/CheikhNaro/luciole-scripts.git
cd luciole-scripts
./install.sh          # all 13 categories
./install.sh --recommended   # curated set (62 actions)
```

Then reopen **Scripts** in Luciole (or restart it).

### Options

```text
-l, --list              List categories and groups.
-r, --recommended       Install the default curated set.
-c, --category NAME     Install one category (repeatable).
-g, --group PATH        Install one group (repeatable).
-x, --exclude NAME      Exclude a category or group (repeatable).
-m, --mode flat         Install actions directly (no category menus, max 64).
    --lang CODE         Force language: en, fr, or auto (default).
    --dry-run           Preview without installing.
-y, --yes               Skip confirmation.
```

## Uninstall

```sh
./uninstall.sh          # remove only what was installed
./uninstall.sh --purge  # remove the entire scripts folder
```

## Requirements

- **Luciole**
- `bash`, coreutils, `grep`, `sed`
- `zenity` or `yad` as fallback if the native dialog fails to build

Each action checks its own dependencies (FFmpeg, ImageMagick, Poppler, etc.) at runtime.

## Add your own action

Drop an executable script (with a `#!/…` shebang, not writable by group/others, no leading dot) into `~/.local/share/luciole/scripts/`. It will appear next to the category launchers and is never touched by reinstall/uninstall.

## Credits

Based on [cfgnunes/nautilus-scripts](https://github.com/cfgnunes/nautilus-scripts) — MIT License.
