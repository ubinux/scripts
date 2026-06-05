#!/usr/bin/env bash
set -euo pipefail

# make_patched_source_archive.sh
#
# For a given Flatcar image directory, generate one patched source archive
# per package installed in the image (base OS + sysexts). Each archive
# contains:
#   - The corresponding ebuild directory from third_party
#   - The patched source tree produced by ebuild-<board> ... clean prepare
#
# Output layout:
#   <out>/
#     <repo>/<category>/<pkg-ver>.tar.gz
#       (tar contents: ebuilds/<repo>/<category>/<pkg>/... + work tree)

BOARD="arm64-usr"
IMAGE_DIR=""
OUT_ROOT="patched-archives"
THIRD_PARTY_ROOT="sdk_container/src/third_party"

usage() {
  cat <<EOF
Usage: $0 [--board <board>] [--image-dir <path>] [--out <dir>]

Defaults:
  board:     ${BOARD}
  image-dir: __build__/images/images/${BOARD}/latest
  out dir:   ${OUT_ROOT}

This script reads the base OS and sysext package lists from the given
image directory:
  - flatcar_production_image_packages.txt
  - rootfs-included-sysexts/*_packages.txt (optional)

For each 'cat/pkg-ver::repo', it:
  - Locates the ebuild under sdk_container/src/third_party/<repo>/<category>/
  - Runs: sudo ebuild-<board> <ebuild> clean prepare
  - Copies the patched source tree from:
      /build/<board>/var/tmp/portage/<category>/<pkg-ver>/work
  - Packs ebuilds + patched sources into:
      <out>/<repo>/<category>/<pkg-ver>.tar.gz
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --board)
      BOARD="${2}"; shift 2;;
    --image-dir)
      IMAGE_DIR="${2}"; shift 2;;
    --out)
      OUT_ROOT="${2}"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown argument: ${1}" >&2
      usage
      exit 1;;
  esac
done

[[ -z "${IMAGE_DIR}" ]] && IMAGE_DIR="__build__/images/images/${BOARD}/latest"

BASE_PKGS_FILE="${IMAGE_DIR}/flatcar_production_image_packages.txt"
SYSEXT_PKGS_DIR="${IMAGE_DIR}/rootfs-included-sysexts"

if [[ ! -f "${BASE_PKGS_FILE}" ]]; then
  echo "ERROR: Base OS package list not found: ${BASE_PKGS_FILE}" >&2
  exit 1
fi

REPO_ROOT="$(pwd)"
OUT_ABS="${REPO_ROOT}/${OUT_ROOT}"

echo "[INFO] Board:        ${BOARD}"
echo "[INFO] Image dir:    ${IMAGE_DIR}"
echo "[INFO] Base pkgs:    ${BASE_PKGS_FILE}"
echo "[INFO] Sysext pkgs:  ${SYSEXT_PKGS_DIR} (if present)"
echo "[INFO] Output root:  ${OUT_ABS}"

mkdir -p "${OUT_ABS}"

# Expand atoms from a packages.txt file (cat/pkg-ver::repo)
expand_atoms_from_pkg_list() {
  local pkg_list_file="${1}"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    atom_with_repo="${line}"
    atom="${atom_with_repo%%::*}"
    repo="${atom_with_repo##*::}"
    process_atom "${atom}" "${repo}"
  done < "${pkg_list_file}"
}

process_atom() {
  local atom="${1}"   # cat/pkg-ver
  local repo="${2}"   # portage-stable, coreos-overlay, ...

  CURRENT_ATOM=$((CURRENT_ATOM + 1))
  local category="${atom%%/*}"
  local pkgver="${atom#*/}"

  # Locate ebuild directory
  local pkgdir=""
  local search_root="${THIRD_PARTY_ROOT}/${repo}/${category}"
  if [[ -d "${search_root}" ]]; then
    local found_pkg
    found_pkg=$(cd "${search_root}" && \
      find . -maxdepth 2 -mindepth 2 -name "${pkgver}.ebuild" \
        -printf '%h\n' 2>/dev/null | head -n 1 | sed 's#^\./##') || true
    if [[ -n "${found_pkg}" ]]; then
      pkgdir="${found_pkg#*/}"
    fi
  fi

  if [[ -z "${pkgdir}" ]]; then
    pkgdir="${pkgver%-*}"
  fi

  local ebuild_dir="${THIRD_PARTY_ROOT}/${repo}/${category}/${pkgdir}"
  if [[ ! -d "${ebuild_dir}" ]]; then
    echo "[WARN] ebuild dir not found: ${ebuild_dir} (atom: ${atom}::${repo}); skipping" >&2
    SKIP_COUNT=$((SKIP_COUNT + 1))
    return
  fi

  local ebuild_path
  ebuild_path=$(cd "${ebuild_dir}" && \
    find . -maxdepth 1 -mindepth 1 -name "${pkgver}.ebuild" -printf '%P\n' \
      2>/dev/null | head -n 1) || true

  if [[ -z "${ebuild_path}" ]]; then
    echo "[WARN] ebuild not found in ${ebuild_dir} for ${pkgver}; skipping" >&2
    SKIP_COUNT=$((SKIP_COUNT + 1))
    return
  fi

  local full_ebuild_path="${ebuild_dir}/${ebuild_path}"
  echo "[INFO] [${CURRENT_ATOM}/${TOTAL_ATOMS}] Processing atom: ${atom}::${repo} (ebuild: ${full_ebuild_path})" >&2

  local ebuild_cmd="ebuild-${BOARD}"
  if ! command -v "${ebuild_cmd}" >/dev/null 2>&1; then
    echo "ERROR: ${ebuild_cmd} not found in PATH; run inside the SDK container." >&2
    exit 1
  fi

  # clean + prepare
  sudo -E "${ebuild_cmd}" "${full_ebuild_path}" clean prepare || {
    echo "[WARN] ebuild prepare failed for ${atom}::${repo}; skipping" >&2
    SKIP_COUNT=$((SKIP_COUNT + 1))
    return
  }

  local work_root="/build/${BOARD}/var/tmp/portage/${category}/${pkgver}/work"
  if [[ ! -d "${work_root}" ]]; then
    echo "[WARN] work directory not found for ${atom}: ${work_root}; skipping" >&2
    SKIP_COUNT=$((SKIP_COUNT + 1))
    return
  fi

  # Prepare per-package archive layout under a temp dir
  local tmp_pkg_root
  tmp_pkg_root="${OUT_ABS}/.tmp-${category}-${pkgver}"
  rm -rf "${tmp_pkg_root}"
  mkdir -p "${tmp_pkg_root}"

  # Copy ebuild tree
  mkdir -p "${tmp_pkg_root}/ebuilds/${repo}/${category}"
  cp -a "${ebuild_dir}" "${tmp_pkg_root}/ebuilds/${repo}/${category}/"

  # Copy patched sources
  mkdir -p "${tmp_pkg_root}/sources/${repo}/${category}/${pkgver}"
  cp -a "${work_root}/." "${tmp_pkg_root}/sources/${repo}/${category}/${pkgver}/"

  # Create per-package tar.gz
  local out_pkg_dir="${OUT_ABS}/${repo}/${category}"
  mkdir -p "${out_pkg_dir}"
  local out_pkg_tar="${out_pkg_dir}/${pkgver}.tar.gz"

  echo "[INFO] Creating package archive: ${out_pkg_tar}" >&2
  ( cd "${tmp_pkg_root}" && tar czf "${out_pkg_tar}" . )
  SUCCESS_COUNT=$((SUCCESS_COUNT + 1))

  # Clean temp
  rm -rf "${tmp_pkg_root}"
}

SUCCESS_COUNT=0
SKIP_COUNT=0
CURRENT_ATOM=0

# Pre-count total atoms for progress reporting
TOTAL_ATOMS=0
while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ -z "${line}" ]] || TOTAL_ATOMS=$((TOTAL_ATOMS + 1))
done < "${BASE_PKGS_FILE}"
if [[ -d "${SYSEXT_PKGS_DIR}" ]]; then
  for f in "${SYSEXT_PKGS_DIR}"/*_packages.txt; do
    [[ -f "${f}" ]] || continue
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -z "${line}" ]] || TOTAL_ATOMS=$((TOTAL_ATOMS + 1))
    done < "${f}"
  done
fi

# Process base OS packages
expand_atoms_from_pkg_list "${BASE_PKGS_FILE}"

# Process sysext packages if present
if [[ -d "${SYSEXT_PKGS_DIR}" ]]; then
  for f in "${SYSEXT_PKGS_DIR}"/*_packages.txt; do
    [[ -f "${f}" ]] || continue
    expand_atoms_from_pkg_list "${f}"
  done
fi

echo "[INFO] Done. Summary: ${CURRENT_ATOM} atoms processed, ${SUCCESS_COUNT} archives created, ${SKIP_COUNT} skipped." >&2
