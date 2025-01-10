#!/bin/bash

# Check if running with sudo/root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo"
    exit 1
fi

echo "Starting OpenFortiVPN uninstallation..."

# Stop and disable the service if it exists
if systemctl is-active --quiet openfortivpn@vpn; then
    echo "Stopping OpenFortiVPN service..."
    systemctl stop openfortivpn@vpn
fi

if systemctl is-enabled --quiet openfortivpn@vpn; then
    echo "Disabling OpenFortiVPN service..."
    systemctl disable openfortivpn@vpn
fi

# Kill any running instances of the applet
echo "Stopping VPN applet..."
pkill -f "systemd-applet.py openfortivpn@vpn"

# Remove configuration files
echo "Removing configuration files..."
rm -f /etc/openfortivpn/vpn.conf
rm -f /etc/systemd/system/openfortivpn@.service
rm -f /usr/local/bin/systemd-applet.py
rm -f /var/lib/openfortivpn/config.public

# Remove desktop entry from system-wide applications
rm -f "/usr/share/applications/openfortivpn-applet.desktop"

# Remove empty directories if they exist
rmdir /etc/openfortivpn 2>/dev/null || true
rmdir /var/lib/openfortivpn 2>/dev/null || true

# Reload systemd to recognize the removed service
echo "Reloading systemd..."
systemctl daemon-reload

# Optional: Remove packages (commented out by default for safety)
read -p "Do you want to remove the OpenFortiVPN package? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Removing OpenFortiVPN package..."
    apt-get remove -y openfortivpn
    
    read -p "Do you want to remove Python dependencies (GTK libraries)? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Removing Python dependencies..."
        apt-get remove -y python3-gi gir1.2-appindicator3-0.1 python3-pip
        apt-get autoremove -y
    fi
fi

echo "Cleaning up any remaining configuration files..."
find /etc -name "*openfortivpn*" -type f -exec rm -f {} +
find /usr/local -name "*openfortivpn*" -type f -exec rm -f {} +
find /var/lib -name "*openfortivpn*" -type f -exec rm -f {} +

echo "Uninstallation completed successfully!"
echo "Note: System-wide Python packages were not removed unless specifically requested."
echo "If you want to completely remove all related packages, you can run:"
echo "sudo apt-get remove --purge openfortivpn python3-gi gir1.2-appindicator3-0.1 python3-pip"
echo "sudo apt-get autoremove --purge"