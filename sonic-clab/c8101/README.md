## Cisco SONiC 8101-32FH-O Emulator running on Containerlab

This folder covers the *`8101-32FH-O`* 

Requirements:
* Ubuntu 22.04 or 24.04  
* **4 vCPU, 10G memory per node** 
* Containerlab (tested using 0.74.2)
* docker, kvm


1. clone the repo, cd into *`cisco8000e/sonic-clab/c8101/`*
```
git clone https://github.com/brmcdoug/cisco8000e.git
```
```
cd cisco8000e/sonic-clab/c8101/
```

2. Optional - edit the topology yaml as needed [topology.yaml](./topology.yaml)

3. Deploy the topology
```
clab deploy -t topology.yaml
```

4. 

