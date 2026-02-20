## VXR 8122-64EHF-O

Requirements:

1. Ubuntu 22.04 host or VM with at least 16 vCPU and 64G of memory to run 4 8122 emulator nodes
2. VXR package: 8000-emulator-eft16.0.tar
3. SONiC image for VXR: 8000-sonic-eft16.0.tar
4. PyVXR patch: pyvxr-ovxr.tar.gz 
5. Updated SDK deb pkg: vxr2-ngdp-sdkdc-24.10.2230.6_1-1_all.deb

Instructions:

1. untar VXR and sonic image packages
```
tar -xvf 8000-emulator-eft16.0.tar
tar -xvf 8000-sonic-eft16.0.tar
```

Directory *`8000-eft16.0`* will be created with *`sonic-cisco-8000.bin`* in *`8000-eft16.0/packages/images/8000/sonic/`*

2. Run pyvxr install script
```
cd 8000-eft16.0/scripts/
sudo ./ubuntuServerManualSetup.sh
```

3. Install pyvxr patch
```
sudo python3 -m pip install pyvxr-ovxr.tar.gz
```

We are looking for *`"Successfully installed pyvxr-1.6.65"`*

4. Install updated SDK deb:
```
sudo dpkg -i vxr2*.deb
```

Example:
```
$ sudo dpkg -i vxr2*.deb
(Reading database ... 258128 files and directories currently installed.)
Preparing to unpack vxr2-ngdp-sdkdc-24.10.2230.6_1-1_all.deb ...
Unpacking vxr2-ngdp-sdkdc-24.10.2230.6 (1-1) over (1-1) ...
Setting up vxr2-ngdp-sdkdc-24.10.2230.6 (1-1) ...
```

5. Clone repo:
```
git clone https://github.com/brmcdoug/vxr.git
```

6. cd into vxr/sonic directory and deploy the 4-node test topology:
```
cd vxr/sonic/
vxr.py start 4-node.yaml 
```

Successful deployment should end in output like this:
```
22:11:45 INFO r01:swss in active state
22:11:45 INFO r00:swss in active state
22:12:16 INFO r02:swss in active state
22:12:17 INFO Sim up
```

