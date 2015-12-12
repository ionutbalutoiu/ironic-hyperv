### I. Deploy OpenStack using Juju manual provider on a Hyper-V Gen2 VM.

1. Create an Ubuntu 14.04 node with 2 NICs (the first one for management/external network and the second one for Ironic isolated network). Also, make sure you attach a second block device (you don't need to format it, just expose it to the machine). It will be used by swift-storage charm to store glance images.

2. Execute the following scripts (found in this repository) on the Hyper-V node. This will install the OpenStack.

    - `juju/prerequisites.sh` -> it gets all the dependencies and it installs Juju stable version
    - `juju/get-charms.sh` -> it gets the required Juju charms (JUJU_REPOSITORY env variable must be set, this points to a directory where all the charms will be saved)
    - `juju/deploy.sh` -> it installs Openstack AIO (includes nova-compute configured with Ironic driver and LXC containers for some services) using `openstack-ironic.yaml` Juju bundle. Script does some steps that must be done before running `juju-deployer`.

     *NOTE(1)*: Before running `deploy.sh`, you must configure the manual provider to point to the current machine and use it as a state machine for Juju.

        ```
        juju init
        vim ~/.juju/environments.yaml # A sample of this file with the necessary configuration for manual or openstack providers can be found on this repository.
        ```

     *NOTE(2)*: Sometimes a race condition appears, when swift keystone user is not initialized even though the identity context is complete (to be fixed and and send PR to the upstream charm). As a temporary fix, just retry the hook for the glance charm and restart the services:

        ```
        juju resolved -r glance/<unit_number>
        juju ssh glance/<unit_number> 'sudo service glance-api restart'
        juju ssh glance/<unit_number> 'sudo service glance-registry restart'
        ```

3. After the deployment is done, you must configure the br-ex bridge to provide external access for the baremetal nodes. Considering our scenario where the OpenStack AIO is deployed on a node with 2 ports, you must add eth0 (primary nic) into br-ex, leave eth0 without IP and configure br-ex with eth0's IP. (do the necessary changes to /etc/network/interfaces to make them persistent over reboots)

4. Create a simple network topology (Ironic flat network + public network for floating IPs)

        neutron net-create --shared --router:external --provider:network_type vlan public
        neutron subnet-create public 10.7.0.0/16 --gateway 10.7.133.31 --allocation-pool start=10.7.133.40,end=10.7.133.50 --name public_subnet --disable-dhcp

        neutron router-create public_router
        neutron router-gateway-set public_router public

        neutron net-create --provider:network_type flat --provider:physical_network physnet2 ironic
        # NOTE: The subnet must be the one configured in the bundle openstack-ironic.yaml for Ironic. (config option 'ironic-subnet')
        neutron subnet-create ironic 10.145.13.0/24 --name ironic_subnet --gateway=10.145.13.100 --allocation-pool start=10.145.13.101,end=10.145.13.110 --enable-dhcp --dns-nameserver 8.8.8.8
        neutron router-interface-add public_router ironic_subnet

    *NOTE*: The gateway for the public network must be the IP of the OpenStack AIO box, as the baremetal nodes need to access the 10.0.3.0/24 LXC containers' network.

5. Prepare the glance images (IPA kernel + ramdisk, win2012hvr2 uefi and ubuntu 14.04 uefi). It is recommended to use raw disk-format in order to save time, as Ironic will convert them to raw anyway before deploying the nodes, if they have other formats.

    Canonical provides qcow2 cloud image with ubuntu uefi. The following commands download the qcow2 image, converts it to raw, and uploads it to glance (make sure you exported the keystone credentials in order to use glance CLI)

        wget http://cloud-images.ubuntu.com/trusty/20151201/trusty-server-cloudimg-amd64-uefi1.img -O /tmp/trusty-server-cloudimg-amd64-uefi1.img
        qemu-img convert -f qcow2 -O raw /tmp/trusty-server-cloudimg-amd64-uefi1.img /tmp/trusty-server-cloudimg-amd64-uefi1-raw.img
        glance image-create --name ubuntu-trusty-uefi --disk-format raw --container-format bare --progress --file /tmp/trusty-server-cloudimg-amd64-uefi1-raw.img
        rm /tmp/trusty-server-cloudimg-amd64-uefi1.img
        rm /tmp/trusty-server-cloudimg-amd64-uefi1-raw.img

    For IPA images you follow the instructions from here: https://github.com/openstack/ironic-python-agent/tree/master/imagebuild/coreos and create your own images. Or for convenience you can get already generated images from this link:

        wget https://googledrive.com/host/0B2CEI88ASvahfmFwWFpfaGJBM3BxdkpCZGo1MGhBWURib1lJUU9Vd1I4dTJPc3VMMVdJdkE/ipa-images.tar.gz

    Untar the archive and upload the images to glance using the following commands:

        glance image-create --name coreos-kernel --visibility public --disk-format aki --container-format aki --file ./coreos_production_pxe.vmlinuz
        glance image-create --name coreos-initramfs --visibility public --disk-format ari --container-format ari --file ./coreos_production_pxe_image-oem.cpio.gz

6. We'll use iPXE for loading the Ironic Python Image on the bare metal node, in order to bootstrap the node with the requested OS. Ironic has been configured (in the openstack-ironic.yaml bundle) to look for the iPXE template at the location `/etc/ironic/ipxe_config.template`. Following command downloads the template from the current repository:

        sudo wget https://raw.githubusercontent.com/ionutbalutoiu/ironic-hyperv/master/ipxe_config.template -O /etc/ironic/ipxe_config.template

7. We also need the iPXE efi binary (source: http://ipxe.org/appnote/uefihttp) into TFTP root directory:

        sudo wget http://boot.ipxe.org/ipxe.efi -O /tftpboot/ipxe.efi
        sudo chown ironic:ironic /tftpboot/ipxe.efi

    *NOTE*: If grub2 is used as the UEFI bootloader instead of iPXE, you need to take care of this bug: http://wiki.cloudbase.it/hyperv-uefi-grub. This **NOT** preferable as it takes TOO MUCH time to load the IPA image to the nodes.

    Script which applies the fix (you may need to re-run it if the ironic Juju agent restarts, as it will overwrite the changes):

        wget http://wiki.cloudbase.it/_media/grubnetx64.efi.gz -O /tmp/grubnetx64.efi.gz
        gunzip /tmp/grubnetx64.efi.gz -c > /tmp/grubnetx64.efi
        rm /tmp/grubnetx64.efi.gz
        sudo mv /tmp/grubnetx64.efi /tftpboot/grubx64.efi
        sudo chown ironic:ironic /tftpboot/grubx64.efi

8. For Hyper-V Gen2 nodes, there's a simple implementation of an agent driver using WinRM to power the nodes and change the boot order. As a prerequisite, you need to enable WinRM on the Hyper-V host. Execute the following on the Ironic machine and install the driver:

        sudo apt-get install python-pip -y
        sudo pip install pywinrm
        git clone https://github.com/ionutbalutoiu/ironic -b hyper-v-driver /tmp/hyper-v-driver
        sudo cp /tmp/hyper-v-driver/ironic/drivers/modules/hyperv.py /usr/lib/python2.7/dist-packages/ironic/drivers/modules/
        sudo cp /tmp/hyper-v-driver/ironic/drivers/agent.py /usr/lib/python2.7/dist-packages/ironic/drivers/
        pushd /tmp/hyper-v-driver
        sudo python setup.py install
        popd
        sudo rm -rf /tmp/hyper-v-driver
        sudo service ironic-api restart
        sudo service ironic-conductor restart

    *NOTE*: You may need to check `/var/log/ironic/ironic-conductor.log` and `/var/log/ironic/ironic-api.log` for any errors.

9. Execute the command `ironic driver-list` and if you see `agent_hyperv` driver listed there, if means that the the driver was successfully installed and ready to be used.

### II. Use the Juju openstack provider to deploy OpenStack on baremetal using Ironic.

We will deploy a simple multi-node OpenStack consisting of two nodes (controller/network node + compute Hyper-V node).

1. Create the following three Gen2 Hyper-V VMs:

    - `state-machine`:
        - 1 VPUs;
        - 1G RAM;
        - 30GB disk;
        - 1 NIC connected to `ironic-private` switch (Internal switch used for Ironic flat network).

    - `controller`:
        - 2 VCPUs;
        - >4G/5GB RAM;
        - 80GB disk;
        - 3 NICs:
            - First NIC connected to the `ironic-private` switch (Internal switch used for Ironic flat network and also for management/external traffic for the multi-node OpenStack VMs);
            - Second NIC connected to the `openstack-private` swicth (Internal switch used for OpenStack private traffic);
            - Third NIC connected to `ironic-private` switch (to provide external access to the VMs).

    - `compute-hyperv`:
        - 2 VCPUs;
        - 2G RAM;
        - 50GB disk;
        - 2 NICs:
            - First NIC connected to the `ironic-private` switch (Internal switch used for Ironic flat network and also for management/external traffic for the multi-node OpenStack VMs);
            - Second NIC connected to the `openstack-private` switch (Internal switch used for OpenStack private traffic).

2. You need to create flavors for all baremetal nodes configurations.

    - state-machine:

            nova flavor-create state-machine auto 1024 30 1
            nova flavor-key state-machine set cpu_arch=x86_64

    - controller:

            nova flavor-create controller auto 6144 80 2
            nova flavor-key controller set cpu_arch=x86_64

    - compute-hyperv:

            nova flavor-create compute-hyperv auto 2048 50 2
            nova flavor-key compute-hyperv set cpu_arch=x86_64

    *NOTE*: You may need to delete the default flavors and keep only the ones for baremetal nodes. This is recommended because when you pass constraints (cpu, memory, disk, etc) to juju deploy/bootstrap commands, you make sure juju boots a new baremetal node with the desired custom flavor.

3. `./create-hyperv-node.sh` -> it creates an Ironic node with Hyper-V driver.

    *NOTE*: The script prints the usage if run without parameters.

    Replace the arguments with the ones matching your machines (node name, MAC address, RAM, VCPUs, etc):

        ./create-hyperv-node.sh \
            state-machine \
            coreos-kernel \
            coreos-initramfs \
            1 1024 30 x86_64 \
            "00:15:5d:85:50:0d" \
            "10.7.133.80" "node-4-state-machine" "ionut" "Passw0rd"

        ./create-hyperv-node.sh \
            controller \
            coreos-kernel \
            coreos-initramfs \
            2 6144 80 x86_64 \
            "00:15:5d:85:50:0a" \
            "10.7.133.80" "node-1-controller" "ionut" "Passw0rd"

        ./create-hyperv-node.sh \
            compute-hyperv \
            coreos-kernel \
            coreos-initramfs \
            2 2048 50 x86_64 \
            "00:15:5d:85:50:0c" \
            "10.7.133.80" "node-3-compute-hyperv" "ionut" "Passw0rd"

4. Edit `~/.juju/environments.yaml` and complete the details for the openstack provider. (sample of the file can be found on this repository)

5. Generate juju tools. For convenience, you can use the following and download already compiled tools for `trusty`, `win2012hvr2` and others:

    ```
    wget https://googledrive.com/host/0B2CEI88ASvahfmFwWFpfaGJBM3BxdkpCZGo1MGhBWURib1lJUU9Vd1I4dTJPc3VMMVdJdkE/tools.tar.gz -O /tmp/tools.tar.gz
    mkdir -p ~/juju-metadata/
    tar xzvf /tmp/tools.tar.gz -C ~/juju-metadata/
    rm /tmp/tools.tar.gz
    ```

6. Generate the juju metadata files for glance images. We'll use only `trusty` and `win2012hvr2` images. Change the `AUTH_URL` to point to your keystone host and execute the following:

    ```
    # Get the uuid for the ubuntu-trusty-uefi and win2012hvr2-uefi uploaded earlier
    UBUNTU_UUID=`glance image-list | grep ubuntu-trusty-uefi | awk '{print $2}'`
    WIN2012HVR2_UUID=`glance image-list | grep win2012hvr2-uefi | awk '{print $2}'`

    # Find the public-address of the keystone unit and use that for the auth_url
    AUTH_URL="http://<keystone_host>:5000/v2.0"
    mkdir -p ~/juju-metadata/

    juju metadata generate-image -a amd64 -i $UBUNTU_UUID -r RegionOne -s trusty -d ~/juju-metadata/ -u $AUTH_URL -e openstack
    juju metadata generate-image -a amd64 -i $WIN2012HVR2_UUID -r RegionOne -s win2012hvr2 -d ~/juju-metadata/ -u $AUTH_URL -e openstack
    ```

7. Copy tools + images to the local web server and set 'agent-metadata-url' & 'image-metadata-url' in environments.yaml accordingly.

    ```
    sudo cp -rf ~/juju-metadata/tools /var/www/html
    sudo cp -rf ~/juju-metadata/images /var/www/html
    sudo chmod -R 755 /var/www/html/tools
    sudo chmod -R 755 /var/www/html/images
    ```

8. Bootstrap the state-machine:

    ```
    juju bootstrap --debug --constraints "mem=1G cpu-cores=1 root-disk=30G"
    ```

    *NOTE(1)*: If you're getting the error: `Memory size is too small for requested image, if it is less...` in `ironic-conductor.log`, this is due to a bug in IPA that required enough RAM (the amount of glance image in size) to deploy the image. This was fixed in a recent commit in IPA master branch, but Ironic code validation must be updated as well.

    Temporary fix:
    - comment out `line 167` where exception is raised in the `/usr/lib/python2.7/dist-packages/ironic/drivers/modules/agent.py` file;
    - `sudo rm /usr/lib/python2.7/dist-packages/ironic/drivers/modules/agent.pyc`
    - `sudo service ironic-api restart && sudo service ironic-conductor restart`

    *NOTE(2)*: `nova-scheduler` should choose the state-machine Hyper-V node as it matches the flavor details.

9. `juju-deployer -S -c juju/openstack-hyperv.yaml` - it deploys controller + Hyper-V compute node.
