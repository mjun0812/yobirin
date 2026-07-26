#!/usr/bin/env bash
# Builds a signed Yobirin.app bundle without an Xcode project. An optional
# profile argument (e.g. "claude") builds a derived bundle with a different
# icon and Bundle ID instead of the default (e.g. Yobirin-Claude.app /
# com.mjun0812.yobirin.claude).
#
# Steps: build arm64 + x86_64 individually -> lipo into a universal binary
# -> assemble Contents/{MacOS,Resources} + Info.plist -> generate AppIcon.icns
# via sips + iconutil -> ad-hoc codesign -> LaunchServices smoke test.
#
# Environment variables:
#   YOBIRIN_PREBUILT_BINARY  Use this universal binary instead of compiling
#                            (skips both swift build passes and lipo).
#   YOBIRIN_VERSION          CFBundleShortVersionString (default: 0.1.0).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROFILE="${1:-}"
if [[ -n "${PROFILE}" && ! "${PROFILE}" =~ ^[a-z0-9]+$ ]]; then
	echo "error: invalid profile name: ${PROFILE} (expected lowercase alphanumeric)" >&2
	exit 1
fi

if [[ -z "${PROFILE}" ]]; then
	APP_NAME="Yobirin"
	BUNDLE_ID="com.mjun0812.yobirin"
	ICON_SOURCE="${REPO_ROOT}/assets/icon/AppIcon.png"
else
	PROFILE_FIRST_CHAR="$(printf '%s' "${PROFILE}" | cut -c1 | tr '[:lower:]' '[:upper:]')"
	PROFILE_REST="$(printf '%s' "${PROFILE}" | cut -c2-)"
	APP_NAME="Yobirin-${PROFILE_FIRST_CHAR}${PROFILE_REST}"
	BUNDLE_ID="com.mjun0812.yobirin.${PROFILE}"
	ICON_SOURCE="${REPO_ROOT}/assets/icon/${PROFILE}.png"
fi

EXECUTABLE_NAME="yobirin"
CONFIGURATION="release"

BUILD_DIR="${REPO_ROOT}/.build"
APP_DIR="${BUILD_DIR}/app/${APP_NAME}.app"
ICONSET_DIR="${BUILD_DIR}/app/${APP_NAME}-AppIcon.iconset"

PREBUILT_BINARY="${YOBIRIN_PREBUILT_BINARY:-}"
if [[ -n "${PREBUILT_BINARY}" && ! -f "${PREBUILT_BINARY}" ]]; then
	echo "error: YOBIRIN_PREBUILT_BINARY not found: ${PREBUILT_BINARY}" >&2
	exit 1
fi

if [[ -z "${PREBUILT_BINARY}" ]]; then
	echo "==> Building arm64 binary"
	swift build --package-path "${REPO_ROOT}" -c "${CONFIGURATION}" --arch arm64

	echo "==> Building x86_64 binary"
	swift build --package-path "${REPO_ROOT}" -c "${CONFIGURATION}" --arch x86_64
fi

echo "==> Assembling ${APP_NAME}.app"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

if [[ -n "${PREBUILT_BINARY}" ]]; then
	echo "==> Using prebuilt binary: ${PREBUILT_BINARY}"
	cp "${PREBUILT_BINARY}" "${APP_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"
	chmod +x "${APP_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"
else
	lipo -create \
		"${BUILD_DIR}/arm64-apple-macosx/${CONFIGURATION}/${EXECUTABLE_NAME}" \
		"${BUILD_DIR}/x86_64-apple-macosx/${CONFIGURATION}/${EXECUTABLE_NAME}" \
		-output "${APP_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"
fi

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
    <string>${YOBIRIN_VERSION:-0.1.0}</string>
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
