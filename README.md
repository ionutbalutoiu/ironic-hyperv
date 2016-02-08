### I. Deploy OpenStack using Juju manual provider on a Hyper-V Gen2 VM.

1. Create an `Ubuntu 14.04` node with 2 NICs (the first one for `management/external network` and the second one for Ironic `isolated network`). Also, make sure you attach a second block device (you don't need to format it, just expose it to the machine). This one will be used by `swift-storage` charm to store glance images.

2. Execute the following scripts (found in this repository) on the Hyper-V `Ubuntu 14.04` node. These steps will install OpenStack.

    - `juju/prerequisites.sh` -> It gets all the dependencies and it installs Juju stable version;
    - `juju/get-charms.sh` -> It gets the required Juju charms (`JUJU_REPOSITORY` environment variable must be set, this points to a directory where all the charms will be saved);
    - `juju/deploy.sh` -> It installs Openstack AIO (includes nova-compute configured with Ironic driver and LXC containers for some services) using `openstack-ironic.yaml` Juju bundle. Script does some steps that must be done before running `juju-deployer`.

     **NOTE(1)**: Before running `deploy.sh`, you must configure the manual provider to point to the current machine and use it as a state machine for Juju.

        ```
        juju init
        # A sample of this file with the necessary configuration for manual or openstack providers can be found on this repository
        vim ~/.juju/environments.yaml
        ```

     **NOTE(2)**: Sometimes a race condition appears, when swift keystone user is not initialized even though the identity context is complete (to be fixed and and send PR to the upstream charm). As a temporary fix, just retry the hook for the glance charm and restart the services:

        ```
        juju resolved -r glance/<unit_number>
        juju ssh glance/<unit_number> 'sudo service glance-api restart'
        juju ssh glance/<unit_number> 'sudo service glance-registry restart'
        ```

3. After the deployment is done, you must configure the `br-ex` bridge to provide external access for the baremetal nodes. Considering our scenario where the OpenStack AIO is deployed on a node with 2 ports, you must:

    - Add `eth0` (primary nic) into `br-ex`;
    - Leave `eth0` without IP; 
    - Configure `br-ex` with `eth0`'s IP;
    - Do the necessary changes to `/etc/network/interfaces` to make them persistent over reboots.

4. Create a simple network topology (Ironic flat network + public network for floating IPs)

        neutron net-create --shared --router:external --provider:network_type vlan public
        neutron subnet-create public 10.7.0.0/16 --gateway 10.7.133.31 --allocation-pool start=10.7.133.40,end=10.7.133.50 --name public_subnet --disable-dhcp

        neutron router-create public_router
        neutron router-gateway-set public_router public

        neutron net-create --provider:network_type flat --provider:physical_network physnet2 ironic
        # NOTE: The subnet must be the one configured in the bundle openstack-ironic.yaml for Ironic. (config option 'ironic-subnet')
        neutron subnet-create ironic 10.145.13.0/24 --name ironic_subnet --gateway=10.145.13.100 --allocation-pool start=10.145.13.101,end=10.145.13.110 --enable-dhcp --dns-nameserver 8.8.8.8
        neutron router-interface-add public_router ironic_subnet

    **NOTE**: The gateway for the public network must be the IP of the OpenStack AIO box, as the baremetal nodes need to access the `10.0.3.0/24` LXC containers' network.

5. Prepare the Glance images (`IPA` kernel + ramdisk, `win10-uefi` and `ubuntu-trusty-uefi`).

    **NOTE**: It is recommended to use raw disk formats in order to save time, as Ironic will convert them to raw anyway before deploying the nodes, if they have other formats.

    Canonical provides qcow2 cloud image with ubuntu trusty uefi. The following commands download the qcow2 image, converts it to raw, and uploads it to glance (make sure you exported the keystone credentials in order to use the Glance CLI).

        wget http://cloud-images.ubuntu.com/trusty/current/trusty-server-cloudimg-amd64-uefi1.img -O /tmp/trusty-server-cloudimg-amd64-uefi1.img
        qemu-img convert -f qcow2 -O raw /tmp/trusty-server-cloudimg-amd64-uefi1.img /tmp/trusty-server-cloudimg-amd64-uefi1-raw.img
        glance image-create --name ubuntu-trusty-uefi --disk-format raw --container-format bare --progress --file /tmp/trusty-server-cloudimg-amd64-uefi1-raw.img
        rm /tmp/trusty-server-cloudimg-amd64-uefi1.img
        rm /tmp/trusty-server-cloudimg-amd64-uefi1-raw.img

    For generating `IPA` coreos based ramdisk you can follow the instructions from [here](https://github.com/openstack/ironic-python-agent/tree/master/imagebuild/coreos). Or for convenience you can get already generated images from this link:

        wget https://googledrive.com/host/0B2CEI88ASvahfmFwWFpfaGJBM3BxdkpCZGo1MGhBWURib1lJUU9Vd1I4dTJPc3VMMVdJdkE/ipa-images.tar.gz

    Untar the archive and upload the images to glance using the following commands:

        glance image-create --name coreos-kernel --visibility public --disk-format aki --container-format aki --file ./coreos_production_pxe.vmlinuz
        glance image-create --name coreos-initramfs --visibility public --disk-format ari --container-format ari --file ./coreos_production_pxe_image-oem.cpio.gz

6. We'll use `iPXE` for loading `Ironic Python Agent` on the bare metal nodes, in order to bootstrap the node with the requested OS. Ironic is has been configured by the Juju charm to look for the iPXE template at the location `/etc/ironic/ipxe_config.template`. The following command downloads the template from the current repository:

        sudo wget https://raw.githubusercontent.com/ionutbalutoiu/ironic-hyperv/master/ipxe_config.template -O /etc/ironic/ipxe_config.template

7. We also need the iPXE efi binary (source: http://ipxe.org/appnote/uefihttp) into TFTP root directory:

        sudo wget http://boot.ipxe.org/ipxe.efi -O /tftpboot/ipxe.efi
        sudo chown ironic:ironic /tftpboot/ipxe.efi

8. For Hyper-V Gen2 nodes, there's a simple implementation of an agent driver using WinRM to power the nodes and change the boot order. As a prerequisite, you need to enable WinRM on the Hyper-V host. Execute the following on the Ironic machine and install the driver:

        sudo apt-get install python-pip -y
        sudo pip install pywinrm
        git clone https://github.com/ionutbalutoiu/ironic -b hyper-v-driver /tmp/hyper-v-driver
        pushd /tmp/hyper-v-driver
        sudo pip install -r requirements.txt
        sudo python setup.py install
        popd
        sudo rm -rf /tmp/hyper-v-driver
        sudo service ironic-api restart
        sudo service ironic-conductor restart

    **NOTE**: You may need to check `/var/log/ironic/ironic-conductor.log` and `/var/log/ironic/ironic-api.log` for any errors.

9. Execute the command `ironic driver-list` and if you see `agent_hyperv` driver listed there, if means that the the driver was successfully installed and ready to be used.

### II. Install and use `ironic-inspector` to discover new Ironic machines.

1. Create a database and an user for the `ironic-inspector`.

    Login to `MySQL` command line prompt and execute the following (replace `<PASSWORD>` with the desired password for the database user). **NOTE**: If you deployed `MySQL` with Juju, you can execute the following command on the `MySQL` host and login with the root user:

    ```
    mysql -u root -p`sudo cat /var/lib/mysql/mysql.passwd`
    ```

    ```
    CREATE DATABASE inspector CHARACTER SET utf8;
    GRANT ALL PRIVILEGES ON inspector.* TO 'inspector'@'localhost' IDENTIFIED BY '<PASSWORD>';
    GRANT ALL PRIVILEGES ON inspector.* TO 'inspector'@'%' IDENTIFIED BY '<PASSWORD>';
    ```

2. Install `ironic-inspector`.

    The script `install-ironic-inspector.sh` will install `ironic-inspector` from git and generates the configuration file for it. 

    **NOTE(1)**: Before running it, make sure you edit the global parameters from the beginning of the script to match your environment.

    **NOTE(2)**: Keystone credentials for Ironic are needed for the `ironic-inspector`. You can find them in the `/etc/ironic/ironic.conf` at section `keystone_authtoken`.

3. Instruct Ironic to use `ironic-inspector`.

    **NOTE**: Ironic has been installed using Juju. This change be overridden by Juju every time the Juju agent restarts. Replace `<IRONIC_INSPECTOR_HOST>` and execute the following commands:

    ```
    sudo apt-get install crudini -y
    sudo crudini --set /etc/ironic/ironic.conf inspector enabled True
    sudo crudini --set /etc/ironic/ironic.conf inspector service_url "http://<IRONIC_INSPECTOR_HOST>:5050"
    sudo service ironic-api restart
    sudo service ironic-conductor restart
    ```

4. Start `ironic-inspector` service and check `/var/log/ironic-inspector/ironic-inspector.log` for any errors.

5. Create the PXE boot environment to serve discovery kernel + ramdisk to new baremetal nodes.

    In this scenario we deployed `ironic-inspector` on the same node with Ironic and the Juju charm configured Ironic's PXE boot environment. For `ironic-inspector` PXE environment, we'll use`iPXE`, and for discovery the same `IPA` coreos based images needed for deploy.

    The script `create-pxe-ironic-inspector.sh` can be executed on the Ironic node and it will set up the environment. **NOTE**: This script uses the fact that Ironic machine has already configured a TFTP server and a web server for `iPXE`.

6. Make sure you have the `IPA` ramdisk + kernel in the `/httpboot` (the root directory of the web server which serves `iPXE` files). You can download the images directly from glance and put them there:

    ```
    COREOS_KERNEL_GLANCE_IMAGE_NAME="coreos-kernel"
    COREOS_INITRAMFS_GLANCE_IMAGE_NAME="coreos-initramfs"

    KERNEL_ID=`glance image-list | egrep "\s+$COREOS_KERNEL_GLANCE_IMAGE_NAME\s+" | awk '{print $2}'`
    RAMDISK_ID=`glance image-list | egrep "\s+$COREOS_INITRAMFS_GLANCE_IMAGE_NAME\s+" | awk '{print $2}'`

    glance image-download $KERNEL_ID --file /tmp/ironic-agent.vmlinuz
    glance image-download $RAMDISK_ID --file /tmp/ironic-agent.initramfs
    sudo mv /tmp/ironic-agent.vmlinuz /tmp/ironic-agent.initramfs /httpboot/
    sudo chown ironic:ironic /httpboot/ironic-agent.vmlinuz /httpboot/ironic-agent.initramfs
    ```

### III. Use the Juju openstack provider to deploy OpenStack on baremetal using Ironic.

We will deploy a simple multi-node OpenStack consisting of two nodes (controller/network node + compute node which are `Hyper-V` Gen2 VMs treated as baremetal nodes by Ironic).

1. Create the following three `Hyper-V` Gen2 VMs:

    - `state-machine`:
        - 1 VPUs;
        - 1G RAM;
        - 30GB disk;
        - 1 NIC connected to `ironic-private` switch (Internal switch used for Ironic flat network).

    - `controller`:
        - 2 VCPUs;
        - 6GB RAM;
        - 100GB disk;
        - 3 NICs:
            - First NIC connected to the `ironic-private` switch (Internal switch used for Ironic flat network and also for management/external traffic for the multi-node OpenStack VMs);
            - Second NIC connected to the `openstack-private` swicth (Internal switch used for OpenStack private traffic);
            - Third NIC connected to `ironic-private` switch (to provide external access to the VMs).

    - `compute-hyperv`:
        - 2 VCPUs;
        - 3G RAM;
        - 50GB disk;
        - 2 NICs:
            - First NIC connected to the `ironic-private` switch (Internal switch used for Ironic flat network and also for management/external traffic for the multi-node OpenStack VMs);
            - Second NIC connected to the `openstack-private` switch (Internal switch used for OpenStack private traffic).

2. Use `ironic-inspector` to inspect the nodes. Firstly we need to add the nodes with the minimum properties required for inspection. Follow the steps for every `Hyper-V` node.

    - Create the `Hyper-V` Ironic node and associate the MAC address of its PXE port:

        ```
        NODE_UUID=`ironic node-create -d agent_hyperv -n <NODE_NAME> | egrep "\|\s*uuid\s*\|" | awk '{print $4}'`
        ironic node-update $NODE_UUID add \
            driver_info/power_address="<HYPERV_HOST>" \
            driver_info/power_id="<VM_NAME>" \
            driver_info/power_user="<WINRM_USER>" \
            driver_info/power_pass="<WINRM_USER_PASSWORD>"
        ironic port-create -n $NODE_UUID -a <MAC_ADDRESS>
        ```

    - Set the provision state of the node to `manage` and after that to `inspect`:

        ```
        ironic node-set-provision-state <NODE_NAME> manage
        ironic node-set-provision-state <NODE_NAME> inspect
        ```

    - After inspection finishes, you can check that the node properties are updated and move the node in `provide` state, which `available`:

        ```
        ironic node-show <NODE_NAME>
        ironic node-set-provision-state <NODE_NAME> provide
        ```

        **NOTE**: `ironic-inspector` doesn't recognize `Hyper-V` Ironic nodes set in UEFI mode. So you'll need to manually update the Ironic node:

        ```
        ironic node-update <NODE_NAME> add properties/capabilities='boot_mode:uefi,boot_option:local'
        ```

    - Make sure you associate the `IPA` deploy images to the Ironic node:

        ```
        COREOS_KERNEL_GLANCE_IMAGE_NAME="coreos-kernel"
        COREOS_INITRAMFS_GLANCE_IMAGE_NAME="coreos-initramfs"
        KERNEL_ID=`glance image-list | egrep "\s+$COREOS_KERNEL_GLANCE_IMAGE_NAME\s+" | awk '{print $2}'`
        RAMDISK_ID=`glance image-list | egrep "\s+$COREOS_INITRAMFS_GLANCE_IMAGE_NAME\s+" | awk '{print $2}'`

        ironic node-update <NODE_NAME> add \
            driver_info/deploy_kernel="$KERNEL_ID" \
            driver_info/deploy_ramdisk="$RAMDISK_ID"
        ```

    **NOTE**: This repository contains a script, `create-hyperv-node.sh`, for manual registration of UEFI Ironic nodes with Hyper-V driver. The script prints the usage if run without parameters.


4. `nova-scheduler` is configured with `scheduler_use_baremetal_filters` set to `True`, which means that the following default filters are applied before booting a node: `RetryFilter`, `AvailabilityZoneFilter`, `ComputeFilter`, `ComputeCapabilitiesFilter`, `ImagePropertiesFilter`, `ExactRamFilter`, `ExactDiskFilter` and `ExactCoreFilter`.

    So, we will need flavors to match exactly the Ironic node properties. The Python script `create-bare-metal-flavors.py` from this repository iterates over all Ironic nodes that are inspected and creates a flavor with the name of the Ironic node for each one.

5. Edit `~/.juju/environments.yaml` and complete the details for the Juju openstack provider. (sample of the file can be found on this repository)

6. Generate juju tools. For convenience, you can use the following and download already compiled tools for `trusty`, `win10` and others:

    ```
    wget https://googledrive.com/host/0B2CEI88ASvahfmFwWFpfaGJBM3BxdkpCZGo1MGhBWURib1lJUU9Vd1I4dTJPc3VMMVdJdkE/tools.tar.gz -O /tmp/tools.tar.gz
    mkdir -p ~/juju-metadata/
    tar xzvf /tmp/tools.tar.gz -C ~/juju-metadata/
    rm /tmp/tools.tar.gz
    ```

7. Generate the juju metadata files for glance images. We'll use only `trusty` and `win10` images. Change the `AUTH_URL` to point to your keystone host and execute the following:

    ```
    # Get the uuid for the ubuntu-trusty-uefi and win10-uefi uploaded earlier
    UBUNTU_UUID=`glance image-list | grep ubuntu-trusty-uefi | awk '{print $2}'`
    WIN10=`glance image-list | grep win10-uefi | awk '{print $2}'`

    # Find the public-address of the keystone unit and use that for the auth_url
    AUTH_URL="http://<keystone_host>:5000/v2.0"
    mkdir -p ~/juju-metadata/

    juju metadata generate-image -a amd64 -i $UBUNTU_UUID -r RegionOne -s trusty -d ~/juju-metadata/ -u $AUTH_URL -e openstack
    juju metadata generate-image -a amd64 -i $WIN10 -r RegionOne -s win10 -d ~/juju-metadata/ -u $AUTH_URL -e openstack
    ```

8. Copy tools + images to the local web server and set 'agent-metadata-url' & 'image-metadata-url' in environments.yaml accordingly.

    ```
    sudo cp -rf ~/juju-metadata/tools /var/www/html
    sudo cp -rf ~/juju-metadata/images /var/www/html
    sudo chmod -R 755 /var/www/html/tools
    sudo chmod -R 755 /var/www/html/images
    ```

9. Bootstrap the state-machine:

    ```
    juju switch openstack
    juju bootstrap --debug --constraints "mem=1G cpu-cores=1 root-disk=30G"
    ```

    *NOTE*: `nova-scheduler` need to choose the `state-machine` Hyper-V node. So the `constraints` must match the `state-machine` flavor details.

10. `juju-deployer -S -c juju/openstack-hyperv.yaml` - it deploys controller + Hyper-V compute node.

11. Once deployment finishes. You need to set a static route on the Win10 Hyper-V compute node in order to provide it connectivity to the LXC containers from the controller node. Execute the following in an elevated PowerShell from the Win10 machine.

    ```
    route -p add 10.0.3.0 mask 255.255.255.0 <CONTROLLER_PRIVATE_IP> metric 1
    ```

12. If everything went well, your OpenStack deployment on `Hyper-V` machines using Ironic is done.
