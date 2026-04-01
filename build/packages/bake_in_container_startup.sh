#!/bin/bash
[[ ${VERBOSE} ]] && set -x
_bake_dir_='/nobackup/bake'
_rpm_dir_='/nobackup/bake/rpm'
_sim_dir_="/nobackup/${USER}/pyvxr"
_device_name_='R0'
pyvxr='/opt/cisco/pyvxr/pyvxr-latest/vxr.py'
_wd_="/nobackup"
yaml_path="${_wd_}/sf.yaml"
_sf_plat_type_="sf_f"

_yaml_template_dir_='/opt/cisco/pyvxr/examples/precook_template'
_sf_f_template_="${_yaml_template_dir_}/sf-f-template.yaml"
_sf_d_8804_template_="${_yaml_template_dir_}/sf-d-8804-template.yaml"
_sf_d_8808_template_="${_yaml_template_dir_}/sf-d-8808-template.yaml"
_sf_d_8704_template_="${_yaml_template_dir_}/sf-c-8704-template.yaml"

_inject_sim_cfg_=0
_sim_cfg_injected_=1
_sim_cfg_content_=""
_sim_cfg_file_="/nobackup/sim_cfg.yml"

function print_help(){
	echo "
This container was improperly called. Please continue reading for instructions!

How to create a precooked qcow2 using your golden ISO:
	1)
		Before launching this container, create a folder on your end and place the intended ISO you wish to bake within it.
		THERE CAN ONLY BE ONE ISO IN THE FOLDER

		To include RPMs, mount the path of the rpms to the container's /nobackup/bake/rpms

		In the docker run call, mount that folder to the container's /nobackup/bake.
		Example:
			local folder with iso on host:	    /nobackup/please_bake_this/7.0.14.iso
			local folder with rpms (optional):  /nobackup/include_rpm/1.rpm		#Place rpms here

			\$ docker run -v /nobackup/please_bake_this/:/nobackup/bake -v /nobackup/include_rpm/:/nobackup/bake/rpm .. [additional arguments]

		Format:
			\$ docker run -v /PATH/WITH/ISO:/nobackup/bake [optional: -v /PATH/WITH/RPMS:/nobackup/bake/rpm]
	2)
		Pass in the platform to build as an environment variable \"PLAT_BUILD\" using -e\--env with the run command from #1
		Allowed options:
			8101-32H, 8101-32FH 8102-64H, 8201-32FH, 8201-sys, 8202, 8201-24H8FH, 8804, 8808-gb
		Example:
			\$ docker run -v /nobackup/please_bake_this/:/nobackup/bake .. -e PLAT_BUILD=8201-sys ..

Optional:
	If you need to provide a different SDK/NPSUITE version, in the case of baking a custom image, please continue reading.

	SDK)
		Pass in the SDK version as an environment variable \"SDK_VER\" using -e\--env
		\$ docker run .. -e SDK_VER=1.24.7.1

		You can get this information by running \"isoinfo -R -x /sim_cfg.yml -i /path/to/ISO\"

	NPSUITE)
		Pass in the NPSuite version as an environment variable \"NPSUITE_VER\" using -e\--env
		\$ docker run .. -e NPSUITE_VER=1.39.1

		You can get this information by running \"isoinfo -R -x /sim_cfg.yml -i /path/to/ISO\"

	SKIP_SDK_CHECK)
		Pass in the environment variable \"SKIP_SDK_CHECK\" using -e\--env to skip the SDK version check
		\$ docker run .. -e SKIP_SDK_CHECK=1


Example Launches:
	Image to bake is in \"/nobackup/bake_this/8000-x64-7.3.2.iso\" on host machine.
	Qcow2 bake docker image is vxrbake:v1

	Bake a 8201-sys precooked disk
	\$ docker run -v /nobackup/bake_this/:/nobackup/bake -e PLAT_BUILD=8201-sys --rm -it --privileged vxrbake:v1

	Bake a 8201-sys precook disk with custom SDK
	\$ docker run -v /nobackup/bake_this/:/nobackup/bake -e PLAT_BUILD=8201-sys -e SDK_VER=1.37.0.1 --rm -it --privileged vxrbake:v1


