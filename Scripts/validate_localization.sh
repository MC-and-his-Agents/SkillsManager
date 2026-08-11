#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
CATALOG="$ROOT_DIR/Sources/SkillsManager/Resources/Localizable.xcstrings"
INFO_CATALOG="$ROOT_DIR/Sources/SkillsManager/Resources/InfoPlist.xcstrings"
[[ -f "$CATALOG" && -f "$INFO_CATALOG" ]] || {
  echo "ERROR: localization catalogs are missing." >&2
  exit 1
}

if rg -n 'bundle: \.module|Bundle\.module' "$ROOT_DIR/Sources/SkillsManager"; then
  echo "ERROR: localization must use SkillsManagerLocalizationResources.bundle." >&2
  exit 1
fi
echo "OK: all localization calls use the packaged resource entry point"

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
raw_source_keys = set(extracted.get("strings", {}))

# xcstringstool emits `%arg` for an interpolation-aware Swift resource. The
# catalog intentionally keeps typed `%@`/`%lld` keys so Foundation can match
# String and Int interpolation at runtime; compare the two representations by
# their interpolation shape rather than introducing a second catalog key.
def interpolation_shape(value):
    return re.sub(r"%(\d+\$)?(?:arg|@|lld)", r"%\1arg", value)

source_keys = set()
for raw_key in raw_source_keys:
    if raw_key in entries:
        source_keys.add(raw_key)
        continue
    candidates = [
        key for key in entries
        if interpolation_shape(key) == raw_key
    ]
    if len(candidates) != 1:
        raise SystemExit(
            f"ERROR: extracted key {raw_key!r} does not map to one typed catalog key: "
            + ", ".join(sorted(candidates))
        )
    source_keys.add(candidates[0])

missing = sorted(source_keys - set(entries))
if missing:
    raise SystemExit("ERROR: source keys missing from catalog: " + ", ".join(missing))
catalog_only = sorted(set(entries) - source_keys)
if catalog_only:
    raise SystemExit("ERROR: catalog keys missing from source extraction: " + ", ".join(catalog_only))

placeholder = re.compile(r"%(?:\d+\$)?(?:arg|@|lld)|%\([^)]*\)(?:lld|ld|d|@)")

# Equal source values are intentional only for opaque/proper names and format
# shells. Every natural-language phrase must have a real zh-Hans translation.
equal_allowlist = {
    "%1$arg: %2$arg": "format shell: two opaque interpolation slots",
    "↻ v%arg": "format shell: version token",
    "%1$@: %2$@": "format shell: two opaque interpolation slots",
    "%1$@: %2$lld": "format shell: localized status plus count",
    "%@ · %@": "format shell: two opaque interpolation slots",
    "↻ v%@": "format shell: version token",
    "SHA-256 %@…": "technical digest label with opaque prefix",
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

stale_dynamic = sorted(
    key for key, entry in entries.items()
    if "%arg" in key or "%1$arg" in key
    or any(
        "%arg" in unit.get("value", "") or "%1$arg" in unit.get("value", "")
        for language in entry.get("localizations", {}).values()
        for unit in units(language)
    )
)
if stale_dynamic:
    raise SystemExit("ERROR: stale %arg localization keys/values: " + ", ".join(stale_dynamic))

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

# Native interpolation-aware resources must not provide a rendered
# `defaultValue:` beside a static format key. That shape bypasses Foundation's
# interpolation metadata and leaves `%@`/`%lld` markers in the UI. Every
# dynamic resource must put its interpolation directly in the first argument.
python3 - "$ROOT_DIR/Sources/SkillsManager" <<'PY'
import pathlib
import re
import sys

source_root = pathlib.Path(sys.argv[1])
forbidden = re.compile(r"LocalizedStringResource\s*\([\s\S]{0,1200}?\bdefaultValue\s*:")
findings = []
for path in sorted(source_root.rglob("*.swift")):
    text = path.read_text(encoding="utf-8")
    for match in forbidden.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        findings.append(f"{path}:{line}:LocalizedStringResource defaultValue bridge")

if findings:
    print("ERROR: format-key LocalizedStringResource defaultValue bridges:", file=sys.stderr)
    print("\n".join(findings), file=sys.stderr)
    raise SystemExit(1)

print("OK: LocalizedStringResource uses interpolation-aware first arguments")
PY

# Static UI literal gate.  Only expression-backed external/user/provider/path/
# raw-diagnostic values are excluded: Text(variable), Label(message, ...), and
# accessibility values built from those expressions intentionally remain verbatim.
# Every direct App-owned SwiftUI literal must resolve through the packaged
# resource entry point (or a String(localized:) / LocalizedStringResource bridge).
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
            "bundle: SkillsManagerLocalizationResources.bundle",
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
            marker in body for marker in (
                "bundle: SkillsManagerLocalizationResources.bundle",
                "String(localized:",
                "LocalizedStringResource",
            )
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
