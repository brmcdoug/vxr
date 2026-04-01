#!/bin/bash
[[ ${VERBOSE} ]] && set -x
_CUR_FILE_DIR_="$(cd "$(dirname "$0")"; pwd -P)"
_FILENAME_="$(basename -- "${0}")"
HN="$(hostname | sed 's/.cisco.com//g')"
FULL_LOG=""
SONIC=""

# OPTIONAL ARGUMENTS START #
while getopts "o:sh" opt;do
	case $opt in
	h)
		help
		exit 0
		;;
  o)
          IMG_FOLDER="${OPTARG}"
          ;;
  s)
          SONIC="sonic"
          ;;
	\?)
		exit
		;;
	esac
done
shift $((OPTIND-1))
# OPTIONAL ARGUMENTS   END #

_internal_initial_ub_layer_="containers.cisco.com/wmyint/ovxr-initial:latest"

_allowed_plats_file_="${_CUR_FILE_DIR_}/allowed_plats"

_docker_folder_="$(realpath ${_CUR_FILE_DIR_}/../../docker)"
_clab_docker_folder_="${_docker_folder_}/kne"


docker manifest inspect ${_internal_initial_ub_layer_} > /dev/null 2>&1
if [[ $? -eq 0 ]];
then
  docker image pull ${_internal_initial_ub_layer_}
  _8000_docker_="${_clab_docker_folder_}/Dockerfile8000${SONIC}_cached"
else
  _8000_docker_="${_clab_docker_folder_}/Dockerfile8000${SONIC}_ovxrdev"
fi

_integration_folder_="$(realpath ${_CUR_FILE_DIR_}/../../packages/integration/clab)"
_8000_template_="${_integration_folder_}/8000${SONIC}.yaml"

_scripts_folder_="$(realpath ${_CUR_FILE_DIR_}/..)"
_docker_build_script_="${_scripts_folder_}/build_docker_image.sh"

_packages_folder_="$(realpath ${_CUR_FILE_DIR_}/../../packages/)"
_images_folder_="${_packages_folder_}/images/8000/clab"
mkdir -p ${_images_folder_}

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

#FULL LOG START#
function appendFullLog() {
  INPT="$@"
  FULL_LOG="${FULL_LOG}
${INPT}"
  return
}
#FULL LOG END#

# HELP MESSAGE START #
function help() {
  msg="
  Use this script to create a generic CLAB docker component.
  _____________________________________________________________

                          Usage
  _____________________________________________________________
  ./${_FILENAME_} -o IMAGE_OUTPUT_DIR [-s] [NAME OF DOCKERIMAGE]
	or
  Note: [NAME OF DOCKER IMAGE TO BUILD] must be all lower case

  -s: build generic clab image for sonic

  Eg.
  ./${_FILENAME_} -o /nobackup/clab c8000-clab:latest
  "
  echo "${msg}"
  return
}
# HELP MESSAGE END #

# MAIN

echo "${_FILENAME_} ($SONIC) called"
outLog "Running prechecks"
[[ ! ${1} ]] && help && echo "Please pass in docker name to use. Read above for help" && exit 1
DOCKER_NAME="${1}"

[[ ! -e ${_docker_build_script_} ]] && echo "Failed to find docker building script at ${_docker_build_script_}. Cannot continue !!!" && exit 1

[[ ! ${IMG_FOLDER} ]] && help && echo "Proper parameters were not passed in. Please refer above" && exit 1

[[ ! -e ${_8000_template_} ]] && echo "Failed to find 8000 template at ${_8000_template_}. Cannot continue !!!" && exit 1

if [ ${SONIC_USERNAME} ]; then
        sed -i "s+linux_username:.*+linux_username: ${SONIC_USERNAME}+" ${_8000_template_}
fi

if [ ${SONIC_PASSWORD} ]; then
        sed -i "s+linux_password:.*+linux_password: ${SONIC_PASSWORD}+" ${_8000_template_}
fi

cat ${_8000_template_}


#Build docker now that preperations are all done
outLog "Building docker image"
_CMD_="${_docker_build_script_} -c ${DOCKER_NAME} ${_8000_docker_}"
outLog "Calling cmd: ${_CMD_}"
eval "${_CMD_}"
[ $? -ne 0 ] && echo "FAILED TO BUILD THE DOCKER IMAGE." && exit 1

outLog "Successfully built docker image"
docker image ls ${DOCKER_NAME}

_tar_name_="${DOCKER_NAME}.tar"
outLog "Exporting ${_tar_name_} to mounted volume"
docker save ${DOCKER_NAME} > ${IMG_FOLDER}/${DOCKER_NAME}.tar
chmod 666 ${IMG_FOLDER}/${DOCKER_NAME}.tar
