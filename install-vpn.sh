#!/bin/bash

# Check if running with sudo/root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo"
    exit 1
fi

# Function to urlencode strings
urlencode() {
    local string="$1"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * )               printf -v o '%%%02x' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# Check arguments
if [ "$#" -lt 3 ] || [ "$#" -gt 5 ]; then
    echo "Usage: $0 <username> <password> <host> [--otp] [--port PORT]"
    echo "Example: $0 user pass vpn.example.com --otp --port 10443"
    exit 1
fi

# Store credentials with proper escaping
USERNAME=$(urlencode "$1")
PASSWORD=$(urlencode "$2")
HOST=$(urlencode "$3")
OTP_ENABLED=false
PORT=443  # Default port

# Parse optional arguments
shift 3
while [ "$#" -gt 0 ]; do
    case "$1" in
        --otp)
            OTP_ENABLED=true
            ;;
        --port)
            if [ -n "$2" ] && [ "$2" -eq "$2" ] 2>/dev/null; then
                PORT="$2"
                shift
            else
                echo "Error: --port requires a numeric value"
                exit 1
            fi
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

# Decode the credentials for the config file
USERNAME=$(printf '%b' "${USERNAME//%/\\x}")
PASSWORD=$(printf '%b' "${PASSWORD//%/\\x}")
HOST=$(printf '%b' "${HOST//%/\\x}")
TRUSTEDCERT=$(openssl s_client -connect ${HOST}:${PORT} -servername ${HOST} < /dev/null 2>/dev/null | openssl x509 -fingerprint -sha256 -noout | sed 's/://g' | awk -F= '{print tolower($2)}')

# Install required packages
echo "Installing required packages..."
apt-get update
apt-get install -y openfortivpn python3-gi gir1.2-appindicator3-0.1 python3-pip

# Create necessary directories
mkdir -p /etc/openfortivpn
mkdir -p /usr/local/bin
mkdir -p /etc/systemd/system

# Create OpenFortiVPN configuration using printf to handle special characters
if [ "$OTP_ENABLED" = true ]; then
    printf "host = %s\nport = 443\nusername = %s\npassword = %s\ntrusted-cert = %s\notp = 1\n" \
        "$HOST" "$USERNAME" "$PASSWORD" "$TRUSTEDCERT" > /etc/openfortivpn/vpn.conf
else
    printf "host = %s\nport = 443\nusername = %s\npassword = %s\ntrusted-cert = %s\n" \
        "$HOST" "$USERNAME" "$PASSWORD" "$TRUSTEDCERT" > /etc/openfortivpn/vpn.conf
fi

# Set proper permissions for the config file
chmod 600 /etc/openfortivpn/vpn.conf

# Create a public file with just the host and OTP info
mkdir -p /var/lib/openfortivpn
if [ "$OTP_ENABLED" = true ]; then
    printf "host = %s\notp = 1\n" "$HOST" > /var/lib/openfortivpn/config.public
else
    printf "host = %s\notp = 0\n" "$HOST" > /var/lib/openfortivpn/config.public
fi
chmod 644 /var/lib/openfortivpn/config.public

# Install systemd service
cat > /etc/systemd/system/openfortivpn@.service << EOF
[Unit]
Description=OpenFortiVPN for %I
After=network-online.target
Documentation=man:openfortivpn(1)

[Service]
Type=simple
PrivateTmp=true
ExecStart=/usr/bin/openfortivpn -c /etc/openfortivpn/%I.conf
OOMScoreAdjust=-100
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Install the systemd applet
cat > /usr/local/bin/systemd-applet.py << 'EOF'
#!/usr/bin/env python3
import gi
gi.require_version('Gtk', '3.0')
gi.require_version('AppIndicator3', '0.1')
from gi.repository import Gtk, AppIndicator3, GLib
import subprocess
import os
import logging
import tempfile
from datetime import datetime

