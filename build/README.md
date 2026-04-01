### Build your own containerlab compatible dockerized C8000 emulator


1. Upload modified scripts
```
scp ./build/scripts/create
```


2. create-docker.py script
```
~/images/8000-eft17.0/scripts/ovxr-docker/

python3 create-docker2.py --iso-tar /home/cisco/images/8000-eft17.0/packages/images/8000/sonic/onie-recovery-x86_64-cisco_8000-r0.iso.tar --image-tar /home/cisco/images/8000-eft17.0/packages/images/8000/sonic/sonic-cisco-8000.bin.tar --platform 8122-64EHF-O  --docker-name 8122-64EHF-O:latest
```

