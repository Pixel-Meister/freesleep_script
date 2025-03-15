#!/bin/bash

# Eight Sleep Pod Modification Script
# Usage: sudo sh ./modify_eight_sleep.sh

set -e  # Exit on any error

# Run in the same directory as your rootfs.tar.gz
# Configuration - Edit these variables
WIFI_SSID='' #Set to the SSID and password of the network to connect to (never could get this to work)
WIFI_PASSWORD=''
ROOT_PASSWORD='' #Set to the new password for root and rewt
SSH_KEY="" #Enter an SSH key that you own. https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent
KEEP_ORIGINAL_SSH_KEYS=true  # Set to false to remove Eight Sleep's SSH keys. Note, later version of the firmware don't have the keys at all
MOVE_TO_SD_CARD=true #move to sd card when done. You can check the script for assumptions about where it's mounting.

# Function to generate hex PSK for WiFi password
generate_hex_psk() {
    local ssid="$1"
    local password="$2"
    local hex_psk=$(wpa_passphrase "$ssid" "$password" | grep -o "psk=.*" | cut -d= -f2)
    if [ -z "$hex_psk" ]; then
        echo "Error: Failed to generate hex PSK" >&2
        exit 1
    fi
    echo "$hex_psk"
}

# Check for rootfs.tar.gz in current directory
if [ ! -f "rootfs.tar.gz" ]; then
    echo "Error: rootfs.tar.gz not found in current directory"
    exit 1
fi

# Create directories
mkdir -p extract patched

echo "Step 1: Extracting rootfs.tar.gz..."
gunzip -c rootfs.tar.gz > rootfs.tar
tar -xf rootfs.tar -C extract

echo "Step 2: Setting root password..."
# Generate password hash
PASSWORD_HASH_ROOT=$(openssl passwd -1 -salt root "$ROOT_PASSWORD")
PASSWORD_HASH_REWT=$(openssl passwd -1 -salt rewt "$ROOT_PASSWORD")
# Modify shadow file
sed -i "s|^root:[^:]*:|root:$PASSWORD_HASH_ROOT:|" extract/etc/shadow
sed -i "s|^rewt:[^:]*:|rewt:$PASSWORD_HASH_REWT:|" extract/etc/shadow
chmod 400 extract/etc/shadow
chown 0:0 extract/etc/shadow 2>/dev/null || true  # Ignore if this fails

echo "Step 3: Adding WiFi configuration..."
# Create NetworkManager directory
mkdir -p extract/etc/NetworkManager/system-connections/

# Generate hex PSK for maximum compatibility
HEX_PSK=$(generate_hex_psk "$WIFI_SSID" "$WIFI_PASSWORD")

# Create WiFi configuration file
# Create both configurations, but make them compatible

# 1. NetworkManager configuration
cat > extract/etc/NetworkManager/system-connections/customer-wifi.nmconnection << EOF
[connection]
id=customer-wifi
uuid=700a7a76-2105-4f46-b1b4-c9f3c791c440
type=802-11-wireless
interface-name=wlan0
autoconnect=yes
autoconnect-priority=0
permissions=

[802-11-wireless]
mac-address-blacklist=
mode=infrastructure
ssid=$WIFI_SSID

[802-11-wireless-security]
auth-alg=open
key-mgmt=wpa-psk
psk=$HEX_PSK

[ipv4]
dns-search=
method=auto

[ipv6]
addr-gen-mode=stable-privacy
dns-search=
method=auto

[proxy]
method=none
EOF
chmod 600 extract/etc/NetworkManager/system-connections/customer-wifi.nmconnection

echo "Step 3.5: Configuring SSH daemon settings..."

# Modify sshd_config to allow root login and password authentication
if [ -f "extract/etc/ssh/sshd_config" ]; then
    # Enable root login
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' extract/etc/ssh/sshd_config

    # Enable password authentication
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' extract/etc/ssh/sshd_config

    echo "✓ Modified sshd_config"
else
    echo "! Warning: sshd_config not found"
fi

# Modify sshd_config_readonly if it exists (some systems use this)
if [ -f "extract/etc/ssh/sshd_config_readonly" ]; then
    # Enable root login
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' extract/etc/ssh/sshd_config_readonly

    # Enable password authentication
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' extract/etc/ssh/sshd_config_readonly

    echo "✓ Modified sshd_config_readonly"
fi


echo "Step 4: Configuring SSH keys..."
mkdir -p extract/etc/ssh
if [ "$KEEP_ORIGINAL_SSH_KEYS" = true ] && [ -f "extract/etc/ssh/authorized_keys" ]; then
    # Append our key to existing keys
    echo "$SSH_KEY" >> extract/etc/ssh/authorized_keys
else
    # Replace with only our key
    echo "$SSH_KEY" > extract/etc/ssh/authorized_keys
fi
chmod 644 extract/etc/ssh/authorized_keys

echo "Step 5: Disable update services..."
# Find and disable update services
echo "Disabling update services..."
cat > extract/etc/init.d/disable-updates << 'EOF'
#!/bin/sh
# Disable all update-related services
SERVICES_TO_DISABLE="swupdate-progress swupdate defibrillator eight-kernel telegraf vector frankenfirmware dac swupdate.socket"

for service in $SERVICES_TO_DISABLE; do
    echo "Disabling $service..."
    systemctl disable --now $service 2>/dev/null || true
done

# Remove this script so it doesn't run again
rm -f /etc/init.d/disable-updates
EOF

chmod 755 extract/etc/init.d/disable-updates
mkdir -p extract/etc/rcS.d
ln -sf ../init.d/disable-updates extract/etc/rcS.d/S99disable-updates






echo "Step 5: Creating patched rootfs..."
tar --group=0 --owner=0 --numeric-owner -cf rootfs-new.tar -C extract .
gzip -c rootfs-new.tar > patched/rootfs.tar.gz

echo "Step 6: Cleaning up..."
rm -f rootfs.tar rootfs-new.tar
rm -f -r ./extract

if [ "$MOVE_TO_SD_CARD" = true ]; then
    echo "Moving to SD Card"
    cp patched/rootfs.tar.gz /media/${HOME##*/}/A/opt/images/Yocto
    echo "Modification complete! You can now insert the SD card back into your Eight Sleep Pod."
else
    echo "Done! Patched rootfs is in patched/rootfs.tar.gz"
fi
echo "Run:"
echo 'ssh-keygen -f "~/.ssh/known_hosts" -R "[eight-pod.lan]:8822"'
echo "Hold the small button at the back while plugging in to reflash the firmware."
echo "After booting, you should be able to SSH with: ssh rewt@eight-pod.lan -p 8822"
echo "Or as root with: ssh root@eight-pod.lan -p 8822"
echo "Disable those pesky software updates with:"
echo "systemctl disable --now swupdate-progress swupdate defibrillator eight-kernel telegraf vector frankenfirmware dac swupdate.socket"

