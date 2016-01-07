#!/usr/bin/env python

from ironicclient import client as ironicclient
from novaclient import client as novaclient
import os


credentials = {
    'os_username': os.environ['OS_USERNAME'],
    'os_password': os.environ['OS_PASSWORD'],
    'os_tenant_name': os.environ['OS_TENANT_NAME'],
    'os_auth_url': os.environ['OS_AUTH_URL']}

ironic_client = ironicclient.get_client(api_version=1, **credentials)
nova_client = novaclient.Client(
    2, credentials['os_username'], credentials['os_password'],
    credentials['os_tenant_name'], credentials['os_auth_url'])

delete_existing_flavors = True

for node in ironic_client.node.list():
    node_name = node.name
    try:
        flavor = nova_client.flavors.find(name=node_name)
    except:
        # Flavor not found
        flavor = None
    if flavor and delete_existing_flavors:
        nova_client.flavors.delete(flavor.id)
    node_properties = ironic_client.node.get(node.uuid).properties
    if ('memory_mb' in node_properties and 'cpus' in node_properties and
       'local_gb' in node_properties):
        nova_client.flavors.create(name=node_name,
                                   ram=node_properties['memory_mb'],
                                   vcpus=node_properties['cpus'],
                                   disk=node_properties['local_gb'])
