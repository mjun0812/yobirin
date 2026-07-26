#!/usr/bin/env bash
# Builds Yobirin.app (or one or more named icon profiles) and installs it for
# PATH-based invocation.
#
# No arguments: builds and installs the default Yobirin.app bundle only
# (unchanged behavior). One or more arguments: each argument is an icon
# profile name (e.g. "claude"), and only that profile's derived bundle
# (Yobirin-<Name>.app / yobirin-<profile> symlink) is built and installed;
# the default bundle is left untouched.
#
# Steps per bundle: run build-app.sh [profile] -> remove the previously
# installed bundle (if any) -> copy the fresh bundle into ~/Applications ->
# (re)create a symlink from BIN_DIR to the bundle's Mach-O -> verify the
# symlink runs.
#
# Environment variables:
#   YOBIRIN_FROM_RELEASE  When set to 1, download the prebuilt universal binary
#                         from a GitHub release instead of compiling locally.
#                         Requires the gh CLI (the repository is private).
#   YOBIRIN_RELEASE_TAG   Release tag to download (default: latest).
#   YOBIRIN_BIN_DIR       Where to place the command symlink (default: ~/.local/bin).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

EXECUTABLE_NAME="yobirin"

if [[ -z "${HOME}" ]]; then
	echo "error: HOME is not set" >&2
	exit 1
fi

INSTALL_DIR="${HOME}/Applications"

BIN_DIR="${YOBIRIN_BIN_DIR:-${HOME}/.local/bin}"
if [[ -z "${BIN_DIR}" ]]; then
	echo "error: BIN_DIR is empty" >&2
	exit 1
fi

PROFILES=("$@")
if [[ ${#PROFILES[@]} -eq 0 ]]; then
	PROFILES=("")
fi

# リリースから取得する場合は、全プロファイルで同じバイナリを使い回す。
DOWNLOAD_DIR=""
if [[ "${YOBIRIN_FROM_RELEASE:-}" == "1" ]]; then
	if ! command -v gh >/dev/null 2>&1; then
		echo "error: YOBIRIN_FROM_RELEASE=1 requires the gh CLI" >&2
		exit 1
	fi

	DOWNLOAD_DIR="$(mktemp -d)"
	trap 'rm -rf "${DOWNLOAD_DIR}"' EXIT

	echo "==> Downloading prebuilt binary from release (${YOBIRIN_RELEASE_TAG:-latest})"
	gh release download ${YOBIRIN_RELEASE_TAG:+"${YOBIRIN_RELEASE_TAG}"} \
		--repo mjun0812/yobirin \
		--pattern "${EXECUTABLE_NAME}-universal" \
		--dir "${DOWNLOAD_DIR}"

	export YOBIRIN_PREBUILT_BINARY="${DOWNLOAD_DIR}/${EXECUTABLE_NAME}-universal"
	chmod +x "${YOBIRIN_PREBUILT_BINARY}"
	lipo -info "${YOBIRIN_PREBUILT_BINARY}"
fi

for PROFILE in "${PROFILES[@]}"; do
	if [[ -n "${PROFILE}" && ! "${PROFILE}" =~ ^[a-z0-9]+$ ]]; then
		echo "error: invalid profile name: ${PROFILE} (expected lowercase alphanumeric)" >&2
		exit 1
	fi

	if [[ -z "${PROFILE}" ]]; then
		APP_NAME="Yobirin"
		LINK_NAME="${EXECUTABLE_NAME}"
	else
		PROFILE_FIRST_CHAR="$(printf '%s' "${PROFILE}" | cut -c1 | tr '[:lower:]' '[:upper:]')"
		PROFILE_REST="$(printf '%s' "${PROFILE}" | cut -c2-)"
		APP_NAME="Yobirin-${PROFILE_FIRST_CHAR}${PROFILE_REST}"
		LINK_NAME="${EXECUTABLE_NAME}-${PROFILE}"
	fi

	BUILT_APP_DIR="${REPO_ROOT}/.build/app/${APP_NAME}.app"
	INSTALLED_APP_DIR="${INSTALL_DIR}/${APP_NAME}.app"
	LINK_PATH="${BIN_DIR}/${LINK_NAME}"
	LINK_TARGET="${INSTALLED_APP_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"

	echo "==> Building ${APP_NAME}.app"
	"${SCRIPT_DIR}/build-app.sh" "${PROFILE}"

	if [[ ! -d "${BUILT_APP_DIR}" ]]; then
		echo "error: build did not produce ${BUILT_APP_DIR}" >&2
		exit 1
	fi

	echo "==> Installing to ${INSTALLED_APP_DIR}"
	mkdir -p "${INSTALL_DIR}"

	if [[ "${INSTALLED_APP_DIR}" != "${HOME}/Applications/${APP_NAME}.app" ]]; then
		echo "error: refusing to install to unexpected path: ${INSTALLED_APP_DIR}" >&2
		exit 1
	fi

	rm -rf "${INSTALLED_APP_DIR}"
	cp -R "${BUILT_APP_DIR}" "${INSTALL_DIR}/"

	echo "==> Linking ${LINK_PATH} -> ${LINK_TARGET}"
	mkdir -p "${BIN_DIR}"

	if [[ -L "${LINK_PATH}" ]]; then
		rm -f "${LINK_PATH}"
	elif [[ -e "${LINK_PATH}" ]]; then
		echo "error: ${LINK_PATH} already exists and is not a symlink; refusing to overwrite" >&2
		exit 1
	fi

	ln -s "${LINK_TARGET}" "${LINK_PATH}"

	echo "==> Verifying installed command"
	if ! "${LINK_PATH}" --help >/dev/null; then
		echo "error: ${LINK_PATH} --help failed" >&2
		exit 1
	fi

	echo "==> Install complete: ${LINK_PATH} -> ${LINK_TARGET}"
done
