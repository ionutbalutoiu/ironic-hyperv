#!/usr/bin/env bash
set -e

### GLOBAL PARAMETERS ###
KEYSTONE_HOST=""
IRONIC_HOST=""
MYSQL_HOST=""
INSPECTOR_MYSQL_DB_USER_PASSWORD=""
IRONIC_KEYSTONE_ADMIN_USER=""
IRONIC_KEYSTONE_ADMIN_PASSWORD=""
IRONIC_KEYSTONE_ADMIN_TENANT_NAME=""
# The following parameters won't probably need to be changed.
GIT_BRANCH="stable/liberty"
IRONIC_INSPECTOR_PYTHON_CLIENT_GIT_URL="https://github.com/openstack/python-ironic-inspector-client.git"
IRONIC_INSPECTOR_GIT_URL="https://github.com/openstack/ironic-inspector.git"
DNSMASQ_INTERFACE="br-ironic"
INSPECTOR_MYSQL_DB_NAME="inspector"
INSPECTOR_MYSQL_DB_USER="inspector"
KEYSTONE_PUBLIC_ENDPOINT="http://${KEYSTONE_HOST}:5000/v2.0"
KEYSTONE_ADMIN_ENDPOINT="http://${KEYSTONE_HOST}:35357"
###

if [[ -z $KEYSTONE_HOST ]] || [[ -z $IRONIC_HOST ]] || [[ -z $DNSMASQ_INTERFACE ]] || \
   [[ -z $MYSQL_HOST ]] || [[ -z $INSPECTOR_MYSQL_DB_USER_PASSWORD ]] || \
   [[ -z $IRONIC_KEYSTONE_ADMIN_USER ]] || [[ -z $IRONIC_KEYSTONE_ADMIN_PASSWORD ]] || \
   [[ -z $IRONIC_KEYSTONE_ADMIN_TENANT_NAME ]]; then
    echo "ERROR: Some global parameters are not set."
    exit 1
fi

# Install prerequisites
apt-get install git python-pip python-dev syslinux-common syslinux -y
pip install pymysql

# Install ironic-inspector python client
CLONE_DIR="/tmp/ironic-inspector-client"
rm -rf $CLONE_DIR
git clone $IRONIC_INSPECTOR_PYTHON_CLIENT_GIT_URL $CLONE_DIR -b $GIT_BRANCH
pushd $CLONE_DIR
pip install -r requirements.txt
python setup.py install
popd
rm -rf $CLONE_DIR

# Create ironic user and ironic-inspector dirs
IRONIC_INSPECTOR_ETC="/etc/ironic-inspector"
IRONIC_INSPECTOR_LOG="/var/log/ironic-inspector"
IRONIC_USER="ironic"
grep $IRONIC_USER /etc/passwd -q || useradd $IRONIC_USER
for i in $IRONIC_INSPECTOR_ETC $IRONIC_INSPECTOR_LOG; do
    mkdir -p $i
    chown -R $IRONIC_USER:$IRONIC_USER $i
done

# Install ironic-inspector from git
CLONE_DIR="/tmp/ironic-inspector"
rm -rf $CLONE_DIR
git clone $IRONIC_INSPECTOR_GIT_URL $CLONE_DIR -b $GIT_BRANCH
pushd $CLONE_DIR
pip install -r requirements.txt
python setup.py install
cp -rf rootwrap.conf rootwrap.d $IRONIC_INSPECTOR_ETC
chown root:root -R $IRONIC_INSPECTOR_ETC/rootwrap.conf $IRONIC_INSPECTOR_ETC/rootwrap.d
popd
rm -rf $CLONE_DIR

# Add ironic-inspector to sudoers
cat << EOF > /etc/sudoers.d/ironic_inspector_sudoers
Defaults:$IRONIC_USER !requiretty

$IRONIC_USER ALL = (root) NOPASSWD: /usr/local/bin/ironic-inspector-rootwrap $IRONIC_INSPECTOR_ETC/rootwrap.conf *
EOF

# Create ironic-inspector config file
cat << EOF > $IRONIC_INSPECTOR_ETC/inspector.conf
[DEFAULT]
debug = true
verbose = true
listen_address = 0.0.0.0
listen_port = 5050
auth_strategy = keystone
timeout = 3600
rootwrap_config = $IRONIC_INSPECTOR_ETC/rootwrap.conf
log_file = ironic-inspector.log
log_dir = $IRONIC_INSPECTOR_LOG

[database]
connection = mysql+pymysql://$INSPECTOR_MYSQL_DB_USER:$INSPECTOR_MYSQL_DB_USER_PASSWORD@$MYSQL_HOST/$INSPECTOR_MYSQL_DB_NAME?charset=utf8

[firewall]
manage_firewall = true
dnsmasq_interface = $DNSMASQ_INTERFACE
firewall_update_period = 15
firewall_chain = ironic-inspector

[ironic]
auth_strategy = keystone
ironic_url = http://$IRONIC_HOST:6385
identity_uri = $KEYSTONE_ADMIN_ENDPOINT
os_auth_url = $KEYSTONE_PUBLIC_ENDPOINT
os_username = $IRONIC_KEYSTONE_ADMIN_USER
os_password = $IRONIC_KEYSTONE_ADMIN_PASSWORD
os_tenant_name = $IRONIC_KEYSTONE_ADMIN_TENANT_NAME

[processing]
add_ports = pxe
keep_ports = all
overwrite_existing = true
ramdisk_logs_dir = $IRONIC_INSPECTOR_LOG
always_store_ramdisk_logs = true
EOF
chmod 600 $IRONIC_INSPECTOR_ETC/inspector.conf
chown $IRONIC_USER:$IRONIC_USER $IRONIC_INSPECTOR_ETC/inspector.conf

# Create database tables
ironic-inspector-dbsync --config-file $IRONIC_INSPECTOR_ETC/inspector.conf upgrade

# Create ironic-inspector upstart service
cat << EOF > /etc/init/ironic-inspector.conf
start on runlevel [2345]
stop on runlevel [016]
pre-start script
  mkdir -p /var/run/ironic
  chown -R $IRONIC_USER:$IRONIC_USER /var/run/ironic
end script
respawn
respawn limit 2 10

exec start-stop-daemon --start -c $IRONIC_USER --exec /usr/local/bin/ironic-inspector -- --config-file $IRONIC_INSPECTOR_ETC/inspector.conf --log-file $IRONIC_INSPECTOR_LOG/ironic-inspector.log
EOF
