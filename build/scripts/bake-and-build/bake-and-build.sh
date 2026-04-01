#!/bin/bash
# ------------------------------------------------------------------------------
# bake-and-build.sh
#
# This script automates the process of baking a Cisco ISO image, generating
# required artifacts (qcow2, yaml templates, etc.), and optionally building
# a Docker image for various OVXR target environments (generic, crystalnet, kne, etc).
#
# Key steps:
#   1. Parse user arguments for ISO, platform, target, and options.
#   2. Validate input and environment, set up required directories.
#   3. Bake the ISO to produce qcow2 images.
#   4. Generate YAML templates and organize artifacts.
#   5. Optionally build a Docker image with the new artifacts.
#
# Usage: See the help() function or run with -h for details.
# ------------------------------------------------------------------------------


# NOTE: there's a new use case where user already has qcow2 files and just wants to skip the bake process as long as the ngdp sdk is available 
# assuming this is done outside of docker, we need to create a route for the script to check if ngdp sdk is available inside the ovxr-release packages
# folder


# Get the directory of this script
_CUR_FILE_DIR_="$(cd "$(dirname "$0")"; pwd -P)"
# Get the script filename
_FILENAME_="$(basename -- "${0}")"
# Full path to this script
_CUR_FILE_PATH_="${_CUR_FILE_DIR_}/${_FILENAME_}"
# Hostname (without .cisco.com)
HN="$(hostname | sed 's/.cisco.com//g')"
FULL_LOG=""
IMG_PATCHED=1 # Tracks if an ISO was patched (1 = yes, 0 = no)
declare -a SDK_VER

# Set up important folder paths relative to script location
_root_folder_="$(realpath ${_CUR_FILE_DIR_}/../../)"
_release_folder_="${_root_folder_}/release"
_int_scripts_folder_="${_root_folder_}/cisco-scripts"
_docker_folder_="${_root_folder_}/docker"
_scripts_folder_="${_root_folder_}/scripts"
_allowed_plats_file_="$(realpath ${_CUR_FILE_DIR_}/allowed_plats)"
# Check for allowed platforms file
[[ ! -e ${_allowed_plats_file_} ]] && echo "${_allowed_plats_file_} does not exist. Cannot continue!" && exit 1
_allowed_plats_="$(cat ${_allowed_plats_file_})"
_azure_scripts_folder_="${_scripts_folder_}/azure"
_azure_scripts_allowed_plat_=" $(realpath ${_azure_scripts_folder_}/allowed_plats 2> /dev/null)"
_packages_folder_="${_root_folder_}/packages"
_images_folder_="${_packages_folder_}/images/"
# Ensure images and user-custom directories exist
[[ ! -e ${_images_folder_} ]] && mkdir -p ${_images_folder_}
[[ ! -e ${_images_folder_}/user-custom ]] && mkdir -p ${_images_folder_}/user-custom
_images_drop_parent_folder_="$(realpath ${_images_folder_}/user-custom)"
_bb_template_folder_="$(realpath ${_CUR_FILE_DIR_}/templates)"

[[ ! -e "${_images_drop_parent_folder_}" ]] && mkdir -p "${_images_drop_parent_folder_}"

_generic_dockerfile_="$(realpath ${_docker_folder_}/Dockerfile.generic)"
_build_docker_script_="$(realpath ${_scripts_folder_}/build_docker_image.sh)"

_build_ovxr_script_="${_scripts_folder_}/ovxr-dev/build-ovxr-dev.sh"
_yaml_template_folder_="${_packages_folder_}/examples/custom_template/user-custom-template"
# Check for YAML template folder
[[ ! -e ${_yaml_template_folder_} ]] && echo "${_yaml_template_folder_} does not exist. Cannot continue!" && exit 1
_yaml_drop_root_folder_="${_packages_folder_}/examples/pyvxr"
_yaml_drop_parent_folder_="${_yaml_drop_root_folder_}/user-custom"
[[ ! -e ${_yaml_drop_parent_folder_} ]] && mkdir -p "${_yaml_drop_parent_folder_}"

ISO_BOOT_ARG=""
USER_ISO_DIR=""
DOCKER_NAME=""
USER_DOCKER_NAME=""

# ------------------------------------------------------------------------------
# Function: isItOldEnough
#   Checks if a file is older than a specified age (in minutes).
#   Usage: isItOldEnough "/path/to/file" "age_in_minutes"
#   Returns: 0 if file is old enough, 1 otherwise
# ------------------------------------------------------------------------------
function isItOldEnough() {
  _FILE_=$1
  _AGE_=$2
  [[ "${_AGE_}" == "" ]] && _AGE_="720"
  if [[ -e "${_FILE_}" ]];
  then
    if [[ "$(find ${_FILE_} -mmin +${_AGE_})" != "" ]];
    then
      return 0
    fi
  fi
  return 1
}
# End of isItOldEnough

# ------------------------------------------------------------------------------
# Function: getLock
#   Attempts to create a lock file to prevent concurrent script executions.
#   Checks if the lock file is older than 10 minutes before reusing it.
#   Returns: 0 if lock is acquired, 1 if not
# ------------------------------------------------------------------------------
_LOK='/tmp/l0ks/enter_lok_name'
function getLock() {
  if [[ -f "${_LOK}" ]]; then
    if [[ "$(find ${_LOK} -mmin +10)" == "" ]]; then
      # Lok file exists and has not passed 10 minutes
      return 1
    fi
  fi
  # No lok file, create one
  touch "${_LOK}" > /dev/null 2>&1
	if [ $? -ne 0 ];
	then
		outLog "Could not touch ${_LOK}, may be permission issue"
		return 1
	fi
  outLog "acquired lock"
  return 0
}

# ------------------------------------------------------------------------------
# Function: releaseLock
#   Releases the lock by removing the lock file.
# ------------------------------------------------------------------------------
function releaseLock() {
  /usr/bin/rm -rf "${_LOK}"
  outLog "released lock"
  return 0
}
#LOK END#

# ------------------------------------------------------------------------------
# Function: outLog
#   Outputs a message to the log with a timestamp.
#   Usage: outLog "Your message here"
# ------------------------------------------------------------------------------
#LOG START#
# $1 - Output message
function outLog {
  MSG="${1}"
  TDATE=$(/bin/date +'%Y-%m-%d %T')
  OPT=$(echo -e "[${TDATE}] ${MSG}")
  echo "${OPT}"
  appendFullLog ${OPT}
  return
}
#LOG END#

# ------------------------------------------------------------------------------
# Function: appendFullLog
#   Appends a message to the full log.
#   Usage: appendFullLog "Your message here"
# ------------------------------------------------------------------------------
#FULL LOG START#
function appendFullLog() {
  INPT="$@"
  FULL_LOG="${FULL_LOG}
${INPT}"
  return
}
#FULL LOG END#

# ------------------------------------------------------------------------------
# Function: sendEmail
#   Sends an email notification.
#   Usage: sendEmail "Subject" "Message" "recipient@example.com" "/path/to/tracefile" "interval_in_minutes"
# ------------------------------------------------------------------------------
# SEND EMAIL START#
function sendEmail() {
  _SUBJECT="${1}"
  _MSG="${2}"
  _TO="${3}"
  _TRACE_FILE="${4}"
  _INTERVAL="${5}" # Interval in minutes of how often an email should be sent out
	_MSG="${_MSG}
	This email was auto-generated by $(hostname):${_CUR_FILE_PATH}
	This email will be sent out again in ${_INTERVAL} minutes if problem continues
	"
  if [[ ( -e "${_TRACE_FILE}" ) && ( "$(find ${_TRACE_FILE} -mmin +${_INTERVAL})" == "" ) ]]; then
    # Will wait another hour until a new message is sent out
    outLog "Message has already been sent out in the last ${_INTERVAL} minutes"
    outLog "Trace File - ${_TRACE_FILE}"
    return 1
  fi
  touch ${_TRACE_FILE}
  outLog "${_MSG}" |  mail -s "${_SUBJECT}" "${_TO}"
  outLog "Email sent out to ${_TO}"
  outLog "Trace File - ${_TRACE_FILE}"
  return
}

# SEND EMAIL END  #

# ------------------------------------------------------------------------------
# Function: help
#   Displays the help message with usage instructions.
# ------------------------------------------------------------------------------
# HELP MESSAGE START #
function help() {
  msg="
  Bake and Build will create the prebaked qcow2 and an ovxr docker image around the user's passed in
  ISO & platform of choice. Ovxr's build folder has an intended structure in order to work properly;
  therefore, this script removes the guess-work of manuevering through ovxr's build folders.

  How Bake & Build works:
   1 - User calls the script with the parameters below
   2 - Bake & Build will spawn \"ovxr-dev\", which is included with all ovxr releases. If ovxr-dev's docker image
        is not found, bake & build will create it on the spot.
      Using ovxr-dev, the ISO will go through a baking process to create the precooked qcow2 files for the platform of user's choice.
  3 - Once the bake process finishes, the resulting qcow2 files will be placed in the same directory as the passed in ISO.
  4 - Yaml templates will then be generated based on the specifics of the ISO & qcow2.
  5 - All the resulting artifacts, yaml templates, iso, qcow2s, etc., will be placed appropriately in the ovxr's build structure.
  6 - The process ends here, unless user passes in -d, which in that case will continue to build a new docker image with the new artifacts.

  Note: if user does not pass in -d, they will have to invoke a docker build themselves using the appropriate dockerfile.

  Flag Parameters:
    Required:
      -i <path_to_iso>          ISO to bake and build around
      -p <plat_to_build>        Platform to build. Available options will depend on the target type.
                                Use --listplatforms to see all available platforms.
      -t <target>               Ovxr has different environments that can be built depending on the use case.
                                - generic: sandbox with preloaded yaml templates in /opt/cisco/pyvxr/examples
                                          This is generally the one you want to build.
                                          Allowed <plat_to_build> with this target:
					  $(echo "${_allowed_plats_}" | paste -sd '|')
                                - crystalnet: specific use case for crystalnet
                                          Allowed <plat_to_build> with this target:
                                          8201-sys|8808-gb
                                - kne: create kne container
                                          REQUIRES -d <docker_name>
                                - clab: create clab container
                                            REQUIRES -d <docker_name>
                                - cml:  create CML container
                                          REQUIRES -d <docker_name>
                                - eve_ng: create EVE-NG container
                                          REQUIRES -d <docker_name>
                                - azure: create cloud_vm for Azure MSEE
                                          Allowed <plat_to_build> with this target:
                                          $(cat ${_azure_scripts_allowed_plat_})
                                - cloud_vm: single instance for cloud vm (e.g. Azure, GCP)
                                - all: kne, clab, cml, eve_ng

    Optional:
      -d <docker_name>          User choice of the targeted docker image's name.
                                NOTICE: ALL LOWER CASE
                                        You MUST pass in -d <docker_name> if you want the docker image to build.
      -r                        Force ovxr-dev container rebuild, which is used to build the target, before building user target.
      -o <existing_docker_image>  If you already have an existing ovxr-dev image locally to use as build env, you can pass it in here to use instead of building a new one.
                                  NOTICE: ALL LOWER CASE
      --forcesdk <sdk_version>  Force a specific SDK version to be used. If not passed in, bake & build will attempt to extract the SDK version from the ISO by booting it and reading sim_cfg.yml 
                                IMPORTANT: Passing in more than one SDK is possible but it must be passed in as --forcesdk \"sdk1 sdk2 sdk3\"
      --listplatforms           List all available platforms for each target type and exit

  Position Parameters:
    skip_sdk_lookup           If you want to skip the SDK lookup process, pass in \"skip_sdk_lookup\" as the last parameter
    no_unique_ovxr_name       If you want to skip the unique ovxr name generation process, pass in \"no_unique_ovxr_name\" as the last parameter
    stable                    If you want to use the stable version of ovxr-dev, pass in \"stable
    insidedocker              If you run this script inside a docker container, pass in \"insidedocker\"
    force_sdk_only            If you want to inject the SDK into ovxr-dev build env, pass in \"force_sdk_lookup\"
                                  Eg. ./bake_and_build.sh -o ovxr-dev:latest --forcesdk \"24.5.3000.30\" force_sdk_only
    keep_force_sdk_only       If you want to keep the force_sdk_only flag in the docker image, pass in \"keep_force_sdk_only\" along with --forcesdk
                                  Eg. ./bake_and_build.sh -o ovxr-dev:latest --forcesdk \"24.5.3000.30\" force_sdk_only keep_force_sdk_only 
    isoboot                   If you want to boot from the ISO instead of using the prebuilt qcow2, pass in \"isoboot\". Skips bake process and uses the ISO directly.
    encoff                   If you want to disable (LUks) encryption on the baked qcow2, pass in \"encoff\". By default, encryption is enabled. 
                                Note: This flag only works when baking 8000 series ISOs and helps reduce the size of the resulting qcow2 + docker image size.
  Usage:
    Eg. ISO is located at /nobackup/sff.iso

    To generate a \"generic\" target, similar to that of Dockerfile.generic, around user passed in ISO w/ choice of 8201-sys and dockerimage
    name 8201-sys-generic:v1:
    ./${_FILENAME_} -i /nobackup/sff.iso -p 8201-sys -t generic -d 8201-sys-generic:v1


  "
  echo "${msg}"
  return
}
# HELP MESSAGE END #

