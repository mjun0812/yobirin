#!/usr/bin/env bash
# Builds Yobirin.app and installs it for PATH-based invocation.
#
# Steps: run build-app.sh -> remove the previously installed bundle (if any)
# -> copy the fresh bundle into ~/Applications -> (re)create a symlink from
# BIN_DIR to the bundle's Mach-O -> verify the symlink runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="Yobirin"
EXECUTABLE_NAME="yobirin"

BUILT_APP_DIR="${REPO_ROOT}/.build/app/${APP_NAME}.app"

if [[ -z "${HOME}" ]]; then
	echo "error: HOME is not set" >&2
	exit 1
fi

INSTALL_DIR="${HOME}/Applications"
INSTALLED_APP_DIR="${INSTALL_DIR}/${APP_NAME}.app"

BIN_DIR="${YOBIRIN_BIN_DIR:-${HOME}/.local/bin}"
if [[ -z "${BIN_DIR}" ]]; then
	echo "error: BIN_DIR is empty" >&2
	exit 1
fi
LINK_PATH="${BIN_DIR}/${EXECUTABLE_NAME}"
LINK_TARGET="${INSTALLED_APP_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"

echo "==> Building ${APP_NAME}.app"
"${SCRIPT_DIR}/build-app.sh"

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
