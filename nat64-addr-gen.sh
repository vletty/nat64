#!/bin/bash
# NAT64 Temporary IPv6 Address Generator
#
# Generates temporary IPv6 source addresses for NAT64 SNAT using:
#   RFC 7217 — Semantically Opaque Interface Identifiers
#   RFC 8981 — Temporary Address Extensions for IPv6
#
# Manages a rotating pool of addresses and atomically updates nftables
# SNAT rules so each new outbound NAT64 connection uses a random source
# address from the pool.

set -euo pipefail

# ── CLI ──────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 [-c CONFIG] [-v]"
    echo "  -c CONFIG  Path to config file (default: /etc/nat64/nat64.conf)"
    echo "  -v         Verbose/debug logging"
    exit 1
}

CONFIG="/etc/nat64/nat64.conf"
VERBOSE=0

while getopts "c:vh" opt; do
    case $opt in
        c) CONFIG="$OPTARG" ;;
        v) VERBOSE=1 ;;
        *) usage ;;
    esac
done

# ── Logging ──────────────────────────────────────────────────────────

log()   { echo "nat64-addr-gen: $*"; }
debug() { [[ $VERBOSE -eq 1 ]] && echo "nat64-addr-gen: debug: $*" || true; }
die()   { echo "nat64-addr-gen: error: $*" >&2; exit 1; }

# ── Prerequisites ────────────────────────────────────────────────────

for cmd in jq openssl xxd nft ip; do
    command -v "$cmd" &>/dev/null || die "missing required command: $cmd"
done

