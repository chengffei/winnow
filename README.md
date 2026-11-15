# Winnow

A native macOS app for tidying up folders, including on network drives (SMB/NAS): duplicate files, empty folders, cluttered file names, needlessly nested folders, and files scattered across many folders.

Winnow is a Mac-style interface on top of the [czkawka](https://github.com/qarmin/czkawka) scanning engine. The engine is fast and thorough; Winnow adds a workflow that is safe and easy to follow.

> **Status: early (0.4).** Available in 8 languages. Requires macOS 14 or later on Apple silicon.

## Install

**One line in Terminal** (recommended):

```sh
curl -fsSL https://raw.githubusercontent.com/chengffei/winnow/main/install.sh | bash
```

The [script](install.sh) downloads the latest release, checks its SHA-256, code signature, bundle ID and developer team, and puts Winnow in Applications. Downloads made this way are not quarantined, so macOS opens Winnow without a warning.

**Or download the disk image**: [Winnow-0.4.0.dmg](https://github.com/chengffei/winnow/releases/download/v0.4.0/Winnow-0.4.0.dmg), then drag Winnow into Applications. Winnow is signed but not notarized, so macOS blocks the first launch: open it, close the warning, then click **Open Anyway** in *System Settings › Privacy & Security*.

To scan folders macOS protects (Desktop, Documents, other apps' data), give Winnow **Full Disk Access** in *System Settings › Privacy & Security*. Winnow lists every folder it could not read.

## Duplicate files and empty folders

1. **Choose where to look.** Add folders or drives, or drag them in. Mark a location as *compare only* and its files are used for matching but never marked for removal.
2. **Choose how to compare.** By content (byte-exact, safe to delete) or by size and name (for a first look; it reads no file contents and takes seconds even on a network drive). Optional conditions: minimum file size, file types (photos, videos, music, documents, archives) and subfolders to exclude.
3. **Watch the scan.** Each stage shows counts, speed and time left. Folders that could not be read are listed, not silently skipped.
4. **Review.** Groups are sorted by how much space they free. Every copy is either *keep* or *remove*, and each group always keeps at least one. Auto-marking rules: keep the oldest, the newest, the shortest path, or the copy in a folder you pick. Groups you edit by hand are never overwritten.
5. **Check, then act.** Nothing is removed until a final check re-reads each marked file and skips anything that changed since the scan. You can move files to a staging folder on the same drive (the default, undoable in one click), move them to the Trash (local drives only, since network drives have none), or delete them permanently.

## More tools

Each of these shows a preview first, changes only the rows you tick, and can undo its last batch.

- **Remove Text from Names.** Takes unwanted text, such as a site's tag, out of every file name that contains it. Several texts at once; the list is kept between launches. **Suggest** lists the texts many file names share, so you tick them instead of typing.
- **Nested Folders.** Finds folders that only wrap one folder or a few files, as download tools like to make, and moves what is inside out. The moved items can take the folder's name, and the emptied folder is removed: to the Trash, or deleted on a drive that has none. In a folder with several files, the main file is told from small leftovers by size: subtitles named after it follow it, and links, notes and promo clips go to the staging folder.
- **Find Files.** Reads the file names of the chosen locations once, then filters by name and type as you type (`.mkv` finds by extension). Ticked files move into one folder; a name already there gets a number, so nothing is replaced. Or set them aside in the staging folder.

In every list you can select several rows and tick them together, and show any row in Finder.

**Favorites.** Each page can save its locations and settings under a name. Favorites sit in the sidebar and put everything back with one click. Nothing is saved unless you ask.

## Languages

English, 简体中文, 繁體中文, 日本語, 한국어, Français, Deutsch, Español.

Winnow follows your system language. To pick another, open **Winnow › Settings › General** (⌘,) and restart Winnow, or set it in *System Settings › General › Language & Region › Applications*.

## Settings

- **Language**: follow the system, or choose one of the eight.
- **Processor use**: all cores, half, or one, so long scans leave the Mac responsive.
- **Hash cache**: remember fingerprints of unchanged files between scans, or clear the cache.
- **Always skip**: names (`node_modules`) or wildcard patterns (`*.tmp`) skipped in every scan.

## Building

```sh
scripts/bundle.sh --open        # builds build/Winnow.app and opens it
swift test                      # needs Xcode's toolchain: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

`scripts/bundle.sh` downloads the pinned czkawka_cli release (12.0.2) into `ThirdParty/` and puts it inside the app.

## How it works

Winnow runs `czkawka_cli` as a separate program, under a pseudo-terminal so its progress output can be read, and loads the JSON results. All marking, safety checks and file operations are Winnow's own code in `Sources/WinnowCore`.

## Translations

All interface text is in [Localization/Translations.json](Localization/Translations.json), keyed by the English text. `scripts/build-strings.py --check` reports missing translations and mismatched placeholders. Corrections from native speakers are welcome.

## License

Winnow is licensed under the [GPL-3.0](LICENSE). Contributions require agreeing to the [CLA](CLA.md), which a bot asks for on your first pull request.

The bundled `czkawka_cli` is MIT-licensed and statically includes libraries under other licenses; see [ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt).
