#!/usr/bin/env bash
set -euo pipefail

OWNER="${OWNER:-richardfariax}"
REPO="${REPO:-orvia}"
CASK_NAME="${CASK_NAME:-orvia}"
APP_DIR="${APP_DIR:-$HOME/Applications}"
CASK_URL="${CASK_URL:-https://raw.githubusercontent.com/${OWNER}/${REPO}/main/Casks/${CASK_NAME}.rb}"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required: https://brew.sh" >&2
  exit 1
fi

mkdir -p "${APP_DIR}"
brew install --cask --appdir="${APP_DIR}" "${CASK_URL}"

echo "Orvia installed via Homebrew at ${APP_DIR}/Orvia.app"
