#!/bin/bash
# bake_iso_and_build_ovxr_component.sh
# Universal script to bake ISO and build ovxr component for clab, kne, cml, etc.
# Usage:
#   ./bake_iso_and_build_ovxr_component.sh -t <target> [target-specific-args]
#
# Example:
#   ./bake_iso_and_build_ovxr_component.sh -t clab -i /path/to/iso -p plat -o mydocker:latest
#   ./bake_iso_and_build_ovxr_component.sh -t kne  -i /path/to/iso -p plat -o mydocker:latest

set -e
[[ ${VERBOSE} ]] && set -x

# --- Common Setup ---
_CUR_FILE_DIR_="$(cd "$(dirname "$0")"; pwd -P)"
_FILENAME_="$(basename -- "${0}")"
_CUR_FILE_PATH_="${_CUR_FILE_DIR_}/${_FILENAME_}"
HN="$(hostname | sed 's/.cisco.com//g')"
FULL_LOG=""

# --- Parse Target ---
TARGET=""
while getopts "t:h" opt; do
  case $opt in
    t)
      TARGET="${OPTARG}"
      ;;
    h)
      echo "Usage: $0 -t <target> [target-specific-args]"
      echo "Targets: clab, kne, cml, eve_ng, ..."
      exit 0
      ;;
    *)
      echo "Unknown option: $opt"; exit 1
      ;;
  esac
done
shift $((OPTIND-1))

if [[ -z "$TARGET" ]]; then
  echo "Error: Must specify -t <target> (e.g. clab, kne, cml, eve_ng)" >&2
  exit 1
fi

# --- Target-specific setup ---
case "$TARGET" in
  clab|kne|cml|eve_ng)
    _component_folder_="${_CUR_FILE_DIR_}"
    _build_component_script_="${_component_folder_}/build_ovxr_component.sh"
    _allowed_plats_file_="${_CUR_FILE_DIR_}/../../${TARGET}/allowed_plats"
    _allowed_plats_=$(< ${_allowed_plats_file_})
    _build_folder_="$(realpath ${_CUR_FILE_DIR_}/../../../build)"
    _docker_folder_="$(realpath ${_CUR_FILE_DIR_}/../../../docker)"
    _ovxr_dev_df_="${_docker_folder_}/Dockerfile.dev"
    _docker_build_script_="${_CUR_FILE_DIR_}/../../build_docker_image.sh"
    _packages_folder_="$(realpath ${_CUR_FILE_DIR_}/../../../packages/)"
    _images_folder_="${_packages_folder_}/images/8000/${TARGET}"
    mkdir -p ${_images_folder_}
    ;;
  *)
    echo "Unsupported target: $TARGET" >&2
    exit 1
    ;;
esac

# --- Parse target-specific arguments ---
ISO_TO_BAKE=""; PLAT_TO_BUILD=""; DOCKER_NAME=""; NO_BAKE=1; OUTSIDE_OVXR_DEV=""
while getopts "i:p:o:nh" opt; do
  case $opt in
    i)
      ISO_TO_BAKE="${OPTARG}"
      [ ! -e ${ISO_TO_BAKE} ] && echo "${ISO_TO_BAKE} is not a valid path" && exit 1
      ISO_TO_BAKE="$(realpath ${OPTARG})"
      ISO_TO_BAKE_NAME=$(basename -- ${ISO_TO_BAKE})
      ISO_TO_BAKE_FOLDER="$(cd \"$(dirname \"${ISO_TO_BAKE}\")\"; pwd -P)"
      ;;
    p)
      PLAT_TO_BUILD="${OPTARG}"
      grep -q ${PLAT_TO_BUILD} <<< "${_allowed_plats_}" || { echo "Invalid plat: ${PLAT_TO_BUILD}"; exit 1; }
      export PLAT_BUILD=${PLAT_TO_BUILD}
      ;;
    o)
      DOCKER_NAME="${OPTARG}"
      ;;
    n)
      NO_BAKE=0
      ;;
    h)
      echo "See help above"; exit 0
      ;;
    *)
      echo "Unknown option: $opt"; exit 1
      ;;
  esac
done
shift $((OPTIND-1))

if [[ -z "$DOCKER_NAME" ]]; then
  echo "Error: Must specify docker image name with -o <docker_name>" >&2
  exit 1
fi

_cp_cmd_=$(which cp)