"
}

function fetch_vxr_ver(){
	latest_vxr2_ver=$(ls -lrt /opt/cisco/vxr2 | grep -oP 'vxr2_\w*' | tail -1)
	echo ${latest_vxr2_ver}
}

function generate_yaml_dep(){
cat > ${yaml_path} <<EOF
simulation:
  no_image_copy: False
  sim_rel: /opt/cisco/vxr2/$(fetch_vxr_ver)
  sim_dir: ${_sim_dir_}
  sim_host: localhost
  rollback_xr_user: True
devices:
  ${_device_name_}:
    platform: spitfire_f
    linecard_types: ['8201-sys']
    image: ${1}
    vxr_sim_config:
      shelf:
       ConfigEnableNgdp: 'true'
       ConfigOvxr: 'true'
       ConfigLeabaSdkVer: '${SDK_VER}'
       ConfigNpsuiteVer: '${NPSUITE_VER}'
EOF
}

function generate_yaml(){
	#select yaml template#
	case ${PLAT_BUILD} in
		8101-32H |8101-32FH | 8102-64H | 8122-64EHF-O | 8201-32FH | 8201-sys | 8202 | 8202-32FH-M | 8201-24H8FH | 8212-48FH-M | 8711-32FH-M)
			cp ${_sf_f_template_} ${yaml_path}
			sed -i "s|_LCC_TYPE_|[${PLAT_BUILD}]|g" ${yaml_path}
			;;
		8804)
			cp ${_sf_d_8804_template_} ${yaml_path}
			;;
		8808-gb)
			cp ${_sf_d_8808_template_} ${yaml_path}
			sed -i "s|_LCC_TYPE_|${PLAT_BUILD}|g" ${yaml_path}
			sed -i "s|_LC_TYPE_|'8800-lc-36fh-m'|g" ${yaml_path}
			;;
		88-LC0-36FH|88-LC0-36FH-M|8800-LC-48H|8800-LC-36FH-2|88-LC1-52Y8H-EM)
			cp ${_sf_d_8808_template_} ${yaml_path}
			sed -i "s|_LCC_TYPE_|'8808'|g" ${yaml_path}
			sed -i "s|_LC_TYPE_|${PLAT_BUILD}|g" ${yaml_path}
			;;
		8K-MPA-16H|8K-MPA-16Z2D|8K-MPA-4D)
		#Atlas, Platform: spitfire_c
			#TODO: use a parameter to change RP_TYPE for yamls, for now set a temp value
			_TEMP_RP_TYPE_="8712-MOD-AM"
			
			cp ${_sf_d_8704_template_} ${yaml_path}
			sed -i "s|_LC_TYPE_|'${PLAT_BUILD}'|g" ${yaml_path}
			sed -i "s|_RP_TYPE_|${_TEMP_RP_TYPE_}|g" ${yaml_path}
			;;
		*)
			print_help
			echo "Invalid \"PLAT_BUILD\" passed. Please read the above."
			exit 1
			;;
	esac
	_sim_path_="/opt/cisco/vxr2/$(fetch_vxr_ver)"
	sed -i "s|_SIM_REL_|${_sim_path_}|g" ${yaml_path}
	sed -i "s|_SIM_DIR_|${_sim_dir_}|g" ${yaml_path}
	sed -i "s|_IMAGE_PATH_|${1}|g" ${yaml_path}
	sed -i "s|_DEVICE_NAME_|${_device_name_}|g" ${yaml_path}

	if [[ ( ${SDK_VER} ) || ( ${NPSUITE_VER} ) ]];
	then
		sed -i 's|_VSC_||g' ${yaml_path}
		if [[ ( ${SDK_VER} ) && ( ${NPSUITE_VER} ) ]];
		then
			sed -i 's|_VSCSDK_||g' ${yaml_path}
			sed -i 's|_VSCNPS_||g' ${yaml_path}

			sed -i "s|_SDK_VER_|${SDK_VER}|g" ${yaml_path}
			sed -i "s|_NPSUITE_VER_|${NPSUITE_VER}|g" ${yaml_path}
		elif [[ ${SDK_VER} ]];
		then
			sed -i 's|_VSCSDK_||g' ${yaml_path}
			sed -i 's|_VSCNPS_|#|g' ${yaml_path}

			sed -i "s|_SDK_VER_|${SDK_VER}|g" ${yaml_path}
		else
			sed -i 's|_VSCSDK_|#|g' ${yaml_path}
			sed -i 's|_VSCNPS_||g' ${yaml_path}

			sed -i "s|_NPSUITE_VER_|${NPSUITE_VER}|g" ${yaml_path}
		fi
	else
		sed -i 's|_VSC_|#|g' ${yaml_path}
		sed -i 's|_VSCSDK_|#|g' ${yaml_path}
		sed -i 's|_VSCNPS_|#|g' ${yaml_path}
	fi

	# Handle NAV (NPU ASIC Version) placeholders from eft17+ templates
	sed -i 's|_NAV_|#|g' ${yaml_path}

}

