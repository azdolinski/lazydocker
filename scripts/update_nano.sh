#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARIES_DIR="${REPO_ROOT}/binaries"

mkdir -p "${BINARIES_DIR}"

NANO_GIT_URL="https://git.savannah.gnu.org/git/nano.git"
NCURSES_VERSION="6.5"
NCURSES_URL="https://invisible-mirror.net/archives/ncurses/ncurses-${NCURSES_VERSION}.tar.gz"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

LATEST_TAG_RAW="$(git ls-remote --tags --refs "${NANO_GIT_URL}" | awk '{print $2}' | sed 's#refs/tags/##' | sort -V | tail -n 1)"

if [[ -z "${LATEST_TAG_RAW}" ]]; then
  echo "Could not resolve latest nano tag from Savannah Git."
  exit 1
fi

if [[ "${LATEST_TAG_RAW}" == v* ]]; then
  LATEST_TAG="${LATEST_TAG_RAW}"
else
  LATEST_TAG="v${LATEST_TAG_RAW}"
fi

VERSIONED_BINARY_PATH="${BINARIES_DIR}/nano.${LATEST_TAG}"
LATEST_BINARY_PATH="${BINARIES_DIR}/nano.latest"

if [[ -f "${VERSIONED_BINARY_PATH}" ]]; then
  install -m 0755 "${VERSIONED_BINARY_PATH}" "${LATEST_BINARY_PATH}"
  md5sum "${VERSIONED_BINARY_PATH}" | awk '{print $1}' > "${VERSIONED_BINARY_PATH}.md5"
  md5sum "${LATEST_BINARY_PATH}" | awk '{print $1}' > "${LATEST_BINARY_PATH}.md5"
  echo "Latest nano already compiled: ${LATEST_TAG}. Skipping download/build."
  exit 0
fi

SRC_DIR="${TMP_DIR}/nano-src"
git clone --depth 1 --branch "${LATEST_TAG_RAW}" "${NANO_GIT_URL}" "${SRC_DIR}"

NCURSES_ARCHIVE_PATH="${TMP_DIR}/ncurses.tar.gz"
NCURSES_SRC_DIR="${TMP_DIR}/ncurses-src"
NCURSES_INSTALL_PREFIX="${TMP_DIR}/ncurses-static"

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

pushd "${SRC_DIR}" > /dev/null
./autogen.sh

if [[ ! -f "${SRC_DIR}/configure" ]]; then
  echo "nano autogen step did not produce configure. Check build dependencies (autopoint/gettext)."
  exit 1
fi

export CPPFLAGS="-I${NCURSES_INSTALL_PREFIX}/include/ncursesw"
export LDFLAGS="-L${NCURSES_INSTALL_PREFIX}/lib -static"
export LIBS="-ltinfow -lncursesw"

./configure \
  --disable-shared \
  --enable-static \
  --disable-nls
make -j"$(nproc)"
popd > /dev/null

if [[ ! -f "${SRC_DIR}/src/nano" ]]; then
  echo "Build finished but nano binary is missing."
  exit 1
fi

if ldd "${SRC_DIR}/src/nano" 2>&1 | grep -vq 'not a dynamic executable'; then
  echo "nano binary is not fully static."
  ldd "${SRC_DIR}/src/nano" || true
  exit 1
fi

install -m 0755 "${SRC_DIR}/src/nano" "${VERSIONED_BINARY_PATH}"
install -m 0755 "${SRC_DIR}/src/nano" "${LATEST_BINARY_PATH}"

md5sum "${VERSIONED_BINARY_PATH}" | awk '{print $1}' > "${VERSIONED_BINARY_PATH}.md5"
md5sum "${LATEST_BINARY_PATH}" | awk '{print $1}' > "${LATEST_BINARY_PATH}.md5"

echo "Latest nano synchronized: ${LATEST_TAG}"
