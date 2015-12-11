#!/usr/bin/env bash

if [ ! -e ~/.juju/environments.yaml ]; then
    echo "ERROR: Juju env not initialized."
    exit 1
fi

juju switch manual
if [ ! -e ~/.juju/environments/manual.jenv ]; then
    juju bootstrap --debug
    if [ $? -ne 0 ]; then exit 1; fi
fi

sudo apt-get install openvswitch-switch -y
if [ $? -ne 0 ]; then exit 1; fi

sudo ovs-vsctl br-exists br-ironic
if [ $? -eq 2 ]; then
    sudo ovs-vsctl add-br br-ironic
fi

if [[ -z $JUJU_REPOSITORY ]]; then
    echo "ERROR: JUJU_REPOSITORY env variable is not set."
    exit 1
fi

juju deploy local:trusty/mysql --to 0
juju-deployer -S -c `dirname $0`/openstack-ironic.yaml