# ------------------------------------------------------------------------------
# Function: list_available_platforms
#   Lists all available platforms from allowed_plats files.
# ------------------------------------------------------------------------------
function list_available_platforms() {
  echo "Available platforms by target type:"
  echo ""
  
  # CLAB platforms
  if [[ -f "${_scripts_folder_}/clab/allowed_plats" ]]; then
    echo "CLAB platforms:"
    cat "${_scripts_folder_}/clab/allowed_plats" | sed 's/^/  /'
    echo -e "\n"
  fi
  
  # CML platforms  
  if [[ -f "${_scripts_folder_}/cml/allowed_plats" ]]; then
    echo "CML platforms:"
    cat "${_scripts_folder_}/cml/allowed_plats" | sed 's/^/  /'
    echo -e "\n"
  fi
  
  # KNE platforms
  if [[ -f "${_scripts_folder_}/kne/allowed_plats" ]]; then
    echo "KNE platforms:"
    cat "${_scripts_folder_}/kne/allowed_plats" | sed 's/^/  /'
    echo -e "\n"
  fi
  
  # EVE-NG platforms
  if [[ -f "${_scripts_folder_}/eve_ng/allowed_plats" ]]; then
    echo "EVE-NG platforms:"
    cat "${_scripts_folder_}/eve_ng/allowed_plats" | sed 's/^/  /'
    echo -e "\n"
  fi
  
  # Azure platforms
  if [[ -f "${_scripts_folder_}/azure/allowed_plats" ]]; then
    echo "Azure platforms:"
    cat "${_scripts_folder_}/azure/allowed_plats" | sed 's/^/  /'
    echo -e "\n"
  fi
  
  # Generic platforms (from bake-and-build folder)
  if [[ -f "${_scripts_folder_}/bake-and-build/allowed_plats" ]]; then
    echo "Generic platforms:"
    cat "${_scripts_folder_}/bake-and-build/allowed_plats" | sed 's/^/  /'
    echo -e "\n"
  fi
  
  # Crystalnet platforms (hardcoded as mentioned in help)
  echo "Crystalnet platforms:"
  echo "  8201-sys"
  echo "  8808-gb"
  echo ""
  
  return
}


# ------------------------------------------------------------------------------
# Function: checkPlats
#   Checks if the specified platform is allowed for the given target.
#   Usage: checkPlats "platform_name"
# ------------------------------------------------------------------------------
function checkPlats() {
  PLAT_TO_BUILD="${1}"
  case ${TARGET_TO_BUILD} in
    azure)
      outLog "Checking allowed plat for target :${TARGET_TO_BUILD}"
      [[ ! -e ${_azure_scripts_allowed_plat_} ]] && outLog "[WARNING] cannot find ${_azure_scripts_allowed_plat_}.. skipping plat check" 
      grep -q ${PLAT_TO_BUILD} ${_azure_scripts_allowed_plat_}
      if [ $? -ne 0 ];
      then
        outLog "[ERROR] ${PLAT_TO_BUILD} is not a plat allowed to be built for target ${TARGET_TO_BUILD} according to file ${_azure_scripts_allowed_plat_}: $(cat ${_azure_scripts_allowed_plat_})"
        outLog "Quitting"
        exit 1
      else
        outLog "Plat ${PLAT_TO_BUILD} is allowed for target ${TARGET_TO_BUILD}"
      fi
      ;;
    *)
      ;;
    esac
: '
  case ${PLAT_TO_BUILD} in
    8101-32H|8122-64EHF-O|8101-32FH|8102-64H|8122-64EHF-O|8201-32FH|8201-sys|8201-24H8FH|8202|8202-32FH-M|8804|8808-gb)
      outLog "Passed in plat: ${PLAT_TO_BUILD}"
      ;;
    *)
      echo "Bad -p passed in" #TODO: give proper help message
      echo "Options: 8101-32H|8101-32FH|8102-64H|8201-32FH|8201-sys|8202|8202-32FH-M|8201-24H8FH|8804|8808-gb"
      echo "User passed in ${PLAT_TO_BUILD}"
      exit 1
      ;;
  esac
'
}

# ------------------------------------------------------------------------------
# Function: checkTarget
#   Checks if the specified target is valid.
#   Usage: checkTarget "target_name"
# ------------------------------------------------------------------------------
function checkTarget() {
  TARGET_TO_BUILD="${1}"
  case ${TARGET_TO_BUILD} in
    crystalnet|generic|kne|clab|cml|eve_ng|cloud_vm|azure|all)
      outLog "Passed in target: ${TARGET_TO_BUILD}"
      if [[ "${TARGET_TO_BUILD}" == "all" ]]; then
        outLog "Building all* targets: kne, clab, cml, eve_ng"
      fi
      ;;
    *)
      echo "Bad -t passed in" #TODO give proper help message
      echo "Options: crystalnet|generic|cloud_vm"
      exit 1
      ;;
    esac
}

# ------------------------------------------------------------------------------
# Function: _sedVerboseLog_
#   A wrapper for sed command to log the changes being made.
#   Usage: _sedVerboseLog_ "search_pattern" "replace_pattern" "file_path"
# ------------------------------------------------------------------------------
function _sedVerboseLog_() {
  _SRC_="${1}"
  _TGT_="${2}"
  _FILE_="${3}"
  sed -i 's|'${_SRC_}'|'${_TGT_}'|g' ${_FILE_} && \
  outLog "SED Operation: ${_SRC_} => ${_TGT_} || File: ${_FILE_}" || \
  outLog "[WARNING] SED FAILED: ${_SRC_} => ${_TGT_} || File: ${_FILE_}"
  return $?
}

