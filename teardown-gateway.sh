#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

echo "=== NAT64 Gateway Teardown ==="

echo "--- Stopping services ---"
systemctl stop nat64-addr-gen.service 2>/dev/null || true
systemctl stop jool-nat64.service 2>/dev/null || true
systemctl disable nat64-addr-gen.service 2>/dev/null || true
systemctl disable jool-nat64.service 2>/dev/null || true

echo "--- Removing Jool instance ---"
jool instance remove default 2>/dev/null || true
modprobe -r jool 2>/dev/null || true

echo "--- Removing nftables table ---"
nft delete table ip6 nat64 2>/dev/null || true

echo "--- Removing sysctl overrides ---"
rm -f /etc/sysctl.d/99-nat64.conf
sysctl -p 2>/dev/null || true

echo "--- Removing module autoload ---"
rm -f /etc/modules-load.d/jool.conf

echo "--- Removing installed files ---"
rm -f /usr/local/bin/nat64-addr-gen
rm -f /etc/systemd/system/nat64-addr-gen.service
rm -f /etc/systemd/system/jool-nat64.service
systemctl daemon-reload

echo ""
echo "=== Teardown complete ==="
echo ""
echo "Config files in /etc/nat64/ were NOT removed."
echo "Remove them manually if no longer needed:"
echo "  rm -rf /etc/nat64/"
