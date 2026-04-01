#!/usr/bin/env bash
#
# build-clab-sonic-onie.sh
#
# Recreates the internal Jenkins CLAB_SONIC flow: ONIE qcow2 + sonic-cisco-8000.bin,
# SDK-only injection via bake-and-build.sh, then docker build of the CLAB SONIC image.
# This does NOT run create-docker.py / ISO bake (modifyIso).
#
# Prerequisites:
#   - Docker, and an ovxr-dev image that contains /opt/ovxr-release (scripts + docker/kne + packages layout).
#   - Typical image: containers.cisco.com/.../ovxr-dev:... or your local ovxr-dev-*:latest
#   - Host: /dev/kvm; script uses --group-add $(stat -c '%g' /dev/kvm) like the bake fixes.
#
# Usage:
#   export SONIC_BIN=/path/to/sonic-cisco-8000.bin
#   export ONIE_QCOW2=/path/to/onie-recovery-x86_64-cisco_8000-r0.qcow2
#   export SDK=sdkdc-24.10.2230.6   # must match your EFT / NGDP drop
#   ./build-clab-sonic-onie.sh
#
# Or pass overrides on the command line (see below).
#
set -euo pipefail

usage() {
  sed -n '1,80p' "$0" | sed -n '/^#/p' | head -n 25
  echo ""
  echo "Options (env vars):"
  echo "  OVXR_DEV_IMAGE     Docker image for build env (default: see script)"
  echo "  CONTAINER_NAME     Running container name (default: clab-sonic-build)"
  echo "  SONIC_BIN          Path to sonic-cisco-8000.bin (required)"
  echo "  ONIE_QCOW2         Path to onie-recovery-x86_64-cisco_8000-r0.qcow2 (required)"
  echo "  SDK                e.g. sdkdc-24.10.2230.6 (required)"
  echo "  DOCKER_TAG         Resulting image tag (default: c8000-clab-sonic:local)"
  echo "  HOST_OUTPUT_DIR    Host dir mounted at /host_dump_dir (artifacts, default: ./clab-build-out)"
  echo "  OVXR_ROOT          Path inside container (default: /opt/ovxr-release)"
  echo "  PLATFORM           e.g. 8122-64EHF-O — patches packages/integration/clab/8000sonic.yaml"
  echo "  SDK_DEB            Host path to vxr2-ngdp-*sdkdc-*.deb (use with purge for offline Jenkins-like SDK swap)"
  echo "  EFT_ROOT           Host path to EFT tree containing docker/kne (Dockerfile8000sonic_*). Auto-inferred from --sonic-bin if possible."
  echo "  REUSE_CONTAINER    If set to 1, do not docker rm/run; use existing CONTAINER_NAME"
  exit "${1:-0}"
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage 0

# --- Defaults (override with environment) ---
: "${OVXR_DEV_IMAGE:=containers.cisco.com/wmyint/ovxr-dev:stable}"
: "${CONTAINER_NAME:=clab-sonic-build}"
: "${DOCKER_TAG:=c8000-clab-sonic:local}"
: "${HOST_OUTPUT_DIR:=$(pwd)/clab-build-out}"
: "${OVXR_ROOT:=/opt/ovxr-release}"
: "${REUSE_CONTAINER:=0}"

SONIC_BIN="${SONIC_BIN:-}"
ONIE_QCOW2="${ONIE_QCOW2:-}"
SDK="${SDK:-}"
PLATFORM="${PLATFORM:-}"
SDK_DEB="${SDK_DEB:-}"
EFT_ROOT="${EFT_ROOT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sonic-bin) SONIC_BIN="$2"; shift 2 ;;
    --onie-qcow2) ONIE_QCOW2="$2"; shift 2 ;;
    --sdk) SDK="$2"; shift 2 ;;
    --sdk-deb) SDK_DEB="$2"; shift 2 ;;
    --eft-root) EFT_ROOT="$2"; shift 2 ;;
    --platform) PLATFORM="$2"; shift 2 ;;
    --image) OVXR_DEV_IMAGE="$2"; shift 2 ;;
    --name) CONTAINER_NAME="$2"; shift 2 ;;
    --tag) DOCKER_TAG="$2"; shift 2 ;;
    --out) HOST_OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