# ------------------------------------------------------------------------------
# Function: buildAllTarget
#   Creates the YAML file and configures the environment for the all target.
# ------------------------------------------------------------------------------
function buildAllTarget() {
  outLog "Building all* targets: kne, clab, cml"
  #TODO: include bypass for npsuite/sdk version, currently getting it from ISO in the folder passed in.

  if [[ ( ! -e ${USER_ISO_DIR}/8000.qcow2 ) && ( ! -e ${USER_ISO_DIR}/8808 ) ]];
  then
    outLog "Checking for existing qcow2 symlinks: 8000.qcow2 and 8808"
    outLog "Finding resulting qcow2 file(s) in ${USER_ISO_DIR}"
    for f in $(realpath "${USER_ISO_DIR}"/* 2>/dev/null);
    do
      outLog "Inspecting file: ${f}"
      _ext_="${f##*.}"
      if [[ "${_ext_}" == "iso" ]];
      then
        #if ${USER_ISO_DIR}/8000-x64.iso does not exist, create symlink of the one ISO in ${USER_ISO_DIR}/*.iso to ${USER_ISO_DIR}/8000-x64.iso
        if [[ ! -e ${USER_ISO_DIR}/8000-x64.iso ]]; then
          outLog "Creating symlink in ${USER_ISO_DIR}: 8000-x64.iso"
          pushd ${USER_ISO_DIR} > /dev/null
          _tmp_sym_name_="$(basename -- ${f})"
          outLog "Creating symlink 8000-x64.iso -> ${_tmp_sym_name_}"
          ln -s ${_tmp_sym_name_} 8000-x64.iso
          outLog "${USER_ISO_DIR}:"
          ls
          popd > /dev/null
        else
          outLog "Skipping ISO file: ${f}"
          continue
        fi
      fi

      if [[ "${_ext_}" == "qcow2" ]];
      then
        outLog "Found qcow2 file: ${f}"
        _cur_dir_="$(dirname -- ${f})"
        _cur_basename_="$(basename -- ${f})"
        _new_basename_="8000.qcow2"
        pushd ${_cur_dir_} > /dev/null
        outLog "Creating symlink from ${_cur_basename_} to ${_new_basename_} in ${_cur_dir_}"
        ln -sf ${_cur_basename_} ${_new_basename_}
        if [[ $? -ne 0 ]]; then
          outLog "ERROR: Failed to create symlink ${_cur_dir_}/${_cur_basename_} to ${_cur_dir_}/${_new_basename_}. Exiting"
          popd > /dev/null
          return 1
        else
          outLog "Symlink created: ${_cur_dir_}/${_new_basename_} -> ${_cur_dir_}/${_cur_basename_}"
          outLog "${USER_ISO_DIR}:"
          ls
        fi
        popd > /dev/null
      else
        outLog "Skipping non-qcow2 file: ${f}"
      fi
    done
    outLog "Symlink creation process completed."

    # if a qcow2 file is found, but not named 8000.qcow2, symlink it to 8000.qcow2
    if [[ ! -e ${USER_ISO_DIR}/8000.qcow2 ]]; then
      outLog "Creating symlink: 8000.qcow2"
      ln -sf ${USER_ISO_DIR}/*.qcow2 ${USER_ISO_DIR}/8000.qcow2
    fi
  else
    if [[ -e ${USER_ISO_DIR}/8808 ]];
    then
      pushd ${USER_ISO_DIR} > /dev/null 2>&1
      for f in $(find ./*.iso);
      do
        _ext_="${f##*.}"
        if [[ ( "${_ext_}" == "iso" ) && ( ! -e ./8000-x64.iso ) ]]; 
        then
          outLog "Creating symlink from ${f} to ${USER_ISO_DIR}/8000-x64.iso"
          ln -sf ${f} ${USER_ISO_DIR}/8000-x64.iso
          outLog "Symlink created: ${USER_ISO_DIR}/8000-x64.iso -> ${f}"

          outLog "${USER_ISO_DIR}:"
          ls
        fi
      done
    fi
  fi

 

  #TODO: change how symlink is determined and created. this is too fragile
  _img_symlink_for_build_="../user-custom/$(basename ${_img_drop_folder_})"

  #create array to loop through targets
  _targets_to_build_=("kne" "clab" "cml" "eve_ng")
  _build_ovxr_component_script_="${_scripts_folder_}/bake-and-build/build_ovxr_component.sh"

  if [[ "${PLAT_TO_BUILD}" == 88* ]];
  then
    _user_iso_dir_param_="-d ${USER_ISO_DIR}"
  else
    _user_iso_dir_param_="-f ${USER_ISO_DIR}"
  fi
  # Loop through each target and call the build_*_component.sh script to populate necessary files
  for target in "${_targets_to_build_[@]}"; do
    outLog  "Building target: ${target}"
    [[ ! -e "${_build_ovxr_component_script_}" ]] && outLog "Missing ${_build_ovxr_component_script_}. FAILED TO BUILD TARGET" && return 1

    _build_component_script_cmd_="${_build_ovxr_component_script_} -t ${target} ${_user_iso_dir_param_} -n ${_NPSUITE_VER_} -s ${_SDK_VER_} -p ${PLAT_TO_BUILD} --symlinkimage ${_img_symlink_for_build_} skip_docker_build"
    outLog "Running command: ${_build_component_script_cmd_}"
    ${_build_component_script_cmd_}
    echo ""
  done

  #Build the dockerimage 
  #DOCKER_NAME should have been determined earlier by determineDOCKER_NAME function
  #Determine which dockerfile to use, they are in ./ovxr-release/docker/all_targets
  #If PLAT_TO_BUILD starts with 88*, then use Dockerfile8808, else use Dockerfile8201
  if [[ "${PLAT_TO_BUILD}" == 88* ]]; then
    _dockerfile_="${_docker_folder_}/all_targets/Dockerfile8808" #TODO: determine if cached can be used or not and then use the right dockerfile
  else
    _dockerfile_="${_docker_folder_}/all_targets/Dockerfile8201"
  fi
  # Test if internal ub layer image exists
  _internal_initial_ub_layer_="containers.cisco.com/wmyint/ovxr-initial:latest"
  docker manifest inspect ${_internal_initial_ub_layer_} > /dev/null 2>&1
  if [[ $? -eq 0 ]];
  then 
    _dockerfile_="${_dockerfile_}_cached"
  fi
  
  outLog "Building docker image with name: ${DOCKER_NAME}"
  _build_docker_cmd_="${_build_docker_script_} -c -i ${_SDK_VER_} ${DOCKER_NAME} ${_dockerfile_}"
  outLog "Running command: ${_build_docker_cmd_}"
  ${_build_docker_cmd_}
  if [[ $? -ne 0 ]]; then
    outLog "Failed to build docker image: ${DOCKER_NAME}"
    return 1
  fi

  outLog "Successfully built docker image: ${DOCKER_NAME}"
  docker image ls ${DOCKER_NAME}

  _tar_name_="$(echo ${DOCKER_NAME} | sed 's/:/-/g').tar"
  _tar_release_path_="${_release_folder_}/ovxr-docker/${_tar_name_}"
  [[ ! -e "${_release_folder_}/ovxr-docker" ]] && mkdir -p "${_release_folder_}/ovxr-docker"
  outLog "Saving docker image, ${DOCKER_NAME} to ${_tar_release_path_}"
  outLog "This may take a while depending on the size of the image"
  #docker save ${DOCKER_NAME} | gzip > ${_tar_release_path_}
  docker save ${DOCKER_NAME} -o ${_tar_release_path_}
  chmod 644 ${_tar_release_path_}

  docker image rm ${DOCKER_NAME}
}

# ------------------------------------------------------------------------------
# Function: buildCloudVmTarget
#   Creates the YAML file and configures the environment for the cloud_vm target.
# ------------------------------------------------------------------------------
function buildCloudVmTarget() {
    outLog "Creating yaml file for cloud_vm target"
    _yaml_="scripts/azure/customImage/simTemplate.yaml"
    _paste_to_="${_yaml_drop_root_folder_}/cloud/"
    mkdir -p ${_paste_to_}
    /usr/bin/cp ${_yaml_} ${_paste_to_}
    [[ $? -ne 0 ]] && exit 1
    _yaml_filename_="$(basename -- ${_yaml_})"
    _pasted_yaml_="$(realpath ${_paste_to_}/${_yaml_filename_})"
    outLog "Placed ${_pasted_yaml_}"
    sed -i 's/_NPSUITE_VER_/'${_NPSUITE_VER_}'/g' ${_pasted_yaml_}
    sed -i 's/_NPSUITE_VER_/'${_NPSUITE_VER_}'/g' ${_yaml_}
    sed -i 's/_SDK_VER_/'${_SDK_VER_}'/g' ${_pasted_yaml_}
    sed -i 's/_SDK_VER_/'${_SDK_VER_}'/g' ${_yaml_}
    sed -i 's/_PLAT_TYPE_/'${PLAT_TO_BUILD}'/g' ${_pasted_yaml_}
    sed -i 's/_PLAT_TYPE_/'${PLAT_TO_BUILD}'/g' ${_yaml_}

    case ${PLAT_TO_BUILD} in
        8804|88*)
          echo "Cloudvm target for 8800 platforms not supported yet ..."
          exit 1
          #_temp_img_path_="${_yaml_img_folder_}/${_img_name_["iso"]}"
          #_temp_rp_path_="${_yaml_img_folder_}/${_img_name_["rp"]}"
          #_temp_lc_path_="${_yaml_img_folder_}/${_img_name_["lc"]}"
          #sed -i 's|_IMAGE_PATH_|'${_temp_img_path_}'|g' ${_pasted_yaml_}
          #sed -i 's|_RP_PATH_|'${_temp_rp_path_}'|g' ${_pasted_yaml_}
          #sed -i 's|_LC_PATH_|'${_temp_lc_path_}'|g' ${_pasted_yaml_}
          ;;
        *)
          _temp_img_path_="${_yaml_img_folder_}/${_img_name_["rp"]}"
          sed -i 's|_IMAGE_PATH_|'${_temp_img_path_}'|g' ${_pasted_yaml_}
	  sed -i 's|_IMAGE_PATH_|'${_temp_img_path_}'|g' ${_yaml_}
          # remove iso for fixed platforms
          RM_ISO="${_img_drop_folder_}/*.iso"
          /usr/bin/rm -f $RM_ISO
          ls $RM_ISO
          ;;
      esac
      cat ${_pasted_yaml_}
}

# ------------------------------------------------------------------------------
# Function: buildCrystalnetTarget
#   Creates the files and configures the environment for the crystalnet target.
# ------------------------------------------------------------------------------
function buildCrystalnetTarget() {
  outLog "Creating files relating to Crystalnet such as Dockerfile and cnet yaml"
  _postfix_="${USER_ISO_NAME}-${PLAT_TO_BUILD}"
  _dockerfile_postfix_="$(basename ${_img_drop_folder_})"
  #Template dir#
  _cn_template_folder_="${_bb_template_folder_}/crystalnet"
  [[ ! -e "${_cn_template_folder_}" ]] && outLog "Missing ${_cn_template_folder_}. FAILED TO BUILD TARGET" && return 1
  _cn_packages_template_folder_="${_cn_template_folder_}/packages/crystalnet"
  _cn_docker_template_folder_="${_cn_template_folder_}/docker/crystalnet"

  #Template file paths#
  _cn_dockerfile_8000_template_="${_cn_docker_template_folder_}/Dockerfile"
  _cn_dockerfile_cached_8000_template_="${_cn_docker_template_folder_}/Dockerfile_cached"
  _cn_dockerfile_8808_template_="${_cn_docker_template_folder_}/Dockerfile_8808"
  _cn_dockerfile_cached_8808_template_="${_cn_docker_template_folder_}/Dockerfile_8808_cached"
  _cn_cnet_8000_template_="${_cn_packages_template_folder_}/cnet_8000_template.yaml"
  _cn_cnet_8704_template_="${_cn_packages_template_folder_}/cnet_8704_template.yaml"
  _cn_cnet_8808_template_="${_cn_packages_template_folder_}/cnet_8808_template.yaml"

  #Target Paths#
  _cnet_target_parent_folder_="$(realpath ${_packages_folder_}/crystalnet)"
  _docker_target_parent_folder_="$(realpath ${_docker_folder_}/crystalnet)"
  _cnet_target_file_="${_cnet_target_parent_folder_}/cnet_${_postfix_}.yaml"
  [[ -e "${_cnet_target_file_}" ]] &&  /usr/bin/mv ${_cnet_target_file_} ${_cnet_target_file_}.bak && outLog "[WARNING] ${_cnet_target_file_} exists! Moved it to ${_cnet_target_file_}.bak"
  _docker_target_file_="${_docker_target_parent_folder_}/Dockerfile_${_dockerfile_postfix_}"
  _docker_cached_target_file_="${_docker_target_parent_folder_}/Dockerfile_cached_${_dockerfile_postfix_}"
  [[ -e "${_docker_target_file_}" ]] && /usr/bin/mv ${_docker_target_file_} ${_docker_target_file_}.bak && outLog "[WARNING] ${_docker_target_file_} exists! Moved it to ${_docker_target_file_}.bak"
  [[ -e "${_docker_cached_target_file_}" ]] && /usr/bin/mv ${_docker_cached_target_file_} ${_docker_cached_target_file_}.bak && outLog "[WARNING] ${_docker_cached_target_file_} exists! Moved it to ${_docker_cached_target_file_}.bak"


  case ${PLAT_TO_BUILD} in
    8804|8101-32H|8101-32FH|8102-64H|8201-32FH|8201-24H8FH|8202)
      echo "${PLAT_TO_BUILD} cannot be built for crystalnet target"
      return 1
      ;;
    8808-gb)
      cp "${_cn_cnet_8808_template_}" "${_cnet_target_file_}"
      outLog "Placed cnet yaml ${_cnet_target_file_} using ${_cn_cnet_8808_template_} as template"
      cp "${_cn_dockerfile_8808_template_}" "${_docker_target_file_}"
      outLog "Placed dockerfile ${_docker_target_file_} using ${_cn_dockerfile_8808_template_} as template"
      cp "${_cn_dockerfile_cached_8808_template_}" "${_docker_cached_target_file_}"
      outLog "Placed dockerfile cached ${_docker_cached_target_file_} using ${_cn_dockerfile_cached_8808_template_} as template"

      #cnet sed
      outLog "Manipulating copied over files to contain proper paths and vers"
      _temp_img_path_="${_yaml_img_folder_}/${_img_name_["iso"]}"
      _temp_rp_path_="${_yaml_img_folder_}/${_img_name_["rp"]}"
      _temp_lc_path_="${_yaml_img_folder_}/${_img_name_["lc"]}"
      #TODO: erase later
#      sed -i 's|_IMAGE_PATH_|'${_temp_img_path_}'|g' ${_cnet_target_file_}
#      sed -i 's|_RP_PATH_|'${_temp_rp_path_}'|g' ${_cnet_target_file_}
#      sed -i 's|_LC_PATH_|'${_temp_lc_path_}'|g' ${_cnet_target_file_}
#      sed -i 's|_LCC_TYPE_|'${PLAT_TO_BUILD}'|g' ${_cnet_target_file_}
#      sed -i 's|_FABCARD_TYPE_|8808-fc|g' ${_cnet_target_file_}
#      sed -i 's|_LINECARD_TYPE_|8800-lc-36fh-m|g' ${_cnet_target_file_}
      _sedVerboseLog_ "_IMAGE_PATH_" "${_temp_img_path_}" "${_cnet_target_file_}"
      _sedVerboseLog_ "_RP_PATH_" "${_temp_rp_path_}" "${_cnet_target_file_}"
      _sedVerboseLog_ "_LC_PATH_" "${_temp_lc_path_}" "${_cnet_target_file_}"
      _sedVerboseLog_ "_LCC_TYPE_" "${PLAT_TO_BUILD}" "${_cnet_target_file_}"
      _sedVerboseLog_ "_FABCARD_TYPE_" "8808-fc" "${_cnet_target_file_}"
      _sedVerboseLog_ "_LINECARD_TYPE_" "8800-lc-36fh-m" "${_cnet_target_file_}"

      #dockerfile sed
      _temp_img_docker_entry_="$(echo ${_img_drop_folder_}/${_img_name_["iso"]} | sed 's|'${_packages_folder_}'|.|g')"
      _temp_rp_docker_entry_="$(echo ${_img_drop_folder_}/${_img_name_["rp"]} | sed 's|'${_packages_folder_}'|.|g')"
      _temp_lc_docker_entry_="$(echo ${_img_drop_folder_}/${_img_name_["lc"]} | sed 's|'${_packages_folder_}'|.|g')"
      _temp_cnet_docker_entry_="$(echo ${_cnet_target_file_} | sed 's|'${_packages_folder_}'|.|g')"
      #TODO: erase later
#      sed -i 's|_SRC_ISO_PATH_|'${_temp_img_docker_entry_}'|g' ${_docker_target_file_} ${_docker_cached_target_file_}
#      sed -i 's|_SRC_RP_PATH_|'${_temp_rp_docker_entry_}'|g' ${_docker_target_file_}  ${_docker_cached_target_file_}
#      sed -i 's|_SRC_LC_PATH_|'${_temp_lc_docker_entry_}'|g' ${_docker_target_file_}  ${_docker_cached_target_file_}
#      sed -i 's|_SRC_CNET_YAML_PATH_|'${_temp_cnet_docker_entry_}'|g' ${_docker_target_file_} ${_docker_cached_target_file_}
      _sedVerboseLog_ "_SRC_ISO_PATH_" "${_temp_img_docker_entry_}" "${_docker_target_file_} ${_docker_cached_target_file_}"
      _sedVerboseLog_ "_SRC_RP_PATH_" "${_temp_rp_docker_entry_}" "${_docker_target_file_} ${_docker_cached_target_file_}"
      _sedVerboseLog_ "_SRC_LC_PATH_" "${_temp_lc_docker_entry_}" "${_docker_target_file_} ${_docker_cached_target_file_}"
      _sedVerboseLog_ "_SRC_CNET_YAML_PATH_" "${_temp_cnet_docker_entry_}" "${_docker_target_file_} ${_docker_cached_target_file_}"

      _temp_img_docker_tgt_entry_="$(echo ${_yaml_img_folder_}/${_img_name_["iso"]})"
      _temp_rp_docker_tgt_entry_="$(echo ${_yaml_img_folder_}/${_img_name_["rp"]})"
      _temp_lc_docker_tgt_entry_="$(echo ${_yaml_img_folder_}/${_img_name_["lc"]})"
      #TODO: erase later
#      sed -i 's|_TGT_ISO_PATH_|'${_temp_img_docker_tgt_entry_}'|g' ${_docker_target_file_}  ${_docker_cached_target_file_}
#      sed -i 's|_TGT_RP_PATH_|'${_temp_rp_docker_tgt_entry_}'|g' ${_docker_target_file_}  ${_docker_cached_target_file_}
#      sed -i 's|_TGT_LC_PATH_|'${_temp_lc_docker_tgt_entry_}'|g' ${_docker_target_file_}  ${_docker_cached_target_file_}
      _sedVerboseLog_ "_TGT_ISO_PATH_" "${_temp_img_docker_tgt_entry_}" "${_docker_target_file_}  ${_docker_cached_target_file_}"
      _sedVerboseLog_ "_TGT_RP_PATH_" "${_temp_rp_docker_tgt_entry_}" "${_docker_target_file_}  ${_docker_cached_target_file_}"
      _sedVerboseLog_ "_TGT_LC_PATH_" "${_temp_lc_docker_tgt_entry_}" "${_docker_target_file_}  ${_docker_cached_target_file_}"
      ;;
    8201-sys|8202-32FH-M)
      cp "${_cn_cnet_8000_template_}" "${_cnet_target_file_}"
      outLog "Placed cnet yaml ${_cnet_target_file_} using ${_cn_cnet_8000_template_} as template"
      cp "${_cn_dockerfile_8000_template_}" "${_docker_target_file_}"
      outLog "Placed dockerfile ${_docker_target_file_} using ${_cn_dockerfile_8000_template_} as template"
      cp "${_cn_dockerfile_cached_8000_template_}" "${_docker_cached_target_file_}"
      outLog "Placed dockerfile cached ${_docker_cached_target_file_} using ${_cn_dockerfile_cached_8000_template_} as template"

      #cnet sed
      _temp_rp_path_="${_yaml_img_folder_}/${_img_name_["rp"]}"
      #TODO: erase later
#      sed -i 's|_LINECARD_TYPE_|'${PLAT_TO_BUILD}'|g' ${_cnet_target_file_}
#      sed -i 's|_IMAGE_PATH_|'${_temp_rp_path_}'|g' ${_cnet_target_file_}
      _sedVerboseLog_ "_LINECARD_TYPE_" "${PLAT_TO_BUILD}" "${_cnet_target_file_}"
      _sedVerboseLog_ "_IMAGE_PATH_" "${_temp_rp_path_}" "${_cnet_target_file_}"

      #dockerfile sed
      _temp_img_docker_entry_="$(echo ${_img_drop_folder_}/${_img_name_["iso"]} | sed 's|'${_packages_folder_}'|.|g')"
      _temp_rp_docker_entry_="$(echo ${_img_drop_folder_}/${_img_name_["rp"]} | sed 's|'${_packages_folder_}'|.|g')"
      _temp_cnet_docker_entry_="$(echo ${_cnet_target_file_} | sed 's|'${_packages_folder_}'|.|g')"
      #TODO: erase later
#      sed -i 's|_SRC_ISO_PATH_|'${_temp_img_docker_entry_}'|g' ${_docker_target_file_} ${_docker_cached_target_file_}
#      sed -i 's|_SRC_QCOW2_PATH_|'${_temp_rp_docker_entry_}'|g' ${_docker_target_file_} ${_docker_cached_target_file_}
#      sed -i 's|_SRC_CNET_YAML_PATH_|'${_temp_cnet_docker_entry_}'|g' ${_docker_target_file_} ${_docker_cached_target_file_}
      _sedVerboseLog_ "_SRC_ISO_PATH_" "${_temp_img_docker_entry_}" "${_docker_target_file_} ${_docker_cached_target_file_}"
      _sedVerboseLog_ "_SRC_QCOW2_PATH_" "${_temp_rp_docker_entry_}" "${_docker_target_file_} ${_docker_cached_target_file_}"
      _sedVerboseLog_ "_SRC_CNET_YAML_PATH_" "${_temp_cnet_docker_entry_}" "${_docker_target_file_} ${_docker_cached_target_file_}"

      _temp_img_docker_tgt_entry_="$(echo ${_yaml_img_folder_}/${_img_name_["iso"]})"
      _temp_rp_docker_tgt_entry_="$(echo ${_yaml_img_folder_}/${_img_name_["rp"]})"
      #TODO: erase later
#      sed -i 's|_TGT_ISO_PATH_|'${_temp_img_docker_tgt_entry_}'|g' ${_docker_target_file_}  ${_docker_cached_target_file_}
#      sed -i 's|_TGT_QCOW2_PATH_|'${_temp_rp_docker_tgt_entry_}'|g' ${_docker_target_file_} ${_docker_cached_target_file_}
      _sedVerboseLog_ "_TGT_ISO_PATH_" "${_temp_img_docker_tgt_entry_}" "${_docker_target_file_}  ${_docker_cached_target_file_}"
      _sedVerboseLog_ "_TGT_QCOW2_PATH_" "${_temp_rp_docker_tgt_entry_}" "${_docker_target_file_} ${_docker_cached_target_file_}"
      ;;
    8K-MPA-16H|8K-MPA-16Z2D)
      #spitfire_c
      cp "${_cn_cnet_8704_template_}" "${_cnet_target_file_}"
      outLog "Placed cnet yaml ${_cnet_target_file_} using ${_cn_cnet_8704_template_} as template"
      cp "${_cn_dockerfile_8000_template_}" "${_docker_target_file_}"
      outLog "Placed dockerfile ${_docker_target_file_} using ${_cn_dockerfile_8000_template_} as template"
      cp "${_cn_dockerfile_cached_8000_template_}" "${_docker_cached_target_file_}"
      outLog "Placed dockerfile cached ${_docker_cached_target_file_} using ${_cn_dockerfile_cached_8000_template_} as template"

      #cnet yaml sed
      _temp_img_path_="${_yaml_img_folder_}/${_img_name_["iso"]}"
      _temp_rp_path_="${_yaml_img_folder_}/${_img_name_["rp"]}"
      _temp_lcc_type_="\"8704\""
      _sedVerboseLog_ "_LINECARD_TYPE_" "${PLAT_TO_BUILD}" "${_cnet_target_file_}"
      _sedVerboseLog_ "_IMAGE_PATH_" "${_temp_img_path_}" "${_cnet_target_file_}"
      _sedVerboseLog_ "_RP_PATH_" "${_temp_rp_path_}" "${_cnet_target_file_}"
      _sedVerboseLog_ "_LCC_TYPE_" "${_temp_lcc_type_}" "${_cnet_target_file_}"

      #dockerfile sed
      _temp_img_docker_entry_="$(echo ${_img_drop_folder_}/${_img_name_["iso"]} | sed 's|'${_packages_folder_}'|.|g')"
      _temp_rp_docker_entry_="$(echo ${_img_drop_folder_}/${_img_name_["rp"]} | sed 's|'${_packages_folder_}'|.|g')"
      _temp_cnet_docker_entry_="$(echo ${_cnet_target_file_} | sed 's|'${_packages_folder_}'|.|g')"
      _sedVerboseLog_ "_SRC_ISO_PATH_" "${_temp_img_docker_entry_}" "${_docker_target_file_} ${_docker_cached_target_file_}"
      _sedVerboseLog_ "_SRC_QCOW2_PATH_" "${_temp_rp_docker_entry_}" "${_docker_target_file_} ${_docker_cached_target_file_}"
      _sedVerboseLog_ "_SRC_CNET_YAML_PATH_" "${_temp_cnet_docker_entry_}" "${_docker_target_file_} ${_docker_cached_target_file_}"

      _temp_img_docker_tgt_entry_="$(echo ${_yaml_img_folder_}/${_img_name_["iso"]})"
      _temp_rp_docker_tgt_entry_="$(echo ${_yaml_img_folder_}/${_img_name_["rp"]})"
      _sedVerboseLog_ "_TGT_ISO_PATH_" "${_temp_img_docker_tgt_entry_}" "${_docker_target_file_}  ${_docker_cached_target_file_}"
      _sedVerboseLog_ "_TGT_QCOW2_PATH_" "${_temp_rp_docker_tgt_entry_}" "${_docker_target_file_} ${_docker_cached_target_file_}"
     
      ;;
    *)
      echo "Something went wrong and the wrong plat to build was passed to crystalnet target function."
      echo "Exiting"
      exit 1
      ;;
  esac

  sed -i 's/_NPSUITE_VER_/'${_NPSUITE_VER_}'/g' ${_cnet_target_file_}
  sed -i 's/_SDK_VER_/'${_SDK_VER_}'/g' ${_cnet_target_file_}

  if [[ "${USER_DOCKER_NAME}" ]];
  then
    _docker_build_cmd_="${_build_docker_script_} ${USER_DOCKER_NAME} ${_docker_target_file_}"
    outLog "Docker image build cmd - ${_docker_build_cmd_}"
    eval "${_docker_build_cmd_}"
  fi
}

# ------------------------------------------------------------------------------
# Function: buildAzureTarget
#   Creates the YAML file and configures the environment for the azure target.
# ------------------------------------------------------------------------------
function buildAzureTarget() {
  outLog "Creating yaml file for azure"
  _azure_yaml_template_original_="${_azure_scripts_folder_}/customImage/.simTemplate.yaml"
  [[ ! -e ${_azure_yaml_template_original_} ]] && outLog "ERROR: ${_azure_yaml_template_original_} cannot be found.. Cannot continue" && exit 1
  _azure_yaml_template_="${_azure_scripts_folder_}/customImage/simTemplate.yaml"
  /usr/bin/cp ${_azure_yaml_template_original_} ${_azure_yaml_template_}
  [ $? -ne 0 ]  && outLog "Failed to copy ${_azure_yaml_template_original_} to ${_azure_yaml_template_}.. cannot continue" && exit 1


  #_IMAGE_PATH_
  _temp_img_path_="${_yaml_img_folder_}/${_img_name_["rp"]}"
  _sedVerboseLog_ "_IMAGE_PATH_" "${_temp_img_path_}" "${_azure_yaml_template_}"

  #_PLAT_TYPE_
  _sedVerboseLog_ "_PLAT_TYPE_" "${PLAT_TO_BUILD}" "${_azure_yaml_template_}"

  #_NPSUITE_VER_
  _sedVerboseLog_ "_NPSUITE_VER_" "${_NPSUITE_VER_}" "${_azure_yaml_template_}"

  #_SDK_VER_
  _sedVerboseLog_ "_SDK_VER_" "${_SDK_VER_}" "${_azure_yaml_template_}"
  #MGMT_MAC_ADDR
}

# ------------------------------------------------------------------------------
# Function: _appendToReleaseTarget_
#   Appends the target image name to the release target file for tracking.
#   Usage: _appendToReleaseTarget_ "target_name"
# ------------------------------------------------------------------------------
function _appendToReleaseTarget_() {
  _target_="${1}"
  _rel_file_="${_int_scripts_folder_}/release/${_target_}"
  [ ! -e ${_rel_file_} ] && outLog "rel target file ${_rel_file_} does not exist, creating it" && touch ${_rel_file_}

  _inpt_name_=$(basename ${_img_drop_folder_})
  grep -q "${_inpt_name_}" ${_rel_file_} && return
  echo "${_inpt_name_}" >> ${_rel_file_}
  [ $? -eq 0 ] && outLog "Appened \"${_inpt_name_}\" to ${_rel_file_}"
  return
}

# ------------------------------------------------------------------------------
# Function: _dlNgdpSdk_
#   Downloads the specified NGDP SDK version from the internal server.
#   Usage: _dlNgdpSdk_ "sdk_version"
# ------------------------------------------------------------------------------
function _dlNgdpSdk_() {
  NGDP_VERSION="${1}"
  _src_http_="http://vxr-nfs-02/Download/ngdp/"
  _ngdp_deb_name_="vxr2-ngdp-${NGDP_VERSION}_1-1_all.deb"
  _wget_results_=0
  outLog "Downloading ${_ngdp_deb_name_} from ${_src_http_}"
  wget -nv --no-proxy "${_src_http_}${_ngdp_deb_name_}"
  _wget_results_=$?
  if [[ ${_wget_results_} -ne 0 ]];
  then
    outLog "Failed to download ${_ngdp_deb_name_} from ${_src_http_}"
    outLog "Will attempt another name.."
    _try_this_="$(sed 's/_/-/g' <<< "${NGDP_VERSION}")"
    _ngdp_deb_name_="vxr2-ngdp-${_try_this_}_1-1_all.deb"
    outLog "Downloading ${_ngdp_deb_name_} from ${_src_http_}"
    wget --no-proxy "${_src_http_}${_ngdp_deb_name_}"
    _wget_results_=$?
  fi
  return ${_wget_results_}
}

# ------------------------------------------------------------------------------
# Function: _setGblSdkFromIsoUsingValidateIso_
#   Extracts the SDK version from the ISO using the validateIso.py script.
#   Usage: _setGblSdkFromIsoUsingValidateIso_ "/path/to/iso"
# ------------------------------------------------------------------------------
function _setGblSdkFromIsoUsingValidateIso_() {
  _iso_file_="${1}"
  _e_=0
  _sdk_extract_script_="${_scripts_folder_}/bin/validateIso.py"
  if [[ -e ${_sdk_extract_script_} ]];
  then
    outLog "Attempting to use ${_sdk_extract_script_} to extract sdk version from ${_iso_file_}"
    _cmd_="${_sdk_extract_script_} -i ${_iso_file_} -c -l DEBUG -f"
    _opt_="$(eval ${_cmd_} 2>&1)"
    _e_=$?

    if [[ ${_e_} -eq 0 ]];
    then
      #validateIso.py, if successful, will return in the last line "SDK Version: <version>"
      outLog "Full output:"
      echo "${_opt_}"
      _extract_sdk_ver_=$(echo ${_opt_} | grep -o "SDK Version: \S*" | tail -1 | awk '{print $3}')
      #check if _extract_sdk_ver_ is in SDK_VER
      if [[ ! " ${SDK_VER[@]} " =~ " ${_extract_sdk_ver_} " ]];
      then
        SDK_VER+=("${_extract_sdk_ver_}")
        outLog "Added ${_extract_sdk_ver_} as SDK to download"
      else
        outLog "SDK version ${_extract_sdk_ver_} already in SDK_VER"
      fi
    else
      outLog "WARNING: ${_cmd_} exited w/ non-0. Bailing on this SDK extraction method"
      outLog "Output: ${_opt_}"
    fi
  else
    outLog "WARNING: ${_sdk_extract_script_} does not exist. Bailing on this SDK extraction method"
    _e_=1
  fi
  return $_e_
}

# ------------------------------------------------------------------------------
# Function: _setGblSdkFromIso_
#   Extracts the SDK version from the ISO using various methods and sets it globally.
#   Usage: _setGblSdkFromIso_ "/path/to/iso"
# ------------------------------------------------------------------------------
function _setGblSdkFromIso_() {
  _iso_file_=$1
  _e_=0
  _sdk_extract_script_="${_scripts_folder_}/bin/getSdk.sh"
  if [[ -e ${_sdk_extract_script_} ]];
  then
    outLog "Attempting to use ${_sdk_extract_script_} to extract sdk version from ${_iso_file_}"
    mkdir -p ./.sdk_extract_ws
    pushd ./.sdk_extract_ws > /dev/null 2>&1
    _cmd_="${_sdk_extract_script_} ${_iso_file_}"
    _opt_="$(eval ${_cmd_} 2>&1)"
    _e_=$?
    popd > /dev/null 2>&1
    rm -rf ./.sdk_extract_ws

    if [[ ${_e_} -eq 0 ]];
    then
      SDK_VER+=("${_opt_}")
      outLog "Added ${_opt_} as SDK to download"
    else
      outLog "WARNING: ${_cmd_} exited w/ non-0. Will attempt to use isoinfo to extract sdk version from ${_iso_file_}"
    fi
  else
    outLog "WARNING: ${_sdk_extract_script_} does not exist. Will attempt to use isoinfo to extract sdk version from ${_iso_file_}"
  fi


  _getisoinfo_="isoinfo -R -x /sim_cfg.yml -i"
  _e_=0
  _cmd_="${_getisoinfo_} ${_iso_file_} | grep sdk: | awk '{print \$2}'"
  outLog "Extracting sdk version from ${_iso_file_} using CMD: ${_cmd_}"
  _sdk_ver_="$(eval ${_cmd_})"
  _e_=$?
  if [[ ${_sdk_ver_} == "" ]];
  then
    outLog "Could not extract using CMD: ${_cmd_}"
    _cmd_="${_getisoinfo_} ${_iso_file_} | grep sdk_ver_pacific: | awk '{print \$2}'"
    outLog "Trying again using CMD: ${_cmd_}"
    _sdk_ver_="$(eval ${_cmd_})"
    _e_=$?
  fi
  if [[ ! " ${SDK_VER[@]} " =~ " ${_sdk_ver_} " ]];
  then
    #check if _sdk_ver_ is in SDK_VER
    if [[ ! " ${SDK_VER[@]} " =~ " ${_sdk_ver_} " ]];
      then
        SDK_VER+=("${_sdk_ver_}")
        outLog "Added ${_sdk_ver_} as SDK to download"
      else
        outLog "SDK version ${_sdk_ver_} already in SDK_VER"
      fi
  else
    outLog "${_sdk_ver_} extracted from sim_cfg.yml is the same as the one extracted from rpm"
  fi
  return $_e_
}

# ------------------------------------------------------------------------------
# Function: _injectSdk_
#   Injects the specified SDK into the Docker container.
#   Usage: _injectSdk_ "docker_runtime_name" "sdk_deb_file"
# ------------------------------------------------------------------------------
function _injectSdk_() {
  _docker_rn_="${1}"
  _sdk_file_="${2}"
  _sdk_filename_=$(basename ${_sdk_file_})
  ensureDCIsRunning "${_docker_rn_}"
  outLog "Copying ${_sdk_file_} to ${_docker_rn_}:/opt/ovxr-release/packages/debs"
  docker cp ${_sdk_file_} ${_docker_rn_}:/opt/ovxr-release/packages/debs/
  [ $? -ne 0 ] && outLog "Failed to copy ${_sdk_file_} to ${_docker_rn_}:/opt/ovxr-release/packages/debs" && return 1
  outLog "Installing to container using dpkg -i"
  runInDC "sudo dpkg -i /opt/ovxr-release/packages/debs/${_sdk_filename_}" "${_docker_rn_}"
  [ $? -ne 0 ] && outLog "Failed to install ${_sdk_filename_} to ${_docker_rn_}" && return 1
  outLog "Successfully injected ${_sdk_filename_} to ${_docker_rn_}"
  return 0
}

# ------------------------------------------------------------------------------
# Function: ensureDCIsRunning
#   Ensures the specified Docker container is running.
#   Usage: ensureDCIsRunning "docker_runtime_name"
# ------------------------------------------------------------------------------
function ensureDCIsRunning() {
  _docker_runtime_name_=$1
  for f in {1..4};
  do
    docker start ${_docker_runtime_name_} > /dev/null 2>&1
    outLog "Checking if docker container ${_docker_runtime_name_} is online.."
    if [[ "$(docker container inspect -f '{{.State.Status}}' ${_docker_runtime_name_} 2>/dev/null)" == "running" ]];
    then
      outLog "container is running..! Continuing with operation"
      return 0
      break
    fi
    if [[ ${f} -eq 4 ]]; then
	outLog "container ${_docker_runtime_name_} is not coming online.. "
	return 1
    fi
    _sleep_=10
    outLog "container is not running yet.. checking again in ${_sleep_} seconds"
    sleep ${_sleep_}s

  done
  return 1
}

# ------------------------------------------------------------------------------
# Function: determineDOCKER_NAME
#   Determines the DOCKER_NAME before ISO gets moved or modified.
#   If USER_DOCKER_NAME is provided via -d option, use that.
#   Otherwise, extract version from ISO name and create format: <plat_to_build>:<iso_version>
# ------------------------------------------------------------------------------
function determineDOCKER_NAME() {
  # Map USER_DOCKER_NAME to DOCKER_NAME if provided via -d option
  if [[ "${USER_DOCKER_NAME}" ]]; then
    DOCKER_NAME="${USER_DOCKER_NAME}"
  elif [[ "${DOCKER_NAME}" == "" ]]; then
    # Extract ISO version from ISO name before it potentially gets moved
    USER_ISO_NAME="$(basename ${USER_ISO_DIR}/*.iso)"
    USER_ISO_VER="$(echo ${USER_ISO_NAME%.iso} | awk -F'-' '{print $NF}')" # Remove .iso extension
    if [ $? -ne 0 ]; then
      outLog "Failed to extract version from ISO name: ${USER_ISO_NAME}"
      outLog "Will default to using 'latest' as the docker image tag"
      USER_ISO_VER="latest"
    fi
    DOCKER_NAME="${PLAT_TO_BUILD}:${USER_ISO_VER}"
  fi
  
  # Make sure the docker name is all lower case
  DOCKER_NAME="$(echo ${DOCKER_NAME} | tr '[:upper:]' '[:lower:]')"
  
  outLog "DOCKER_NAME determined as: ${DOCKER_NAME}"
}

# ------------------------------------------------------------------------------
# Function: patchIsoWithEncOff
#   Patches the ISO to add enc_off=1 to sim_cfg.yml using vxr_set_yml_in_iso.sh
#   Usage: patchIsoWithEncOff
# ------------------------------------------------------------------------------
function patchIsoWithEncOff() {
  outLog "Starting ISO patching process to add enc_off=1"
  
  # Create temporary workspace in root directory
  _temp_workspace_="${_root_folder_}/tmp_iso_patch_$$"
  outLog "Creating temporary workspace: ${_temp_workspace_}"
  mkdir -p "${_temp_workspace_}"
  if [[ $? -ne 0 ]]; then
    outLog "[ERROR] Failed to create temporary workspace: ${_temp_workspace_}"
    return 1
  fi
  
  # Copy all ISO and QCOW2 files from USER_ISO directory to temporary workspace
  _user_iso_dir_="$(dirname "${USER_ISO}")"
  _temp_iso_="${_temp_workspace_}/$(basename "${USER_ISO}")"
  outLog "Copying ISO and QCOW2 files from ${_user_iso_dir_} to ${_temp_workspace_}"
  
  # First, find and log what files will be copied
  _files_to_copy_=($(find "${_user_iso_dir_}" -maxdepth 1 -type f \( -iname "*.iso" -o -iname "*.qcow2" \)))
  outLog "Found ${#_files_to_copy_[@]} ISO/QCOW2 files to copy:"
  for _file_ in "${_files_to_copy_[@]}"; do
    outLog "  - $(basename "${_file_}")"
  done
  
  # Copy the files and log each copy operation
  for _file_ in "${_files_to_copy_[@]}"; do
    outLog "Copying: $(basename "${_file_}")"
    cp "${_file_}" "${_temp_workspace_}/"
    if [[ $? -eq 0 ]]; then
      outLog "  Successfully copied $(basename "${_file_}")"
    else
      outLog "  Failed to copy $(basename "${_file_}")"
      rm -rf "${_temp_workspace_}"
      return 1
    fi
  done
  # Set _temp_iso_ to the path of the ISO file in the temp workspace
  _temp_iso_="${_temp_workspace_}/$(basename "${USER_ISO}")"
  
  # Extract sim_cfg.yml from the ISO
  _temp_sim_cfg_="${_temp_workspace_}/sim_cfg.yml"
  outLog "Extracting sim_cfg.yml from ISO: ${_temp_iso_}"
  isoinfo -R -x /sim_cfg.yml -i "${_temp_iso_}" > "${_temp_sim_cfg_}"
  if [[ $? -ne 0 ]]; then
    outLog "[ERROR] Failed to extract sim_cfg.yml from ISO"
    rm -rf "${_temp_workspace_}"
    return 1
  fi
  
  outLog "Original sim_cfg.yml content:"
  cat "${_temp_sim_cfg_}"
  
  # Check if enc_off is already present
  if grep -q "enc_off" "${_temp_sim_cfg_}"; then
    outLog "enc_off already exists in sim_cfg.yml, modifying value to 1"
    sed -i 's/enc_off=.*/enc_off=1/' "${_temp_sim_cfg_}"
  else
    outLog "Adding enc_off=1 to sim_cfg.yml"
    echo "enc_off=1" >> "${_temp_sim_cfg_}"
  fi
  
  outLog "Modified sim_cfg.yml content:"
  cat "${_temp_sim_cfg_}"
  
  # Use vxr_set_yml_in_iso.sh to patch the ISO
  _vxr_script_="${_root_folder_}/scripts/bin/vxr_set_yml_in_iso.sh"
  outLog "Using script: ${_vxr_script_}"
  outLog "Patching ISO with modified sim_cfg.yml"
  
  # Change to temp workspace to ensure relative paths work correctly
  pushd "${_temp_workspace_}" > /dev/null
  "${_vxr_script_}" "${_temp_iso_}" "${_temp_sim_cfg_}"
  _patch_result_=$?
  popd > /dev/null
  
  if [[ ${_patch_result_} -ne 0 ]]; then
    outLog "[ERROR] Failed to patch ISO using vxr_set_yml_in_iso.sh"
    rm -rf "${_temp_workspace_}"
    return 1
  fi
  
  # Remove sim_cfg.yml from temporary workspace
  rm -f "${_temp_sim_cfg_}"
  
  # The patched ISO should be ${_temp_iso_}.patched
  _patched_iso_="${_temp_iso_}.patched"
  if [[ ! -e "${_patched_iso_}" ]]; then
    outLog "[ERROR] Patched ISO not found: ${_patched_iso_}"
    rm -rf "${_temp_workspace_}"
    return 1
  fi
  
  outLog "Successfully created patched ISO: ${_patched_iso_}"
  
  # Rename patched ISO and point $USER_ISO to it
  outLog "Renaming patched ISO to ${_temp_iso_}"
  mv "${_patched_iso_}" "${_temp_iso_}"
  if [[ $? -ne 0 ]]; then
    outLog "[ERROR] Failed to rename patched ISO"
    rm -rf "${_temp_workspace_}"
    return 1
  fi
  
  # Update USER_ISO to point to patched version
  USER_ISO="${_temp_iso_}"
  outLog "Updated USER_ISO to: ${USER_ISO}"

  # Print new sim_cfg.yml content for verification
  outLog "Verifying patched sim_cfg.yml content from patched ISO:"
  isoinfo -R -x /sim_cfg.yml -i "${USER_ISO}"

  outLog "ISO patching completed successfully"
  return 0
}

# ------------------------------------------------------------------------------
# Function: runInDC
#   Runs a command inside the specified Docker container.
#   Usage: runInDC "command" "docker_runtime_name"
# ------------------------------------------------------------------------------
function runInDC() {
  _cmd_="${1}"
  _docker_runtime_name_="${2}"
  ensureDCIsRunning ${_docker_runtime_name_}
  if [[ $? -eq 0 ]];
  then
    sleep 1s
    for f in {0..5};
    do
      echo "${_cmd_}"| docker exec -i ${_docker_runtime_name_}  /bin/bash
      if [ $? -eq 0 ];
      then
	outLog "Ran cmd ${_cmd_} in ${_docker_runtime_name_}"
	break
      fi
      sleep 2s
      ensureDCIsRunning ${_docker_runtime_name_}
      sleep 2s
    done
    return 0
  else
    outLog "Failed to run cmd ${_cmd_} in ${_docker_runtime_name_}"
    return 1
  fi

}

# ------------------------------------------------------------------------------
# Function: cleanupTempWorkspaces
#   Cleans up any temporary ISO patch workspaces
# ------------------------------------------------------------------------------
function cleanupTempWorkspaces() {
  outLog "Cleaning up temporary ISO patch workspaces"
  for temp_dir in "${_root_folder_}"/tmp_iso_patch_*; do
    if [[ -d "${temp_dir}" ]]; then
      outLog "Removing temporary workspace: ${temp_dir}"
      rm -rf "${temp_dir}"
    fi
  done
}

# Set up trap to clean up on exit
trap cleanupTempWorkspaces EXIT

# OPTIONAL ARGUMENTS START #
OPTIONS=t:d:p:o:i:rh
LONGOPTIONS=forcesdk:,listplatforms

# Parse the options
PARSED=$(getopt --options=$OPTIONS --longoptions=$LONGOPTIONS --name "$0" -- "$@")
if [[ $? -ne 0 ]]; then
    # If getopt has complained about wrong arguments, print the help message and exit
    help
    exit 1
fi

# Use eval with set to properly handle the parsed options
eval set -- "$PARSED"

while true; do
    case "$1" in
        -t)
            TARGET_TO_BUILD="${2}"
            shift 2
            ;;
        -d)
            USER_DOCKER_NAME="${2}"
            shift 2
            ;;
        -p)
            PLAT_TO_BUILD="${2}"
            shift 2
            ;;
        -o)
            USER_OVXR_DOCKER="${2}"
            shift 2
            ;;
        -i)
            USER_ISO="$(realpath ${2})"
            [[ "${USER_ISO}" != *.iso ]] && help && echo "Please pass in the path to an ISO using -i." && \
            echo "Eg: -i /path/to/file.iso" && exit 1
            shift 2
            ;;
        -r)
            REBUILD_OVXR_DOCKER=0
            shift 1
            ;;
        -h)
            help
            exit 0
            ;;
        --forcesdk)
            FORCE_SDK="${2}"
            _skip_sdk_="True"
            shift 2
            ;;
        --listplatforms)
            list_available_platforms
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Invalid option: $1"
            help
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))
# OPTIONAL ARGUMENTS   END #

