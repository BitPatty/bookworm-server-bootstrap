#!/bin/sh
#
# pre-bootstrap.sh
#
# This script installs the dependencies for running the primary bootstrap
# script (bootstrap.sh)


############################################################################
# Preconditions
############################################################################

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

############################################################################
# OS Detection
############################################################################

# Detect the OS/Version based on the /etc/os-release.
# This file should exist in every supported base OS.
echo "Detecting Operating System"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    echo "Error: Unable to detect the operating system."
    exit 1
fi

############################################################################
# Debian Preparation Functions
############################################################################

prepare_debian_12() {
    if ! command -v apt >/dev/null 2>&1; then
        echo "Error: apt is not available."
        exit 1
    fi

    echo "Adding contributor packages"
    sed -r -i'.BAK' 's/^deb(.*)$/deb\1 contrib/g' /etc/apt/sources.list

    echo "Updating package lists..."
    apt update

    echo "Installing necessary packages..."
    apt install -y \
        bash \
        debootstrap \
        zfsutils-linux \
        linux-headers-amd64 \
        gdisk \
        grep \
        nano

    echo "Finished package installation."
}

############################################################################
# Preparation
############################################################################

case "$OS" in
    debian)
        if [ "$VERSION" = "12" ]; then
            echo "Debian 12 (Bookworm) detected. Proceeding with package installation."
            prepare_debian_12
        else
            echo "Error: Unsupported Debian version."
            exit 1
        fi
        ;;
    *)
        echo "Error: Unsupported operating system: $OS."
        exit 1
        ;;
esac