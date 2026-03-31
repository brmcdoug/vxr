## Cisco SONiC 8000 Emulator running on Containerlab

This folder covers scenarios involving the *`8101-32FH-O`* and *`8122-64EHF-O`* platforms

Requirements:
* Ubuntu 22.04 or 24.04  
* **4 vCPU, 10G memory per node** 
* Containerlab (tested using 0.74.2)

clab topology, configs, etc. can be found in subfolders:

1. [Cisco 8101-32FH-O](./c8101/README.md) - 32x400G 1RU platform
2. [Cisco 8122-64EHF-O](./c8122/README.md) - 64x800G 2 GU platform - this one is under construction

Currently the clab topologies are single platform (aka 4x8101 and a separate 4x8122). In the near future we can develop a mixed topology.