# ------------------------------------------------------------------------------
# Main script logic
# ------------------------------------------------------------------------------

# Process positional parameters
for arg in "$@";
do
  if [[ ${arg} == 'skip_sdk_lookup' ]];
  then
    _skip_sdk_="True"
    outLog "_skip_sdk_ enabled. NO SDK LOOKUP"
  elif [[ ${arg} == "no_unique_ovxr_name" ]];
  then
    _no_unique_ovxr_name_="True"
    outLog "_no_unique_ovxr_name_ enabled. the ovxr-dev image built to bake the image will use default name: ovxr-dev:latest"
  elif [[ ${arg} == "stable" ]];
  then
    _use_stable_ovxrdev_="True"
    outLog "_use_stable_ovxrdev_ enabled. Will use stable ovxr-dev image from containers.cisco.com/wmyint/ovxr-dev:stable"
  elif [[ ${arg} == "insidedocker" ]];
  then
    _inside_docker_="True"
    outLog "_inside_docker_ enabled."
  elif [[ ( ${arg} == "force_sdk_only" ) || ( ${arg} == "force_sdk_only_and_save" ) ]];
  then
    _FORCE_SDK_ONLY_="True"
    _no_unique_ovxr_name_="True"

    if [[ ${args} == "force_sdk_only_and_save" ]];
    then
      _FORCE_SDK_AND_SAVE_="True"
      outLog "force_sdk_only_and_save enabled. Will docker commit the ovxr-dev image after injecting the SDK"
    fi

    #Exit if FORCE_SDK is not set
    if [[ ! ${FORCE_SDK} ]];
    then
      outLog "FORCE_SDK is not set. Pass in --forcesdk <sdk_version> to force a specific sdk version with force_sdk_only"
      exit 1
    fi
  elif [[ ${arg} == "keep_force_sdk_only" ]];
  then
    _keep_force_sdk_only_="True"
    outLog "_keep_force_sdk_only_ enabled. Will remove all other SDKs except the one specified in FORCE_SDK"
  fi
  if [[ ${arg} == "isoboot" ]];
  then
    _isoboot_="True"
    ISO_BOOT_ARG="-n"
    outLog "_isoboot_ enabled. Will skip bake"
  fi
  if [[ ${arg} == "encoff" ]];
  then
    _enc_off_="True"
    outLog "_enc_off_ enabled. Will disable encryption during bake"
  fi
