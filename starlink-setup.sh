#!/bin/sh
# starlink-setup.sh
# Applies recommended OpenWrt settings for Starlink residential.
# Tested on OpenWrt 25.12.0, GL-iNet Beryl AX (MT3000).
#
# Usage:
#   scp -O starlink-setup.sh root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 "sh /tmp/starlink-setup.sh"

set -e

echo "================================================"
echo " Starlink OpenWrt Setup Script"
echo "================================================"
echo ""

# --- Detect WAN device ---
WAN_DEV=$(uci get network.wan.device 2>/dev/null)
if [ -z "$WAN_DEV" ]; then
    echo "ERROR: Could not detect WAN device. Check 'uci get network.wan.device'."
    exit 1
fi
echo "WAN device detected: $WAN_DEV"

# --- Detect LAN bridge ---
LAN_BR=$(uci get network.lan.device 2>/dev/null)
[ -z "$LAN_BR" ] && LAN_BR="br-lan"
echo "LAN bridge detected: $LAN_BR"

# --- Check for fw4 ---
if [ ! -d /etc/nftables.d ]; then
    echo "ERROR: /etc/nftables.d not found. This script requires fw4 (OpenWrt 22.03+)."
    exit 1
fi

echo ""

# --- 1. IPv6 WAN ---
echo "[1/6] Configuring IPv6 WAN (DHCPv6-PD)..."

if uci show network.wan6 >/dev/null 2>&1; then
    echo "      wan6 interface exists, updating..."
else
    echo "      Creating wan6 interface..."
    uci set network.wan6=interface
    uci set network.wan6.device='@wan'
fi

uci set network.wan6.proto='dhcpv6'
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'
uci set network.wan6.peerdns='0'
uci set network.lan.ip6assign='60'
uci commit network
echo "      Done."

# --- 2. odhcpd — fix Starlink short prefix lifetimes ---
echo "[2/6] Configuring odhcpd (Starlink prefix lifetime fix)..."
if ! command -v odhcpd >/dev/null 2>&1; then
    echo "      WARNING: odhcpd not found. RA/DHCPv6 config skipped."
    echo "               Install odhcpd-ipv6only and re-run for IPv6 prefix delegation."
else
uci set dhcp.lan.ra='server'
uci set dhcp.lan.dhcpv6='server'
uci set dhcp.lan.ra_default='1'
uci set dhcp.lan.ra_lifetime='600'
uci set dhcp.lan.ra_maxinterval='60'
uci set dhcp.lan.ra_mininterval='30'
uci set dhcp.lan.preferred_lft='3600'
uci set dhcp.lan.valid_lft='7200'
uci commit dhcp
echo "      Done."
fi

# --- 3. DNS ---
echo "[3/6] Configuring DNS..."
uci set network.wan.peerdns='0'
uci set network.wan.dns='1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4'
uci set network.wan6.peerdns='0'
uci set network.wan6.dns='2606:4700:4700::1111 2606:4700:4700::1001 2001:4860:4860::8888 2001:4860:4860::8844'
uci commit network
echo "      Done."

# --- 4. Flow offloading ---
echo "[4/6] Enabling software flow offloading (disabling hardware offloading)..."
uci set firewall.@defaults[0].flow_offloading='1'
uci set firewall.@defaults[0].flow_offloading_hw='0'
uci commit firewall
echo "      Done."

# --- 5. MSS clamping ---
# fw4 bug (openwrt/openwrt#12112): mtu_fix only generated an ingress clamp rule.
# Fixed in firewall4 commit 698a533 (OpenWrt 24.10+): enabling mtu_fix now
# generates both ingress (mangle_forward) and egress (mangle_postrouting) rules.
# NOTE: drop-in files with a top-level 'table' block are broken on 25.12 — fw4
# renders its ruleset as a single inline script, causing a syntax conflict.
# mtu_fix=1 is the correct fix for OpenWrt 24.10 / 25.12.
echo "[5/6] Applying MSS clamping (mtu_fix)..."
uci set firewall.@defaults[0].mtu_fix='1'
uci commit firewall
echo "      mtu_fix enabled. fw4 will generate both ingress and egress clamp rules."

# --- 6. Kernel optimisation ---
echo "[6/6] Applying kernel optimisation (BBR, fq_codel, conntrack)..."

# Install BBR (try apk first for OpenWrt 25.x, fall back to opkg)
echo "      Installing kmod-tcp-bbr..."
if command -v apk >/dev/null 2>&1; then
    apk add kmod-tcp-bbr >/dev/null 2>&1 \
        && echo "      kmod-tcp-bbr installed (apk)." \
        || echo "      WARNING: kmod-tcp-bbr install failed. Run 'apk add kmod-tcp-bbr' manually."
