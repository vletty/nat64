#!/bin/bash
set -euo pipefail

CONF="${1:-/etc/nat64/nat64.conf}"

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# ── helpers ──────────────────────────────────────────────────────────
jq_val() { jq -r "$1" "$CONF"; }
jq_arr() { jq -r "$1"' | "\(.port) \(.protocol)"' "$CONF"; }

# ── read config ──────────────────────────────────────────────────────
echo "=== NAT64 Gateway Setup ==="
echo "Config: ${CONF}"

if [[ ! -f "${CONF}" ]]; then
    echo "Config file not found.  Copy nat64.conf.example to ${CONF} and edit it." >&2
    exit 1
fi

IPV4_IFACE=$(jq_val  '.ipv4_iface')
IPV4_ADDR=$(jq_val   '.ipv4_addr')
IPV6_IFACE=$(jq_val  '.ipv6_iface')
IPV6_PREFIX=$(jq_val '.ipv6_prefix')
NAT64_PREFIX=$(jq_val '.nat64_prefix')
EXTERNAL_IPV6=$(jq_val '.external_ipv6')

echo "  IPv4 iface : ${IPV4_IFACE} (${IPV4_ADDR})"
echo "  IPv6 iface : ${IPV6_IFACE} (${IPV6_PREFIX}/64)"
echo "  NAT64 pfx  : ${NAT64_PREFIX}"
echo "  Remote host: ${EXTERNAL_IPV6}"
echo ""

# ── prerequisites ────────────────────────────────────────────────────
echo "--- Checking prerequisites ---"
for cmd in nft ip jq openssl xxd python3 modprobe jool; do
    if ! command -v "${cmd}" &>/dev/null; then
        echo "Missing command: ${cmd}" >&2
        [[ "${cmd}" == "jool" ]] && echo "Run install-jool.sh first." >&2
        exit 1
    fi
done
echo "All required commands found."

# ── IP forwarding ────────────────────────────────────────────────────
echo "--- Enabling IP forwarding ---"
cat > /etc/sysctl.d/99-nat64.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
SYSCTL
sysctl -p /etc/sysctl.d/99-nat64.conf

# ── Jool module persistence ─────────────────────────────────────────
echo "--- Configuring Jool module autoload ---"
echo "jool" > /etc/modules-load.d/jool.conf
modprobe jool

# ── Generate Jool config ────────────────────────────────────────────
echo "--- Generating Jool configuration ---"

# Build pool4 and bib arrays from forwarded_ports
POOL4_ENTRIES=""
BIB_ENTRIES=""
while read -r PORT PROTO; do
    PROTO_LOWER=$(echo "${PROTO}" | tr '[:upper:]' '[:lower:]')
    [[ -n "${POOL4_ENTRIES}" ]] && POOL4_ENTRIES="${POOL4_ENTRIES},"
    POOL4_ENTRIES="${POOL4_ENTRIES}
        {
            \"protocol\": \"${PROTO}\",
            \"prefix\": \"${IPV4_ADDR}/32\",
            \"port range\": \"${PORT}\"
        }"

    [[ -n "${BIB_ENTRIES}" ]] && BIB_ENTRIES="${BIB_ENTRIES},"
    BIB_ENTRIES="${BIB_ENTRIES}
        {
            \"protocol\": \"${PROTO}\",
            \"ipv4 address\": \"${IPV4_ADDR}#${PORT}\",
            \"ipv6 address\": \"${EXTERNAL_IPV6}#${PORT}\"
        }"
done < <(jq_arr '.forwarded_ports[]')

cat > /etc/nat64/jool.conf <<EOF
{
    "instance": "default",
    "framework": "netfilter",
    "global": {
        "manually-enabled": true,
        "pool6": "${NAT64_PREFIX}"
    },
    "pool4": [${POOL4_ENTRIES}
    ],
    "bib": [${BIB_ENTRIES}
    ]
}
EOF

echo "  Written to /etc/nat64/jool.conf"

# ── Apply Jool config ───────────────────────────────────────────────
echo "--- Applying Jool NAT64 configuration ---"
jool instance remove default 2>/dev/null || true
jool file handle /etc/nat64/jool.conf
echo "  Jool instance active:"
jool instance display
echo ""
echo "  BIB entries:"
jool bib display --tcp
echo ""

# ── nftables base table ─────────────────────────────────────────────
echo "--- Creating nftables SNAT table ---"
nft -f - <<NFT
add table ip6 nat64
add chain ip6 nat64 postrouting { type nat hook postrouting priority srcnat \; policy accept \; }
NFT
echo "  Table ip6 nat64 ready."

# ── firewalld integration ───────────────────────────────────────────
if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "--- Configuring firewalld ---"
    while read -r PORT PROTO; do
        PROTO_LOWER=$(echo "${PROTO}" | tr '[:upper:]' '[:lower:]')
        firewall-cmd --permanent --add-port="${PORT}/${PROTO_LOWER}" 2>/dev/null || true
    done < <(jq_arr '.forwarded_ports[]')
    firewall-cmd --permanent --add-masquerade 2>/dev/null || true
    firewall-cmd --reload
    echo "  firewalld rules applied."
else
    echo "--- firewalld not active, skipping ---"
fi

# ── Install address generator ───────────────────────────────────────
echo "--- Installing address generator daemon ---"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install -m 0755 "${SCRIPT_DIR}/nat64-addr-gen.sh" /usr/local/bin/nat64-addr-gen
install -m 0644 "${SCRIPT_DIR}/nat64-addr-gen.service" /etc/systemd/system/
install -m 0644 "${SCRIPT_DIR}/jool-nat64.service" /etc/systemd/system/

mkdir -p /var/lib/nat64

systemctl daemon-reload

# ── Enable and start services ───────────────────────────────────────
echo "--- Enabling services ---"
systemctl enable jool-nat64.service
systemctl enable nat64-addr-gen.service

echo "--- Starting address generator ---"
systemctl start nat64-addr-gen.service

echo ""
echo "=== Setup complete ==="
echo ""
echo "Verify with:"
echo "  jool bib display --tcp        # BIB entries"
echo "  jool session display --tcp    # Active sessions"
echo "  nft list table ip6 nat64      # SNAT rules"
echo "  ip -6 addr show dev ${IPV6_IFACE}  # Assigned addresses"
echo "  systemctl status nat64-addr-gen"
echo ""
echo "The internal host (${IPV4_ADDR%.*}.x) can now connect to"
echo "  ${IPV4_ADDR}:443  -> ${EXTERNAL_IPV6}:443  (HTTPS)"
echo "  ${IPV4_ADDR}:3389 -> ${EXTERNAL_IPV6}:3389 (RDP)"