done

# MAIN #
_TTY_="-it"
for arg in "$@";
do
  if [[ ${arg} == "notty" ]];
  then
    _TTY_=""
  fi
done

echo "=======================================================
        ${_CUR_FILE_PATH_} called!
        Printing Parameters & Running Checks before starting
======================================================="
#print out the parameters
echo "PLAT_TO_BUILD:      ${PLAT_TO_BUILD}"
echo "TARGET_TO_BUILD:    ${TARGET_TO_BUILD}"
echo "USER_ISO:           ${USER_ISO}"
echo "USER_DOCKER_NAME:   ${USER_DOCKER_NAME}"
[[ ${_inside_docker_} ]] && echo "INSIDE_DOCKER:   ${_inside_docker_}" || echo "INSIDE_DOCKER:   False :: CWD ${_root_folder_}"
echo "---------------------------------
 Optional Parameters
---------------------------------"
[[ "${_no_unique_ovxr_name_}" ]] && echo "_no_unique_ovxr_name_:                ${_no_unique_ovxr_name_}" || echo "_no_unique_ovxr_name_:                n/a"
[[ "${USER_OVXR_DOCKER}" ]] && echo "USER_OVXR_DOCKER:                ${USER_OVXR_DOCKER}" || echo "USER_OVXR_DOCKER:                n/a"
[[ "${REBUILD_OVXR_DOCKER}" ]] && echo "REBUILD_OVXR_DOCKER:                ${REBUILD_OVXR_DOCKER}" || echo "REBUILD_OVXR_DOCKER:                n/a"
[[ "${_skip_sdk_}" ]] && echo "_skip_sdk_:                ${_skip_sdk_}" || echo "_skip_sdk_:                False"
[[ "${FORCE_SDK}" ]] && echo "FORCE_SDK:                ${FORCE_SDK}" || echo "FORCE_SDK:                n/a"
[[ "${_FORCE_SDK_ONLY_}" ]] && echo "_FORCE_SDK_ONLY_:                ${_FORCE_SDK_ONLY_}" || echo "_FORCE_SDK_ONLY_:                n/a"  
[[ "${_keep_force_sdk_only_}" ]] && echo "_keep_force_sdk_only_:                ${_keep_force_sdk_only_}" || echo "_keep_force_sdk_only_:                n/a"
[[ "${_isoboot_}" ]] && echo "_isoboot_:                ${_isoboot_}" || echo "_isoboot_:                n/a"

