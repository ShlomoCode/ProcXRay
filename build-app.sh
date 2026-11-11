#!/bin/bash
# Builds ProcXRay.app (release) into ./build. Uses full Xcode: the Command Line Tools
# SDK for macOS 27 lacks the SwiftUI macro plugin, so `@State` fails to compile there.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ProcXRay"

APP=build/ProcXRay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ProcXRay"

# SwiftPM stamps the binary with sdk == deployment target (14.0). AppKit then runs the app in
# macOS-14 compatibility mode (opaque toolbar band, thicker split divider → a 2pt "kink" where the
# sidebar meets the toolbar). Record the SDK we actually built against, keeping minos 14.0.
SDK_VER="$(xcrun --sdk macosx --show-sdk-version)"
vtool -set-build-version macos 14.0 "$SDK_VER" -replace -output "$APP/Contents/MacOS/ProcXRay" "$APP/Contents/MacOS/ProcXRay"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ProcXRay</string>
  <key>CFBundleDisplayName</key><string>ProcXRay</string>
  <key>CFBundleIdentifier</key><string>local.procxray</string>
  <key>CFBundleExecutable</key><string>ProcXRay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Privileged helper: the same binary, started by launchd as root with --helper (SMAppService.daemon).
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cat > "$APP/Contents/Library/LaunchDaemons/local.procxray.helper.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.procxray.helper</string>
  <key>BundleProgram</key><string>Contents/MacOS/ProcXRay</string>
  <key>ProgramArguments</key>
  <array><string>ProcXRay</string><string>--helper</string></array>
  <key>MachServices</key>
  <dict><key>local.procxray.helper</key><true/></dict>
  <key>AssociatedBundleIdentifiers</key>
  <array><string>local.procxray</string></array>
</dict>
</plist>
PLIST

# Sign with an Apple Development identity: SMAppService won't run an ad-hoc daemon, and the helper's XPC
# listener only accepts clients signed by this team. Override with SIGN_ID=<sha1 or name>.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
if [[ -z "$SIGN_ID" ]]; then
  echo "warning: no Apple Development identity; signing ad-hoc (privileged helper will not work)" >&2
  SIGN_ID=-
fi
codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier|TeamIdentifier|Authority=Apple Development' || true
echo "built $APP"
