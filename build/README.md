### Build your own containerlab compatible dockerized C8000 emulator


1. Upload modified scripts
```
scp scripts/ovxr-docker/create-docker.py cisco@198.18.133.100:/home/cisco/images/8000-eft17.0/scripts/ovxr-docker/

scp scripts/bake-and-build/bake-and-build.sh cisco@198.18.133.100:/home/cisco/images/8000-eft17.0/scripts/bake-and-build/

scp scripts/bake-and-build/allowed_plats cisco@198.18.133.100:/home/cisco/images/8000-eft17.0/scripts/bake-and-build/

scp packages/bake_in_container_startup.sh cisco@198.18.133.100:/home/cisco/images/8000-eft17.0/packages/
```


2. create-docker.py script
```
~/images/8000-eft17.0/scripts/ovxr-docker/

python3 create-docker.py --iso-tar /home/cisco/images/8000-eft17.0/packages/images/8000/sonic/onie-recovery-x86_64-cisco_8000-r0.iso.tar --image-tar /home/cisco/images/8000-eft17.0/packages/images/8000/sonic/sonic-cisco-8000.bin.tar --platform 8122-64EHF-O  --docker-name 8122-64EHF-O:latest
```