#Output notice notification to stdout if _FORCE_SDK_ONLY_ is set that only sdk injection is happening
if [[ ${_FORCE_SDK_ONLY_} ]];
then
  echo "=============================================================
 !!  _FORCE_SDK_ONLY_ is set. Only SDK injection will happen !!
============================================================="
fi

if [[ ! ${_FORCE_SDK_ONLY_} ]];
then
  #checks
  checkPlats "${PLAT_TO_BUILD}"
  [[ ! ${PLAT_TO_BUILD} ]] && help && echo "Pass -p <plat>" && exit 1
  checkTarget "${TARGET_TO_BUILD}"

  which isoinfo > /dev/null 2>&1
  [[ $? -ne 0 ]] && echo "isoinfo missing. Please install rpm genisoimage" && exit 1

  USER_ISO="$(realpath ${USER_ISO})"
  USER_ISO_NAME="$(basename ${USER_ISO} | sed 's/.iso//g')"

  #YAML DROP LOCATION & ISO DROP LOCATION#
  _yaml_folder_prefix_="user-custom-yaml-${USER_ISO_NAME}-"
  _img_folder_prefix_="user-custom-iso-${USER_ISO_NAME}-"
  i=1
  _yaml_drop_folder_="${_yaml_drop_parent_folder_}/${_yaml_folder_prefix_}${i}"
  _img_drop_folder_="${_images_drop_parent_folder_}/${_img_folder_prefix_}${i}"
  while true;
  do
    if [[ ( -e ${_yaml_drop_folder_} ) || ( -e ${_img_drop_folder_}) ]];
    then
      ((i+=1))
      _yaml_drop_folder_="$(echo ${_yaml_drop_folder_:0:-1}${i})"
      _img_drop_folder_="$(echo ${_img_drop_folder_:0:-1}${i})"
    else
      break
    fi
  done
  _yaml_drop_folder_="$(realpath ${_yaml_drop_folder_})"
  _img_drop_folder_="$(realpath ${_img_drop_folder_})"
  _yaml_img_folder_="/opt/cisco/images/user-custom/$(basename ${_img_drop_folder_})"


  [[ ! -e ${USER_ISO} ]] && echo "${USER_ISO} does not exist! Pass in a valid path to an ISO" && exit 1 #TODO: exit w/ help msg
  USER_ISO_DIR="$(cd "$(dirname ${USER_ISO})"; pwd -P)"

  # Patch ISO to add enc_off=1 to sim_cfg.yml
  if [[ ${_enc_off_} == "True" ]];
  then
    echo ""
   echo "$(printf '=%.0s' {1..55})
        Patching ISO to disable encryption (enc_off=1)
$(printf '=%.0s' {1..55})"
  
    outLog "Patching ISO to add enc_off=1 to sim_cfg.yml"
    patchIsoWithEncOff
    if [[ $? -ne 0 ]]; then
      outLog "[ERROR] Failed to patch ISO with enc_off=1"
      exit 1
    fi
    # Update USER_ISO_DIR to reflect the new patched ISO location
    USER_ISO_DIR="$(cd "$(dirname ${USER_ISO})"; pwd -P)"
  fi


  echo "=======================================================
        Paths
======================================================="
  echo "YAML_DROP_FOLDER:   ${_yaml_drop_folder_}"
  echo "IMG_DROP_FOLDER:    ${_img_drop_folder_}"
  echo "YAML_IMG_FOLDER:    ${_yaml_img_folder_}"
  echo "USER_ISO:           ${USER_ISO}"

fi
echo "



=======================================================
        Checking for existing qcow2 files
======================================================="
# Check if there's a qcow2 file in the same folder as the USER_ISO
# If found, we can skip creating a bake environment
USER_ISO_DIR="$(dirname "${USER_ISO}")"
outLog "Checking for existing qcow2 files in ISO directory: ${USER_ISO_DIR}"