# Prechecks
[ ! ${PLAT_TO_BUILD} ] && echo "Please specify platform to build with -p" && exit 1
[ ! -e ${_ovxr_dev_df_} ] && echo "Missing ${_ovxr_dev_df_} It should be included with the release" && exit 1
[ ! -e ${_docker_build_script_} ] && echo "Missing ${_docker_build_script_} It should be included with the release" && exit 1
[ ! -e ${_build_component_script_} ] && echo "Missing ${_build_component_script_} It should be included with the release" && exit 1

if [[ ( ${OUTSIDE_OVXR_DEV} ) && ( ${NO_BAKE} -eq 1 ) ]]; then
  _ovxr_dev_docker_name_="ovxr-dev:latest"
  docker image inspect ${_ovxr_dev_docker_name_} > /dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    echo "Creating ovxr-dev dockerimage since it was not found - which is required to create the qcow2 disk"
    sleep 5s
    _cmd_="${_docker_build_script_} ${_ovxr_dev_docker_name_} ${_ovxr_dev_df_}"
    echo "cmd to build ovxr-dev:latest: $ ${_cmd_}"
    eval ${_cmd_}
    [ $? -ne 0 ] && exit 1
  else
    echo "Using the existing ${_ovxr_dev_docker_name_}"
  fi
  _a_=1
  _bake_folder_="${_build_folder_}/bakeme_${_a_}"
  while true; do
    [ ! -e ${_bake_folder_} ] && mkdir -p ${_bake_folder_} && break
    ((_a_++))
    _bake_folder_="${_bake_folder_::-1}""${_a_}"
  done
  echo "bake folder: ${_bake_folder_}"
  _iso_drop_path_="${_bake_folder_}/8000-x64.iso"
  echo "copying ${ISO_TO_BAKE} to ${_iso_drop_path_}"
  ${_cp_cmd_} ${ISO_TO_BAKE} ${_iso_drop_path_}
  [ $? -ne 0 ] && exit 1
else
  echo "NOTICE: -o was not passed in so assuming we are running inside an ovxr-dev container. If this is not the case, exit immediately and call again with -o"
  sleep 4s
fi