# Set up logging
log_file = os.path.join(tempfile.gettempdir(), 'openfortivpn-applet.log')
logging.basicConfig(
    filename=log_file,
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

class OTPDialog(Gtk.Dialog):
    def __init__(self, parent=None):
        super().__init__(
            title="Enter OTP",
            parent=parent,
            flags=0
        )
        self.add_buttons(
            Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
            Gtk.STOCK_OK, Gtk.ResponseType.OK
        )

        self.set_default_size(150, 100)

        label = Gtk.Label(label="Enter your One-Time Password:")
        self.entry = Gtk.Entry()
        self.entry.set_visibility(True)
        
        box = self.get_content_area()
        box.add(label)
        box.add(self.entry)
        self.show_all()

    def get_otp(self):
        return self.entry.get_text()

class FortiVPNApplet:
    def __init__(self, service_name):
        self.service_name = service_name
        logging.info("Initializing FortiVPN Applet")
        
        # Read public config file
        try:
            with open('/var/lib/openfortivpn/config.public', 'r') as f:
                config = {}
                for line in f:
                    line = line.strip()
                    if '=' in line:
                        key, value = [x.strip() for x in line.split('=', 1)]
                        config[key] = value
                self.vpn_host = config.get('host', 'Unknown Host')
                self.vpn_port = config.get('port', '443')
                self.otp_required = config.get('otp', '0') == '1'
        except Exception as e:
            logging.error(f"Error reading config: {e}")
            self.vpn_host = 'Unknown Host'
            self.vpn_port = '443'
            self.otp_required = False
        
        # Create indicator
        self.indicator = AppIndicator3.Indicator.new(
            f"fortivpn-{service_name}",
            "network-vpn-symbolic",
            AppIndicator3.IndicatorCategory.APPLICATION_STATUS
        )
        self.indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
        
        self.menu = Gtk.Menu()
        self.create_menu()
        self.indicator.set_menu(self.menu)
        
        self.vpn_ip = "Not Connected"
        GLib.timeout_add_seconds(2, self.update_status)
    
    def start_service_with_otp(self, _):
        logging.info("Attempting to start VPN service")
        if self.otp_required:
            logging.info("OTP required, showing dialog")
            dialog = OTPDialog()
            response = dialog.run()
            
            if response == Gtk.ResponseType.OK:
                otp = dialog.get_otp()
                dialog.destroy()
                
                try:
                    env = os.environ.copy()
                    env['VPN_OTP'] = otp
                    subprocess.run(['pkexec', 'systemctl', 'start', self.service_name],
                                 env=env, check=True)
                except subprocess.CalledProcessError as e:
                    error_dialog = Gtk.MessageDialog(
                        transient_for=None,
                        flags=0,
                        message_type=Gtk.MessageType.ERROR,
                        buttons=Gtk.ButtonsType.OK,
                        text="Failed to start VPN"
                    )
                    error_dialog.format_secondary_text(str(e))
                    error_dialog.run()
                    error_dialog.destroy()
            else:
                dialog.destroy()
        else:
            self.start_service(_)

    def create_menu(self):
        # Status items
        self.status_item = Gtk.MenuItem(label="VPN Status: Checking...")
        self.status_item.set_sensitive(False)
        self.menu.append(self.status_item)
        
        self.ip_item = Gtk.MenuItem(label="VPN IP: Not Connected")
        self.ip_item.set_sensitive(False)
        self.menu.append(self.ip_item)
        
        self.menu.append(Gtk.SeparatorMenuItem())
        
        # Connection controls
        connect_item = Gtk.MenuItem(label="Connect VPN" + (" (OTP Required)" if self.otp_required else ""))
        connect_item.connect("activate", self.start_service_with_otp)
        self.menu.append(connect_item)
        
        disconnect_item = Gtk.MenuItem(label="Disconnect VPN")
        disconnect_item.connect("activate", self.stop_service)
        self.menu.append(disconnect_item)
        
        reconnect_item = Gtk.MenuItem(label="Reconnect VPN")
        reconnect_item.connect("activate", self.restart_service)
        self.menu.append(reconnect_item)
        
        self.menu.append(Gtk.SeparatorMenuItem())
        
        vpn_logs_item = Gtk.MenuItem(label="View VPN Service Logs")
        vpn_logs_item.connect("activate", self.view_vpn_logs)
        self.menu.append(vpn_logs_item)
        
        app_logs_item = Gtk.MenuItem(label="View Applet Logs")
        app_logs_item.connect("activate", self.view_app_logs)
        self.menu.append(app_logs_item)
        
        ping_item = Gtk.MenuItem(label="Test Connection")
        ping_item.connect("activate", self.test_connection)
        self.menu.append(ping_item)
        
        self.menu.append(Gtk.SeparatorMenuItem())
        
        quit_item = Gtk.MenuItem(label="Quit")
        quit_item.connect("activate", self.quit)
        self.menu.append(quit_item)
        
        self.menu.show_all()
    
    def run_systemctl(self, command):
        try:
            subprocess.run(['pkexec', 'systemctl', command, self.service_name], 
                         check=True)
            return True
        except subprocess.CalledProcessError:
            return False
    
    def get_service_status(self):
        try:
            result = subprocess.run(['systemctl', 'is-active', self.service_name],
                                  capture_output=True, text=True)
            return result.stdout.strip()
        except subprocess.CalledProcessError:
            return "unknown"
    
    def get_vpn_ip(self):
        try:
            # Check for ppp0 first (common for openfortivpn)
            interfaces = ["ppp0", "tun0", "vpn0"]
            
            for interface in interfaces:
                result = subprocess.run(
                    ["ip", "addr", "show", interface],
                    capture_output=True,
                    text=True,
                    check=False  # Don't raise exception on non-zero exit
                )
                if result.returncode == 0:
                    for line in result.stdout.split("\n"):
                        if "inet " in line:
                            # Extract IP address
                            ip = line.strip().split()[1].split("/")[0]
                            return ip
            return "Not Connected"
        except Exception as e:
            logging.error(f"Error getting VPN IP: {e}")
            return "Not Connected"
            
    def get_service_status(self):
        try:
            # Check systemd service status
            result = subprocess.run(
                ["systemctl", "is-active", self.service_name],
                capture_output=True,
                text=True,
                check=False
            )
            service_status = result.stdout.strip()
            
            # Check if the VPN interface exists and has an IP
            vpn_ip = self.get_vpn_ip()
            
            if service_status == "active" and vpn_ip != "Not Connected":
                return "active"
            elif service_status == "active":
                return "connecting"
            else:
                return "inactive"
                
        except Exception as e:
            print(f"Error getting service status: {e}")
            return "unknown"
    
    def test_connection(self, _):
        def run_test():
            try:
                # Try to establish a TCP connection to the VPN gateway
                logging.info(f"Testing connection to {self.vpn_host}:{self.vpn_port}")
                result = subprocess.run(
                    ["nc", "-zv", "-w", "5", self.vpn_host, self.vpn_port],
                    capture_output=True,
                    text=True
                )

                dialog = Gtk.MessageDialog(
                    transient_for=None,
                    flags=0,
                    message_type=Gtk.MessageType.INFO,
                    buttons=Gtk.ButtonsType.OK,
                    text="Connection Test Results"
                )

                if result.returncode == 0:
                    dialog.format_secondary_text(
                        f"Successfully connected to VPN gateway\nHost: {self.vpn_host}\nPort: {self.vpn_port}"
                    )
                    logging.info("Connection test successful")
                else:
                    dialog.format_secondary_text(
                        f"Could not reach VPN gateway at {self.vpn_host}:{self.vpn_port}\n" +
                        "Please check your connection."
                    )
                    logging.warning("Connection test failed")

                dialog.run()
                dialog.destroy()

            except Exception as e:
                logging.error(f"Error during connection test: {e}")
                error_dialog = Gtk.MessageDialog(
                    transient_for=None,
                    flags=0,
                    message_type=Gtk.MessageType.ERROR,
                    buttons=Gtk.ButtonsType.OK,
                    text="Error Testing Connection"
                )
                error_dialog.format_secondary_text(str(e))
                error_dialog.run()
                error_dialog.destroy()
        
        # Run the test in a separate thread to avoid blocking the UI
        from threading import Thread
        Thread(target=run_test, daemon=True).start()
    
    def update_status(self):
        try:
            status = self.get_service_status()
            vpn_ip = self.get_vpn_ip()
            logging.debug(f"Status update - Status: {status}, IP: {vpn_ip}")
            
            # Update status label with more user-friendly text
            if status == "active":
                status_text = "Connected"
                icon_name = "network-vpn-symbolic"
            elif status == "connecting":
                status_text = "Connecting..."
                icon_name = "network-vpn-acquiring-symbolic"
            else:
                status_text = "Disconnected"
                icon_name = "network-vpn-offline-symbolic"
            
            # Set the icon - fallback to system-run-symbolic if VPN icons aren't available
            try:
                self.indicator.set_icon(icon_name)
            except:
                self.indicator.set_icon("system-run-symbolic")
            
            self.status_item.set_label(f"VPN Status: {status_text}")
            self.ip_item.set_label(f"VPN IP: {vpn_ip}")
            
        except Exception as e:
            print(f"Error updating status: {e}")
            self.status_item.set_label("VPN Status: Error")
            self.ip_item.set_label("VPN IP: Unknown")
            self.indicator.set_icon("dialog-error-symbolic")
            
        return True  # Continue updating
    
    def start_service(self, _):
        self.run_systemctl('start')
        self.update_status()
    
    def stop_service(self, _):
        self.run_systemctl('stop')
        self.update_status()
    
    def restart_service(self, _):
        self.run_systemctl('restart')
        self.update_status()
    
    def view_vpn_logs(self, _):
        logging.info("Opening VPN service logs")
        subprocess.Popen(['gnome-terminal', '--', 'journalctl', '-u', 
                         self.service_name, '-f'])

    def view_app_logs(self, _):
        logging.info("Opening applet logs")
        subprocess.Popen(['gnome-terminal', '--', 'tail', '-f', log_file])
    
    def quit(self, _):
        Gtk.main_quit()

def main():
    import argparse
    parser = argparse.ArgumentParser(description='FortiVPN Tray Applet')
    parser.add_argument('service_name', help='Name of the OpenFortiVPN service to monitor')
    args = parser.parse_args()
    
    applet = FortiVPNApplet(args.service_name)
    Gtk.main()

if __name__ == "__main__":
    main()
EOF
EOF

# Make the applet executable
chmod +x /usr/local/bin/systemd-applet.py

# Create system-wide desktop entry
mkdir -p /usr/share/applications

# Create the desktop entry
cat > /usr/share/applications/openfortivpn-applet.desktop << EOF
[Desktop Entry]
Type=Application
Name=OpenFortiVPN Applet
Exec=/usr/local/bin/systemd-applet.py openfortivpn@vpn
Icon=network-vpn
Categories=Network;
X-GNOME-Autostart-enabled=true
EOF

# Reload systemd
systemctl daemon-reload

# Enable the service
systemctl enable openfortivpn@vpn.service

echo "Installation completed successfully!"
echo "To start it now, run: /usr/local/bin/systemd-applet.py openfortivpn@vpn"
