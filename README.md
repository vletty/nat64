# NAT64 Gateway with Privacy Source Addresses

Transparent IPv4-to-IPv6 translation using [Jool](https://nicmx.github.io/Jool/)
with per-connection source address rotation from a /64 pool, generated using
RFC 7217 (Semantically Opaque IIDs) and RFC 8981 (Temporary Addresses).

## Architecture

```
 Internal Host          Gateway                    External Host
 (IPv4 only)        (dual-stack, RHEL)              (IPv6 only)
                  ┌──────────────────┐
 10.0.0.100 ────► │ eth0  (IPv4)     │
                  │                  │
                  │  Jool NAT64      │  Translates IPv4 ↔ IPv6
                  │  (kernel, prio   │  at the packet level.
                  │   -75)           │  Transparent to both ends.
                  │                  │
                  │  nftables SNAT   │  Picks a random source addr
                  │  (postrouting)   │  from the /64 pool for each
                  │                  │  new connection.
                  │  addr-gen daemon │  Rotates the pool using
                  │  (RFC 7217/8981) │  HMAC-SHA-256-based IIDs.
                  │                  │
                  │ eth1  (IPv6)     │ ────► 2001:db8:2::1
                  └──────────────────┘
```

### Packet flow

**Outbound** (internal → external):

1. Internal host connects to `GATEWAY_IPV4:443`
2. Jool translates to IPv6: `src=64:ff9b::10.0.0.100, dst=EXTERNAL_IPV6`
3. nftables SNAT rewrites src to a random address from the /64 pool
4. Packet exits with an opaque, rotating source address

**Return** (external → internal):

1. Reply arrives at the pool address
2. conntrack (priority -100) reverses the SNAT before Jool sees the packet
3. Jool (priority -75) sees the NAT64 prefix, translates back to IPv4
4. Reply delivered to internal host

## Prerequisites

**RHEL 8 or 9** with:

| Package | Provides | Install |
|---------|----------|---------|
| `jool` (DKMS) | Kernel NAT64 module + CLI | `install-jool.sh` |
| `jq` | JSON config parsing | `dnf install jq` |
| `nftables` | SNAT rule management | installed by default |
| `openssl` | HMAC-SHA-256 for IID generation | installed by default |
| `vim-common` | `xxd` hex conversion | installed by default |
| `python3` | IPv6 prefix expansion (one-liner) | installed by default |

## Setup

### 1. Install Jool

```bash
sudo ./install-jool.sh
```

Set `JOOL_VERSION` to override the default (4.1.12):

```bash
sudo JOOL_VERSION=4.1.13 ./install-jool.sh
```

### 2. Configure

```bash
sudo mkdir -p /etc/nat64
sudo cp nat64.conf.example /etc/nat64/nat64.conf
sudo vi /etc/nat64/nat64.conf
```

Edit these values to match your environment:

| Key | Description |
|-----|-------------|
| `ipv4_iface` | Internal-facing IPv4 interface |
| `ipv4_addr` | Gateway's IPv4 address on that interface |
| `ipv6_iface` | External-facing IPv6 interface |
| `ipv6_prefix` | /64 prefix for source addresses (must end with `::`) |
| `external_ipv6` | IPv6 address of the remote host |
| `forwarded_ports` | Ports to translate (default: 443/TCP, 3389/TCP) |
| `pool_size` | Number of active addresses in the SNAT pool |
| `rotation_interval` | Seconds between pool rotations |

### 3. Deploy

```bash
sudo ./setup-gateway.sh
```

This enables forwarding, configures Jool with static BIB entries, installs the
address generator daemon, and starts everything.

### 4. Verify

```bash
jool bib display --tcp                   # BIB entries
jool session display --tcp               # Active translated sessions
nft list table ip6 nat64                 # Current SNAT address pool
ip -6 addr show dev eth1 scope global    # Addresses on the interface
systemctl status nat64-addr-gen          # Daemon health
```

## Usage

Once deployed, the internal host connects to the **gateway's IPv4 address**
on the forwarded port. The gateway transparently translates to IPv6:

```
Internal host:  curl https://10.0.0.1:443   →  reaches  [2001:db8:2::1]:443
Internal host:  xfreerdp /v:10.0.0.1:3389   →  reaches  [2001:db8:2::1]:3389
```

Each connection gets a random source address from the /64 pool.
The external host sees native IPv6 connections from different addresses.

## Operations

| Action | Command |
|--------|---------|
| Force address rotation | `systemctl reload nat64-addr-gen` |
| View daemon logs | `journalctl -u nat64-addr-gen -f` |
| Stop translation | `sudo ./teardown-gateway.sh` |
| Add a port | Edit `forwarded_ports` in config, re-run `setup-gateway.sh` |

## How the address generator works

The daemon (`nat64-addr-gen.sh`) runs a loop:

1. **Generate** — produces `pool_size` IIDs using HMAC-SHA-256 over
   `(prefix, interface, timestamp, counter, random, DAD_counter)`,
   combining RFC 7217's deterministic-but-opaque approach with
   RFC 8981's temporal unlinkability.

2. **Assign** — adds each address as a `/128` on the IPv6 interface
   with kernel-managed `preferred_lft` and `valid_lft` timers.

3. **Apply** — writes an nftables rule file using `numgen random mod N map`
   and loads it atomically with `nft -f`.

4. **Sleep** — waits `rotation_interval` seconds, then repeats.
   Old addresses are deprecated (conntrack keeps existing connections alive)
   and cleaned up after `deprecated_lifetime`.

SIGHUP forces an immediate rotation. SIGTERM triggers a clean shutdown
that removes all managed addresses and the nftables table.
