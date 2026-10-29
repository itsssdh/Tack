#!/bin/bash
# Adds a release to docs/appcast.xml, the feed that installed copies of Tack read to find updates.
#   ./dmg/add_to_appcast.sh VERSION BUILD DMG "What changed"
# The DMG is signed with the update key in your login keychain (made once with Sparkle's generate_keys).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$1"; BUILD="$2"; DMG="$3"; NOTES="$4"
SIGN="$(find .build/artifacts -path '*Sparkle/bin/sign_update' | head -1)"
[ -n "$SIGN" ] || { echo "STOP: Sparkle's sign_update not found; run: swift package resolve" >&2; exit 1; }
SIG="$("$SIGN" "$DMG")"   # prints: sparkle:edSignature="..." length="..."
URL="https://github.com/itsssdh/Tack/releases/download/v$VERSION/$(basename "$DMG")"
python3 - "$VERSION" "$BUILD" "$URL" "$SIG" "$NOTES" <<'PY'
import sys, os, email.utils
version, build, url, sig, notes = sys.argv[1:6]
path = "docs/appcast.xml"
head = '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tack</title>
    <link>https://itsssdh.github.io/Tack/</link>
    <description>Updates for Tack</description>
    <language>en</language>
'''
tail = "  </channel>\n</rss>\n"
items = ""
if os.path.exists(path):
    s = open(path).read()
    items = s[s.index("    <item>"):s.index(tail)] if "<item>" in s else ""
import re
# Re-releasing the same version (a quiet rebuild with a higher BUILD) replaces its entry.
items = "".join(i for i in re.findall(r"    <item>.*?</item>\n", items, re.S) if f"<sparkle:shortVersionString>{version}<" not in i)
esc = notes.replace("&", "&amp;").replace("<", "&lt;")
desc = f"      <description><![CDATA[<p>{esc}</p>]]></description>\n" if notes else ""
item = f'''    <item>
      <title>Version {version}</title>
      <pubDate>{email.utils.formatdate(localtime=False)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
{desc}      <enclosure url="{url}" {sig} type="application/octet-stream"/>
    </item>
'''
open(path, "w").write(head + item + items + tail)
print("Added", version, "to", path)
PY
