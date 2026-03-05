#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARIES_DIR="${REPO_ROOT}/binaries"

mkdir -p "${BINARIES_DIR}"

FORCE_REBUILD="${FORCE_REBUILD:-false}"
MC_TAGS_API_URL="https://api.github.com/repos/MidnightCommander/mc/tags?per_page=100"
NCURSES_VERSION="6.5"
NCURSES_URL="https://invisible-mirror.net/archives/ncurses/ncurses-${NCURSES_VERSION}.tar.gz"

retry() {
  local attempts="$1"
  local delay_seconds="$2"
  shift 2

  local i
  for i in $(seq 1 "${attempts}"); do
    if "$@"; then
      return 0
    fi

    if [[ "${i}" -lt "${attempts}" ]]; then
      echo "Command failed (attempt ${i}/${attempts}): $*"
      echo "Retrying in ${delay_seconds}s..."
      sleep "${delay_seconds}"
    fi
  done

  return 1
}

LATEST_TAG_RAW="$(retry 5 10 curl -fsSL "${MC_TAGS_API_URL}" | python3 -c 'import json,re,sys
tags=json.load(sys.stdin)
stable=[t["name"] for t in tags if re.fullmatch(r"\d+\.\d+\.\d+", t.get("name",""))]
print(stable[0] if stable else "")')"

if [[ -z "${LATEST_TAG_RAW}" ]]; then
  echo "Could not resolve latest mc tag from GitHub tags."
  exit 1
fi

LATEST_VERSION="${LATEST_TAG_RAW#v}"
LATEST_VERSION="${LATEST_VERSION#mc-}"
LATEST_TAG="v${LATEST_VERSION}"

VERSIONED_BINARY_PATH="${BINARIES_DIR}/mc.${LATEST_TAG}"
LATEST_BINARY_PATH="${BINARIES_DIR}/mc.latest"

if [[ -f "${VERSIONED_BINARY_PATH}" && "${FORCE_REBUILD}" != "true" ]]; then
  install -m 0755 "${VERSIONED_BINARY_PATH}" "${LATEST_BINARY_PATH}"
  md5sum "${VERSIONED_BINARY_PATH}" | awk '{print $1}' > "${VERSIONED_BINARY_PATH}.md5"
  md5sum "${LATEST_BINARY_PATH}" | awk '{print $1}' > "${LATEST_BINARY_PATH}.md5"
  echo "Latest mc already compiled: ${LATEST_TAG}. Skipping download/build."
  exit 0
fi

if [[ -f "${VERSIONED_BINARY_PATH}" && "${FORCE_REBUILD}" == "true" ]]; then
  echo "Force rebuild enabled for mc ${LATEST_TAG}."
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

NCURSES_ARCHIVE_PATH="${TMP_DIR}/ncurses.tar.gz"
NCURSES_SRC_DIR="${TMP_DIR}/ncurses-src"
NCURSES_INSTALL_PREFIX="${TMP_DIR}/ncurses-static"

retry 5 10 curl -fL "${NCURSES_URL}" -o "${NCURSES_ARCHIVE_PATH}"
tar -xzf "${NCURSES_ARCHIVE_PATH}" -C "${TMP_DIR}"
mv "${TMP_DIR}/ncurses-${NCURSES_VERSION}" "${NCURSES_SRC_DIR}"

pushd "${NCURSES_SRC_DIR}" > /dev/null
./configure \
  --prefix="${NCURSES_INSTALL_PREFIX}" \
  --with-shared=no \
  --with-normal \
  --with-termlib \
  --with-default-terminfo-dir=/usr/share/terminfo \
  --with-terminfo-dirs=/usr/lib/terminfo:/usr/lib64/terminfo:/usr/share/terminfo:/etc/terminfo:/lib/terminfo \
  --without-debug \
  --without-ada \
  --enable-widec
make -j"$(nproc)"
make install
popd > /dev/null

# Create ncurses.pc alias so mc configure finds ncursesw under the generic name.
ln -sf "${NCURSES_INSTALL_PREFIX}/lib/pkgconfig/ncursesw.pc" \
        "${NCURSES_INSTALL_PREFIX}/lib/pkgconfig/ncurses.pc"

ARCHIVE_PATH="${TMP_DIR}/mc.tar"
ASSET_URL="https://api.github.com/repos/MidnightCommander/mc/tarball/refs/tags/${LATEST_TAG_RAW}"

retry 5 10 curl -fL "${ASSET_URL}" -o "${ARCHIVE_PATH}"
tar -xf "${ARCHIVE_PATH}" -C "${TMP_DIR}"

SRC_DIR="$(find "${TMP_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'MidnightCommander-*' | head -n 1)"
if [[ -z "${SRC_DIR}" || ! -d "${SRC_DIR}" ]]; then
  echo "Could not find extracted mc source directory."
  exit 1
fi

pushd "${SRC_DIR}" > /dev/null

if [[ ! -f "${SRC_DIR}/configure" ]]; then
  if [[ -f "${SRC_DIR}/autogen.sh" ]]; then
    bash ./autogen.sh
  else
    echo "Missing configure and autogen.sh in mc source directory."
    exit 1
  fi
fi

export PKG_CONFIG_PATH="${NCURSES_INSTALL_PREFIX}/lib/pkgconfig"
export CPPFLAGS="-I${NCURSES_INSTALL_PREFIX}/include/ncursesw"
export LDFLAGS="-L${NCURSES_INSTALL_PREFIX}/lib"
export LIBS="-lm"
# Pass ncurses flags directly so configure skips its own pkg-config detection.
export NCURSES_CFLAGS="-I${NCURSES_INSTALL_PREFIX}/include/ncursesw"
export NCURSES_LIBS="-L${NCURSES_INSTALL_PREFIX}/lib -lncursesw"

./configure \
  --without-x \
  --without-gpm \
  --disable-mouse \
  --with-screen=ncursesw

# Force static ncurses/tinfo archives to avoid runtime ABI mismatch on Flatcar.
sed -i \
  -e "s#-lncursesw -ltinfo#${NCURSES_INSTALL_PREFIX}/lib/libncursesw.a ${NCURSES_INSTALL_PREFIX}/lib/libtinfow.a#g" \
  -e "s#-lncursesw#${NCURSES_INSTALL_PREFIX}/lib/libncursesw.a ${NCURSES_INSTALL_PREFIX}/lib/libtinfow.a#g" \
  Makefile

make -j"$(nproc)"
popd > /dev/null

if [[ ! -f "${SRC_DIR}/src/mc" ]]; then
  echo "Build finished but mc binary is missing."
  exit 1
fi

install -m 0755 "${SRC_DIR}/src/mc" "${VERSIONED_BINARY_PATH}"
install -m 0755 "${SRC_DIR}/src/mc" "${LATEST_BINARY_PATH}"

md5sum "${VERSIONED_BINARY_PATH}" | awk '{print $1}' > "${VERSIONED_BINARY_PATH}.md5"
md5sum "${LATEST_BINARY_PATH}" | awk '{print $1}' > "${LATEST_BINARY_PATH}.md5"
