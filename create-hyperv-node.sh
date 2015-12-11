#!/bin/bash
set -e

if [ $# -ne 12 ]; then
    echo "USAGE: $0 <node_name>" \
                   "<deploy_kernel_name>" \
                   "<deploy_ramdisk_name>" \
                   "<cpus>" \
                   "<ram_mb>" \
                   "<disk_gb>" \
                   "<cpu_arch=i686|x86_64>" \
                   "<port_mac_address>" \
                   "<power_address>" \
                   "<power_id>" \
                   "<power_user>" \
                   "<power_pass>"
    exit 1
fi

NODE_UUID=`ironic node-create -d agent_hyperv | egrep "\|\s*uuid\s*\|" | awk '{print $4}'`

KERNEL_ID=`glance image-list | egrep "\s+$2\s+" | awk '{print $2}'`
RAMDISK_ID=`glance image-list | egrep "\s+$3\s+" | awk '{print $2}'`
ironic node-update $NODE_UUID add \
    name="$1" \
    driver_info/deploy_kernel="$KERNEL_ID" \
    driver_info/deploy_ramdisk="$RAMDISK_ID" \
    properties/cpus="$4" \
    properties/memory_mb="$5" \
    properties/local_gb="$6" \
    properties/cpu_arch="$7" \
    driver_info/power_address="${9}" \
    driver_info/power_id="${10}" \
    driver_info/power_user="${11}" \
    driver_info/power_pass="${12}"

ironic port-create -n $NODE_UUID -a "$8"

# ./create-hyperv-node.sh controller coreos-kernel coreos-initramfs 2 16384 80 x86_64 00:15:5d:85:50:03" "10.7.133.80" "node-1-controller" "ionut" "Passw0rd"