[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"

# ── Load config ──────────────────────────────────────────────────────

IPV6_PREFIX=$(jq -r '.ipv6_prefix'                              "$CONFIG")
IPV6_IFACE=$(jq -r  '.ipv6_iface'                              "$CONFIG")
NAT64_PREFIX=$(jq -r '.nat64_prefix       // "64:ff9b::/96"'   "$CONFIG")
POOL_SIZE=$(jq -r   '.pool_size           // 16'               "$CONFIG")
ROTATION_INTERVAL=$(jq -r '.rotation_interval // 300'           "$CONFIG")
DEPRECATED_LIFETIME=$(jq -r '.deprecated_lifetime // 600'       "$CONFIG")
SECRET_KEY_FILE=$(jq -r '.secret_key_file // "/etc/nat64/secret.key"' "$CONFIG")
NFT_RULES_FILE=$(jq -r  '.nft_rules_file // "/etc/nat64/snat-rules.nft"' "$CONFIG")

# Expand the /64 prefix to 16 hex characters (first 64 bits).
# This is the one place we lean on python3 — IPv6 expansion in pure
# bash is brittle and the one-liner is easier to audit than a manual
# group-splitting loop.
PREFIX_HEX=$(python3 -c "
import ipaddress, sys
try:
    a = ipaddress.IPv6Address('${IPV6_PREFIX}')
    sys.stdout.write(a.packed[:8].hex())
except Exception as e:
    sys.stderr.write('bad ipv6_prefix: %s\n' % e)
    sys.exit(1)
")

# ── Secret key (RFC 7217 §5) ────────────────────────────────────────

mkdir -p "$(dirname "$SECRET_KEY_FILE")"

if [[ -f "$SECRET_KEY_FILE" ]] && [[ $(stat -c%s "$SECRET_KEY_FILE") -ge 32 ]]; then
    SECRET_HEX=$(xxd -l 32 -p "$SECRET_KEY_FILE" | tr -d '\n')
else
    dd if=/dev/urandom bs=32 count=1 2>/dev/null > "$SECRET_KEY_FILE"
    chmod 600 "$SECRET_KEY_FILE"
    SECRET_HEX=$(xxd -l 32 -p "$SECRET_KEY_FILE" | tr -d '\n')
    log "generated new secret key at $SECRET_KEY_FILE"
fi

# ── State ────────────────────────────────────────────────────────────

declare -a ACTIVE_ADDRS=()
declare -A DEPRECATED_ADDRS=()   # addr → deprecation epoch
COUNTER=0
RUNNING=1
LAST_ROTATION=0

# ── Address generation ───────────────────────────────────────────────
#
# RFC 7217 §5 — IID = F(Prefix, Net_Iface, Network_ID, DAD_Counter, key)
# RFC 8981 §3.3.1 — temporal variation via timestamp + random component
#
# F = HMAC-SHA-256, truncated to 64 bits.

generate_iid() {
    local counter=$1 attempt=$2

    local ts_hex
    ts_hex=$(printf '%016x' "$(date +%s)")
    local ctr_hex
    ctr_hex=$(printf '%016x' "$counter")
    local rnd_hex
    rnd_hex=$(dd if=/dev/urandom bs=8 count=1 2>/dev/null | xxd -p | tr -d '\n')
    local att_hex
    att_hex=$(printf '%08x' "$attempt")

    # Pad interface name to 16 bytes (32 hex chars)
    local iface_hex
    iface_hex=$(printf '%s' "$IPV6_IFACE" | xxd -p | tr -d '\n')
    while [[ ${#iface_hex} -lt 32 ]]; do iface_hex+="00"; done
    iface_hex=${iface_hex:0:32}

    local data="${PREFIX_HEX}${iface_hex}${ts_hex}${ctr_hex}${rnd_hex}${att_hex}"

    local digest
    digest=$(echo -n "$data" | xxd -r -p | \
        openssl dgst -sha256 -mac HMAC -macopt "hexkey:${SECRET_HEX}" 2>/dev/null | \
        awk -F'= ' '{print $2}')

    local iid=${digest:0:16}

    # Clear bit 6 of the first byte (universal/local — RFC 7217 §5).
    local hi=$(( 16#${iid:0:2} & 16#fd ))
    printf '%02x%s' "$hi" "${iid:2}"
}

is_usable_iid() {
    local iid=$1
    [[ $iid == "0000000000000000" ]] && return 1
    [[ $iid == "ffffffffffffffff" ]] && return 1
    [[ ${iid:0:8} == "00005efe" ]]   && return 1   # ISATAP
    return 0
}

form_address() {
    local full="${PREFIX_HEX}$1"
    printf '%s:%s:%s:%s:%s:%s:%s:%s' \
        "${full:0:4}" "${full:4:4}" "${full:8:4}"  "${full:12:4}" \
        "${full:16:4}" "${full:20:4}" "${full:24:4}" "${full:28:4}"
}

generate_pool() {
    local want=$1
    local -a pool=()
    local attempts=0 max_attempts=$(( want * 20 ))

    while [[ ${#pool[@]} -lt $want ]] && [[ $attempts -lt $max_attempts ]]; do
        local iid
        iid=$(generate_iid "$COUNTER" "$attempts")

        if is_usable_iid "$iid"; then
            local addr
            addr=$(form_address "$iid")

            # duplicate check
            local dup=0
            for existing in "${pool[@]+"${pool[@]}"}"; do
                [[ $existing == "$addr" ]] && { dup=1; break; }
            done
            [[ $dup -eq 0 ]] && pool+=("$addr")
        fi

        (( attempts++ )) || true
        (( COUNTER++ )) || true
    done

    if [[ ${#pool[@]} -lt $want ]]; then
        die "could only generate ${#pool[@]}/${want} addresses"
    fi

    printf '%s\n' "${pool[@]}"
}

# ── Interface helpers ────────────────────────────────────────────────

add_address() {
    local addr=$1
    local vlft=$(( ROTATION_INTERVAL + DEPRECATED_LIFETIME ))

    if ip -6 addr add "${addr}/128" dev "$IPV6_IFACE" \
            preferred_lft "$ROTATION_INTERVAL" valid_lft "$vlft" 2>/dev/null; then
        debug "added ${addr} on ${IPV6_IFACE}"
    else
        debug "address ${addr} may already exist"
    fi
}

remove_address() {
    ip -6 addr del "${addr}/128" dev "$IPV6_IFACE" 2>/dev/null || true
    debug "removed ${addr} from ${IPV6_IFACE}"
}

# ── nftables ─────────────────────────────────────────────────────────

ensure_nftables_table() {
    nft add table ip6 nat64 2>/dev/null || true
    nft 'add chain ip6 nat64 postrouting { type nat hook postrouting priority srcnat; policy accept; }' \
        2>/dev/null || true
}

update_nftables() {
    [[ ${#ACTIVE_ADDRS[@]} -eq 0 ]] && return

    local n=${#ACTIVE_ADDRS[@]}
    local map=""
    local i=0
    for addr in "${ACTIVE_ADDRS[@]}"; do
        [[ -n $map ]] && map+=", "
        map+="${i} : ${addr}"
        (( i++ )) || true
    done

    mkdir -p "$(dirname "$NFT_RULES_FILE")"
    cat > "$NFT_RULES_FILE" <<-EOF
	flush chain ip6 nat64 postrouting
	add rule ip6 nat64 postrouting ip6 saddr ${NAT64_PREFIX} oifname "${IPV6_IFACE}" snat to numgen random mod ${n} map { ${map} }
	EOF

    if nft -f "$NFT_RULES_FILE"; then
        log "applied nftables SNAT rules (${n} addresses)"
    else
        log "error: failed to apply nftables rules"
    fi
}

# ── Rotation ─────────────────────────────────────────────────────────

rotate() {
    local now
    now=$(date +%s)

    # Move current actives into the deprecated set
    for addr in "${ACTIVE_ADDRS[@]+"${ACTIVE_ADDRS[@]}"}"; do
        DEPRECATED_ADDRS["$addr"]=$now
    done

    # Generate fresh pool
    ACTIVE_ADDRS=()
    while IFS= read -r addr; do
        ACTIVE_ADDRS+=("$addr")
    done < <(generate_pool "$POOL_SIZE")

    log "generated ${#ACTIVE_ADDRS[@]} new addresses"

    for addr in "${ACTIVE_ADDRS[@]}"; do
        add_address "$addr"
    done

    update_nftables

    # Expire old deprecated addresses
    for addr in "${!DEPRECATED_ADDRS[@]}"; do
        local dep_time=${DEPRECATED_ADDRS[$addr]}
        if (( now - dep_time > DEPRECATED_LIFETIME )); then
            remove_address "$addr"
            unset "DEPRECATED_ADDRS[$addr]"
        fi
    done
}

# ── Cleanup (shutdown) ──────────────────────────────────────────────

cleanup() {
    log "cleaning up"
    for addr in "${ACTIVE_ADDRS[@]+"${ACTIVE_ADDRS[@]}"}"; do
        remove_address "$addr"
    done
    for addr in "${!DEPRECATED_ADDRS[@]}"; do
        remove_address "$addr"
    done
    nft delete table ip6 nat64 2>/dev/null || true
    log "shutdown complete"
}

# ── Signal handlers ─────────────────────────────────────────────────

handle_term() {
    log "received shutdown signal"
    RUNNING=0
}

handle_hup() {
    log "received SIGHUP — forcing immediate rotation"
    LAST_ROTATION=0
}

trap handle_term TERM INT
trap handle_hup HUP

# ── Main loop ────────────────────────────────────────────────────────

ensure_nftables_table
rotate
LAST_ROTATION=$(date +%s)

log "running — pool_size=${POOL_SIZE}, rotation every ${ROTATION_INTERVAL}s"

while [[ $RUNNING -eq 1 ]]; do
    sleep 1 || true
    [[ $RUNNING -eq 0 ]] && break

    NOW=$(date +%s)
    if (( NOW - LAST_ROTATION >= ROTATION_INTERVAL )); then
        rotate
        LAST_ROTATION=$(date +%s)
    fi
done

cleanup
