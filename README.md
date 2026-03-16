# starlink-openwrt

Single-shot setup script for running Starlink residential on OpenWrt 25.x.

Tested on **GL-iNet Beryl AX (MT3000)** running **OpenWrt 25.12.0**.

## What it does

1. **IPv6 WAN** — creates/updates `wan6` interface with DHCPv6-PD, `ip6assign=64`
2. **odhcpd** — overrides Starlink's short prefix lifetimes via `max_preferred_lifetime`/`max_valid_lifetime` (prevents constant address churn on LAN clients)
3. **DNS** — disables peerdns, sets Cloudflare + Google resolvers
4. **NTP** — adds the Starlink dish (`192.168.100.1`) as a GPS-disciplined Stratum 1 NTP source
5. **Flow offloading** — enables software offloading, disables hardware offloading (required for fq_codel to work)
6. **MSS clamping** — sets `mtu_fix 1`; fw4 generates both ingress and egress clamp rules on OpenWrt 24.10+
7. **Kernel** — installs `kmod-tcp-hybla`, applies sysctl block (hybla congestion control, fq_codel, conntrack tuning)

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

Full IPv6 test: https://test-ipv6.com

## Requirements

- OpenWrt 22.03+ with fw4 (nftables)
- Tested on OpenWrt 25.12.0
- Starlink residential (CGNAT, DHCPv6-PD /56)

## Key notes

**Hardware flow offloading must be off** for fq_codel to be active. The script sets software offloading only.

**MSS clamping** uses `mtu_fix 1` via uci. The fw4 egress MSS bug (openwrt/openwrt#12112) is fixed in OpenWrt 24.10+ — both ingress and egress clamp rules are generated automatically.

**Hybla congestion control** — the script installs `kmod-tcp-hybla` and sets `net.ipv4.tcp_congestion_control = hybla`. Hybla was designed for satellite and high-latency links: standard loss-based algorithms (cubic, reno) grow their congestion window proportional to RTT, penalising high-latency connections even when there is no congestion. Hybla normalises window growth against a 25ms reference RTT so satellite connections ramp up at the same rate as local ones. It remains loss-based and fair to other flows — unlike BBRv1 which probes aggressively. If hybla is unavailable on a given kernel build the script falls back to CDG, then BBR, then cubic. Note: congestion control only affects TCP sessions terminating at the router (WireGuard, a local proxy, etc.) — not LAN client traffic through NAT.

**Prefix lifetimes vs prefix changes** — Starlink sends very short DHCPv6-PD lifetimes (~279s valid, ~129s preferred). The odhcpd fix overrides the *advertised* lifetimes so LAN clients get stable addresses (3600s preferred, 7200s valid) while the router renews the prefix internally on Starlink's schedule. This fixes the common case of address churn from frequent renewals. It does *not* prevent address changes if Starlink genuinely assigns a new prefix (e.g. after a dish reboot or beam handoff) — in that case LAN clients will renumber regardless.

**odhcpd option names** — the correct UCI options are `max_preferred_lifetime` and `max_valid_lifetime`. The similar-looking `preferred_lft` and `valid_lft` are not valid odhcpd options and are silently ignored. The script cleans these up automatically if present from a previous run.

**Starlink dish NTP** — the dish at `192.168.100.1` serves GPS-disciplined NTP (Stratum 1) on port 123, available since mid-2024. The script adds it as an NTP source alongside the default pool servers via `uci add_list system.ntp.server`. Accuracy in practice is ~85–123µs. No extra packages required.

---

## Buy me a beer

If this project saved you some time, feel free to shout me a beer!

[![PayPal](https://img.shields.io/badge/PayPal-Buy%20me%20a%20beer-blue?logo=paypal)](https://paypal.me/bergfirmware)
