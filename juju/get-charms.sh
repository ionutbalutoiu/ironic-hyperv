#!/usr/bin/env bash
set -e

if [[ -z $JUJU_REPOSITORY ]]; then
    echo "ERROR: JUJU_REPOSITORY env variable is not set."
    exit 1
fi

mkdir -p $JUJU_REPOSITORY/trusty
mkdir -p $JUJU_REPOSITORY/win10

# Stable branches for the upstream charms
bzr branch lp:charms/trusty/neutron-api $JUJU_REPOSITORY/trusty/neutron-api
bzr branch lp:charms/trusty/nova-cloud-controller $JUJU_REPOSITORY/trusty/nova-cloud-controller
bzr branch lp:charms/trusty/openstack-dashboard $JUJU_REPOSITORY/trusty/openstack-dashboard
bzr branch lp:charms/trusty/rabbitmq-server $JUJU_REPOSITORY/trusty/rabbitmq-server
bzr branch lp:~cloudbaseit/charms/trusty/ironic/trunk $JUJU_REPOSITORY/trusty/ironic
bzr branch lp:~cloudbaseit/charms/trusty/nova-compute-ironic/trunk $JUJU_REPOSITORY/trusty/nova-compute-ironic
bzr branch lp:charms/trusty/swift-storage $JUJU_REPOSITORY/trusty/swift-storage
bzr branch lp:charms/trusty/neutron-openvswitch $JUJU_REPOSITORY/trusty/neutron-openvswitch
bzr branch lp:~cloudbaseit/charms/win2012hvr2/nova-hyperv/trunk $JUJU_REPOSITORY/win10/nova-hyperv

# Dev branches in order to have some changes until they merge into stable branches
bzr branch lp:~openstack-charmers/charms/trusty/keystone/next $JUJU_REPOSITORY/trusty/keystone
bzr branch lp:~openstack-charmers/charms/trusty/neutron-gateway/next $JUJU_REPOSITORY/trusty/neutron-gateway
bzr branch lp:~ionutbalutoiu/charms/trusty/mysql/trunk $JUJU_REPOSITORY/trusty/mysql
bzr branch lp:~ionutbalutoiu/charms/trusty/glance/next $JUJU_REPOSITORY/trusty/glance
bzr branch lp:~ionutbalutoiu/charms/trusty/swift-proxy/next $JUJU_REPOSITORY/trusty/swift-proxy
