#!/usr/bin/env bash
# Builds a signed Yobirin.app bundle without an Xcode project.
#
# Steps: build arm64 + x86_64 individually -> lipo into a universal binary
# -> assemble Contents/{MacOS,Resources} + Info.plist -> generate AppIcon.icns
# via sips + iconutil -> ad-hoc codesign -> LaunchServices smoke test.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="Yobirin"
BUNDLE_ID="com.mjun0812.yobirin"
EXECUTABLE_NAME="yobirin"
CONFIGURATION="release"

BUILD_DIR="${REPO_ROOT}/.build"
APP_DIR="${BUILD_DIR}/app/${APP_NAME}.app"
ICONSET_DIR="${BUILD_DIR}/app/AppIcon.iconset"
ICON_SOURCE="${REPO_ROOT}/assets/icon/AppIcon.png"

echo "==> Building arm64 binary"
swift build --package-path "${REPO_ROOT}" -c "${CONFIGURATION}" --arch arm64

echo "==> Building x86_64 binary"
swift build --package-path "${REPO_ROOT}" -c "${CONFIGURATION}" --arch x86_64

echo "==> Assembling ${APP_NAME}.app"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

lipo -create \
	"${BUILD_DIR}/arm64-apple-macosx/${CONFIGURATION}/${EXECUTABLE_NAME}" \
	"${BUILD_DIR}/x86_64-apple-macosx/${CONFIGURATION}/${EXECUTABLE_NAME}" \
	-output "${APP_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"

cat >"${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Generating AppIcon.icns"
rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"

for size in 16 32 128 256 512; do
	sips -z "${size}" "${size}" "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null
	retina_size=$((size * 2))
	sips -z "${retina_size}" "${retina_size}" "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "${ICONSET_DIR}" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"

echo "==> ad-hoc signing (no entitlements)"
codesign --force --sign - "${APP_DIR}"

echo "==> Verifying signature"
codesign --verify --deep --strict "${APP_DIR}"

echo "==> LaunchServices smoke test"
if ! open -W -n "${APP_DIR}" --args --help; then
	echo "error: LaunchServices smoke test failed to launch ${APP_DIR}" >&2
	exit 1
fi

echo "==> Build complete: ${APP_DIR}"
