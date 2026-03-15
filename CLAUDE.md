# CLAUDE.md — starlink-openwrt

This file provides context for Claude Code when working on this project.

---

## Project Overview

**starlink-openwrt** is a collection of setup scripts and configuration guides
for running Starlink residential on OpenWrt 25.x. The goal is a single script
that applies all recommended settings to a fresh OpenWrt install.

- **Target device:** GL-iNet Beryl AX (MT3000) running OpenWrt 25.12.0
- **ISP:** Starlink residential (CGNAT, DHCPv6-PD /56, AS14593, AU)

---

## File Structure

```
starlink-openwrt/
├── CLAUDE.md                            ← this file
├── starlink-setup.sh                    ← single-shot setup script (main deliverable)
├── starlink-ipv6-notes.txt              ← IPv6 research notes, bug fixes found
├── starlink-gen2-openwrt-config.txt     ← Gen2 firmware config extracted from GitHub
├── openwrt-starlink-forum-post.txt      ← forum post / human-readable guide
├── starlink-bug-report.txt              ← Starlink LAX4 CDN bug report (filed with Starlink)
├── starlink-bug-report-addendum.txt     ← additional tcpdump evidence for bug report
```

---

## What the Setup Script Does

Applied in order:

1. **IPv6 WAN** — creates/updates `wan6` interface with DHCPv6-PD, `reqprefix=auto`, `ip6assign=64`
2. **odhcpd** — overrides Starlink's short prefix lifetimes (`max_preferred_lifetime=3600`, `max_valid_lifetime=7200`); cleans up old incorrect option names if present
3. **DNS** — disables peerdns, sets Cloudflare + Google (IPv4 and IPv6)
4. **Flow offloading** — enables software offloading, disables hardware offloading (required for fq_codel to be active)
5. **MSS clamping** — sets `mtu_fix 1` via uci; fw4 generates both ingress and egress clamp rules on OpenWrt 24.10+
6. **Kernel** — installs `kmod-tcp-hybla`, auto-detects best congestion control (hybla > cdg > bbr > cubic), appends sysctl block (fq_codel, conntrack tuning)
7. **Restarts** — network, odhcpd, dnsmasq, firewall
8. **Verification** — prints WAN IPv6, LAN prefix, congestion control, qdisc, MSS rules, lifetimes

---

## Key Technical Background

### IPv6 prefix lifetimes
Starlink sends very short DHCPv6-PD prefix lifetimes (~279s valid, ~129s preferred).
odhcpd forwards these to LAN clients by default, causing constant address churn.
The fix overrides the advertised lifetimes in odhcpd config — the router renews
its own prefix internally while advertising stable longer lifetimes to clients.

**Critical:** the correct UCI option names are `max_preferred_lifetime` and
`max_valid_lifetime`. The similar-looking `preferred_lft` and `valid_lft` are
NOT valid odhcpd UCI options — they are silently ignored. The script cleans
these up automatically on re-run.

### ip6assign
Set to `64`. Starlink delegates a /56; the router sub-assigns a /64 directly
to the LAN. The official Starlink Gen2 firmware uses `60` in `config_generate`
but that is for internal use (it IS the Starlink firmware). For an OpenWrt
bypass router receiving a /56 via DHCPv6-PD, `64` is correct.

### fw4 egress MSS bug
`mtu_fix 1` in `/etc/config/firewall` historically generated an ingress MSS
clamp rule but not an egress one. Outbound TCP SYN packets left with an
unclamped MSS, causing large downloads to stall on Starlink's encapsulated link.

