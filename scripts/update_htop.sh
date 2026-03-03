#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARIES_DIR="${REPO_ROOT}/binaries"

mkdir -p "${BINARIES_DIR}"

API_URL="https://api.github.com/repos/htop-dev/htop/releases/latest"
NCURSES_VERSION="6.5"
NCURSES_URL="https://invisible-mirror.net/archives/ncurses/ncurses-${NCURSES_VERSION}.tar.gz"
LATEST_TAG_RAW="$(curl -fsSL "${API_URL}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"

if [[ -z "${LATEST_TAG_RAW}" || "${LATEST_TAG_RAW}" == "null" ]]; then
  echo "Could not resolve latest htop tag from GitHub API."
  exit 1
fi

LATEST_TAG_VERSION="${LATEST_TAG_RAW#v}"
LATEST_TAG="v${LATEST_TAG_VERSION}"
ASSET_URL="https://github.com/htop-dev/htop/releases/download/${LATEST_TAG_VERSION}/htop-${LATEST_TAG_VERSION}.tar.xz"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ARCHIVE_PATH="${TMP_DIR}/htop.tar.xz"
NCURSES_ARCHIVE_PATH="${TMP_DIR}/ncurses.tar.gz"
NCURSES_SRC_DIR="${TMP_DIR}/ncurses-src"
NCURSES_INSTALL_PREFIX="${TMP_DIR}/ncurses-static"

curl -fL "${ASSET_URL}" -o "${ARCHIVE_PATH}"
tar -xJf "${ARCHIVE_PATH}" -C "${TMP_DIR}"

curl -fL "${NCURSES_URL}" -o "${NCURSES_ARCHIVE_PATH}"
tar -xzf "${NCURSES_ARCHIVE_PATH}" -C "${TMP_DIR}"
mv "${TMP_DIR}/ncurses-${NCURSES_VERSION}" "${NCURSES_SRC_DIR}"

pushd "${NCURSES_SRC_DIR}" > /dev/null
./configure \
  --prefix="${NCURSES_INSTALL_PREFIX}" \
  --with-shared=no \
  --with-normal \
  --with-termlib \
  --without-debug \
  --without-ada \
  --enable-widec
make -j"$(nproc)"
make install
popd > /dev/null

SRC_DIR="$(find "${TMP_DIR}" -maxdepth 1 -type d -name 'htop-*' | head -n 1)"
if [[ -z "${SRC_DIR}" ]]; then
  echo "Could not find extracted htop source directory."
  exit 1
fi

pushd "${SRC_DIR}" > /dev/null
export CPPFLAGS="-I${NCURSES_INSTALL_PREFIX}/include/ncursesw"
export LDFLAGS="-L${NCURSES_INSTALL_PREFIX}/lib -static"
export LIBS="-ltinfow -lncursesw"

./configure \
  --disable-shared \
  --enable-static
make -j"$(nproc)"
popd > /dev/null

if [[ ! -f "${SRC_DIR}/htop" ]]; then
  echo "Build finished but htop binary is missing."
  exit 1
fi

if ldd "${SRC_DIR}/htop" 2>&1 | grep -vq 'not a dynamic executable'; then
  echo "htop binary is not fully static."
  ldd "${SRC_DIR}/htop" || true
  exit 1
fi

VERSIONED_BINARY_PATH="${BINARIES_DIR}/htop.${LATEST_TAG}"
LATEST_BINARY_PATH="${BINARIES_DIR}/htop.latest"

install -m 0755 "${SRC_DIR}/htop" "${VERSIONED_BINARY_PATH}"
install -m 0755 "${SRC_DIR}/htop" "${LATEST_BINARY_PATH}"

md5sum "${VERSIONED_BINARY_PATH}" | awk '{print $1}' > "${VERSIONED_BINARY_PATH}.md5"
md5sum "${LATEST_BINARY_PATH}" | awk '{print $1}' > "${LATEST_BINARY_PATH}.md5"

echo "Latest htop synchronized: ${LATEST_TAG}"