function _checkSimCfgInjection_(){
		which guestfish > /dev/null 2>&1
		[[ $? -ne 0 ]] && echo "/usr/bin/guestfish is missing - cannot inject sim_cfg.yml into qcow2" && return
		which isoinfo > /dev/null 2>&1
		[[ $? -ne 0 ]] && echo "/usr/bin/isoinfo is missing - cannot inject sim_cfg.yml into qcow2" && return
		echo ""
}

function _getSimCfgFromIso_(){
	[ ! ${1} ]  && echo "" && return
	_iso_="${1}"
	_content_="$(isoinfo -R -i ${_iso_} -x /sim_cfg.yml)"
	echo "${_content_}" > "${_sim_cfg_file_}" && echo "${_content_}"
}

function _injectSimCfg_(){
	[ ! ${1} ] && return 1
	_qcow2_="${1}"
	[[ "$(_getSimCfgFromQcow2_ ${_qcow2_})" == "${_sim_cfg_content_}" ]] && return
	echo "Injecting sim_cfg.yml from ${_sim_cfg_file_} into ${_qcow2_}"
	sudo guestfish <<_EOF_
	add ${_qcow2_}
	run
	mount /dev/sda1	/
	copy-in ${_sim_cfg_file_} /EFI/BOOT
_EOF_
}

function _getSimCfgFromQcow2_(){
	[ ! ${1} ] && return 1
	_qcow2_="${1}"
	sudo guestfish 2>/dev/null <<_EOF_
	add ${_qcow2_}
	run
	mount /dev/sda1	/
	cat /EFI/BOOT/sim_cfg.yml
_EOF_
}

function _rmSimCfgFromQcow2_(){
	[ ! ${1} ] && return 1
	_qcow2_="${1}"
	sudo guestfish <<_EOF_
	add ${_qcow2_}
	run
	mount /dev/sda1	/
	rm /EFI/BOOT/sim_cfg.yml
_EOF_
}

#cat ${yaml_path}
if [ -e ${_rpm_dir_} ];
then
	find "${_rpm_dir_}/*" > /dev/null 2>&1
	[ $? -ne 0 ] && return
	_prefix_="    "
#	cat
fi


function get_cpu(){
	[[ $(nproc) -le 16 ]] && echo $(nproc) && return
	echo "16"
	return
}

function fail_exit(){
	[[ ! ${SHELL_ON_EXIT} ]] && exit 1
	echo -e "\e[41mLast step failed.. opening up a shell so you can take a look\e[0m"
	/bin/bash
	exit
}

[ ! -e ${_bake_dir_} ] && _improper_=1
#[[ (! ${SDK_VER}) || (! ${NPSUITE_VER}) ]] && _improper_=1
[[ ! ${PLAT_BUILD} ]] && _improper_=1
[ ${_improper_} ] && print_help && exit 0

