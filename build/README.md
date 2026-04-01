### Build your own containerlab compatible dockerized C8000 emulator


1. Upload modified scripts
```
scp scripts/ovxr-docker/create-docker.py cisco@198.18.133.100:/home/cisco/images/8000-eft17.0/scripts/ovxr-docker/

scp scripts/bake-and-build/bake-and-build.sh cisco@198.18.133.100:/home/cisco/images/8000-eft17.0/scripts/bake-and-build/

scp scripts/bake-and-build/allowed_plats cisco@198.18.133.100:/home/cisco/images/8000-eft17.0/scripts/bake-and-build/

scp packages/bake_in_container_startup.sh cisco@198.18.133.100:/home/cisco/images/8000-eft17.0/packages/
```

2. Check build container's vxr version
```
docker run --rm --entrypoint /bin/bash ovxr-dev-025528642-1:latest -c '/opt/cisco/pyvxr/pyvxr-latest/vxr.py --version 2>&1 || pip3 show pyvxr 2>/dev/null | grep Version'
```
2. create-docker.py script
```
~/images/8000-eft17.0/scripts/ovxr-docker/

python3 create-docker.py --iso-tar /home/cisco/images/8000-eft17.0/packages/images/8000/sonic/onie-recovery-x86_64-cisco_8000-r0.iso.tar --image-tar /home/cisco/images/8000-eft17.0/packages/images/8000/sonic/sonic-cisco-8000.bin.tar --platform 8122-64EHF-O  --docker-name 8122-64EHF-O:latest
```


clab script (`--platform` patches `packages/integration/clab/8000sonic.yaml` inside the ovxr-dev container before the image build). By default the SDK step does **not** purge all NGDP packages (avoids wget to `vxr-nfs-02`). To match Jenkins (purge + reinstall) **offline**, add `--sdk-deb /path/to/vxr2-ngdp-sdkdc-24.10.2230.6_1-1_all.deb` (copy the `.deb` from the build host).

The script syncs **`docker/kne`** from your EFT tree into the container (many `ovxr-dev` images omit it). It auto-detects the EFT root by walking up from `--sonic-bin` until it finds `docker/kne`, or pass **`--eft-root /home/cisco/images/8000-eft17.0`** explicitly.
```
./build-clab-sonic-onie.sh \
  --sonic-bin /home/cisco/images/8000-eft17.0/packages/images/8000/sonic/sonic-cisco-8000.bin \
  --onie-qcow2 /home/cisco/images/8000-eft17.0/packages/images/8000/sonic/onie-recovery-x86_64-cisco_8000-r0.qcow2 \
  --sdk sdkdc-24.10.2230.6 \
  --platform 8122-64EHF-O \
  --image 'ovxr-dev-837398714-1:latest' \
  --tag 'c8000-clab-sonic:eft17'
```