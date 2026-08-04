#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/Scripts/load_version_env.sh"
load_version_env "$ROOT/version.env"
ZIP=${1:?
"Usage: $0 MyApp-<ver>.zip https://example.com/appcast.xml https://example.com"}
FEED_URL=${2:?
"Usage: $0 MyApp-<ver>.zip https://example.com/appcast.xml https://example.com"}
PRODUCT_URL=${3:?
"Usage: $0 MyApp-<ver>.zip https://example.com/appcast.xml https://example.com"}
PRIVATE_KEY_FILE=${SPARKLE_PRIVATE_KEY_FILE:-}
PUBLIC_KEY=${SPARKLE_PUBLIC_KEY:-}
SPARKLE_TOOLS_SHA256=5cddb7695674ef7704268f38eccaee80e3accbf19e61c1689efff5b6116d85be
if [[ -z "$PRIVATE_KEY_FILE" ]]; then
  echo "Set SPARKLE_PRIVATE_KEY_FILE to your ed25519 private key (Sparkle)." >&2
  exit 1
fi
if [[ -z "$PUBLIC_KEY" ]]; then
  echo "Set SPARKLE_PUBLIC_KEY to the matching Sparkle EdDSA public key." >&2
  exit 1
fi
if [[ ! -f "$ZIP" ]]; then
  echo "Zip not found: $ZIP" >&2
  exit 1
fi

derived_public_key=$(swift - "$PRIVATE_KEY_FILE" <<'SWIFT'
import CryptoKit
import Foundation

let encodedKey = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
guard let seed = Data(base64Encoded: encodedKey, options: .ignoreUnknownCharacters) else {
    throw CocoaError(.fileReadCorruptFile)
}
let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(privateKey.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)
[[ "$derived_public_key" == "$PUBLIC_KEY" ]] || {
  echo "Sparkle private key does not match SPARKLE_PUBLIC_KEY." >&2
  exit 1
}

ZIP_DIR=$(cd "$(dirname "$ZIP")" && pwd)
ZIP_NAME=$(basename "$ZIP")
ZIP_BASE="${ZIP_NAME%.zip}"
VERSION=${SPARKLE_RELEASE_VERSION:-}
if [[ -z "$VERSION" ]]; then
  if [[ "$ZIP_NAME" =~ ^[^-]+-([0-9]+(\.[0-9]+){1,2}([-.][^.]*)?)\.zip$ ]]; then
    VERSION="${BASH_REMATCH[1]}"
  else
    echo "Could not infer version from $ZIP_NAME; set SPARKLE_RELEASE_VERSION." >&2
    exit 1
  fi
fi

NOTES_HTML="${ZIP_DIR}/${ZIP_BASE}.html"
KEEP_NOTES=${KEEP_SPARKLE_NOTES:-0}
if [[ -x "$ROOT/Scripts/changelog-to-html.sh" ]]; then
  "$ROOT/Scripts/changelog-to-html.sh" "$VERSION" >"$NOTES_HTML"
elif [[ -n "${SPARKLE_RELEASE_NOTES_FILE:-}" && -f "${SPARKLE_RELEASE_NOTES_FILE:-}" ]]; then
  python3 - <<'PY' "${SPARKLE_RELEASE_NOTES_FILE}" "$NOTES_HTML" "$ZIP_BASE"
import sys
from pathlib import Path

notes_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
title = sys.argv[3]
lines = [line.strip() for line in notes_path.read_text().splitlines()]
items = [line[2:].strip() for line in lines if line.startswith(("- ", "* "))]
paras = [line for line in lines if line and not line.startswith(("- ", "* "))]

body = []
if paras:
  for p in paras:
    body.append(f"<p>{p}</p>")
if items:
  body.append("<ul>")
  for item in items:
    body.append(f"<li>{item}</li>")
  body.append("</ul>")

html = "\n".join([
  "<!doctype html>",
  "<html lang=\"en\">",
  "<meta charset=\"utf-8\">",
  f"<title>{title}</title>",
  "<body>",
  f"<h2>{title}</h2>",
  *body,
  "</body>",
  "</html>",
])
out_path.write_text(html)
PY
elif [[ -f "/tmp/skillsmanager-release-notes-${VERSION}.md" ]]; then
  python3 - <<'PY' "/tmp/skillsmanager-release-notes-${VERSION}.md" "$NOTES_HTML" "$ZIP_BASE"
import sys
from pathlib import Path

notes_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])
title = sys.argv[3]
lines = [line.strip() for line in notes_path.read_text().splitlines()]
items = [line[2:].strip() for line in lines if line.startswith(("- ", "* "))]
paras = [line for line in lines if line and not line.startswith(("- ", "* "))]