echo "Starting iso bake container. Interrupting this process will require you to start over."
_iso_="$(find ${_bake_dir_} | grep .iso)"
[[ $(wc -l <<< "${_iso_}") -ne 1 ]] && echo "Please place only one iso file in the directory.. Found more than one iso: ${_iso_}. Exitting" && exit 1
_initial_iso_path_="${_iso_}"
_iso_name_=$(basename -- ${_iso_})
_new_iso_path_="/nobackup/bakeme.iso"
cp ${_iso_} ${_new_iso_path_}
_iso_="${_new_iso_path_}"

generate_yaml "${_iso_}"

echo "ISO Name: ${_iso_name_}"
echo "PLAT: ${PLAT_BUILD}"

_continue_bake_=0
#Determine first if there's existing hda/qcow2 to see if bake has already been done#
case ${PLAT_BUILD} in
	88-LC0-36FH | 88-LC0-36FH-M | 8800-LC-48H | 8800-LC-36FH-2 | 8808-gb)
		[[ ( -e "${_bake_dir_}/8808/lc/hda" ) && ( -e "${_bake_dir_}/8808/rp/hda" ) ]] && _continue_bake_=1 
		which nc > /dev/null 2>&1 
		[[ $? -ne 0 ]] && echo "/usr/bin/nc is missing - please install in this enviornment and then try the bake again" && fail_exit
		_sf_plat_type_="sf_d"
		;;
	8804)
		[[ ( -e "${_bake_dir_}/8804/lc/hda" ) && ( -e "${_bake_dir_}/8804/lc/hda" ) ]] && _continue_bake_=1
		_sf_plat_type_="sf_c"
		;;
	*)
		for f in $(realpath ${_bake_dir_}/*);
		do
			_ext_="${f##*.}"
			[[ "${_ext_}" == "qcow2" ]] && _continue_bake_=1
		done
		;;
esac

if [[ ${_continue_bake_} -eq 0 ]];
then
	echo "YAML Content:"
	cat ${yaml_path}

	echo ""
	echo "starting baking process"
	echo "this will take some time.."
	cd ${_wd_}
	${pyvxr} start ${yaml_path}
	if [ $? -ne 0 ];
	then
		echo "Failed to bring up SIM during the bake process. ERROR:"
		${pyvxr} sim-check
		for f in $(find /nobackup/);
		do
		  grep -q "\.log" <<< "${f}"
		  [ $? -ne 0 ] && continue
		  echo "$f:"
		  cat $f
		done
		fail_exit
	else
		echo "SIM started successfully"
	fi

	#If sf plat is sf_d, a gentler shutdown is needed#
	if [[ "${_sf_plat_type_}" == "sf_d" ]];
	then
		echo "sf_d platform detected. Shutting down SIM gently"
		_serial_port_=$(vxr.py ports | grep -oP '"serial0": [0-9]*' | head -1 | awk '{print $2}')
		[[ ! ${_serial_port_} ]] && echo "Failed to get serial port for sf_d. Exiting" && fail_exit
		_host_agent_="0"
		echo "passing \"run init 0\" to ${_host_agent_}:${_serial_port_}"
		echo "run init 0" | nc ${_host_agent_} ${_serial_port_} -w 60
		if [ $? -ne 0 ];
		then
			echo "Failed to bring down SIM during the bake process. ERROR:"
			${pyvxr} sim-check
			${pyvxr} stop
			fail_exit
		fi
		sleep 120
	fi

	${pyvxr} stop
	if [ $? -ne 0 ];
	then
		echo "Failed to bring down SIM during the bake process. ERROR:"
		${pyvxr} sim-check
		fail_exit
	fi

	#SIM_CFG.YML INJECTION PREP#
	_inject_sim_cfg_=$(_checkSimCfgInjection_)
	_sdk_ver_=""
	if [[ ${_inject_sim_cfg_} == "" ]];
	then
		_sim_cfg_content_="$(_getSimCfgFromIso_ ${_iso_})"
		echo "sim_cfg.yml content:"
		echo "${_sim_cfg_content_}"

		_sdk_ver_="$(grep sdk: <<< "${_sim_cfg_content_}" | awk '{print $2}')"
		[[ ! ${_sdk_ver_} ]] && _sdk_ver_="$(grep sdk_ver_pacific: <<< "${_sim_cfg_content_}" | awk '{print $2}')"
	else
		echo "skiping sim_cfg.yml injection to qcow2 for this bake for the reason above. continuing with bake"
	fi

	<<comment
		#TODO: check for sdk mismatch
		#pyvxr logs
		#vxr@84ed1731d319:/nobackup/vxr.out/logs/localhost$ grep 'About to remove current NGDP' vxr.log  | grep -o sdk\([0-9.*]*
		#sdk(1.51.0.1
		#sdk(1.51.0.3
comment

	#SDK MISMATCH CHECK#
	if [[ ${SKIP_SDK_CHECK} ]];
	then
		echo "Skipping SDK Mismatch check because SKIP_SDK_CHECK is set"
	else
		opt=$(vxr.py logs 2>&1)
		log_dir="$(grep 'Logs located under'<<< "${opt}" | awk -F"Logs located under " '{print $NF}')"
		log_dir=$(realpath ${log_dir})
		vxr_log="${log_dir}/vxr.log"
		_opt_="$(grep -o "sdk(\S*)" ${vxr_log})"
		_updated_sim_cfg_yaml_="/tmp/sim_cfg.yml"
		_patched_iso_path_="${_initial_iso_path_}.patched"
		if [[ "${_opt_}" !=  "" ]];
		then
			_new_sdk_ver_=$(echo ${_opt_} | awk '{print $2}' | sed 's/sdk(//g' | sed 's/)//g')
			_new_iso_name_="${_iso_name_}.patched"
			echo "WARNING: sdk defined in iso, ${_sdk_ver_}, is incorrect and should be ${_new_sdk_ver_}"
			echo "updating sim_cfg.yml with the right sdk and outputting a new patched iso based on the original iso"
			echo "going forward, this new patched iso will be used for the remainder of the process"

			_old_sim_cfg_content_="$(echo "${_sim_cfg_content_}")"
			_sim_cfg_content_="$(echo "${_sim_cfg_content_}"  | sed 's/'${_sdk_ver_}'/'${_new_sdk_ver_}'/g')"
			echo "initial sim_cfg.yml pulled from iso: "
			echo "${_old_sim_cfg_content_}"
			echo ""
			echo "new sim_cfg.yml: "
			echo "${_sim_cfg_content_}"
			echo ""
			echo "${_sim_cfg_content_}" > "${_updated_sim_cfg_yaml_}"

			if [[ $? -eq 0 ]];
			then
				pushd $(dirname ${_initial_iso_path_}) > /dev/null 2>&1
				sudo /opt/ovxr-release/scripts/bake-and-build/vxr_set_yml_in_iso.sh ${_initial_iso_path_} ${_updated_sim_cfg_yaml_}
				sudo chmod 666 ${_patched_iso_path_}
				/usr/bin/mv ${_patched_iso_path_} ${_initial_iso_path_}
				echo "Replaced ${_initial_iso_path_} with patched iso"
				popd > /dev/null 2>&1
				_getSimCfgFromIso_ ${_initial_iso_path_}
			else
				echo "ERROR: failed to create patched iso with correct sdk information !!! Please address the errors before running again"
				exit 1
			fi
		fi
	fi
	

	#HDA TO QCOW2 & COMPRESS STAGE#
	_init_hda_="${_sim_dir_}/${_device_name_}/hda"
	_opt_qcow2_="${_sim_dir_}/${_device_name_}/hda.cont.qcow2"
	_qcow2_="${_sim_dir_}/${_device_name_}/hda.qcow2"

	echo "converting hda to qcow2.. this could take a while"
	qemu-img convert -m $(get_cpu) -O qcow2 ${_init_hda_} ${_opt_qcow2_}
	if [ $? -ne 0 ];
	then
			echo "Failed to convert resulting hda to qcow2"
		 fail_exit
	fi
	echo "compressing qcow2.. this could take a while"
	qemu-img convert -m $(get_cpu) -c -O qcow2 ${_opt_qcow2_} ${_qcow2_}
	if [ $? -ne 0 ];
	then
			echo "Failed to compress qcow2"
		 fail_exit
	fi



	case ${PLAT_BUILD} in
		8804 | 8808-gb | 88-LC0-36FH | 88-LC0-36FH-M | 8800-LC-48H | 8800-LC-36FH-2)
			_8808_baked_="TRUE"
			_init_hda_lc_="${_sim_dir_}/${_device_name_}_lc0/hda"
			_opt_qcow2_lc_="${_sim_dir_}/${_device_name_}_lc0/hda.cont.qcow2"
			_qcow2_lc_="${_sim_dir_}/${_device_name_}_lc0/hda.lc0.qcow2"
			echo "converting lc hda to qcow2.. this could take a while"
			qemu-img convert -m $(get_cpu) -O qcow2 ${_init_hda_lc_} ${_opt_qcow2_lc_}
			if [ $? -ne 0 ];
			then
					echo "Failed to convert resulting lc hda to qcow2"
				 fail_exit
			fi
			echo "compressing lc qcow2.. this could take a while"
			qemu-img convert -m $(get_cpu) -c -O qcow2 ${_opt_qcow2_lc_} ${_qcow2_lc_}
			if [ $? -ne 0 ];
			then
					echo "Failed to compress lc qcow2"
				 fail_exit
			fi

			echo "copying over compressed lc qcow2 to mounted volume"
			if [[ "${PLAT_BUILD}" == "8804" ]];
			then
				_plat_folder_name_='8804'
			else
				_plat_folder_name_='8808'
			fi
			_drop_path_="${_bake_dir_}/${_plat_folder_name_}/lc"
			sudo mkdir -p "${_drop_path_}"
			sudo chmod -R 777 "${_bake_dir_}/${_plat_folder_name_}"
			#sudo cp ${_qcow2_lc_} ${_bake_dir_}
			sudo cp ${_qcow2_lc_} ${_drop_path_}/hda
			#sudo chmod 666 "${_bake_dir_}/hda.lc0.qcow2"
			sudo chmod -R 777 ${_drop_path_}
			sudo chmod 666 ${_drop_path_}/hda

			;;

		*)
			;;
	esac

	echo "copying over compressed qcow2 to mounted volume"
	if [[ ${_8808_baked_} ]];
	then
		if [[ "${PLAT_BUILD}" == "8804" ]];
			then
				_plat_folder_name_='8804'
			else
				_plat_folder_name_='8808'
			fi
		_drop_path_="${_bake_dir_}/${_plat_folder_name_}/rp"
		sudo mkdir -p "${_drop_path_}"
		sudo cp ${_qcow2_} ${_drop_path_}/hda
		sudo chmod -R 777 ${_drop_path_}
		sudo chmod 666 "${_drop_path_}/hda"
	else
	  _qcow2_name_="$(echo ${_iso_name_} | sed 's/.iso//g')-${PLAT_BUILD}.qcow2"
	  sudo cp ${_qcow2_} ${_bake_dir_}/${_qcow2_name_}
	  sudo chmod 666 "${_bake_dir_}/${_qcow2_name_}"
		_injectSimCfg_ "${_bake_dir_}/${_qcow2_name_}"
	fi
	[ $? -ne 0 ] && fail_exit
	echo -e "\e[42mqcow2 successfully generated and placed in the mounted volume! \e[0m"
else
	echo -e "\e[43mExisting baked disk found in the same directory as the ISO. Move it out the folder and re-run if you want to reinitiate the bake \e[0m"
fi
exit