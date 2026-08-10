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

python3 - "$CATALOG" "$tmp_dir/extracted/Localizable.xcstrings" <<'PY'
import json
import re
import sys

catalog_path, extracted_path = sys.argv[1:]
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

echo "OK: compiled zh-Hans/en Localizable and InfoPlist resources"
