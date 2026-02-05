# VXR

## under construction

### Instructions (if not using pre-built dCloud VM)

1. Acquire a Cisco VXR EFT package and untar it:
```
tar -xvf 8000-emulator-eft12.1.tar
```

2. Install the **vxr.py** tool: cd into the 'scripts' directory and run the Ubuntu server setup script then reboot
```
sudo ./ubuntuServerManualSetup.sh
```
   * The script takes a few minutes to run and may have a couple user prompts. Look for terminal output: [SERVER SETUP IS COMPLETED]

3. Download and untar 8000e image tarball (if not using one of the images that come with the EFT package)

4. Construct a vxr topology yaml file [like-this-one](dcloud/5-node-8201-32FH.yaml)

5. Note the "Custom" section in the example topology file - this is to connect router ports to linux bridge instances.  Create linux bridge instances:
```
sudo brctl addbr ce1
sudo brctl addbr ce2
sudo ip link set ce1 up
sudo ip link set ce2 up
```
Or simply run the *'add-bridges.sh'* shell script
```
cd dcloud/
sudo ./add-bridges.sh
```
```
cisco@linux-host-1:~$ brctl show
bridge name	bridge id		STP enabled	interfaces
ce1		8000.fe5a42b0d485	no		
ce2		8000.5e8491331a59	no		
docker0		8000.02425afcc113	no			
virbr0		8000.525400578356	yes		
virbr1		8000.525400d6574c	yes
```

6. test vxr.py
```
sudo vxr.py --version
```
Example output:
```
cisco@linux-host-1:~$ sudo vxr.py --version
1.5.16
```

7. Start the topology
```
sudo vxr.py start 5-node-8201-32FH.yaml
```
   * The script takes a good 10+ minutes to run depending on the host
  
example output:
```
cisco@linux-host-1:~/Cisco8000-emulator$ sudo vxr.py start 4-node-8201.yaml 
13:37:15 INFO v1.5.16 2024-08-24 13:37 output_dir:vxr.out profile:None pyvxr_id:139714654633936
13:37:15 INFO linux-host-1:/home/cisco/Cisco8000-emulator
13:37:15 WARN disabling telemetry. Cannot find influxdb_access utility: /auto/vxr/influxdb_access
13:37:15 INFO start command invoked
13:37:15 INFO Yaml:4-node-8201.yaml
13:37:15 INFO Recommending a vxr release for platform:spitfire_f  image:/home/cisco/images/8000-golden-x86_64-24.1.2.iso
13:37:15 INFO Recommended vxr release is /opt/cisco/vxr2/latest
13:37:15 INFO Extracting vxr version from '/opt/cisco/vxr2/latest/setup.sh' file.
13:37:15 INFO CVAC files will be copied to sim directory
13:37:15 INFO Launch: sim_dir:/nobackup/root/pyvxr sim_rel:/opt/cisco/vxr2/latest
13:37:17 INFO Starting vxr: 'sim --skiphomecheck -n '
13:38:10 INFO Vxr up on host localhost
13:38:10 INFO Getting port vector files for:leaf1, leaf2, rr1, spine1
13:38:42 INFO leaf1:wait for XR login prompt (console output captured in vxr.out/logs/console.leaf1.log)
13:38:42 INFO spine1:wait for XR login prompt (console output captured in vxr.out/logs/console.spine1.log)
13:38:42 INFO rr1:wait for XR login prompt (console output captured in vxr.out/logs/console.rr1.log)
13:38:42 INFO leaf2:wait for XR login prompt (console output captured in vxr.out/logs/console.leaf2.log)
<snip>

13:58:18 INFO leaf1:found all interfaces
13:58:19 INFO leaf1:loading config from /mnt/pacific/iosxr_config.txt cvac file.
13:58:25 INFO leaf1:waiting for config lock to get released
13:58:26 INFO leaf1:config lock released
13:58:26 INFO Sim up
```

8. ssh to routers (pw = cisco123):
```
rr1
ssh cisco@192.168.122.100

leaf1
ssh cisco@192.168.122.101

spine1
ssh cisco@192.168.122.102

leaf2
ssh cisco@192.168.122.103
```

9. verify MPLSoUDP from leaf1

```
show ospf route
show bgp vpnv4 uni summary
show bgp vrf carrots 10.103.1.0/24
show cef tunnel encap
show cef tunnel decap
```

