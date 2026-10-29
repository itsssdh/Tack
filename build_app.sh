#!/bin/bash
# Builds Tack.app into ./build (Apple Silicon by default).
#   Intel + Apple Silicon:  UNIVERSAL=1 ./build_app.sh
#   Use your own certificate:  SIGN_ID="My Certificate Name" ./build_app.sh
#
# Signing: the first run creates a private signing certificate just for Tack
# (stored in its own keychain file, nothing in your login keychain). Every later build is
# signed with the same certificate, so macOS keeps your Screen Recording permission.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Tack.app"
ARCHS=(--arch arm64)
if [ "${UNIVERSAL:-0}" = "1" ]; then ARCHS=(--arch arm64 --arch x86_64); fi

# TESTING=1 builds the self-test into the app (for development only). A normal build, and every release, leaves it out.
EXTRA=()
if [ "${TESTING:-0}" = "1" ]; then EXTRA=(-Xswiftc -DFRAMEGRAB_TESTING); fi

echo "Building..."
swift build -c release "${ARCHS[@]}" ${EXTRA[@]+"${EXTRA[@]}"}
BIN="$(swift build -c release "${ARCHS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Tack" "$APP/Contents/MacOS/Tack"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Sparkle (the updater) travels inside the app.
SPARKLE="$(find .build/artifacts -type d -path '*macos-arm64_x86_64/Sparkle.framework' | head -1)"
[ -n "$SPARKLE" ] || { echo "Sparkle.framework not found; run: swift package resolve"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

# Your details (Release.config) go into the Info.plist. Anything still unfilled is left visible as {{...}}.
[ -f Release.config ] && source Release.config
fill() {  # fill FILE: replace the {{...}} placeholders that have a real value
    local f="$1" v
    for pair in "APP_NAME=${APP_NAME:-}" "COPYRIGHT_HOLDER=${COPYRIGHT_HOLDER:-}" "YEAR=$(date +%Y)"; do
        v="${pair#*=}"
        if [ -n "$v" ] && [ "$v" != "REPLACE_ME" ]; then
            v="${v//&/\\&}"
            /usr/bin/sed -i '' "s|{{${pair%%=*}}}|${v//|/\\|}|g" "$f"
        fi
    done
}
fill "$APP/Contents/Info.plist"
PB=/usr/libexec/PlistBuddy
[ -n "${BUNDLE_ID:-}" ] && $PB -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
[ -n "${VERSION:-}" ] && $PB -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
[ -n "${BUILD:-}" ] && $PB -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"

echo "Making the app icon..."
ICONSET="$(mktemp -d)/Tack.iconset"
if "$APP/Contents/MacOS/Tack" --make-icon "$ICONSET" && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Tack.icns"; then
    :
else
    echo "(Could not make the icon; the app will use a plain one.)"
fi

echo "Signing..."
if [ -n "${SIGN_ID:-}" ]; then
    codesign --force --deep --options runtime --entitlements Resources/Tack.entitlements --sign "$SIGN_ID" "$APP"
else
    CERT_NAME="Framegrab Local Signing"
    KC="$HOME/Library/Keychains/framegrab-signing.keychain-db"

    if [ ! -f "$KC" ]; then
        echo "Creating a one-time local signing certificate..."
        TMP="$(mktemp -d)"
        cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
        /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
            -config "$TMP/openssl.cnf" >/dev/null 2>&1
        /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
            -out "$TMP/id.p12" -passout pass:framegrab -name "$CERT_NAME" >/dev/null 2>&1

        security create-keychain -p "" "$KC"
        security set-keychain-settings "$KC"
        security unlock-keychain -p "" "$KC"
        security import "$TMP/id.p12" -k "$KC" -P framegrab -T /usr/bin/codesign >/dev/null
        security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KC" >/dev/null 2>&1 || true
        rm -rf "$TMP"
    fi

    security unlock-keychain -p "" "$KC"
    if ! codesign --force --deep --options runtime --entitlements Resources/Tack.entitlements --sign "$CERT_NAME" --keychain "$KC" "$APP"; then
        echo "Could not sign with the local certificate; falling back to a temporary signature."
        echo "(macOS will ask for Screen Recording again after each rebuild.)"
        codesign --force --deep --sign - "$APP"
    fi
fi

echo ""
echo "Done: $(pwd)/$APP"
echo "Next: drag it into /Applications, then open it."
