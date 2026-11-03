#!/usr/bin/env python3
"""Checks Localization/Translations.json against the code and writes <lang>.lproj/Localizable.strings.

Usage: scripts/build-strings.py OUT_DIR      (writes OUT_DIR/<lang>.lproj)
       scripts/build-strings.py --check      (only reports problems)
Fails when a key used in the code has no entry, a translation is missing, or the
printf placeholders of a translation do not match its English key.
"""
import json, re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
LANGS = ["zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es"]
CALL = re.compile(r'\b(?:L|Text|Button|Label|Toggle|Section|ContentUnavailableView|navigationTitle|navigationSubtitle|help|Picker|Menu|TextField)\(\s*"((?:[^"\\]|\\.)*)"')
SPEC = re.compile(r'%(?:(\d+)\$)?(ld|lld|d|@|%)')

def keys_in_code():
    found = {}
    for f in sorted((ROOT / "Sources").rglob("*.swift")):
        for m in CALL.finditer(f.read_text()):
            key = m.group(1)
            if key == "" or "\\(" in key:
                continue
            key = key.replace('\\"', '"')
            found.setdefault(key, f.name)
    return found

def specs(s):
    out, i = [], 0
    for m in SPEC.finditer(s):
        if m.group(2) == "%":
            continue
        pos = int(m.group(1)) if m.group(1) else (i := i + 1)
        kind = "int" if m.group(2) in ("ld", "lld", "d") else "obj"
        out.append((pos, kind))
    return sorted(out)

def main():
    table = json.loads((ROOT / "Localization/Translations.json").read_text())
    code = keys_in_code()
    problems = []
    for key, where in code.items():
        if key not in table:
            problems.append(f"missing entry: {key!r} ({where})")
    for key, tr in table.items():
        if key not in code:
            problems.append(f"unused entry: {key!r}")
        for lang in LANGS:
            if not tr.get(lang):
                problems.append(f"no {lang}: {key!r}")
            elif specs(tr[lang]) != specs(key):
                problems.append(f"placeholders differ in {lang}: {key!r} -> {tr[lang]!r}")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        sys.exit(1)
    if sys.argv[1:] == ["--check"]:
        print(f"{len(table)} strings, {len(LANGS)} languages: ok")
        return
    out = pathlib.Path(sys.argv[1])
    def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    for lang in ["en"] + LANGS:
        d = out / f"{lang}.lproj"
        d.mkdir(parents=True, exist_ok=True)
        lines = [f'"{esc(k)}" = "{esc(k if lang == "en" else v[lang])}";' for k, v in sorted(table.items())]
        (d / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {len(table)} strings for {len(LANGS) + 1} languages")

main()