[[ -z "$SONIC_BIN" || ! -f "$SONIC_BIN" ]] && { echo "ERROR: Set SONIC_BIN to sonic-cisco-8000.bin (existing file)." >&2; exit 1; }
[[ -z "$ONIE_QCOW2" || ! -f "$ONIE_QCOW2" ]] && { echo "ERROR: Set ONIE_QCOW2 to onie-recovery-...qcow2 (existing file)." >&2; exit 1; }
[[ -z "$SDK" ]] && { echo "ERROR: Set SDK (e.g. sdkdc-24.10.2230.6) to match your release." >&2; exit 1; }

mkdir -p "$HOST_OUTPUT_DIR"
HOST_OUTPUT_DIR="$(cd "$HOST_OUTPUT_DIR" && pwd -P)"

# Walk up from SONIC_BIN dir until we find docker/kne (same layout as full ovxr-release / EFT drop)
_resolve_eft_root() {
  local p
  p="$(dirname "$(realpath "$SONIC_BIN")")"
  while [[ "$p" != "/" ]]; do
    if [[ -d "${p}/docker/kne" ]]; then
      echo "$p"
      return 0
    fi
    p="$(dirname "$p")"
  done
  return 1
}

# Typical layout: .../<eft>/packages/images/8000/sonic/<bin> -> 4 dirnames from .../sonic == <eft>
_likely_eft_root_from_sonic_bin() {
  local p i
  p="$(dirname "$(realpath "$SONIC_BIN")")"
  for i in 1 2 3 4; do p="$(dirname "$p")"; done
  realpath "$p" 2>/dev/null || echo "$p"
}

if [[ -z "${EFT_ROOT}" ]]; then
  if EFT_ROOT="$(_resolve_eft_root)"; then
    EFT_ROOT="$(realpath "${EFT_ROOT}")"
  else
    EFT_ROOT=""
  fi
else
  EFT_ROOT="$(realpath "${EFT_ROOT}")"
fi

# Fail fast if standard EFT layout has packages/ but no docker/kne (incomplete tarball)
_LIKELY_="$(_likely_eft_root_from_sonic_bin)"
if [[ -z "${EFT_ROOT}" && -d "${_LIKELY_}/packages" && ! -d "${_LIKELY_}/docker/kne" ]]; then
  echo "ERROR: Incomplete EFT tree on this host."
  echo "      Found ${_LIKELY_}/packages but NOT ${_LIKELY_}/docker/kne"
  echo "      Copy docker/kne from a full ovxr-release / 8000 EFT bundle (same train as eft17), e.g.:"
  echo "        mkdir -p ${_LIKELY_}/docker && cp -a /path/to/full-release/docker/kne ${_LIKELY_}/docker/"
  echo "      Then re-run, or: --eft-root /path/that/contains/docker/kne"
  exit 1
fi

if [[ -n "${EFT_ROOT}" && ! -d "${EFT_ROOT}/docker/kne" ]]; then
  echo "ERROR: EFT_ROOT=${EFT_ROOT} does not contain docker/kne (Dockerfile8000sonic_*)."
  echo "      Fix the path or copy docker/kne from a full ovxr-release drop into that tree."
  exit 1
fi

IMAGES_DIR="${OVXR_ROOT}/packages/images"
DEBS_DIR="${OVXR_ROOT}/packages/debs"
BAKE_SCRIPT="${OVXR_ROOT}/scripts/bake-and-build/bake-and-build.sh"
CLAB_SCRIPT="${OVXR_ROOT}/scripts/clab/build_clab_generic_component.sh"

_KVM_GID=""
if [[ -e /dev/kvm ]]; then
  _KVM_GID="$(stat -c '%g' /dev/kvm 2>/dev/null || true)"
fi
_KVM_OPTS=(--device /dev/kvm)
[[ -n "${_KVM_GID}" ]] && _KVM_OPTS+=(--group-add "${_KVM_GID}")

