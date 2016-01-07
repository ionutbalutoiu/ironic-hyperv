#!/usr/bin/env bash
set -e

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Script must be run as root user."
    exit 1
fi

### GLOBAL PARAMETERS ###
INSPECTOR_HOST=""
IRONIC_HOST=""
DHCPD_IP_NETWORK="" # Example of network -> "10.145.13.0"
DHCPD_IP_NETMASK="" # Example of netmask -> "255.255.255.0"
DHCPD_IP_RANGE=""   # Example of range -> "10.145.13.240 10.145.13.250"
DHCPD_GATEWAY=""
DHCPD_DNS=""
# The following parameters won't probably need to be changed.
HTTP_BOOT="/httpboot"
IRONIC_IPXE_WEBSERVER_PORT="9090"
DNSMASQ_INTERFACE="br-ironic"
IRONIC_USER="ironic"
###

if [[ -z $INSPECTOR_HOST ]] || [[ -z $IRONIC_HOST ]] || [[ -z $DHCPD_IP_NETWORK ]] || \
   [[ -z $DHCPD_IP_NETMASK ]] || [[ -z $DHCPD_IP_RANGE ]] || [[ -z $DHCPD_GATEWAY ]] || [[ -z $DHCPD_DNS ]]; then
    echo "ERROR: Some global parameters are not set."
    exit 1
fi

apt-get install isc-dhcp-server -y

mkdir -p $HTTP_BOOT/pxelinux.cfg
cat << EOF > $HTTP_BOOT/pxelinux.cfg/inspector_config
#!ipxe
dhcp
initrd http://$IRONIC_HOST:$IRONIC_IPXE_WEBSERVER_PORT/ironic-agent.initramfs
kernel http://$IRONIC_HOST:$IRONIC_IPXE_WEBSERVER_PORT/ironic-agent.vmlinuz initrd=ironic-agent.initramfs ipa-inspection-callback-url=http://$INSPECTOR_HOST:5050/v1/continue systemd.journald.forward_to_console=yes
boot
EOF

cat << EOF > $HTTP_BOOT/boot_inspector.ipxe
#!ipxe
chain pxelinux.cfg/inspector_config || goto boot_failed

:boot_failed
echo PXE boot failed!
echo Press any key to reboot...
prompt --timeout 180
reboot
EOF
chown -R $IRONIC_USER:$IRONIC_USER $HTTP_BOOT

cat << EOF > /etc/dhcp/dhcpd.conf
ddns-update-style none;
default-lease-time 600;
max-lease-time 7200;
log-facility local7;

option arch code 93 = unsigned integer 16;
subnet $DHCPD_IP_NETWORK netmask $DHCPD_IP_NETMASK {
    range $DHCPD_IP_RANGE;
    option routers $DHCPD_GATEWAY;
    option domain-name-servers $DHCPD_DNS;
    option tftp-server-name "$IRONIC_HOST";

    if exists user-class and option user-class = "iPXE" {
        filename "http://$IRONIC_HOST:$IRONIC_IPXE_WEBSERVER_PORT/boot_inspector.ipxe";
    } else {
        if option arch = 00:07 {
            filename "ipxe.efi";
        } else {
            filename "undionly.kpxe";
        }
    }
}
EOF

cat << EOF > /etc/default/isc-dhcp-server
INTERFACES="$DNSMASQ_INTERFACE"
EOF

service isc-dhcp-server restart
