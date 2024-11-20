HOSTNAME="myhostname"
FQDN="myhostname.foo.bar"

LANG="en_GB.UTF-8"
LANGUAGE="en_GB:en"
KEYBOARD_LAYOUT="de-ch"

# The DNS servers to use
DNS_SERVERS="1.1.1.1 8.8.8.8"

# The NTP servers to use
NTP_SERVERS="0.debian.pool.ntp.org 1.debian.pool.ntp.org"

# The timezone to configure on the server
TIMEZONE=Europe/Zurich

# The passphrase for the primary ZFS pool
ZFS_PASSPHRASE=superstrongpass

# IPv4 / IPv6 addresses on the default
# interface. Best to get these from the server itself
# (ip a)
INTERFACE_NAME="eth0"
IPV4_ADDRESS="192.168.1.100"
IPV4_NETMASK="255.255.255.0"
IPV4_GATEWAY="192.168.1.1"
IPV6_ADDRESS="2001:db8::100"
IPV6_NETMASK="64"
IPV6_GATEWAY="2001:db8::1"
DNS_SERVERS="8.8.8.8 8.8.4.4 2001:4860:4860::8888 2001:4860:4860::8844"

# The target debian release to install
DEBIAN_RELEASE="bookworm"

# Hostname / FQDN of the installation
HOSTNAME="myhostname.foo.bar"

# Timezone configuration
TIMEZONE=Europe/Zurich

# Keyboard configuration
XKBMODEL="pc105"
XKBLAYOUT="ch"
XKBVARIANT="de"

# Additional packages to install on the system
ADDITIONAL_PACKAGES="lsb-release net-tools iputils-ping dnsutils curl wget vim nano software-properties-common htop tar git ca-certificates console-setup"

# SSH configuration
SSH_PORT="2222"
ALLOWED_SSH_USERS="root"

# Root password
ROOT_PASSWORD="superstrongpass"
ROOT_SSH_PUBLIC_KEY="ssh-ed25519 abcdefg"
