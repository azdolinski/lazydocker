#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARIES_DIR="${REPO_ROOT}/binaries"

mkdir -p "${BINARIES_DIR}"

FORCE_REBUILD="${FORCE_REBUILD:-false}"

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

MC_TAGS_API_URL="https://api.github.com/repos/MidnightCommander/mc/tags?per_page=100"
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

ARCHIVE_PATH="${TMP_DIR}/mc.tar"
ASSET_URL="https://api.github.com/repos/MidnightCommander/mc/tarball/refs/tags/${LATEST_TAG_RAW}"

retry 5 10 curl -fL "${ASSET_URL}" -o "${ARCHIVE_PATH}"
tar -xf "${ARCHIVE_PATH}" -C "${TMP_DIR}"

SRC_DIR="$(find "${TMP_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [[ -z "${SRC_DIR}" ]]; then
  echo "Could not find extracted mc source directory."
  exit 1
fi

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Could not find extracted mc source directory: ${SRC_DIR}"
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

GPM_STATIC_LIB=""
if [[ -f "/usr/lib/x86_64-linux-gnu/libgpm.a" ]]; then
  GPM_STATIC_LIB="/usr/lib/x86_64-linux-gnu/libgpm.a"
elif [[ -f "/usr/lib64/libgpm.a" ]]; then
  GPM_STATIC_LIB="/usr/lib64/libgpm.a"
elif [[ -f "/usr/lib/libgpm.a" ]]; then
  GPM_STATIC_LIB="/usr/lib/libgpm.a"
fi

if [[ -z "${GPM_STATIC_LIB}" ]]; then
  echo "Could not find static libgpm.a. Install gpm static development package."
  exit 1
fi

export LIBS="${GPM_STATIC_LIB} ${LIBS:-}"

./configure \
  --without-x \
  --with-gpm-mouse \
  --with-screen=ncurses

# Keep gpm support enabled, but avoid runtime dependency on libgpm.so.2.
sed -i \
  -e 's#-lgpm#-Wl,-Bstatic -lgpm -Wl,-Bdynamic#g' \
  Makefile src/Makefile lib/Makefile 2>/dev/null || true

# Autotools/libtool may still append dynamic -lgpm later in nested Makefiles.
# Remove dynamic gpm flags and rely on explicit static libgpm.a injected via LIBS.
while IFS= read -r file; do
  sed -i -E 's#(^|[[:space:]])-lgpm([[:space:]]|$)# #g' "${file}"
done < <(find . -type f \( -name 'Makefile' -o -name '*.la' \))

make -j"$(nproc)"

STAGE_DIR="${TMP_DIR}/mc-stage"
make install DESTDIR="${STAGE_DIR}"
popd > /dev/null

STAGED_MC_BIN="${STAGE_DIR}/usr/local/bin/mc"

if [[ ! -f "${STAGED_MC_BIN}" ]]; then
  echo "Build finished but staged mc binary is missing."
  exit 1
fi

if ldd "${STAGED_MC_BIN}" 2>&1 | grep -q 'libgpm'; then
  echo "mc binary is still linked to dynamic libgpm."
  ldd "${STAGED_MC_BIN}" || true
  exit 1
fi

LAUNCHER_STUB_PATH="${TMP_DIR}/mc-launcher.sh"
cat > "${LAUNCHER_STUB_PATH}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SELF_PATH="$(readlink -f "$0")"
PAYLOAD_START_LINE="$(awk '/^__MC_PAYLOAD_BELOW__$/ {print NR + 1; exit 0; }' "${SELF_PATH}")"

if [[ -z "${PAYLOAD_START_LINE}" ]]; then
  echo "Corrupted mc bundle: payload marker not found."
  exit 1
fi

RUN_DIR="${TMPDIR:-/tmp}/mc-bundle-$(id -u)-$(basename "${SELF_PATH}")"
PREFIX_DIR="${RUN_DIR}/usr/local"

if [[ ! -x "${PREFIX_DIR}/bin/mc" ]]; then
  rm -rf "${RUN_DIR}"
  mkdir -p "${RUN_DIR}"
  tail -n +"${PAYLOAD_START_LINE}" "${SELF_PATH}" | tar -xzf - -C "${RUN_DIR}"
fi

if [[ -f "${PREFIX_DIR}/etc/mc/sfs.ini" && ! -f "${PREFIX_DIR}/share/mc/sfs.ini" ]]; then
  ln -sf "${PREFIX_DIR}/etc/mc/sfs.ini" "${PREFIX_DIR}/share/mc/sfs.ini"
fi

# mc still uses hardcoded /usr/local paths for some resources.
# If writable, map them to extracted bundle locations.
if [[ -w "/usr/local" ]]; then
  mkdir -p "/usr/local/libexec" "/usr/local/etc"

  if [[ ! -e "/usr/local/libexec/mc" ]]; then
    ln -s "${PREFIX_DIR}/libexec/mc" "/usr/local/libexec/mc" || true
  fi

  if [[ ! -e "/usr/local/etc/mc" ]]; then
    ln -s "${PREFIX_DIR}/etc/mc" "/usr/local/etc/mc" || true
  fi
fi

export MC_DATADIR="${PREFIX_DIR}/share/mc"
export MC_LIBDIR="${PREFIX_DIR}/libexec/mc"
export MC_EXTFS_DIR="${PREFIX_DIR}/libexec/mc/extfs.d"
export MC_HOME="${HOME:-${RUN_DIR}}/.mc"

exec "${PREFIX_DIR}/bin/mc" "$@"
EOF

{
  cat "${LAUNCHER_STUB_PATH}"
  echo "__MC_PAYLOAD_BELOW__"
  tar -czf - -C "${STAGE_DIR}" .
} > "${VERSIONED_BINARY_PATH}"

install -m 0755 "${VERSIONED_BINARY_PATH}" "${LATEST_BINARY_PATH}"
chmod 0755 "${VERSIONED_BINARY_PATH}"

md5sum "${VERSIONED_BINARY_PATH}" | awk '{print $1}' > "${VERSIONED_BINARY_PATH}.md5"
md5sum "${LATEST_BINARY_PATH}" | awk '{print $1}' > "${LATEST_BINARY_PATH}.md5"