body = []
if paras:
  for p in paras:
    body.append(f"<p>{p}</p>")
if items:
  body.append("<ul>")
  for item in items:
    body.append(f"<li>{item}</li>")
  body.append("</ul>")

html = "\n".join([
  "<!doctype html>",
  "<html lang=\"en\">",
  "<meta charset=\"utf-8\">",
  f"<title>{title}</title>",
  "<body>",
  f"<h2>{title}</h2>",
  *body,
  "</body>",
  "</html>",
])
out_path.write_text(html)
PY
else
  cat >"$NOTES_HTML" <<HTML
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<title>${ZIP_BASE}</title>
<body>
<h2>${ZIP_BASE}</h2>
<p>Release notes not provided.</p>
</body>
</html>
HTML
fi
cleanup() {
  if [[ -n "${WORK_DIR:-}" ]]; then
    rm -rf "$WORK_DIR"
  fi
  if [[ -n "${TEMP_DIR:-}" ]]; then
    rm -rf "$TEMP_DIR"
  fi
  if [[ "$KEEP_NOTES" != "1" ]]; then
    rm -f "$NOTES_HTML"
  fi
}
trap cleanup EXIT

DOWNLOAD_URL_PREFIX=${SPARKLE_DOWNLOAD_URL_PREFIX:-"https://github.com/MC-and-his-Agents/SkillsManager/releases/download/v${VERSION}/"}

TEMP_DIR=$(mktemp -d /tmp/sparkle-appcast.XXXXXX)
curl -fsSL -o "$TEMP_DIR/sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-2.8.1.tar.xz"
printf '%s  %s\n' "$SPARKLE_TOOLS_SHA256" "$TEMP_DIR/sparkle.tar.xz" \
  | shasum -a 256 -c -
tar -xf "$TEMP_DIR/sparkle.tar.xz" -C "$TEMP_DIR" \
  ./bin/generate_appcast \
  ./bin/sign_update
GEN_APPCAST="$TEMP_DIR/bin/generate_appcast"
SIGN_UPDATE="$TEMP_DIR/bin/sign_update"

WORK_DIR=$(mktemp -d /tmp/appcast.XXXXXX)

cp "$ROOT/appcast.xml" "$WORK_DIR/appcast.xml"
cp "$ZIP" "$WORK_DIR/$ZIP_NAME"
cp "$NOTES_HTML" "$WORK_DIR/$ZIP_BASE.html"

pushd "$WORK_DIR" >/dev/null
"$GEN_APPCAST" \
  --ed-key-file "$PRIVATE_KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --embed-release-notes \
  --link "$PRODUCT_URL" \
  "$WORK_DIR"
popd >/dev/null

cp "$WORK_DIR/appcast.xml" "$ROOT/appcast.xml"

item="(//*[local-name()='item'][\
* [local-name()='shortVersionString' and text()='${VERSION}'] and \
* [local-name()='version' and text()='${BUILD_NUMBER}']])[1]"
signature=$(xmllint --xpath \
  "string($item/*[local-name()='enclosure']/@*[local-name()='edSignature'])" \
  "$ROOT/appcast.xml")
length=$(xmllint --xpath \
  "string($item/*[local-name()='enclosure']/@length)" \
  "$ROOT/appcast.xml")
[[ -n "$signature" && "$length" == "$(stat -f%z "$ZIP")" ]] || {
  echo "Sparkle did not generate a signed enclosure for this build." >&2
  exit 1
}
"$SIGN_UPDATE" --verify --ed-key-file "$PRIVATE_KEY_FILE" "$ZIP" "$signature"

echo "Appcast generated (appcast.xml). Upload alongside $ZIP at $FEED_URL"
