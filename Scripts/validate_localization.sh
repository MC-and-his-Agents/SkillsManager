#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
CATALOG="$ROOT_DIR/Sources/SkillsManager/Resources/Localizable.xcstrings"
INFO_CATALOG="$ROOT_DIR/Sources/SkillsManager/Resources/InfoPlist.xcstrings"
[[ -f "$CATALOG" && -f "$INFO_CATALOG" ]] || {
  echo "ERROR: localization catalogs are missing." >&2
  exit 1
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/skillsmanager-localization-XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

xcrun xcstringstool extract \
  "$ROOT_DIR/Sources/SkillsManager" \
  --SwiftUI \
  --modern-localizable-strings \
  --output-format xcstrings \
  --output-directory "$tmp_dir/extracted" >/dev/null

xcrun xcstringstool compile "$CATALOG" \
  --output-directory "$tmp_dir/compiled" \
  --language zh-Hans \
  --language en >/dev/null
xcrun xcstringstool compile "$INFO_CATALOG" \
  --output-directory "$tmp_dir/compiled" \
  --language zh-Hans \
  --language en >/dev/null

python3 - "$CATALOG" "$tmp_dir/extracted/Localizable.xcstrings" "$tmp_dir/compiled" <<'PY'
import json
import pathlib
import plistlib
import re
import sys

catalog_path, extracted_path, compiled_root = sys.argv[1:]
catalog = json.load(open(catalog_path, encoding="utf-8"))
extracted = json.load(open(extracted_path, encoding="utf-8"))
if catalog.get("sourceLanguage") != "zh-Hans":
    raise SystemExit("ERROR: Localizable.xcstrings sourceLanguage must be zh-Hans")

entries = catalog.get("strings", {})
source_keys = set(extracted.get("strings", {}))
missing = sorted(source_keys - set(entries))
if missing:
    raise SystemExit("ERROR: source keys missing from catalog: " + ", ".join(missing))

placeholder = re.compile(r"%(?:\d+\$)?arg|%\([^)]*\)(?:lld|ld|d|@)|%lld")

# Equal source values are intentional only for opaque/proper names and format
# shells. Every natural-language phrase must have a real zh-Hans translation.
equal_allowlist = {
    "%1$arg: %2$arg": "format shell: two opaque interpolation slots",
    "↻ v%arg": "format shell: version token",
    "OK": "protocol acknowledgement",
    "ClawHub": "provider name",
    "GitHub": "vendor name",
    "Claude Code": "vendor name",
    "Claude": "vendor name",
    "Codex": "vendor name",
    "Copilot": "vendor name",
    "GitHub Copilot": "vendor name",
    "OpenCode": "vendor name",
    "skills.sh": "provider name",
    "Skills Manager": "product name",
    "https://github.com/owner/repository": "literal URL",
}

def units(localization):
    if "stringUnit" in localization:
        return [localization["stringUnit"]]
    variations = localization.get("variations", {}).get("plural", {})
    return [variant["stringUnit"] for variant in variations.values() if "stringUnit" in variant]

for key, entry in entries.items():
    if entry.get("extractionState") != "manual":
        raise SystemExit(f"ERROR: {key!r} has deprecated or non-manual extraction state")
    localizations = entry.get("localizations", {})
    for language in ("zh-Hans", "en"):
        language_units = units(localizations.get(language, {}))
        if not language_units:
            raise SystemExit(f"ERROR: {key!r} has no complete {language} value")
        for unit in language_units:
            value = unit.get("value")
            if unit.get("state") != "translated" or not isinstance(value, str) or not value:
                raise SystemExit(f"ERROR: {key!r} has no complete {language} value")
    zh_values = [unit["value"] for unit in units(localizations["zh-Hans"])]
    en_values = [unit["value"] for unit in units(localizations["en"])]
    for zh, en in zip(zh_values, en_values):
        if sorted(placeholder.findall(zh)) != sorted(placeholder.findall(en)):
            raise SystemExit(f"ERROR: placeholder mismatch for {key!r}")
        if zh == en and zh not in equal_allowlist:
            raise SystemExit(
                f"ERROR: untranslated equal zh-Hans/en value for {key!r}: {zh!r}"
            )

compiled_dir = pathlib.Path(compiled_root)
catalog_keys = set(entries)
for language in ("zh-Hans", "en"):
    strings_path = compiled_dir / f"{language}.lproj" / "Localizable.strings"
    stringsdict_path = compiled_dir / f"{language}.lproj" / "Localizable.stringsdict"
    compiled_keys = set(plistlib.load(strings_path.open("rb")))
    if stringsdict_path.exists():
        compiled_keys.update(plistlib.load(stringsdict_path.open("rb")))
    missing_compiled = sorted(catalog_keys - compiled_keys)
    stale_compiled = sorted(compiled_keys - catalog_keys)
    if missing_compiled:
        raise SystemExit(
            f"ERROR: {language} compiled resources missing catalog keys: "
            + ", ".join(missing_compiled)
        )
    if stale_compiled:
        raise SystemExit(
            f"ERROR: {language} compiled resources contain stale keys: "
            + ", ".join(stale_compiled)
        )

print(f"OK: {len(source_keys)} extracted keys; {len(entries)} catalog entries; zh-Hans/en complete")
PY

# Static UI literal gate.  Only expression-backed external/user/provider/path/
# raw-diagnostic values are excluded: Text(variable), Label(message, ...), and
# accessibility values built from those expressions intentionally remain verbatim.
# Every direct App-owned SwiftUI literal must resolve through Bundle.module (or
# a String(localized:) / LocalizedStringResource bridge) before this gate passes.
python3 - "$ROOT_DIR/Sources/SkillsManager" <<'PY'
import pathlib
import re
import sys

source_root = pathlib.Path(sys.argv[1])
patterns = (
    r"\bText\(\s*\"",
    r"\bButton\(\s*\"",
    r"\bLabel\(\s*\"",
    r"\bGroupBox\(\s*\"",
    r"\bProgressView\(\s*\"",
    r"\.navigationTitle\(\s*\"",
    r"\.navigationSubtitle\(\s*\"",
    r"\.help\(\s*\"",
    r"\.accessibility(?:Label|Value|Hint)\(\s*\"",
)
literal = re.compile("|".join(patterns))
findings = []
for path in sorted(source_root.rglob("*.swift")):
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not literal.search(line):
            continue
        if any(marker in line for marker in (
            "bundle: .module",
            "String(localized:",
            "LocalizedStringResource",
        )):
            continue
        findings.append(f"{path}:{line_number}:{line.strip()}")

if findings:
    print("ERROR: unregistered App-owned SwiftUI literals:", file=sys.stderr)
    print("\n".join(findings), file=sys.stderr)
    raise SystemExit(1)

print(
    "OK: App-owned SwiftUI literal gate found 0 actionable candidates; "
    "expression-backed external/provider/user/path/raw diagnostics remain verbatim"
)
PY

# Dynamic localization bridges are prohibited: app-owned presentation text
# must use a static key with typed interpolation, never a rendered String key.
python3 - "$ROOT_DIR/Sources/SkillsManager" <<'PY'
import pathlib
import re
import sys

source_root = pathlib.Path(sys.argv[1])
forbidden = (
    re.compile(r"String\.LocalizationValue\s*\("),
    re.compile(r"\bfunc\s+localized\s*\([^\n]*:\s*String\b"),
)
findings = []
for path in sorted(source_root.rglob("*.swift")):
    text = path.read_text(encoding="utf-8")
    for pattern in forbidden:
        for match in pattern.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            findings.append(f"{path}:{line}:{match.group(0).strip()}")

if findings:
    print("ERROR: generic dynamic localization bridges:", file=sys.stderr)
    print("\n".join(findings), file=sys.stderr)
    raise SystemExit(1)

print("OK: no generic String.LocalizationValue or localized(String) bridges")
PY

# ContentUnavailableView often spans multiple lines, so retain a whole-file
# check in addition to the line-oriented SwiftUI literal gate above.
python3 - "$ROOT_DIR/Sources/SkillsManager" <<'PY'
import pathlib
import re
import sys

source_root = pathlib.Path(sys.argv[1])
call = re.compile(r"\bContentUnavailableView\s*\((.*?)\)", re.DOTALL)
literal = re.compile(r"^\s*\"(?:[^\"\\]|\\.)*\"\s*$", re.DOTALL)
findings = []
for path in sorted(source_root.rglob("*.swift")):
    text = path.read_text(encoding="utf-8")
    for match in call.finditer(text):
        body = match.group(1)
        first_argument = body.split(",", 1)[0].strip()
        if literal.match(first_argument) and not any(
            marker in body for marker in ("bundle: .module", "String(localized:", "LocalizedStringResource")
        ):
            line = text.count("\n", 0, match.start()) + 1
            findings.append(f"{path}:{line}:{first_argument}")

if findings:
    print("ERROR: direct App-owned ContentUnavailableView literals:", file=sys.stderr)
    print("\n".join(findings), file=sys.stderr)
    raise SystemExit(1)

print("OK: ContentUnavailableView localization gate found 0 actionable literals")
PY

echo "OK: compiled zh-Hans/en Localizable and InfoPlist resources"
