#!/bin/bash
set -euo pipefail

JOOL_VERSION="${JOOL_VERSION:-4.1.12}"
JOOL_URL="https://github.com/NICMx/Jool/releases/download/v${JOOL_VERSION}/jool-${JOOL_VERSION}.tar.gz"

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" >&2
    exit 1
fi

echo "=== Installing Jool ${JOOL_VERSION} on $(cat /etc/redhat-release) ==="

RHEL_MAJOR=$(rpm -E %{rhel})
echo "Detected RHEL major version: ${RHEL_MAJOR}"

echo "--- Installing build dependencies ---"
dnf install -y \
    dkms \
    "kernel-devel-$(uname -r)" \
    "kernel-headers-$(uname -r)" \
    gcc \
    make \
    pkgconfig \
    libnl3-devel \
    libxtables-devel \
    tar \
    wget

echo "--- Downloading Jool ${JOOL_VERSION} ---"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

wget -q -O "${WORK_DIR}/jool.tar.gz" "${JOOL_URL}"
tar xzf "${WORK_DIR}/jool.tar.gz" -C "${WORK_DIR}"

JOOL_SRC="${WORK_DIR}/jool-${JOOL_VERSION}"

echo "--- Installing kernel module via DKMS ---"
cp -r "${JOOL_SRC}" "/usr/src/jool-${JOOL_VERSION}"
dkms add -m jool -v "${JOOL_VERSION}" 2>/dev/null || true
dkms build -m jool -v "${JOOL_VERSION}"
dkms install -m jool -v "${JOOL_VERSION}"

echo "--- Building userspace tools ---"
cd "${JOOL_SRC}"
./configure
make -j"$(nproc)" -C src/usr
make -C src/usr install
ldconfig

echo "--- Verifying installation ---"
modprobe jool
echo "Kernel module loaded:"
modinfo jool | grep -E '^(filename|version|description):'

echo ""
jool --version
echo ""
echo "=== Jool ${JOOL_VERSION} installed successfully ==="
echo ""
echo "Next step: run setup-gateway.sh to configure the NAT64 gateway"
