#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARIES_DIR="${REPO_ROOT}/binaries"

mkdir -p "${BINARIES_DIR}"

API_URL="https://api.github.com/repos/jesseduffield/lazydocker/releases/latest"
LATEST_TAG="$(curl -fsSL "${API_URL}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"

if [[ -z "${LATEST_TAG}" || "${LATEST_TAG}" == "null" ]]; then
  echo "Could not resolve latest lazydocker tag from GitHub API."
  exit 1
fi

VERSION_NO_V="${LATEST_TAG#v}"
ASSET_URL="https://github.com/jesseduffield/lazydocker/releases/download/${LATEST_TAG}/lazydocker_${VERSION_NO_V}_Linux_x86_64.tar.gz"

VERSIONED_BINARY_PATH="${BINARIES_DIR}/lazydocker.${LATEST_TAG}"
LATEST_BINARY_PATH="${BINARIES_DIR}/lazydocker.latest"

if [[ -f "${VERSIONED_BINARY_PATH}" ]]; then
  install -m 0755 "${VERSIONED_BINARY_PATH}" "${LATEST_BINARY_PATH}"
  md5sum "${VERSIONED_BINARY_PATH}" | awk '{print $1}' > "${VERSIONED_BINARY_PATH}.md5"
  md5sum "${LATEST_BINARY_PATH}" | awk '{print $1}' > "${LATEST_BINARY_PATH}.md5"
  echo "Latest lazydocker already compiled: ${LATEST_TAG}. Skipping download/build."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ARCHIVE_PATH="${TMP_DIR}/lazydocker.tar.gz"

curl -fL "${ASSET_URL}" -o "${ARCHIVE_PATH}"
tar -xzf "${ARCHIVE_PATH}" -C "${TMP_DIR}"

if [[ ! -f "${TMP_DIR}/lazydocker" ]]; then
  echo "Downloaded archive did not contain the lazydocker binary."
  exit 1
fi

install -m 0755 "${TMP_DIR}/lazydocker" "${VERSIONED_BINARY_PATH}"
install -m 0755 "${TMP_DIR}/lazydocker" "${LATEST_BINARY_PATH}"

md5sum "${VERSIONED_BINARY_PATH}" | awk '{print $1}' > "${VERSIONED_BINARY_PATH}.md5"
md5sum "${LATEST_BINARY_PATH}" | awk '{print $1}' > "${LATEST_BINARY_PATH}.md5"

echo "Latest lazydocker synchronized: ${LATEST_TAG}"