else
    opkg update >/dev/null 2>&1 && opkg install kmod-tcp-bbr >/dev/null 2>&1 \
        && echo "      kmod-tcp-bbr installed (opkg)." \
        || echo "      WARNING: kmod-tcp-bbr install failed. Run 'opkg install kmod-tcp-bbr' manually."
fi

# Remove any existing starlink-setup block to avoid duplicates on re-run
if grep -q "# --- starlink-setup ---" /etc/sysctl.conf 2>/dev/null; then
    echo "      Existing starlink-setup block found in sysctl.conf, replacing..."
    # Remove from marker to end of file then re-append
    sed -i '/# --- starlink-setup ---/,$d' /etc/sysctl.conf
fi

cat >> /etc/sysctl.conf << 'EOF'

# --- starlink-setup ---
# TCP optimisation (BBR affects router-terminated TCP flows only, e.g. OpenVPN in TCP mode)
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 2

# IPv6 — required for Starlink router mode
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.all.forwarding = 1

# Conntrack
net.netfilter.nf_conntrack_max = 65536
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 60
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 30
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
net.netfilter.nf_conntrack_icmp_timeout = 30
net.netfilter.nf_conntrack_generic_timeout = 600
EOF

sysctl -p /etc/sysctl.conf >/dev/null 2>&1
echo "      Done."

# --- Restart services ---
echo ""
echo "Restarting services..."
service network restart   >/dev/null 2>&1 && echo "  network     OK"
service odhcpd restart    >/dev/null 2>&1 && echo "  odhcpd      OK"
service dnsmasq restart   >/dev/null 2>&1 && echo "  dnsmasq     OK"
service firewall restart  >/dev/null 2>&1 && echo "  firewall    OK"

# Give DHCPv6-PD time to complete before verifying
echo ""
echo "Waiting 15 seconds for IPv6 to come up..."
sleep 15

echo ""
echo "================================================"
echo " Verification"
echo "================================================"
echo ""

echo "--- WAN IPv6 address ---"
ip -6 addr show dev "$WAN_DEV" | grep "inet6" || echo "  (none yet — may take a moment)"

echo ""
echo "--- LAN delegated prefix ---"
LAN_GUA=$(ip -6 addr show dev "$LAN_BR" 2>/dev/null \
    | grep "inet6" | grep "scope global" | grep -v "fe80")
if [ -n "$LAN_GUA" ]; then
    echo "$LAN_GUA"
else
    ip -6 addr show dev "$LAN_BR" | grep "inet6" || true
    echo ""
    echo "  WARNING: No delegated prefix on LAN."
    echo "  This usually means one of:"
    echo "    1. IPv6 is still coming up — wait 30s and re-run verification:"
    echo "       ip -6 addr show dev $LAN_BR"
    echo "    2. Your Starlink plan only provides a /64 (some low-end tiers)."
    echo "       A /64 cannot be sub-delegated — LAN clients cannot get routable"
    echo "       IPv6 addresses via prefix delegation. Options:"
    echo "         a) NDP proxy: enables LAN clients to share the WAN /64"
    echo "            (limited — max ~250 clients, no DHCPv6 on LAN)"
    echo "            See: https://openwrt.org/docs/guide-user/network/ipv6/ipv6.ndp"
    echo "         b) Upgrade to a Starlink plan that provides a /56 PD prefix."
fi

echo ""
echo "--- IPv6 default route ---"
ip -6 route show default || echo "  (none yet)"

echo ""
echo "--- TCP congestion control ---"
sysctl -n net.ipv4.tcp_congestion_control

echo ""
echo "--- Default qdisc ---"
sysctl -n net.core.default_qdisc

echo ""
echo "--- MSS clamp rules ---"
nft list chain inet fw4 mangle_postrouting 2>/dev/null | grep "maxseg" \
    && echo "  Egress clamp rule present (mangle_postrouting)." \
    || echo "  WARNING: Egress MSS clamp rule not found in mangle_postrouting."
nft list chain inet fw4 mangle_forward 2>/dev/null | grep "maxseg" \
    && echo "  Ingress clamp rule present (mangle_forward)." \
    || echo "  WARNING: Ingress MSS clamp rule not found in mangle_forward."

echo ""
echo "--- odhcpd prefix lifetimes ---"
echo "  preferred_lft : $(uci get dhcp.lan.preferred_lft 2>/dev/null || echo '(not configured)')"
echo "  valid_lft     : $(uci get dhcp.lan.valid_lft 2>/dev/null || echo '(not configured)')"

echo ""
echo "================================================"
echo " All done. Test IPv6: ping6 ipv6.google.com"
echo " Full test:           https://test-ipv6.com"
echo "================================================"