**Status:** Confirmed bug (openwrt/openwrt#12112), fixed in firewall4 commit
698a533 (3 Nov 2023). OpenWrt 24.10+ generates both ingress (`mangle_forward`)
and egress (`mangle_postrouting`) clamp rules when `mtu_fix 1` is set.
OpenWrt 23.05 does NOT have the fix.

**Script approach:** Sets `mtu_fix 1` via uci. Verified on 25.12 — both rules
appear after `service firewall restart`. Uses `rt mtu` (routing table MTU) so
no hardcoded value is needed.

**Drop-in files are broken on 25.12:** fw4 now renders its entire ruleset as a
single inline nftables script. A drop-in containing a top-level `table inet fw4`
block causes a syntax conflict and firewall restart fails with "unexpected table"
errors. Do NOT use the drop-in approach on 25.12 — `mtu_fix 1` is the fix.

### Congestion control — hybla
The script installs `kmod-tcp-hybla` and sets hybla as the congestion control
for router-terminated TCP sessions (WireGuard, local proxy, etc.). It does NOT
affect LAN client traffic passing through NAT.

**Why hybla:** Standard loss-based algorithms (cubic, reno) grow their
congestion window proportional to RTT — satellite connections are structurally
penalised vs terrestrial ones even with no congestion. Hybla normalises window
growth against a 25ms reference RTT, removing this bias. It is otherwise
loss-based and fair to other flows.

**Why not BBRv1:** BBRv1 probes for bandwidth aggressively and can be unfair
toward loss-based flows (cubic/reno) sharing the same bottleneck. Known issues
exist. CDG (delay-gradient) is theoretically better but is not compiled into the
mediatek/filogic kernel build on OpenWrt 25.12.0.

**Auto-detection:** The script checks `/proc/sys/net/ipv4/tcp_available_congestion_control`
and selects: hybla > cdg > bbr > cubic. On the GL-iNet MT3000 with 25.12.0,
hybla is used (installed via apk). CDG is not available on this target.

Available congestion control modules in the OpenWrt 25.12.0 apk repo
(mediatek/filogic):
- `kmod-tcp-hybla` — satellite-optimised RTT normalisation
- `kmod-tcp-bbr` — bandwidth+RTT based
- `kmod-tcp-scalable` — high-speed cubic variant

### Conntrack timeouts
Aligned to the official Starlink Gen2 firmware `sysctl.conf`
(extracted from github.com/SpaceExplorationTechnologies/starlink-wifi-gen2):
- `tcp_timeout_established = 7440` (2h — avoids dropping long-lived NAT sessions)
- `udp_timeout = 60`
- `udp_timeout_stream = 180`

### fq_codel instead of CAKE
Both fq_codel and CAKE need back pressure from a traffic shaper (or BQL at line
rate) to effectively counter bufferbloat. For Starlink the bottleneck is at the
satellite link, not the LAN-side ethernet port where BQL applies, so a software
shaper is required on the WAN side for either qdisc to work well.

CAKE without a configured bandwidth limit still provides per-IP fairness and a
secondary BLUE AQM (more than fq_codel), but at higher CPU cost. The practical
reason to prefer fq_codel for Starlink: configuring a shaper accurately is
difficult when Starlink throughput varies constantly, and fq_codel has lower
overhead when running unshaped. If you add a SQM/shaper layer later, CAKE
becomes the stronger choice.

### Hardware flow offloading vs fq_codel
Hardware flow offloading (MediaTek NPU on MT7981) pushes established flows
entirely off the Linux network stack. fq_codel lives in the Linux qdisc layer,
so offloaded flows bypass it completely — fq_codel is effectively inactive when
hardware offloading is enabled.

Software flow offloading (`flow_offloading 1`, `flow_offloading_hw 0`) keeps
packets in the Linux stack via a fast conntrack path; qdiscs still apply.

Starlink residential can reach 400–500 Mbps on a good connection. Software
offloading on the MT7981 should handle this but headroom is tighter than with
hardware offloading. For most users the trade is worth it; if consistently
hitting peak Starlink speeds and prioritising throughput over AQM, hardware
offloading may be preferable.
Recommended: software offloading only, or no offloading.

In `/etc/config/firewall`:
```
config defaults
    option flow_offloading '1'
    option flow_offloading_hw '0'
```

### sysctl block idempotency
The script tags the sysctl block with `# --- starlink-setup ---` and strips
it before re-appending, so the script is safe to re-run on an existing install
without duplicating entries.

### IPv6 forwarding sysctl
Both `net.ipv6.conf.all.forwarding=1` and `net.ipv6.conf.default.forwarding=1`
are set. The `default` variant ensures interfaces created after boot also inherit
forwarding. `accept_ra=2` is set on both `all` and `default` — required because
Linux ignores RAs when forwarding is enabled; `=2` overrides this so the router
receives its upstream default route from Starlink via RA.

---

## Starlink Gen2 Firmware Reference

The official Starlink WiFi Gen2 firmware is OpenWrt-based (MT7629, kernel 4.4).
Config extracted from github.com/SpaceExplorationTechnologies/starlink-wifi-gen2
is in `starlink-gen2-openwrt-config.txt`. Key observations:

- Uses `wifi_control` (SpaceX proprietary Go binary) as the user interface — not LuCI
- No BBR or non-default congestion control in the kernel config
- conntrack timeouts: established=7440, udp=60, udp_stream=180 (adopted by our script)
- dnsmasq pins `my.starlink.com` to `34.120.255.244`
- Captive portal mode redirects all DNS to `34.120.255.244` except `wifi-update.starlink.com`
- `ip6assign='60'` in config_generate is for internal use only (not applicable to bypass router)
- Crontab: `* * * * * /etc/init.d/wifi_control start` (watchdog for the proprietary daemon)

## Starlink Gen3 Router

The Gen3 Starlink router runs custom SpaceX Go firmware (not OpenWrt).
- Dish accessible at `192.168.100.1`, gRPC API on port 9200
- Router at `192.168.1.1` when active (SSH port 22 — SpaceX Router CA cert, publickey only; HTTP port 80 — wifi_control UI; gRPC port 9200 — closed from LAN)
- `wifi_get_config` / `get_network_interfaces` return Unimplemented from LAN — auth-gated or cloud-only
- Dish hardware: `rev4_panda_prod2`, firmware `2026.03.08.mr75503`
- Router firmware: `2026.03.05.mr72456`, ID: `Router-010000000000000001272DC7`
- grpcurl query example: `grpcurl -plaintext -d '{"get_status":{}}' 192.168.100.1:9200 SpaceX.API.Device.Device/Handle`

---

## Usage

```sh
scp -O starlink-setup.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "sh /tmp/starlink-setup.sh"
```

---

## Known Issues & Decisions

1. **WAN device auto-detection** — uses `uci get network.wan.device`. Aborts if
   not found. Works on all standard OpenWrt configs.

2. **hybla not available fallback** — the script auto-detects the best available
   congestion control. On kernels without hybla it falls back to cdg > bbr > cubic.
   CDG is not available on the mediatek/filogic target in 25.12.0.

3. **IPv6 not immediate** — WAN IPv6 address and LAN prefix delegation can take
   10-30 seconds after `service network restart`. The verification output may
   show empty on first run — wait and re-check with `ip -6 addr show`.

4. **Starlink LAX4 CDN bug** — `customer.lax4.mc.starlinkisp.net`
   (206.214.227.88/89) is unresponsive, causing Google Play Store downloads to
   fail for affected Starlink customers. Also intercepts traffic to 1.1.1.1 and
   google.com from this subnet. This is a Starlink infrastructure fault, not
   fixable by router config. Workaround: VPN on affected devices.
   Bug report: `starlink-bug-report.txt` + `starlink-bug-report-addendum.txt`

---

## Router Statistics (luci-app-statistics / collectd)

Installed and configured on the router. Key settings:

- **Ping hosts:** `8.8.8.8`, `1.0.0.1` (not 1.1.1.1 — intercepted by broken LAX4 CDN)
- **Interface plugin:** `br-lan` and `eth0` (WAN)
- **RRD data:** `/mnt/usb/rrd/` — written to USB drive (`/dev/sda1`, ext4, ~14GB)
- **USB auto-mount:** configured via `/etc/config/fstab`, mounts to `/mnt/usb`
- **Interval:** 30 seconds

### Graph titles and hostname

Graph titles use `%H` which is replaced with the router hostname at render time.
The hostname is set to `Starlink` — this gives all graphs the "Starlink: ..."
prefix automatically. To change it: `uci set system.@system[0].hostname='...'`

### Editing LuCI JS graph definitions on 25.12

Do NOT edit files in `/www/luci-static/...` directly using `sed -i` or `cat >`
with heredocs — shell quoting mangles the content and `sed -i` breaks the
overlayfs inode (link count drops to 0, LuCI can't load the file).

**Correct approach:** write the file locally, then `scp -O` it to the overlay:

```sh
scp -O ./ping.js root@192.168.1.1:/overlay/upper/www/luci-static/resources/statistics/rrdtool/definitions/ping.js
```

After copying: `rm -rf /tmp/rrdimg/* && /etc/init.d/uhttpd restart`

Graph definition files are at:
`/www/luci-static/resources/statistics/rrdtool/definitions/<plugin>.js`

### Argon theme — not compatible with OpenWrt 25.12

`luci-theme-argon` depends on the Lua LuCI stack which is being phased out in
25.12. Installing it pulls in `libubus-lua` which requires a libubox version
that doesn't exist on this build, breaking LuCI entirely. Do not install it.
Official themes only: `luci-theme-bootstrap` (default), `luci-theme-material`.

---

## Device Details (GL-iNet Beryl AX / MT3000)

- WAN device: `eth0`
- LAN bridge: `br-lan`
- OpenWrt version: 25.12.0 (mediatek/filogic, aarch64_cortex-a53)
- Package manager: `apk` (primary on 25.x; opkg still works)
- Firewall: fw4 (nftables)
- Kernel: 6.12.71

---

## Applicable Versions

- Confirmed tested: OpenWrt 25.12.0
- Applicable to:    OpenWrt 23.05+ with fw4 and odhcpd
- ISP:              Starlink residential (CGNAT, DHCPv6-PD /56)