FOUND_QCOW2_FILES=()
for qcow2_file in "${USER_ISO_DIR}"/*.qcow2; do
  if [[ -f "$qcow2_file" ]]; then
    FOUND_QCOW2_FILES+=("$qcow2_file")
    outLog "Found qcow2 file: $(basename "$qcow2_file")"
  fi
done

# Check for distributed platform qcow2 structure (e.g., 8808/lc/hda, 8808/rp/hda)
FOUND_DISTRIBUTED_QCOW2=0
for platform_dir in "${USER_ISO_DIR}"/88[0-9][0-9]; do
  if [[ -d "$platform_dir" ]]; then
    platform_name=$(basename "$platform_dir")
    outLog "Checking distributed platform directory: $platform_name"
    
    # Look for lc/hda and rp/hda components specifically
    lc_hda_file="${platform_dir}/lc/hda"
    rp_hda_file="${platform_dir}/rp/hda"
    
    if [[ -f "$lc_hda_file" && -f "$rp_hda_file" ]]; then
      outLog "Found distributed platform qcow2 structure for $platform_name:"
      outLog "  - lc/hda: $lc_hda_file"
      outLog "  - rp/hda: $rp_hda_file"
      FOUND_QCOW2_FILES+=("$lc_hda_file")
      FOUND_QCOW2_FILES+=("$rp_hda_file")
      FOUND_DISTRIBUTED_QCOW2=1
    else
      # Alternative: look for any component directories with hda files
      component_count=0
      for component_dir in "${platform_dir}"/*; do
        if [[ -d "$component_dir" ]]; then
          hda_file="${component_dir}/hda"
          if [[ -f "$hda_file" ]]; then
            component_name=$(basename "$component_dir")
            outLog "  - $component_name/hda: $hda_file"
            FOUND_QCOW2_FILES+=("$hda_file")
            ((component_count++))
          fi
        fi
      done
      
      if [[ $component_count -ge 2 ]]; then
        outLog "Found distributed platform qcow2 structure for $platform_name with $component_count components"
        FOUND_DISTRIBUTED_QCOW2=1
      fi
    fi
  fi
done

SKIP_BAKE_ENV=0
if [[ ${#FOUND_QCOW2_FILES[@]} -gt 0 ]]; then
  if [[ $FOUND_DISTRIBUTED_QCOW2 -eq 1 ]]; then
    outLog "Found distributed platform qcow2 structure with ${#FOUND_QCOW2_FILES[@]} component file(s)"
  else
    outLog "Found ${#FOUND_QCOW2_FILES[@]} qcow2 file(s) in the same directory as the ISO"
  fi
  outLog "Skipping bake environment creation since qcow2 files are already available"
  SKIP_BAKE_ENV=1
else
  outLog "No qcow2 files found in ISO directory. Will proceed with bake environment creation"
fi

echo "



=======================================================
        Establishing ovxr-dev Environment
======================================================="
if [[ ( "${_inside_docker_}" == "" ) || ( ${_FORCE_SDK_ONLY_} ) ]] && [[ ${SKIP_BAKE_ENV} -eq 0 ]];
then
  _build_ovxr_=1
  if [[ "${_no_unique_ovxr_name_}" == "" ]];
  then
    outLog "Generating unique random docker image name to use to tag the bake environment"
    #create random dockername to use as dockername and as well as foldername
    i=1
    _dn_name_="ovxr-dev-$(date +%N)-${i}"
    while true;#double check dockercontainer image name does not exist
    do
      docker exec ${_dn_name_} whoami > /dev/null 2>&1
      if [[ $(docker image ls "${_dn_name_}:latest" | sed 1d | wc -l) -ge 1 ]];
      then
        ((i+=1))
        _dn_name_="$(echo ${_dn_name_:0:-1}${i})"
        continue
      fi
      break
    done
    OVXR_DOCKER="${_dn_name_}:latest"
  else
    OVXR_DOCKER="ovxr-dev:latest"
  fi
  [[ ${_use_stable_ovxrdev_} ]] && OVXR_DOCKER_FROM_CONTAINERS="containers.cisco.com/wmyint/ovxr-dev:stable" || OVXR_DOCKER_FROM_CONTAINERS="containers.cisco.com/wmyint/ovxr-dev:latest"
  #User passed in their own ovxr-dev by docker image name  to use or they _FORCE_SDK_ONLY_ is set
  if [[ ( "${USER_OVXR_DOCKER}" ) || ( ${_FORCE_SDK_ONLY_} ) ]]; 
  then
    outLog "Using user passed in ovxr-dev docker image: ${USER_OVXR_DOCKER}"
    if [[ $(docker images -q ${USER_OVXR_DOCKER} | wc -l) -ge 1 ]];
    then
      OVXR_DOCKER="${USER_OVXR_DOCKER}"
      outLog "${OVXR_DOCKER} exists on this server. Will use it as the bake & build environment"
    else
      outLog "Failed to find ${USER_OVXR_DOCKER} on this server.. will resort to building ovxr-dev from dockerfile"
     _build_ovxr_=0
     
     #Quit if _FORCE_SDK_ONLY_ is set
     if [[ ${_FORCE_SDK_ONLY_} ]];
     then
       outLog "_FORCE_SDK_ONLY_ is set. Cannot continue without user passing in a valid ovxr-dev docker image via -o <docker_image>"
       exit 1
     fi
    fi

  else #User did not pass in their own ovxr-dev container to use, assessing whether or not ${OVXR_DOCKER} is available on the machine
    if [[ ! ${REBUILD_OVXR_DOCKER} ]];
    then
      #docker image ovxr-dev:latest was not found and user did not request to rebuild ovxr-dev, pulling from ${OVXR_DOCKER_FROM_CONTAINERS}
      outLog "Tagging ${OVXR_DOCKER_FROM_CONTAINERS} to ${OVXR_DOCKER} <-- This will be our bake & build environment"
      docker image pull ${OVXR_DOCKER_FROM_CONTAINERS} && docker image tag ${OVXR_DOCKER_FROM_CONTAINERS} ${OVXR_DOCKER}
      [ $? -ne 0 ] && outLog "operation failed.. will attempt to build ${OVXR_DOCKER} from dockerfile" && _build_ovxr_=0
    fi

    if [[ ${REBUILD_OVXR_DOCKER} ]];#Force ovxr-dev rebuild
    then
      _build_ovxr_=0
      outLog "-r was passed in. Forcing ovxr-dev docker image build before building target"
    fi
  fi

  if [[ ( ${_build_ovxr_} -eq 0 ) && ( ! ${_FORCE_SDK_ONLY_} ) ]];
  then
    outLog "Ovxr-dev container rebuilding.."
    eval "${_build_ovxr_script_}" "${OVXR_DOCKER}"
    [[ $? -ne 0 ]] && outLog "Failed to build the ovxr container.. please address the issue before continuing" && exit 1
  fi
else
  if [[ ${SKIP_BAKE_ENV} -eq 1 ]]; then
    outLog "Skipping ovxr-dev environment creation - using existing qcow2 files"
  else
    outLog "Operating inside docker.. will use this docker instance's /opt/ovxr-release as bake & build environment"
  fi
fi

echo "

=======================================================
        SDK Dependency Check
======================================================="
#DETERMINE SDK OF ISO AND FULFILL SDK DEPENDENCIES IF NECESSARY#
#THIS WILL CHECK TO MAKE SURE BAKE AND BUILD ENV. HAVE THE NECESSARY SDK ACCORDING TO THE
#sim_cfg.yml OF THE ISO
#IT IS THE UERS' RESPONSIBILITY TO PROVIDE PROPER sim_cfg.yml
#

# if [[ ${SKIP_BAKE_ENV} -eq 1 ]]; then
#   outLog "Skipping SDK dependency check since qcow2 files are already available"
#   outLog "Assuming SDK dependencies are already fulfilled in existing qcow2 files"
# el
if [[ "${_skip_sdk_}" == "True" ]]; #This is set to true autoamtically if --forcesdk is passed in
then
  if [[ "${FORCE_SDK}" == "" ]];
  then
    help 
    outLog "[ERROR] --forcesdk was not passed in. Cannot skip SDK lookup without --forcesdk"
  fi
  outLog "Skipping SDK lookup since --forcesdk \"${FORCE_SDK}\" was passed in"
  #FORCE_SDK can have multiple SDKs to download and include in bake & build env. so parse through them and add each individual into SDK_VER. Delimiter is " "
  IFS=' ' read -r -a TMP_SDK_ARRAY <<< "${FORCE_SDK}"

  for sdk in "${TMP_SDK_ARRAY[@]}"; do
    SDK_VER+=("${sdk}")
    outLog "Added ${sdk} as SDK to download and include in bake & build env."
  done
else
  #UPDATE 09/06/2024: Added ability to properly extract sdk by invoking sim bring-up via ./ovxr-release/scripts/bin/validateIso.py
  #This method will be invoked via _setGblSdkFromIsoUsingValidateIso_() function
  outLog "Running Checks to see if SDK dependency is fulfilled"
  _setGblSdkFromIsoUsingValidateIso_ ${USER_ISO} #This will extract sdk via sim launch
  _setGblSdkFromIso_ ${USER_ISO} #This will extract sdk version from sim_cfg.yml and rpm
  #SO why are we considering both methods? Because we want to make sure we have the correct SDK debs to both:
  #1 - boot the sim (what is in sim_cfg.yml is what is needed to boot the sim)
  #2 - appropriately launch the sim (which is the actual SDK version that the iso needs)
  # bake_in_container_startup.sh will detect if the SDK needs modifying in sim_cfg.yml of the iso
  # we just need to make sure the needed SDK debs are in place
fi

if [[ "${SDK_VER}" == "" ]];
then
  outLog "Could not determine SDK version from ${USER_ISO}. Cannot continue" && exit 1
fi
outLog "SDK version(s) of ${USER_ISO} found in RPM & sim_cfg: "
echo "${SDK_VER[@]}"

if [[ ${_keep_force_sdk_only_} ]];
then
  outLog "_keep_force_sdk_only_ is set. Will clean all SDKs first before injecting ${FORCE_SDK}"
  if [[ ${_inside_docker_} ]];
  then
    sudo apt purge vxr2-ngdp-* -y
    rm -rf /opt/ovxr-release/packages/debs/vxr2-ngdp-*
    outLog "Removed all SDKs from /opt/ovxr-release/packages/debs and uninstalled all SDKs"
  else
    #TODO: Implement this
    outLog "This operation is only supported inside docker. Please run this script inside docker and pass in \"insidedocker\". Pass in -h for more info"
  fi
fi

# ------------------------------------------------------------------------------
# Loop through each SDK version and ensure it is available in the environment.
# If not, download and install it.
# ------------------------------------------------------------------------------
for _cur_sdk_ in "${SDK_VER[@]}"
do
  outLog "Checking if ${_cur_sdk_} exists"
  if [[ ${_inside_docker_} ]];
  then
    _cmd_="ls /opt/cisco/ngdp/libngdp-*${_cur_sdk_}-*.so"
  else
    if [[ ${SKIP_BAKE_ENV} -eq 1 ]]; then
      # Check ./packages/debs/ for the SDK since we are skipping bake env creation
      _cmd_="ls ${_packages_folder_}/debs/vxr2-ngdp-*${_cur_sdk_}*.deb"
    else
      _cmd_="docker run --privileged --rm ${OVXR_DOCKER} 'ls /opt/cisco/ngdp/libngdp-*${_cur_sdk_}-*.so'"
    fi
  fi
  outLog "Checking ${OVXR_DOCKER} if SDK ${_cur_sdk_} is available using CMD: ${_cmd_}"
  eval "${_cmd_}"
  if [ $? -ne 0 ];
  then
    _inject_e_=0
    # Pre-staged .deb under packages/debs (offline builds; e.g. docker cp before running this script)
    if [[ ${_inside_docker_} ]];
    then
      shopt -s nullglob
      _prestaged=(/opt/ovxr-release/packages/debs/vxr2-ngdp-*"${_cur_sdk_}"*.deb)
      shopt -u nullglob
      if [[ ${#_prestaged[@]} -gt 0 ]];
      then
        _dl_sdk_="${_prestaged[0]}"
        outLog "Installing pre-staged SDK deb (offline, skips vxr-nfs): ${_dl_sdk_}"
        sudo dpkg -i "${_dl_sdk_}"
        if [[ $? -eq 0 ]];
        then
          outLog "Pre-staged SDK installed successfully"
          continue
        fi
        outLog "WARNING: dpkg -i failed for pre-staged deb; will try download"
      fi
    fi
    outLog "SDK ${_cur_sdk_} not found in ${OVXR_DOCKER}. Attempting to download it"
    mkdir -p .tmp
    pushd .tmp >/dev/null 2>&1
    _dlNgdpSdk_ ${_cur_sdk_}
    if [[ $? -ne 0 ]];
    then
        popd
        outLog "ERROR: Failed to download SDK ${_cur_sdk_} to fulfill missing NGDP SDK. Please check if NGDP SDK is built, and available at /auto/vxr/ngdp/external/rpms"
        exit 1
    else
      _dl_sdk_=$(realpath $(pwd)/*.deb)
      outLog "Successfully downloaded to ${_dl_sdk_}"
    fi
    _tmp_pkgs_folder_="${_packages_folder_}/debs"
    outLog "Copying it over to local workspace ${_tmp_pkgs_folder_}"
    mkdir -p "${_tmp_pkgs_folder_}"
    /usr/bin/cp ${_dl_sdk_} "${_tmp_pkgs_folder_}/"
    #Now we have to make sure the SDK is available in the bake&build env.#
    if [[ ${_inside_docker_} ]];
    then
      #If we are already inside a docker build env, we just need to wget, install the file, and mv it to /opt/ovxr-release/packages/debs/
      outLog "Considering we are inside a docker env., we will just install the SDK ${SDK_VER} and move it to /opt/ovxr-release/packages/debs/"
      outLog "Attempting to install ${_dl_sdk_}"
      sudo dpkg -i ${_dl_sdk_}
      [ $? -ne 0 ] && outLog "Failed to install ${_dl_sdk_}" && _inject_e_=1
      outLog "Moving ${_dl_sdk_} to /opt/ovxr-release/packages/debs/"
      sudo mv ${_dl_sdk_} /opt/ovxr-release/packages/debs/
      [ $? -ne 0 ] && outLog "Failed to move ${_dl_sdk_} to /opt/ovxr-release/packages/debs/" && _inject_e_=1
    else
      _d_rn_="ovxr-dev-ngdp-injection-$(date +%N)"
      outLog "Attempting to inject SDK ${SDK_VER} into ${OVXR_DOCKER} using docker container ${_d_rn_}"
      docker run -i --privileged --name ${_d_rn_} ${OVXR_DOCKER} > /dev/null 2>&1 &
      sleep 2s
      _injectSdk_ ${_d_rn_} ${_dl_sdk_}
      _inject_e_=$?
      if [[ ${_inject_e_} -eq 0 ]];
      then
        outLog "Saving ${_d_rn_} as ${OVXR_DOCKER}"
        docker commit ${_d_rn_} ${OVXR_DOCKER}
        [ $? -ne 0 ] && outLog "Failed to commit ${_d_rn_} to ${OVXR_DOCKER}" && _inject_e_=1
      fi
      docker kill ${_d_rn_} > /dev/null 2>&1
      docker container rm ${_d_rn_} > /dev/null 2>&1
    fi
    popd > /dev/null 2>&1
    rm -rf .tmp
    if [[ ${_inject_e_} -ne 0 ]];
    then
      if [[ ${_inside_docker_} ]];
      then
        outLog "ERROR: Failed to install ${_cur_sdk_} and move it to /opt/ovxr-release/packages/debs/ inside docker env. Please check if NGDP SDK is built, and available at /auto/vxr/ngdp/external/rpms EXITING"
      else
        outLog "ERROR: Failed to inject SDK ${_cur_sdk_} to ${OVXR_DOCKER}. Please check if NGDP SDK is built, and available at /auto/vxr/ngdp/external/rpms EXITING"
      fi
      exit 1
    fi
  else
    outLog "Found ${SDK_VER} in ${OVXR_DOCKER} - Check complete"
    outLog "Continuing with operations"
  fi
done

if [[ ${_FORCE_SDK_ONLY_} ]];
then
  [[ ! ${_inside_docker_} ]] && _printPost_=" and injected into ${OVXR_DOCKER}" || _printPost_=""
  outLog "SDK(s) $(printf '%s ' "${SDK_VER[@]}")have been downloaded ${_printPost_}. Exiting"
  exit 0
fi

echo "

=======================================================
        Baking ${USER_ISO}
======================================================="

if [[ ${SKIP_BAKE_ENV} -eq 1 ]]; then
  outLog "Skipping baking process since qcow2 files are already available in: ${USER_ISO_DIR}"
  outLog "Found qcow2 files:"
  for qcow2_file in "${FOUND_QCOW2_FILES[@]}"; do
    outLog "  - $(basename "$qcow2_file")"
  done
  outLog "Proceeding directly to Docker image creation using existing qcow2 files"
  
  # Set USER_ISO_DIR for the rest of the script to use the existing qcow2 files
  # This ensures compatibility with the existing build process
  
else
  outLog "Starting baking process for ${USER_ISO}"
fi

# If the passed in TARGET_TO_BUILD is either "kne", "clab", "cml", or "eve_ng",
# the rest of the execution will be handed off to the build script
# corresponding to the selected target.
if [[ ( "${TARGET_TO_BUILD}" == "kne" ) || ( "${TARGET_TO_BUILD}" == "clab" ) || ( "${TARGET_TO_BUILD}" == "cml" ) || ( "${TARGET_TO_BUILD}" == "eve_ng" ) ]] && [[ ${SKIP_BAKE_ENV} -eq 0 ]];
then
  echo "---------------------------------
-t ${TARGET_TO_BUILD} requested, handing it off
to ${OVXR_DOCKER}:/opt/ovxr-release/scripts/${TARGET_TO_BUILD}/bake_iso_and_build_${TARGET_TO_BUILD}_component.sh
---------------------------------"
  [[ ! "${USER_DOCKER_NAME}" ]] && echo "-t ${TARGET_TO_BUILD} requires user to pass in -d <docker_name> where \"docker_name\" will be used as the name of the resulting docker image." && exit 1
  if [[ ${_inside_docker_} ]];
  then
    _cmd_="/opt/ovxr-release/scripts/${TARGET_TO_BUILD}/bake_iso_and_build_${TARGET_TO_BUILD}_component.sh -i ${USER_ISO} -p ${PLAT_TO_BUILD} ${ISO_BOOT_ARG} ${USER_DOCKER_NAME}"
    outLog "CMND: ${_cmd_}"
      #SF_DtLog "Calling CMD - ${_cmd_}"
    eval "${_cmd_}"
    exit
  else
    #TODO: create isoboot flow here
    [[ ! -e ${USER_ISO} ]] && echo "${USER_ISO} does not exist! Pass in a valid path to an ISO" && exit 1 #TODO: exit w/ help msg
    _docker_bld_param_="-e ACTION=build${TARGET_TO_BUILD} -e DOCKERNAME_OUTPUT=${USER_DOCKER_NAME} -e PLAT_BUILD=${PLAT_TO_BUILD} -v ${USER_ISO_DIR}:/nobackup/bake -v /var/run/docker.sock:/var/run/docker.sock"
    _DOCKER_BUILD_CMD_="docker run --rm ${_TTY_} --privileged ${_docker_bld_param_} ${OVXR_DOCKER}"
    outLog "Build ${TARGET_TO_BUILD} Cmd: ${_DOCKER_BUILD_CMD_}"
    eval "${_DOCKER_BUILD_CMD_}"
    exit
  fi
fi



#BAKE ISO#
# C
      #SF_Check first if there's multiple ISO/qcow2 that exists in ${USER_ISO_DIR}. This is an indicator that iso may have already been
#cooked/processed and user may just want to continue previous operations.. we'll give them that option

if [[ ${SKIP_BAKE_ENV} -eq 0 ]]; then
  _iso_count_=$(find "${USER_ISO_DIR}" -maxdepth 1 -type f -name "*.iso" | wc -l)
  if [[ ${_iso_count_} -ne 1 ]];
  then
    outLog "[WARNING] ${USER_ISO_DIR} has >=2 ISOs. This is one indicator of a previous bake process.. Cannot determine if it failed or not. If you want to proceed this entire build and SKIP bake, please pass in \"y\""
    outLog "[WARNING] If you do not want to continue and want to start from the beginning.. Please ONLY leave the ISO you want to bake in ${USER_ISO_DIR} and remove everything else"
    read -p "Do you want to continue? (y/n)[n if you want to restart, clean up ${USER_ISO_DIR}]: " answer
    if [[ ${answer} == "y" || ${answer} == "Y" ]];
    then
      outLog "Continuing.."
      outLog "Contents of ${USER_ISO_DIR}: $(find ${USER_ISO_DIR}/*)"
    else
      outLog "EXITING"
      exit 0
    fi
  else
    # Determine DOCKER_NAME before any potential ISO movement
    determineDOCKER_NAME

    #If insidedocker, run /etc/bake_in_container_startup.sh
    if [[ ${_inside_docker_} ]];
    then
    export ACTION="bake"
    export PLAT_BUILD="${PLAT_TO_BUILD}"
    outLog "Baking insidedocker, moving user pased in ISO to /nobackup/bake"
    mkdir -p /nobackup/bake
    [[ $? -ne 0 ]] && outLog "Failed to create /nobackup/bake inside docker" && exit 1
    mv "${USER_ISO}" /nobackup/bake/

    outLog "Running /etc/bake_in_container_startup.sh inside docker to bake the ISO"
    /etc/bake_in_container_startup.sh 
    [[ $? -ne 0 ]] && outLog "Failed to bake the ISO inside docker" && exit 1
    outLog "Successfully baked the ISO inside docker"

    #Mv /nobackup/bake to /tmp/bake and then clean everything in ${USER_ISO_DIR} and move /tmp/bake/* to ${USER_ISO_DIR}
    outLog "Moving /nobackup/bake to /tmp/bake and cleaning up ${USER_ISO_DIR}"
    mkdir -p /tmp/bake
    [[ $? -ne 0 ]] && outLog "Failed to create /tmp/bake inside docker" && exit 1
    mv /nobackup/bake/* /tmp/bake/
    [[ $? -ne 0 ]] && outLog "Failed to move /nobackup/bake to /tmp/bake" && exit 1
    rm -rf "${USER_ISO_DIR}"/*
    [[ $? -ne 0 ]] && outLog "Failed to clean up ${USER_ISO_DIR}" && exit 1
    outLog "Successfully cleaned up ${USER_ISO_DIR} and moved /tmp/bake/* to ${USER_ISO_DIR}"
    mv /tmp/bake/* "${USER_ISO_DIR}/"
    [[ $? -ne 0 ]] && outLog "Failed to move /tmp/bake/* to ${USER_ISO_DIR}" && exit 1
    outLog "Successfully moved /tmp/bake/* to ${USER_ISO_DIR}"
    outLog "Baking inside docker completed."
    
  else
    # chmod /dev/kvm on host so it's accessible inside the container
    chmod 666 /dev/kvm 2>/dev/null || sudo chmod 666 /dev/kvm 2>/dev/null || true
    _KVM_GID_="$(stat -c '%g' /dev/kvm 2>/dev/null)"
    _KVM_OPTS_="--device /dev/kvm"
    [[ -n "${_KVM_GID_}" ]] && _KVM_OPTS_="${_KVM_OPTS_} --group-add ${_KVM_GID_}"
    _DOCKER_BUILD_CMD_="docker run --rm ${_TTY_} --privileged ${_KVM_OPTS_} --security-opt seccomp=unconfined --security-opt apparmor=unconfined -e ACTION=bake -v ${USER_ISO_DIR}:/nobackup/bake -e PLAT_BUILD=${PLAT_TO_BUILD}"
    if [[ ${FORCE_SDK} ]];
    then
      _DOCKER_BUILD_CMD_="${_DOCKER_BUILD_CMD_} -e SKIP_SDK_CHECK=1 -e SDK_VER=${SDK_VER}"
    fi

    if [[ -f "${_allowed_plats_file_}" ]]; then
      # Write wrapper script to a file on disk (mounted into container at /nobackup/bake).
      # This avoids nested-quoting issues with eval + docker -c.
      _WRAPPER_FILE_="${USER_ISO_DIR}/_bake_wrapper.sh"
      cat > "${_WRAPPER_FILE_}" <<'WRAPPER_EOF'
#!/bin/bash
# Allow non-root users (vxr) to access KVM for QEMU
chmod 666 /dev/kvm 2>/dev/null || true
cp /etc/bake_in_container_startup.sh /tmp/bake_startup.sh
WRAPPER_EOF
      cat >> "${_WRAPPER_FILE_}" <<WRAPPER_EOF
if ! grep -q "${PLAT_TO_BUILD}" /tmp/bake_startup.sh; then
  sed -i "/8201-sys.*)/s/)/ | ${PLAT_TO_BUILD})/" /tmp/bake_startup.sh
fi
WRAPPER_EOF
      cat >> "${_WRAPPER_FILE_}" <<'WRAPPER_EOF'
for tpl in /opt/cisco/pyvxr/examples/precook_template/*.yaml; do
  sed -i 's|_NAV_|#|g' "${tpl}" 2>/dev/null
done
chmod +x /tmp/bake_startup.sh
exec /tmp/bake_startup.sh
WRAPPER_EOF
      chmod +x "${_WRAPPER_FILE_}"
      _DOCKER_BUILD_CMD_="${_DOCKER_BUILD_CMD_} ${OVXR_DOCKER} /nobackup/bake/_bake_wrapper.sh"
    else
      _DOCKER_BUILD_CMD_="${_DOCKER_BUILD_CMD_} ${OVXR_DOCKER}"
    fi
    outLog "Bake Docker Cmd: ${_DOCKER_BUILD_CMD_}"
    ${_DOCKER_BUILD_CMD_}
    [ $? -ne 0 ] && exit 1 #TODO: exit help message
  fi
  fi
else
  # We are skipping bake environment because qcow2 files already exist
  outLog "Skipping ISO baking process since qcow2 files are already available"
  
  # Still need to determine DOCKER_NAME for later use
  determineDOCKER_NAME
fi

echo "

=======================================================
      Generate YAMLs for target ${TARGET_TO_BUILD}
                    &
      Sort out ISO/qcow2 for target ${TARGET_TO_BUILD}
======================================================="
declare -A _img_name_
_img_name_["iso"]="$(basename -- "${USER_ISO}")"
#DETERMINE HDA/ISO NAMES#
case ${PLAT_TO_BUILD} in
  8804)
    _img_name_["rp"]="8804/rp/hda"
    _img_name_["lc"]="8804/lc/hda"
    ;;
  88*)
    _img_name_["rp"]="8808/rp/hda"
    _img_name_["lc"]="8808/lc/hda"
    ;;
  *)
    _img_name_["rp"]="$(basename -- "$(ls ${USER_ISO_DIR}/*.qcow2)")"
    ;;
esac
for f in ${!_img_name_[@]};
do
  outLog "card: ${f} img: ${_img_name_[${f}]}"
done
#COPY BAKED CONTENTS + ISO#
outLog "Copying ISO + baked QCOW2 from ${USER_ISO_DIR} to ${_img_drop_folder_}"
mkdir -p ${_img_drop_folder_}
[[ $? -ne 0 ]] && exit 1 #TODO: echo fail message not being able to create img drop folder
outLog "Copying ${USER_ISO_DIR}/* to ${_img_drop_folder_}"
outLog "Contents of ${USER_ISO_DIR}: $(find ${USER_ISO_DIR}/*)"
/usr/bin/cp -r "${USER_ISO_DIR}"/* "${_img_drop_folder_}/"
[[ $? -ne 0 ]] && exit 1 #TODO: echo fail message not being able to copy iso/qcow to img drop folder
outLog "Copied ${USER_ISO_DIR}/* to ${_img_drop_folder_}/"
outLog "Contents: $(find ${_img_drop_folder_}/* -maxdepth 1 -type f | sed 's|'"${_img_drop_folder_}/"'||g')"
#Set USER_ISO_DIR to the drop folder so that the rest of the script can use it
USER_ISO_DIR="${_img_drop_folder_}"
for file in ${!_img_name_[@]};
do
  outLog "File: $(realpath ${_img_drop_folder_}/${_img_name_[${file}]})"
done
#GET SDK/NPSUITE#
_getisoinfo_="isoinfo -R -x /sim_cfg.yml -i "
_iso_drop_path_="$(realpath ${_img_drop_folder_}/${_img_name_["iso"]})"
if [[ -e ${_iso_drop_path_}.patched ]];
then
  _iso_drop_path_="${_iso_drop_path_}.patched"
  outLog "[IMPORTANT] Patched ISO found. This means the SDK ver mentioned in the sim_cfg.yml of the initially passed in ISO is incorrect and a patched ISO with the correct SDK was created."
  outLog "[IMPORTANT] SDK information from the patched ISO will be used to create the template yaml files"
  IMG_PATCHED=0
fi
outLog "${_iso_drop_path_}"
if [[ "${FORCE_SDK}" ]];
then
  outLog "Forcing SDK to be the first input from ${FORCE_SDK} (if multiple were provided) because --forcesdk \"${FORCE_SDK}\" was passed in"
  _SDK_VER_="$(awk '{print $1}' <<< "${FORCE_SDK}")" #TODO: FORCE_SDK can be multiple SDKs passed in.. only take the first one
  outLog "_SDK_VER_: ${_SDK_VER_}"
else
  _SDK_VER_="$(${_getisoinfo_} ${_iso_drop_path_} | grep sdk: | awk '{print $2}')"
  [[ ! ${_SDK_VER_} ]] && _SDK_VER_="$(${_getisoinfo_} ${_iso_drop_path_} | grep sdk_ver_pacific: | awk '{print $2}')"
  [[ ! ${_SDK_VER_} ]] && echo "Failed to extract SDK VERSION from iso ${_iso_drop_path_}" && exit 1 #TODO: proper exit on fail
fi

_NPSUITE_VER_="$(${_getisoinfo_} ${_iso_drop_path_} | grep npsuite: | awk '{print $2}')"


echo "---------------------------------
 Generating Generic YAMLs
---------------------------------"
#GENERATE SAMPLE YAML#
outLog "Creating sample YAML templates"
if [[ ! ${_skip_sdk_} ]];
then
  outLog "Assessing ISO to determine proper SDK"
fi

  mkdir -p ${_yaml_drop_folder_}
  [[ $? -ne 0 ]] && exit 1 #TODO: echo fail message not being able to create yaml template folder
  #declare -A _sample_yamls_=()
  #Copy template yaml to user-custom-yaml folder so when new dockerimage gets built, it gets picked up#
  for _yaml_ in ${_yaml_template_folder_}/*/*;
  do
    [ "${TARGET_TO_BUILD}" == "cloud_vm" ] && continue;

    #Only copy over template yamls where lc matches passed in plat
    grep -q "${PLAT_TO_BUILD}" ${_yaml_} > /dev/null 2>&1
    [ $? -ne 0 ] && continue

    _parent_plat_folder_="$(basename -- $(cd "$(dirname "${_yaml_}")"; pwd -P))"
    _yaml_filename_="$(basename -- ${_yaml_})"
    _paste_to_="${_yaml_drop_folder_}/${_parent_plat_folder_}/"
    mkdir -p ${_paste_to_}
    outLog "Copying ${_yaml_} to ${_paste_to_}"
    /usr/bin/cp ${_yaml_} ${_paste_to_}

    _pasted_yaml_="$(realpath ${_paste_to_}/${_yaml_filename_})"
    outLog "Placed ${_pasted_yaml_}"
    sed -i 's/_NPSUITE_VER_/'${_NPSUITE_VER_}'/g' ${_pasted_yaml_}
    outLog "Replaced _NPSUITE_VER_ -> ${_NPSUITE_VER_} in ${_pasted_yaml_}"
    sed -i 's/_SDK_VER_/'${_SDK_VER_}'/g' ${_pasted_yaml_}
    outLog "Replaced _SDK_VER_ -> ${_SDK_VER_} in ${_pasted_yaml_}"

    case ${PLAT_TO_BUILD} in
      8804|88*)
        _temp_img_path_="${_yaml_img_folder_}/${_img_name_["iso"]}"
        _temp_rp_path_="${_yaml_img_folder_}/${_img_name_["rp"]}"
        _temp_lc_path_="${_yaml_img_folder_}/${_img_name_["lc"]}"
        sed -i 's|_IMAGE_PATH_|'${_temp_img_path_}'|g' ${_pasted_yaml_}
        outLog "Replaced _IMAGE_PATH_ -> ${_temp_img_path_} in ${_pasted_yaml_}"
        sed -i 's|_RP_PATH_|'${_temp_rp_path_}'|g' ${_pasted_yaml_}
        outLog "Replaced _RP_PATH_ -> ${_temp_rp_path_} in ${_pasted_yaml_}"
        sed -i 's|_LC_PATH_|'${_temp_lc_path_}'|g' ${_pasted_yaml_}
        outLog "Replaced _LC_PATH_ -> ${_temp_lc_path_} in ${_pasted_yaml_}"
        ;;
      8K-MPA-16H|8K-MPA-16Z2D)
        _temp_img_path_="${_yaml_img_folder_}/${_img_name_["iso"]}"
        _temp_rp_path_="${_yaml_img_folder_}/${_img_name_["rp"]}"
        sed -i 's|_IMAGE_PATH_|'${_temp_img_path_}'|g' ${_pasted_yaml_}
        outLog "Replaced _IMAGE_PATH_ -> ${_temp_img_path_} in ${_pasted_yaml_}"
        sed -i 's|_RP_PATH_|'${_temp_rp_path_}'|g' ${_pasted_yaml_}
        outLog "Replaced _RP_PATH_ -> ${_temp_rp_path_} in ${_pasted_yaml_}"
        ;;
      *)
        if [[ $(echo "${_pasted_yaml_: -8}" | grep "iso.yaml") ]]; #Sed _IMAGE_PATH_ for yamls ending in *iso.yaml with iso path
        then
          _temp_img_path_="${_yaml_img_folder_}/${_img_name_["iso"]}"
          sed -i 's|_IMAGE_PATH_|'${_temp_img_path_}'|g' ${_pasted_yaml_}
          outLog "Replaced _IMAGE_PATH_ -> ${_temp_img_path_} in ${_pasted_yaml_}"
        else #Sed _IMAGE_PATH_ for every other yaml w/ qcow2 path
          _temp_img_path_="${_yaml_img_folder_}/${_img_name_["rp"]}"
          sed -i 's|_IMAGE_PATH_|'${_temp_img_path_}'|g' ${_pasted_yaml_}
          outLog "Replaced _IMAGE_PATH_ -> ${_temp_img_path_} in ${_pasted_yaml_}"
        fi
        ;;
    esac
  done
