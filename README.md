# Winnow

A native macOS app for finding and cleaning up duplicate files and empty folders, including on network drives (SMB/NAS).

Winnow is a Mac-style interface on top of the [czkawka](https://github.com/qarmin/czkawka) scanning engine. The engine is fast and thorough; Winnow adds a workflow that is safe and easy to follow.

> **Status: early (0.1).** Duplicate files and empty folders only. Interface in Simplified Chinese. Requires macOS 14 or later on Apple silicon.

## What it does

1. **Choose where to look.** Add folders or drives, or drag them in. Mark a location as *compare only* (只作对照) and its files are used for matching but never marked for removal.
2. **Choose how to compare.** By content (byte-exact, safe to delete) or by size and name (fast, for a first look).
3. **Watch the scan.** Each stage shows counts, speed and time left. Folders that could not be read are listed, not silently skipped.
4. **Review.** Groups are sorted by how much space they free. Every copy is either *keep* or *remove*, and each group always keeps at least one. Auto-marking rules: keep the oldest, the newest, the shortest path, or the copy in a folder you pick. Groups you edit by hand are never overwritten.
5. **Check, then act.** Nothing is removed until a final check re-reads each marked file and skips anything that changed since the scan. You can move files to a staging folder on the same drive (the default, undoable in one click), move them to the Trash (local drives only, since network drives have none), or delete them permanently.

## Building

```sh
scripts/bundle.sh --open        # builds build/Winnow.app and opens it
swift test                      # needs Xcode's toolchain: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

`scripts/bundle.sh` downloads the pinned czkawka_cli release (12.0.2) into `ThirdParty/` and puts it inside the app.

## How it works

Winnow runs `czkawka_cli` as a separate program, under a pseudo-terminal so its progress output can be read, and loads the JSON results. All marking, safety checks and file operations are Winnow's own code in `Sources/WinnowCore`.

## License

Winnow is licensed under the [GPL-3.0](LICENSE). Contributions require agreeing to the [CLA](CLA.md), which a bot asks for on your first pull request.

The bundled `czkawka_cli` is MIT-licensed and statically includes libraries under other licenses; see [ThirdPartyNotices.txt](Resources/ThirdPartyNotices.txt).
