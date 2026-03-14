# starlink-openwrt

Single-shot setup script for running Starlink residential on OpenWrt 25.x.

Tested on **GL-iNet Beryl AX (MT3000)** running **OpenWrt 25.12.0**.

## What it does

1. **IPv6 WAN** — creates/updates `wan6` interface with DHCPv6-PD
2. **odhcpd** — overrides Starlink's short prefix lifetimes (prevents constant address churn on LAN clients)
3. **DNS** — disables peerdns, sets Cloudflare + Google resolvers
4. **Flow offloading** — enables software offloading, disables hardware offloading (required for fq_codel to work)
5. **MSS clamping** — sets `mtu_fix 1`; fw4 generates both ingress and egress clamp rules on OpenWrt 24.10+
6. **Kernel** — installs `kmod-tcp-bbr`, applies sysctl block (BBR, fq_codel, conntrack tuning)

The script is idempotent — safe to re-run on an existing install.

## Usage

```sh
scp -O starlink-setup.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "sh /tmp/starlink-setup.sh"
```

After the script completes, wait ~30 seconds for IPv6 to come up, then verify:

```sh
ssh root@192.168.1.1 "ip -6 addr show eth0; ip -6 route show default"
ping6 ipv6.google.com
```

Full IPv6 test: https://test-ipv6.roedu.net/

## Requirements

- OpenWrt 22.03+ with fw4 (nftables)
- Tested on OpenWrt 25.12.0
- Starlink residential (CGNAT, DHCPv6-PD /56)

## Key notes

**Hardware flow offloading must be off** for fq_codel to be active. The script sets software offloading only.

**MSS clamping** uses `mtu_fix 1` via uci. The fw4 egress MSS bug (openwrt/openwrt#12112) is fixed in OpenWrt 24.10+ — both ingress and egress clamp rules are generated automatically.

**BBR** only affects TCP sessions terminating at the router (e.g. WireGuard, OpenVPN). It has no effect on flows from LAN clients passing through NAT.

**Prefix lifetimes vs prefix changes** — Starlink sends very short DHCPv6-PD lifetimes (~279s valid, ~129s preferred). The odhcpd fix overrides the *advertised* lifetimes so LAN clients get stable addresses (3600s preferred, 7200s valid) while the router renews the prefix internally on Starlink's schedule. This fixes the common case of address churn from frequent renewals. It does *not* prevent address changes if Starlink genuinely assigns a new prefix (e.g. after a dish reboot or beam handoff) — in that case LAN clients will renumber regardless.