echo "

=======================================================
      BUILD TARGET: ${TARGET_TO_BUILD}
======================================================="
#HANDLE SPECIFIC TARGETS PASSED IN BY USER#
case ${TARGET_TO_BUILD} in
  all)
    buildAllTarget
    ;;
  cloud_vm)
    buildCloudVmTarget
    ;;

  crystalnet)
    buildCrystalnetTarget
    _appendToReleaseTarget_ "${TARGET_TO_BUILD}"
    ;;
  azure)
    buildAzureTarget
    _appendToReleaseTarget_ "${TARGET_TO_BUILD}"
    ;;
  generic)
    #Build the docker image if user passes in docker name#
    if [[ "${USER_DOCKER_NAME}" ]];
    then
      _docker_build_cmd_="${_build_docker_script_} ${USER_DOCKER_NAME} ${_generic_dockerfile_}"
      outLog "Docker image build cmd - ${_docker_build_cmd_}"
      eval "${_docker_build_cmd_}"
    fi
    ;;
  *)
    ;;
esac


outLog "Cleaning up.."

# Clean up temporary ISO patch workspaces
cleanupTempWorkspaces

if [[ "${USER_OVXR_DOCKER}" == "" ]]; #User did not pass in their own ovxr-dev docker image to use, so let's clean up the one we built
then
  if [[ ( "${_inside_docker_}" == "" ) && ( ! ${_no_unique_ovxr_name_} ) && ( ! ${REBUILD_OVXR_DOCKER} ) && ( ${OVXR_DOCKER} )  ]];
  then
    outLog "Cleaning up docker image ${OVXR_DOCKER}"
    docker image rm ${OVXR_DOCKER} > /dev/null 2>&1
    [ $? -ne 0 ] && outLog "Failed to remove docker image ${OVXR_DOCKER}" 
  fi
fi
echo "=======================================================
        ${_CUR_FILE_PATH_} End!
======================================================="
