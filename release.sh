#!/bin/bash
# Makes the release build: a DMG in ./release.
#   With an Apple Developer Program membership: signed, notarized and stapled, so it opens without any warning.
#   Without one (SIGN_IDENTITY="local" in Release.config): signed with your own steady certificate and NOT notarized.
#     macOS then warns on first launch and they must use System Settings > Privacy & Security > Open Anyway.
#     The DMG window says so. Put the same steps on your download page.
# Before the first run: fill every REPLACE_ME in Release.config.
set -euo pipefail
cd "$(dirname "$0")"
source Release.config

fail() { echo "STOP: $1" >&2; exit 1; }

# 1. Refuse to ship anything unfinished.
NOTARIZE=1
[ "$SIGN_IDENTITY" = "local" ] && NOTARIZE=0
for v in COPYRIGHT_HOLDER SIGN_IDENTITY; do
    [ "${!v}" = "REPLACE_ME" ] && fail "$v is still REPLACE_ME in Release.config."
done
[ "$NOTARIZE" = 1 ] && [ "$NOTARY_PROFILE" = "REPLACE_ME" ] && fail "NOTARY_PROFILE is still REPLACE_ME in Release.config."
case "$BUNDLE_ID" in com.local.*|com.example.*) fail "BUNDLE_ID ($BUNDLE_ID) is a placeholder. Use an ID you own.";; esac
if [ "$NOTARIZE" = 1 ]; then
    security find-identity -v -p codesigning | grep -qF "$SIGN_IDENTITY" || fail "No signing identity named \"$SIGN_IDENTITY\" in your keychain."
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail "Notary profile \"$NOTARY_PROFILE\" does not work. Create it with: xcrun notarytool store-credentials"
else
    KC="$HOME/Library/Keychains/framegrab-signing.keychain-db"
    [ -f "$KC" ] || fail "No local signing certificate yet. Run ./build_app.sh once to create it, then BACK UP $KC: if you ever lose it, everyone has to grant Screen Recording permission again after an update."
fi

# 2. Build the real thing: both Mac types, no self-test code in it.
echo "Building (Apple Silicon + Intel)..."
if [ "$NOTARIZE" = 1 ]; then
    SIGN_ID="$SIGN_IDENTITY" UNIVERSAL=1 TESTING=0 ./build_app.sh >/dev/null
else
    UNIVERSAL=1 TESTING=0 ./build_app.sh >/dev/null   # signed with the local certificate
fi
APP="build/Tack.app"

# 3. Check it before and after signing.
grep -qF "{{" "$APP/Contents/Info.plist" && fail "A {{placeholder}} is still in the app's Info.plist."
ARCHS_FOUND="$(lipo -archs "$APP/Contents/MacOS/Tack")"
case "$ARCHS_FOUND" in *arm64*) ;; *) fail "Missing the Apple Silicon build.";; esac
case "$ARCHS_FOUND" in *x86_64*) ;; *) fail "Missing the Intel build.";; esac
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNATURE_INFO="$(codesign -dv "$APP" 2>&1)"
case "$SIGNATURE_INFO" in *"flags=0x10000(runtime)"*) ;; *) fail "The hardened runtime is not on.";; esac
STRINGS_FOUND="$(strings "$APP/Contents/MacOS/Tack")"
case "$STRINGS_FOUND" in *selftest-apple-roundtrip*) fail "Test code is inside the release build.";; esac

# 4. Notarize the app, then put it in a DMG and notarize that too.
mkdir -p release && rm -f release/*.dmg release/*.zip
if [ "$NOTARIZE" = 1 ]; then
    ditto -c -k --keepParent "$APP" release/app.zip
    echo "Notarizing the app (a few minutes)..."
    xcrun notarytool submit release/app.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm release/app.zip
fi

DMG="release/${APP_NAME// /-}-$VERSION.dmg"
NOTE=""
[ "$NOTARIZE" = 0 ] && NOTE="First time opening? If macOS warns, go to System Settings > Privacy & Security > Open Anyway."
./dmg/make_dmg.sh "$APP" "$DMG" "$APP_NAME" "$NOTE"
if [ "$NOTARIZE" = 1 ]; then
    codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"
    echo "Notarizing the disk image..."
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

# 5. Last check, the way another Mac will do it.
if [ "$NOTARIZE" = 1 ]; then
    spctl -a -t open --context context:primary-signature -v "$DMG"
    spctl -a -t exec -v "$APP"
else
    echo "NOTE: this build is not notarized. macOS will warn on first launch; say so on your download page."
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo
echo "Done: $DMG"
echo "Before you publish: test this DMG on a Mac that has never had the app."