Example output from leaf1
```
cisco@linux-host-1:~$ ssh cisco@192.168.122.101
Warning: Permanently added '192.168.122.101' (ED25519) to the list of known hosts.
(cisco@192.168.122.101) Password: 


RP/0/RP0/CPU0:leaf1#show ospf route
Sun Aug 25 05:46:38.461 UTC

Topology Table for ospf 1 with ID 10.0.0.101

Codes: O - Intra area, O IA - Inter area
       O E1 - External type 1, O E2 - External type 2
       O N1 - NSSA external type 1, O N2 - NSSA external type 2

O    10.0.0.100/32, metric 2100
       10.1.1.1, from 10.0.0.100, via FourHundredGigE0/0/0/0, ifIndex 35, path-id 1
O    10.0.0.101/32, metric 100
       10.0.0.101, directly connected, via Loopback0, ifIndex 69
O    10.0.0.102/32, metric 1100
       10.1.1.1, from 10.0.0.102, via FourHundredGigE0/0/0/0, ifIndex 35, path-id 1
O    10.0.0.103/32, metric 2100
       10.1.1.1, from 10.0.0.103, via FourHundredGigE0/0/0/0, ifIndex 35, path-id 1
O    10.1.1.0/31, metric 1000
       10.1.1.0, directly connected, via FourHundredGigE0/0/0/0, ifIndex 35
O    10.1.1.2/31, metric 2000
       10.1.1.1, from 10.0.0.102, via FourHundredGigE0/0/0/0, ifIndex 35, path-id 1
O    10.1.1.4/31, metric 2000
       10.1.1.1, from 10.0.0.102, via FourHundredGigE0/0/0/0, ifIndex 35, path-id 1

RP/0/RP0/CPU0:leaf1#show bgp vpnv4 uni sum
Sun Aug 25 05:46:48.238 UTC
BGP router identifier 10.0.0.101, local AS number 65000
BGP generic scan interval 60 secs
Non-stop routing is enabled
BGP table state: Active
Table ID: 0x0
BGP table nexthop route policy: MPLSoUDP-Encap
BGP main routing table version 83
BGP NSR Initial initsync version 11 (Reached)
BGP NSR/ISSU Sync-Group versions 0/0
BGP scan interval 60 secs

BGP is operating in STANDALONE mode.


Process    RcvTblVer     bRIB/RIB     LabelVer    ImportVer    SendTblVer   StandbyVer
Speaker           83            83            83            83            83             0

Neighbor        Spk    AS MsgRcvd MsgSent       TblVer  InQ OutQ  Up/Down  St/PfxRcd
10.0.0.100        0 65000     576     533           83    0    0 08:47:20          2

RP/0/RP0/CPU0:leaf1#show bgp vrf carrots 10.103.1.0/24
Sun Aug 25 05:47:01.186 UTC
BGP routing table entry for 10.103.1.0/24, Route Distinguisher: 65000:100
Versions:
  Process           bRIB/RIB   SendTblVer
  Speaker                 82           82
Last Modified: Aug 25 05:28:53.432 for 00:18:07
Paths: (1 available, best #1)
  Not advertised to any peer
  Path #1: Received by speaker 0
  Not advertised to any peer
  Local
    10.0.0.103 (metric 2100) from 10.0.0.100 (10.0.0.103)
      Received Label 24000 
      Origin incomplete, metric 0, localpref 100, valid, internal, best, group-best, import-candidate, imported
      Received Path ID 1, Local Path ID 1, version 82
      Extended community: RT:65000:100 
      Originator: 10.0.0.103, Cluster list: 10.0.0.100
      Source AFI: VPNv4 Unicast, Source VRF: carrots, Source Route Distinguisher: 65000:100

RP/0/RP0/CPU0:leaf1#show cef tunnel encap
Sun Aug 25 05:47:08.955 UTC
===============================================================================
RTEP: Tunnel-type: MPLSoUDP, Dest addr: 10.0.0.103/32, Underlay Table: 0xe0000000
  Packets/Bytes Switched: 5/670
  LTEP: Tunnel-type: MPLSoUDP, Src addr: 10.0.0.101/32, Underlay Table: 0xe0000000

RP/0/RP0/CPU0:leaf1#show cef tunnel decap
Sun Aug 25 05:47:13.043 UTC
===============================================================================
LTEP: Tunnel-type: MPLSoUDP, Src addr: 10.0.0.101/32, Underlay Table: 0xe0000000
  Packets/Bytes Switched: 2/268
RP/0/RP0/CPU0:leaf1#
```

10.  The routers themselves won't ping across the MPLSoUDP tunnel. To test the tunnel its easiest to attach something (a docker container, a VM, XRd, etc.) to the ce1 and ce2 bridges and assign appropriate IPs/routes/etc.

Or simply give ce1 and IP address on the 10.101.1.0/24 network and spin up a container or VM and attach it to ce2 bridge

Example ce1:
```
cisco@linux-host-1:~$ ifconfig ce1
ce1: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 11000
        inet 10.101.1.2  netmask 255.255.255.0  broadcast 0.0.0.0
```

Example container with interface attached to ce2:
```
root@c6100d1cbb44:/# ip a
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host 
       valid_lft forever preferred_lft forever
446: eth0@if447: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default 
    link/ether 02:42:ac:11:00:02 brd ff:ff:ff:ff:ff:ff link-netnsid 0
    inet 10.103.1.2/24 scope global eth0
       valid_lft forever preferred_lft forever
root@c6100d1cbb44:/# ip route
default via 10.103.1.1 dev eth0 
10.103.1.0/24 dev eth0 proto kernel scope link src 10.103.1.2 
root@c6100d1cbb44:/# 
```

Truncated brctl show output:
```
ce2		8000.5e8491331a59	no		H0UNCU00JLVW2C2
							veth29a5d5a       <-------- docker container eth0

```

11. ping from ce1 to something connected to ce2:
```
cisco@linux-host-1:~$ ping 10.103.1.2
PING 10.103.1.2 (10.103.1.2) 56(84) bytes of data.
64 bytes from 10.103.1.2: icmp_seq=1 ttl=62 time=3.89 ms
64 bytes from 10.103.1.2: icmp_seq=2 ttl=62 time=2.88 ms
64 bytes from 10.103.1.2: icmp_seq=3 ttl=62 time=3.06 ms
64 bytes from 10.103.1.2: icmp_seq=4 ttl=62 time=3.21 ms
^C
--- 10.103.1.2 ping statistics ---
4 packets transmitted, 4 received, 0% packet loss, time 3004ms
rtt min/avg/max/mdev = 2.882/3.259/3.888/0.380 ms
cisco@linux-host-1:~$ 
```
