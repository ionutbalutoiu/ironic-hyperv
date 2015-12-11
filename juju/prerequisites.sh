#!/usr/bin/env bash
set -e

sudo apt-add-repository ppa:juju/stable -y
sudo apt-get update

sudo apt-get install juju juju-deployer juju-core charm-tools bzr git -y
