#!/bin/bash

# fast fail on error
set -euo pipefail;

# === Configuration ===
VPN_BRIDGE=vmbr1
VPN_BRIDGE_IP=10.10.10.1/24
VPN_CTID=200
VPN_CT_IP=10.10.10.2
VPN_SUBNET=10.10.10.0/24
STORAGE=local
TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
HOST_CONFIG_SOURCE="/root/vpn"
WG_CONTAINER_CONFIG_DIR="/etc/wireguard/config"

# === Create vmbr1 ===
if ! grep -q "$VPN_BRIDGE" /etc/network/interfaces; then
  echo "Creating $VPN_BRIDGE"
  cat <<EOF >> /etc/network/interfaces

auto $VPN_BRIDGE
iface $VPN_BRIDGE inet static
    address ${VPN_BRIDGE_IP}
    bridge_ports none
    bridge_stp off
    bridge_fd 0
EOF
  ifdown $VPN_BRIDGE && ifup $VPN_BRIDGE
fi

# Download template if not present already
if ! ls /var/lib/vz/template/cache/$TEMPLATE &>/dev/null; then
  echo "📦 Downloading LXC template: $TEMPLATE"
  pveam update
  pveam download $STORAGE $TEMPLATE
fi

# === Create VPN Gateway LXC ===
pct create $VPN_CTID $TEMPLATE \
  -hostname vpn-gateway \
  -net0 name=eth0,bridge=$VPN_BRIDGE,ip=$VPN_CT_IP/24 \
  -storage $STORAGE -memory 512 -cores 1 -unprivileged 1

pct start $VPN_CTID

# Wait until container is running and responsive to commands
while ! pct exec $VPN_CTID -- true 2>/dev/null; do
  sleep 1
done

# === Enable IP Forwarding ===
pct exec $VPN_CTID -- bash -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
pct exec $VPN_CTID -- sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
pct exec $VPN_CTID -- sysctl -p

# === Install WireGuard & iptables ===
pct exec $VPN_CTID -- bash -c "apt update && apt install -y wireguard iptables iptables-persistent"

# === WireGuard Config Copy (host -> container) ===
CONFIG_COUNT=$(pct exec $VPN_CTID -- bash -c "ls $WG_CONTAINER_CONFIG_DIR/*.conf 2>/dev/null | wc -l")
if [ "$CONFIG_COUNT" -eq 0 ]; then
  echo "Copying WireGuard config from host..."
  pct exec $VPN_CTID -- mkdir -p "$WG_CONTAINER_CONFIG_DIR"
  for conf in "$HOST_CONFIG_SOURCE"/*.conf; do
    pct push $VPN_CTID "$conf" "$WG_CONTAINER_CONFIG_DIR/"
  done
fi

# === Install systemd service inside VPN Gateway ===
pct exec $VPN_CTID -- bash -c "
cat >/etc/systemd/system/wg-client.service <<EOF
[Unit]
Description=WireGuard VPN Client
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/bash -c 'CONF=\$(ls $WG_CONTAINER_CONFIG_DIR/*.conf | shuf -n1); cp \$CONF /etc/wireguard/wg0.conf; chmod 600 /etc/wireguard/wg0.conf; wg-quick up wg0'
ExecStop=/usr/bin/wg-quick down wg0
Restart=always
RestartSec=5
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable wg-client.service
systemctl start wg-client.service
"

# === Setup NAT ===
pct exec $VPN_CTID -- iptables -t nat -A POSTROUTING -s $VPN_SUBNET -o wg0 -j MASQUERADE
pct exec $VPN_CTID -- netfilter-persistent save

echo "✅ VPN Gateway ready at $VPN_CT_IP on $VPN_BRIDGE"

# === TUI Prompt for Downstream Container ===
# install dialog if not present already
(apt-get update -qq && apt-get install -y -qq dialog) >/dev/null 2>&1

dialog --yesno "Do you want to create a downstream container routed via VPN Gateway?" 10 60
if [[ $? -eq 0 ]]; then
  # Get Container ID
  DOWNSTREAM_CTID=$(dialog --stdout --inputbox "Enter Downstream Container ID (e.g. 201):" 8 50 "201")
  [[ -z "$DOWNSTREAM_CTID" ]] && echo "⛔ Aborted: CTID missing." && exit 1

  # Get IP Address
  DOWNSTREAM_CT_IP=$(dialog --stdout --inputbox "Enter Downstream Container IP (e.g. 10.10.10.10):" 8 50 "10.10.10.10")
  [[ -z "$DOWNSTREAM_CT_IP" ]] && echo "⛔ Aborted: IP missing." && exit 1

  # clear before proceeding ahead
  clear

  pct create $DOWNSTREAM_CTID $TEMPLATE \
    -hostname vpn-client-$DOWNSTREAM_CTID \
    -net0 name=eth0,bridge=$VPN_BRIDGE,ip=${DOWNSTREAM_CT_IP}/24,gw=$VPN_CT_IP \
    -storage $STORAGE -memory 256 -cores 1 -unprivileged 1

  pct start $DOWNSTREAM_CTID
  # Wait until container is running and responsive to commands
  while ! pct exec $DOWNSTREAM_CTID -- true 2>/dev/null; do
    sleep 1
  done
  echo "✅ Downstream container $DOWNSTREAM_CTID routed via VPN Gateway ($VPN_CT_IP)"
else
  echo "⏩ Skipped downstream container creation."
fi