echo "==> Configuration"
echo "    OVXR_DEV_IMAGE=$OVXR_DEV_IMAGE"
echo "    CONTAINER_NAME=$CONTAINER_NAME"
echo "    SONIC_BIN=$SONIC_BIN"
echo "    ONIE_QCOW2=$ONIE_QCOW2"
echo "    SDK=$SDK"
echo "    DOCKER_TAG=$DOCKER_TAG"
echo "    HOST_OUTPUT_DIR=$HOST_OUTPUT_DIR"
[[ -n "${PLATFORM}" ]] && echo "    PLATFORM=$PLATFORM"
[[ -n "${SDK_DEB}" ]] && echo "    SDK_DEB=$SDK_DEB"
[[ -n "${EFT_ROOT}" ]] && echo "    EFT_ROOT=$EFT_ROOT (docker/kne synced into container)"
echo ""

if [[ "${REUSE_CONTAINER}" != "1" ]]; then
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  echo "==> Starting ${OVXR_DEV_IMAGE} as ${CONTAINER_NAME}"
  # Match Jenkins: privileged + docker socket; add KVM for local builds
  docker run -d --privileged \
    "${_KVM_OPTS[@]}" \
    --security-opt seccomp=unconfined \
    --security-opt apparmor=unconfined \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${HOST_OUTPUT_DIR}:/host_dump_dir" \
    --name "${CONTAINER_NAME}" \
    --entrypoint /bin/bash \
    "${OVXR_DEV_IMAGE}" \
    -c "exec sleep infinity"
else
  docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1 || { echo "ERROR: container ${CONTAINER_NAME} not running"; exit 1; }
fi

if ! docker exec "${CONTAINER_NAME}" test -d "${OVXR_ROOT}"; then
  echo "ERROR: ${OVXR_ROOT} not found inside ${OVXR_DEV_IMAGE}."
  echo "      Set OVXR_ROOT if your image uses a different tree (inspect: docker run --rm --entrypoint ls ${OVXR_DEV_IMAGE} -la /opt)"
  exit 1
fi

echo "==> Ensuring ${IMAGES_DIR} and ${DEBS_DIR} exist in container"
docker exec "${CONTAINER_NAME}" sudo mkdir -p "${IMAGES_DIR}" "${DEBS_DIR}"

if [[ -n "${EFT_ROOT}" && -d "${EFT_ROOT}/docker/kne" ]]; then
  echo "==> Syncing ${EFT_ROOT}/docker/kne -> ${CONTAINER_NAME}:${OVXR_ROOT}/docker/kne"
  docker exec "${CONTAINER_NAME}" sudo mkdir -p "${OVXR_ROOT}/docker/kne"
  docker cp "${EFT_ROOT}/docker/kne/." "${CONTAINER_NAME}:${OVXR_ROOT}/docker/kne/"
else
  _w="${EFT_ROOT:-${_LIKELY_}}"
  echo "WARN: No host directory ${_w}/docker/kne — CLAB build needs Dockerfile8000sonic_* there."
  echo "      Add docker/kne under your EFT root (see ERROR above if packages/ exists without docker/)."
fi

echo "==> Copying SONIC binary into container"
docker cp "${SONIC_BIN}" "${CONTAINER_NAME}:${IMAGES_DIR}/sonic-cisco-8000.bin"

if [[ -n "${SDK_DEB}" ]]; then
  [[ -f "${SDK_DEB}" ]] || { echo "ERROR: SDK_DEB not a file: ${SDK_DEB}" >&2; exit 1; }
  echo "==> Copying SDK .deb into container (for offline install after optional purge)"
  docker cp "${SDK_DEB}" "${CONTAINER_NAME}:${DEBS_DIR}/"
fi

