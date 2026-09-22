#!/usr/bin/env bash
set -euo pipefail

OWNER="${OWNER:-richardfariax}"
REPO="${REPO:-clip-flow}"
APP_NAME="${APP_NAME:-Orvia}"
DMG_NAME="${DMG_NAME:-Orvia.dmg}"
APP_DIR="${APP_DIR:-$HOME/Applications}"
DOWNLOAD_URL="${DOWNLOAD_URL:-https://github.com/${OWNER}/${REPO}/releases/latest/download/${DMG_NAME}}"

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

if ! command -v hdiutil >/dev/null 2>&1; then
  echo "hdiutil is required." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
DMG_PATH="${TMP_DIR}/${DMG_NAME}"
MOUNT_POINT=""

cleanup() {
  if [[ -n "${MOUNT_POINT}" && -d "${MOUNT_POINT}" ]]; then
    hdiutil detach "${MOUNT_POINT}" -quiet || true
  fi
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "Downloading ${APP_NAME}..."
curl --fail --location --silent --show-error --retry 3 --output "${DMG_PATH}" "${DOWNLOAD_URL}"

echo "Mounting disk image..."
MOUNT_POINT="$(hdiutil attach "${DMG_PATH}" -nobrowse -readonly -noverify | awk '/\/Volumes\// {print substr($0, index($0, "/Volumes/"))}' | tail -n 1)"
if [[ -z "${MOUNT_POINT}" ]]; then
  echo "Failed to mount DMG." >&2
  exit 1
fi

SOURCE_APP="${MOUNT_POINT}/${APP_NAME}.app"
TARGET_APP="${APP_DIR}/${APP_NAME}.app"

if [[ ! -d "${SOURCE_APP}" ]]; then
  echo "App not found inside DMG: ${SOURCE_APP}" >&2
  exit 1
fi

mkdir -p "${APP_DIR}"
rm -rf "${TARGET_APP}"
cp -R "${SOURCE_APP}" "${TARGET_APP}"

echo "${APP_NAME} installed at ${TARGET_APP}"
echo "You can open it from Applications."
