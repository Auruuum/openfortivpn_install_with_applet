# OpenFortiVPN Installer and Applet

A complete solution for installing and managing OpenFortiVPN connections on Linux systems with a convenient system tray applet.

## Features

- One-line installation script
- System tray applet for VPN management
- Automatic service configuration
- Real-time connection status monitoring
- VPN IP address display
- Connection testing tools
- Secure credential handling
- OTP (One-Time Password) support
- Clean uninstallation script

## Prerequisites

- Ubuntu/Debian-based Linux distribution
- systemd
- GTK3 desktop environment (GNOME, Xfce, etc.)
- sudo privileges

## Quick Installation

Without OTP:
```bash
curl -sSL https://raw.githubusercontent.com/Auruuum/openfortivpn_install_with_applet/main/install-vpn.sh | sudo bash -s -- USERNAME 'PASSWORD' HOST
```

With OTP support:
```bash
curl -sSL https://raw.githubusercontent.com/Auruuum/openfortivpn_install_with_applet/main/install-vpn.sh | sudo bash -s -- USERNAME 'PASSWORD' HOST --otp
```

Replace `USERNAME`, `PASSWORD`, and `HOST` with your FortiVPN credentials.

## Manual Installation

1. Clone the repository:
```bash
git clone https://github.com/Auruuum/openfortivpn_install_with_applet.git
cd openfortivpn_install_with_applet
```

2. Run the installation script:
```bash
sudo ./install-vpn.sh USERNAME PASSWORD HOST        # Without OTP
sudo ./install-vpn.sh USERNAME PASSWORD HOST --otp  # With OTP
```

## Components Installed

1. OpenFortiVPN package and dependencies
2. System tray applet
3. Systemd service configuration
4. System-wide desktop entry
5. Public configuration for applet functionality

## Security Features

- Secure password handling with special character support
- Configuration file permissions set to 600 (root-only)
- Uses pkexec for privileged operations
- Separate public and private configuration files
- Certificate hash automatically calculated and verified
- OTP support for additional security

## Using the VPN Applet

The applet provides the following features:

- **Status Monitoring**: Shows current VPN connection status
- **IP Display**: Shows your VPN IP when connected
- **Connection Controls**: 
  - Connect VPN (with OTP prompt if enabled)
  - Disconnect VPN
  - Reconnect VPN
- **Tools**:
  - Connection testing
  - VPN log viewing
  - Status updates every 2 seconds

## Uninstallation

To remove all components:

```bash
curl -sSL https://raw.githubusercontent.com/Auruuum/openfortivpn_install_with_applet/main/uninstall-vpn.sh | sudo bash
```

Or manually:
```bash
sudo ./uninstall-vpn.sh
```

The uninstaller will:
1. Stop and disable the VPN service
2. Remove all configuration files (both private and public)
3. Remove the applet and desktop entry
4. Optionally remove installed packages

## Troubleshooting

### Common Issues

1. **Applet doesn't show up in system tray**
   - Check if python3-gi and gir1.2-appindicator3-0.1 are installed
   - Verify the desktop entry in /usr/share/applications
   - Try restarting your session

2. **VPN won't connect**
   - Check your credentials in /etc/openfortivpn/vpn.conf
   - Verify network connectivity
   - Check system logs: `journalctl -u openfortivpn@vpn`
   - If using OTP, ensure you're entering the correct code

3. **Status doesn't update**
   - The applet checks multiple interfaces (ppp0, tun0, vpn0)
   - Verify the service status: `systemctl status openfortivpn@vpn`
   - Check applet logs in system journal

4. **Connection test fails**
   - Verify your network connection
   - Check if the VPN host is reachable
   - Ensure the public configuration file is readable

### Debug Logs

To view VPN logs:
```bash
journalctl -u openfortivpn@vpn -f
```

## Contributing

1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- OpenFortiVPN project
- GTK and AppIndicator developers
- System tray integration based on GTK3 standards
