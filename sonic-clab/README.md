## Cisco SONiC 8000 Emulator running on Containerlab

### March 25, 2026 - under construction

This repo covers scenarios involving the *`8101-32FH-O`* and *`8122-64EHF-O`* platforms

Requirements:
* Ubuntu 22.04 or 24.04  
* **4 vCPU, 10G memory per node** 
* Containerlab (any recent version should work)

1. clone this repo, cd into *`cisco8000e/sonic-clab/`*
```
git clone https://github.com/brmcdoug/cisco8000e.git
```
```
cd cisco8000e/sonic-clab/
```

2. Optional - edit the topology yaml as needed

3. Deploy the topology
```
clab deploy -t topology-8101-32FH-O.yaml
```