if [[ ! ${OUTSIDE_OVXR_DEV} ]]; then
  _bake_folder_="/nobackup/bake"
  _iso_drop_path_=""
  for f in $(realpath $(find "${_bake_folder_}"/* 2>/dev/null) 2>/dev/null); do
    _ext_="${f##*.}"
    if [[ "${_ext_}" == "iso" ]]; then
      _iso_drop_path_=${f}
      break
    fi
  done
  if [[ "${_iso_drop_path_}" == "" ]]; then
    mkdir -p /nobackup/bake
    _cp_cmd_=$(which cp)
    ${_cp_cmd_} ${ISO_TO_BAKE} /nobackup/bake/8000-x64.iso
    [[ -e /nobackup/bake/8000-x64.iso ]] && _iso_drop_path_="/nobackup/bake/8000-x64.iso"
  fi
  [[ "${_iso_drop_path_}" == "" ]] && echo "Was not able to find an ISO.. Exiting" && exit 1
fi

if [[ ${NO_BAKE} -eq 1 ]]; then
  if [[ ${OUTSIDE_OVXR_DEV} ]]; then
    _cmd_="docker run --rm -it --privileged -e ACTION=bake -e PLAT_BUILD=${PLAT_TO_BUILD} -v ${_bake_folder_}:/nobackup/bake ${_ovxr_dev_docker_name_}"
    echo "Calling ovxr-dev to bake ${_iso_drop_path_}"
    echo "cmd: ${_cmd_}"
    eval ${_cmd_}
    [ $? -ne 0 ] && echo "Creating prebake disk failed !!! Cannot continue to create the docker component for this reason." && exit 1
  else
    [ $UID -ne 0 ] && echo "ERROR: Please re-run as root or call using sudo" && exit 1
    _bake_folder_="/nobackup/bake"
    _SKIP_=1
    if [[ "${PLAT_BUILD::2}" == "88" ]]; then
      [[ ( $(ls ${_bake_folder_}/8808/rp/hda) ) && ( $(ls ${_bake_folder_}/8808/lc/hda) ) && ( $(ls ${_bake_folder_}/*.iso) ) ]] && _SKIP_=0
    else
      [[ ( $(ls ${_bake_folder_}/*.qcow2 2>/dev/null) ) ]] && _SKIP_=0
    fi
    if [[ ${_SKIP_} -ne 0 ]]; then
      /etc/bake_in_container_startup.sh
      if [ $? -ne 0 ]; then
        echo "ERROR: failed to bake ISO for the reason above. Exiting"
        exit 1
      fi
    fi
  fi
  if [[ ( ! -e ${_bake_folder_}/8000.qcow2 ) && ( ! -e ${_bake_folder_}/8808 ) ]]; then
    for f in $(realpath "${_bake_folder_}"/* 2>/dev/null); do
      _ext_="${f##*.}"
      if [[ "${_ext_}" == "iso" ]]; then
        continue
      fi
      if [[ "${_ext_}" == "qcow2" ]]; then
        _cur_basename_="$(basename -- ${f})"
        _new_basename_="8000.qcow2"
        mv "${_bake_folder_}/${_cur_basename_}" "${_bake_folder_}/${_new_basename_}"
        [ $? -ne 0 ] && echo "ERROR: Failed to move ${_bake_folder_}/${_cur_basename_} to ${_bake_folder_}/${_new_basename_}. Exiting" && exit 1
      fi
    done
  fi
  if [[ "${PLAT_TO_BUILD::2}" != "88" ]]; then
    [[ ! -e ${_bake_folder_}/8000.qcow2 ]] && echo "ERROR: Could not find 8000.qcow2. Exiting" && exit 1
  fi
else
  echo "-n was passed in, so skipping the baking process. Resulting docker image will boot from ISO instead of qcow2"
fi

_iso_boot_cmd_arg_=""
[[ ${NO_BAKE} -eq 0 ]] && _iso_boot_cmd_arg_="-i"
_cmd_="${_build_component_script_} -t ${TARGET} -p ${PLAT_TO_BUILD} ${_iso_boot_cmd_arg_} ${DOCKER_NAME}"
if [[ "${PLAT_TO_BUILD::2}" == "88" ]]; then
  _cmd_="${_cmd_} -d ${_bake_folder_}"
else
  which isoinfo > /dev/null 2>&1
  [[ $? -ne 0 ]] && echo "/usr/bin/isoinfo missing. Please install rpm genisoimage" && exit 1
  _getisoinfo_="isoinfo -R -x /sim_cfg.yml -i "
  _sim_cfg_="$(${_getisoinfo_} ${_iso_drop_path_})"
  SDK_VER="$(echo "${_sim_cfg_}" | grep sdk: | awk '{print $2}')"
  [[ ! ${SDK_VER} ]] && SDK_VER="$(echo "${_sim_cfg_}" | grep sdk_ver_pacific: | awk '{print $2}')"
  [[ ! ${SDK_VER} ]] && SDK_VER="$(echo "${_sim_cfg_}" | grep -i sdk | head -1 | awk -F': ' '{print $2}')"
  if [[ ! ${SDK_VER} ]] && [[ "${SKIP_SDK_CHECK}" == "1" ]] && [[ "${SDK_VER_ENV}" ]]; then
    SDK_VER="${SDK_VER_ENV}"
    echo "Using SDK_VER from environment: ${SDK_VER}"
  fi
  [[ ! ${SDK_VER} ]] && echo "Failed to extract SDK VERSION from iso ${_iso_drop_path_}. sim_cfg.yml contents:" && echo "${_sim_cfg_}" && exit 1
  NPSUITE_VER="$(echo "${_sim_cfg_}" | grep npsuite: | awk '{print $2}')"
  [[ ! ${NPSUITE_VER} ]] && NPSUITE_VER="$(echo "${_sim_cfg_}" | grep npsuite_ver_pacific: | awk '{print $2}')"
  [[ ! ${NPSUITE_VER} ]] && NPSUITE_VER="$(echo "${_sim_cfg_}" | grep -i npsuite | head -1 | awk -F': ' '{print $2}')"
  [[ ! ${NPSUITE_VER} ]] && echo "WARNING: Could not extract NPSUITE VERSION from iso ${_iso_drop_path_}, continuing without it"
  if [[ "${PLAT_TO_BUILD}" == "8K-MPA-16H" ]]; then
    _cmd_="${_cmd_} -c ${_bake_folder_}"
  else
    _cmd_="${_cmd_} -f ${_bake_folder_}"
  fi
  _cmd_="${_cmd_} -s ${SDK_VER} -n ${NPSUITE_VER}"
fi
_cmd_="${_cmd_} ${DOCKER_NAME}"
echo "cmd: ${_cmd_}"
eval ${_cmd_}
exit