echo "==> SDK-only bake-and-build (insidedocker)"
# Default: force_sdk_only only — does NOT purge other SDKs, so no wget to vxr-nfs (works when the image already has the right NGDP).
# With --sdk-deb: also keep_force_sdk_only (Jenkins-like purge) + bake-and-build installs the pre-staged .deb from ${DEBS_DIR}.
_BAKE_ARGS_=(--forcesdk "${SDK}" insidedocker force_sdk_only)
if [[ -n "${SDK_DEB}" ]]; then
  _BAKE_ARGS_+=(keep_force_sdk_only)
fi
docker exec "${CONTAINER_NAME}" sudo -E "${BAKE_SCRIPT}" "${_BAKE_ARGS_[@]}" \
  || { echo "ERROR: bake-and-build SDK step failed"; exit 1; }

echo "==> Copying ONIE qcow2 into container"
# Use explicit dest filename — `docker cp ... container:dir/` requires dir to exist; full file path is more reliable
docker cp "${ONIE_QCOW2}" "${CONTAINER_NAME}:${IMAGES_DIR}/$(basename "${ONIE_QCOW2}")"

_SONIC_YAML_="${OVXR_ROOT}/packages/integration/clab/8000sonic.yaml"
_patch_sonic_yaml_() {
  local f="${_SONIC_YAML_}"
  docker exec "${CONTAINER_NAME}" sudo sed -i "s/\\['LC_TYPE'\\]/['${PLATFORM}']/g" "$f"
  docker exec "${CONTAINER_NAME}" sudo sed -i "s/\\[LC_TYPE\\]/['${PLATFORM}']/g" "$f"
  docker exec "${CONTAINER_NAME}" sudo sed -i "s/_PLAT_TYPE_FILLER_/${PLATFORM}/g" "$f"
  docker exec "${CONTAINER_NAME}" sudo sed -i "s/'LC_TYPE'/'${PLATFORM}'/g" "$f"
}
if [[ -n "${PLATFORM}" ]]; then
  echo "==> Patching CLAB template for platform ${PLATFORM} (${_SONIC_YAML_})"
  if docker exec "${CONTAINER_NAME}" test -f "${_SONIC_YAML_}"; then
    _patch_sonic_yaml_ || { echo "ERROR: failed to patch 8000sonic.yaml"; exit 1; }
  else
    echo "WARN: ${_SONIC_YAML_} not in container; skipping platform patch."
  fi
fi

if ! docker exec "${CONTAINER_NAME}" test -d "${OVXR_ROOT}/docker/kne"; then
  echo "ERROR: ${OVXR_ROOT}/docker/kne is missing inside the container."
  echo "      The ovxr-dev image often omits it. Copy from your full EFT checkout, e.g.:"
  echo "        --eft-root /home/cisco/images/8000-eft17.0"
  echo "      (that path must contain docker/kne/Dockerfile8000sonic_ovxrdev or _cached)"
  exit 1
fi

echo "==> Building CLAB SONIC image (${DOCKER_TAG})"
if docker exec "${CONTAINER_NAME}" test -f "${CLAB_SCRIPT}"; then
  docker exec "${CONTAINER_NAME}" sudo -E "${CLAB_SCRIPT}" -s -o /host_dump_dir/ "${DOCKER_TAG}" \
    || { echo "ERROR: build_clab_generic_component.sh failed"; exit 1; }
else
  echo "WARN: ${CLAB_SCRIPT} not found inside the image."
  echo "      Your ovxr-dev image may use a different layout. Try manually inside the container:"
  echo "        ls -la ${OVXR_ROOT}/scripts/clab/"
  echo "        ls -la ${OVXR_ROOT}/docker/kne/"
  echo "      Jenkins used: build_docker_image.sh -c <tag> docker/kne/Dockerfile8000sonic_cached"
  echo "      Container kept running: docker exec -it ${CONTAINER_NAME} bash"
  exit 2
fi

echo ""
echo "==> Done. Image tag: ${DOCKER_TAG}"
echo "    To export: docker save '${DOCKER_TAG}' | gzip > ${HOST_OUTPUT_DIR}/$(echo "${DOCKER_TAG}" | tr ':/' '_').tar.gz"
echo "    To stop:   docker stop ${CONTAINER_NAME} && docker rm ${CONTAINER_NAME}"
