#!/usr/bin/env bash
set -euo pipefail

SCHEME="${SCHEME:-Orvia}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="${BUILD_DIR:-build}"
ARCHIVE_PATH="${BUILD_DIR}/${SCHEME}.xcarchive"
APP_PATH="${ARCHIVE_PATH}/Products/Applications/${SCHEME}.app"
DMG_STAGING_DIR="${BUILD_DIR}/dmg-staging"
DMG_PATH="${BUILD_DIR}/${SCHEME}.dmg"
SHA_PATH="${BUILD_DIR}/${SCHEME}.dmg.sha256"

mkdir -p "${BUILD_DIR}"
rm -rf "${DMG_STAGING_DIR}" "${DMG_PATH}" "${SHA_PATH}"
if [[ ! -d "${APP_PATH}" ]]; then
  ./Scripts/release.sh
fi

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Erro: app não encontrado em ${APP_PATH}" >&2
  exit 1
fi

mkdir -p "${DMG_STAGING_DIR}"
cp -R "${APP_PATH}" "${DMG_STAGING_DIR}/"
ln -s /Applications "${DMG_STAGING_DIR}/Applications"

diskutil image create from \
  --volumeName "${SCHEME}" \
  --format UDZO \
  "${DMG_STAGING_DIR}" \
  "${DMG_PATH}"

(cd "${BUILD_DIR}" && shasum -a 256 "${SCHEME}.dmg" > "${SCHEME}.dmg.sha256")

rm -rf "${DMG_STAGING_DIR}"

echo "DMG gerado: ${DMG_PATH}"
echo "Checksum SHA256: ${SHA_PATH}"
