#!/bin/zsh
# Rainpane.app 빌드. 사용법: ./build.sh [run]
set -euo pipefail
cd "$(dirname "$0")"

# xcode-select가 Command Line Tools를 가리켜도 Xcode 툴체인을 쓰도록
if [[ -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Rainpane"

APP=build/Rainpane.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Rainpane"
cp Resources/* "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Rainpane</string>
  <key>CFBundleDisplayName</key><string>Rainpane</string>
  <key>CFBundleIdentifier</key><string>local.rainpane</string>
  <key>CFBundleExecutable</key><string>Rainpane</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# 프로젝트 전용 자체 서명 인증서가 있으면 그걸로 (권한이 다시 빌드해도 유지됨), 없으면 임시 서명
KC="$PWD/.signing/rainpane-dev.keychain-db"
if [[ -f "$KC" ]]; then
  security unlock-keychain -p "$(cat "$PWD/.signing/password")" "$KC" 2>/dev/null || true
  ID=$(security find-identity -p codesigning "$KC" | awk '/Rainpane Local Dev/ {print $2; exit}')
  if [[ -z "$ID" ]] || ! codesign --force --keychain "$KC" --sign "$ID" "$APP" >/dev/null 2>&1; then
    echo "⚠️  자체 서명 실패: ./setup-signing.sh를 다시 실행하세요. 임시 서명으로 대신합니다 (권한을 다시 허용해야 할 수 있음)"
    codesign --force --sign - "$APP" >/dev/null
  fi
else
  codesign --force --sign - "$APP" >/dev/null
fi
echo "✅ $APP"

if [[ "${1:-}" == "run" ]]; then
  pkill -x Rainpane 2>/dev/null || true
  open "$APP"
fi
