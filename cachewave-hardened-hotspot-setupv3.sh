#!/bin/bash
#
# cachewave-hardened-hotspot-setup.sh
#
# Builds the isolated CacheWave Chromebook hotspot on a device that is
# ALREADY connected to the internet (facility Wi-Fi or ethernet).
# This script does NOT configure the uplink itself, and does NOT install
# CacheWave — both are handled separately.
#
# Setup type is detected automatically on every run:
#   A: ethernet uplink, onboard Wi-Fi chip is the hotspot (no USB adapter plugged in)
#   B: facility Wi-Fi uplink on the onboard chip, USB adapter is the hotspot
#   C: ethernet uplink, USB adapter is the hotspot, onboard chip turned off
# To change setup type, change the hardware (plug/unplug ethernet or the adapter) and re-run.
#
# Safe to re-run: cleans up and rebuilds its own prior configuration.

set -Eeuo pipefail

# ---------- Output helpers ----------
WARNINGS=0
CURRENT_STEP="Starting up"
# Set once the hotspot profile exists; if setup then fails, the hotspot is turned off
HOTSPOT_LIVE=false
hotspot_off_on_failure() {
  if [ "$HOTSPOT_LIVE" = true ]; then
    nmcli connection modify cachewave-ap connection.autoconnect no &>/dev/null || true
    nmcli connection down cachewave-ap &>/dev/null || true
    echo "       The hotspot has been turned off because setup didn't finish."
  fi
}
print_info() { echo "  -> $1"; }
print_note() { echo "NOTE - $1"; }
print_ok()   { echo "OK  - $1"; }
print_fail() { echo "FAIL - $1"; WARNINGS=$((WARNINGS + 1)); }
die()        { echo "FAIL - $1"; hotspot_off_on_failure; exit 1; }
step()       { CURRENT_STEP="$1"; echo "$1"; }

# If any command fails unexpectedly, say where instead of stopping silently
on_error() {
  echo
  echo "FAIL - Setup stopped unexpectedly during: ${CURRENT_STEP} (script line $1)."
  echo "       Nothing after this point was applied. Fix the issue above, then re-run the script."
  hotspot_off_on_failure
}
trap 'on_error $LINENO' ERR

# ---------- Must run as root ----------
if [ "$(id -u)" -ne 0 ]; then
  die "This script must be run with sudo/root."
fi

# ---------- Shared locations ----------
REQUIRED_PACKAGES="dnsmasq iptables iptables-persistent"
STATE_DIR="/var/lib/cachewave"
CONFIG_FILE="$STATE_DIR/hotspot.conf"
COMPLETE_MARKER="$STATE_DIR/setup-complete"
ICON_PATH_FILE="$STATE_DIR/icon-path"
INSTALLED_SCRIPT="/usr/local/sbin/cachewave-setup"
LAUNCHER="/usr/local/bin/cachewave-launcher"
POSTBOOT_LOG="/var/log/cachewave-postboot-check.log"
# A USB hotspot adapter gets this permanent name, tied to its hardware address, so the
# hotspot, DHCP and firewall settings keep matching it after a reboot or re-plug
HOTSPOT_NAME="cwhotspot"
NAME_RULE="/etc/udev/rules.d/70-cachewave-hotspot.rules"
# Setup C: tells NetworkManager to leave the unused onboard Wi-Fi chip off
ONBOARD_OFF_CONF="/etc/NetworkManager/conf.d/90-cachewave-onboard-off.conf"

# Remote access this device must never offer: SSH, VNC, xrdp and Raspberry Pi Connect.
# Setup turns these off and locks them (masks them), including ones not installed yet.
REMOTE_SYSTEM_UNITS="ssh.service ssh.socket wayvnc.service wayvnc-control.service vncserver-x11-serviced.service vncserver-virtuald.service xrdp.service xrdp-sesman.service"
REMOTE_USER_UNITS="rpi-connect.service rpi-connect-wayvnc.service rpi-connect-wayvnc-watcher.path"
REMOTE_PORTS="22 3389 5900"

# Prints one line per remote-access problem; prints nothing when everything is locked off
remote_access_problems() {
  local U P
  for U in $REMOTE_SYSTEM_UNITS; do
    [ "$(systemctl is-enabled "$U" 2>/dev/null || true)" = "masked" ] || echo "$U is not locked off"
    systemctl is-active --quiet "$U" 2>/dev/null && echo "$U is running"
  done
  for U in $REMOTE_USER_UNITS; do
    [ "$(readlink "/etc/systemd/user/$U" 2>/dev/null || true)" = "/dev/null" ] || echo "$U is not locked off for all users"
  done
  for P in $REMOTE_PORTS; do
    ss -Htln "( sport = :$P )" 2>/dev/null | grep -q . && echo "something is listening on port $P"
  done
  pgrep -f rpi-connect &>/dev/null && echo "Raspberry Pi Connect is running"
  return 0
}

# The hotspot's actual Wi-Fi security, read from the running Wi-Fi software
# (falls back to the saved setting if the live value can't be read)
wifi_security_mode() {
  local IFPATH="" NETPATH="" KM="" PMF=""
  IFPATH=$(busctl call fi.w1.wpa_supplicant1 /fi/w1/wpa_supplicant1 fi.w1.wpa_supplicant1 GetInterface s "$1" 2>/dev/null | awk '{gsub(/"/, "", $2); print $2}' || true)
  if [ -n "$IFPATH" ]; then
    NETPATH=$(busctl get-property fi.w1.wpa_supplicant1 "$IFPATH" fi.w1.wpa_supplicant1.Interface CurrentNetwork 2>/dev/null | awk '{gsub(/"/, "", $2); print $2}' || true)
  fi
  if [ -n "$NETPATH" ] && [ "$NETPATH" != "/" ]; then
    KM=$(busctl get-property fi.w1.wpa_supplicant1 "$NETPATH" fi.w1.wpa_supplicant1.Network Properties 2>/dev/null | grep -o '"key_mgmt" s "[^"]*"' | sed 's/^"key_mgmt" s "//; s/"$//' || true)
  fi
  KM=" $KM "
  if [[ "$KM" == *" SAE "* && "$KM" == *" WPA-PSK "* ]]; then echo "WPA2/WPA3 (transition mode)"
  elif [[ "$KM" == *" SAE "* ]]; then echo "WPA3 only"
  elif [[ "$KM" == *" WPA-PSK "* ]]; then echo "WPA2 only"
  else
    PMF=$(nmcli -g 802-11-wireless-security.pmf connection show cachewave-ap 2>/dev/null || true)
    case "$PMF" in
      disable|1) echo "WPA2 only (saved setting — live value couldn't be read)" ;;
      "")        echo "unknown" ;;
      *)         echo "WPA2/WPA3 (saved setting — live value couldn't be read)" ;;
    esac
  fi
}

# The state folder holds files that administrator-level code reads, so only an administrator may change it
secure_state_dir() {
  mkdir -p "$STATE_DIR"
  chown root:root "$STATE_DIR"
  chmod 755 "$STATE_DIR"
}

# Relabel the desktop icon (if one was added by --prepare). Done with the icon owner's own
# permissions, never as administrator, so this can't be used to edit any other file.
set_icon_label() {
  local ICON_FILE OWNER
  ICON_FILE=$(cat "$ICON_PATH_FILE" 2>/dev/null) || return 0
  [ -n "$ICON_FILE" ] && [ -f "$ICON_FILE" ] && [ ! -L "$ICON_FILE" ] || return 0
  OWNER=$(stat -c %U "$ICON_FILE")
  if [ "$1" = "status" ]; then
    runuser -u "$OWNER" -- sed -i 's/^Name=.*/Name=CacheWave hotspot status/; s/^Comment=.*/Comment=Shows whether the CacheWave hotspot is set up correctly/' "$ICON_FILE" 2>/dev/null || true
  else
    runuser -u "$OWNER" -- sed -i 's/^Name=.*/Name=Set up CacheWave hotspot/; s/^Comment=.*/Comment=Builds the isolated CacheWave hotspot for Chromebooks/' "$ICON_FILE" 2>/dev/null || true
  fi
}

packages_installed() {
  local PKG
  for PKG in $REQUIRED_PACKAGES; do
    dpkg-query -W -f='${Status}' "$PKG" 2>/dev/null | grep -q "install ok installed" || return 1
  done
  return 0
}

# ---------- Mode: --prepare (run once during assembly, on a known-good network) ----------
# Usage: sudo bash cachewave-hardened-hotspot-setup.sh --prepare
if [ "${1:-}" = "--prepare" ] || [ "${1:-}" = "--install-icon" ]; then
  trap - ERR
  DESKTOP_USER="${SUDO_USER:-}"
  [ -n "$DESKTOP_USER" ] || die "Run this with sudo from the desktop user's account (not as root directly), so the icon goes on that user's desktop."
  echo "=== CacheWave Device Preparation ==="
  echo

  echo "Installing required software..."
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
  apt-get -o DPkg::Lock::Timeout=120 update -qq &>/dev/null || die "Couldn't reach the software repositories. Check this network's internet connection, then re-run."
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y $REQUIRED_PACKAGES &>/dev/null || true
  packages_installed || die "Couldn't install the required software. Check this network's internet connection, then re-run."
  # dnsmasq starts itself on install with default settings — keep it off until setup configures it
  systemctl stop dnsmasq &>/dev/null || true
  systemctl disable dnsmasq &>/dev/null || true
  print_ok "Required software installed (dnsmasq left off until setup)."

  # Root-owned copy, so the icon always runs a version that can't be edited without administrator access
  install -m 755 -o root -g root "$0" "$INSTALLED_SCRIPT"
  secure_state_dir
  print_ok "Setup script stored at $INSTALLED_SCRIPT."

  # The icon's helper: runs setup before a successful install, and the status screen after
  cat > "$LAUNCHER" <<EOF
#!/bin/bash
echo "This needs administrator access."
echo "Enter this device's login password when asked (it stays hidden as you type — that's normal)."
echo
if [ -f "$COMPLETE_MARKER" ]; then
  sudo "$INSTALLED_SCRIPT" --status
else
  sudo "$INSTALLED_SCRIPT"
fi
echo
read -rp "Press Enter to close this window."
EOF
  chmod 755 "$LAUNCHER"

  USER_HOME=$(getent passwd "$DESKTOP_USER" | cut -d: -f6)
  DESKTOP_DIR=$(sudo -u "$DESKTOP_USER" xdg-user-dir DESKTOP 2>/dev/null || echo "$USER_HOME/Desktop")
  mkdir -p "$DESKTOP_DIR"
  ICON_FILE="$DESKTOP_DIR/cachewave.desktop"
  rm -f "$DESKTOP_DIR/cachewave-setup.desktop"
  cat > "$ICON_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Set up CacheWave hotspot
Comment=Builds the isolated CacheWave hotspot for Chromebooks
Icon=network-wireless
Terminal=false
Exec=lxterminal --title=CacheWave -e $LAUNCHER
EOF
  chown "$DESKTOP_USER" "$DESKTOP_DIR" "$ICON_FILE"
  chmod 755 "$ICON_FILE"
  echo "$ICON_FILE" > "$ICON_PATH_FILE"
  if [ -f "$COMPLETE_MARKER" ]; then
    # Already set up successfully — keep the icon on the status screen
    set_icon_label status
    print_ok "Desktop icon added: \"CacheWave hotspot status\" (this device is already set up)."
  else
    print_ok "Desktop icon added: \"Set up CacheWave hotspot\"."
  fi
  echo
  echo "Preparation complete. On site: connect this device to the facility's internet, then double-click the icon."
  echo "Re-run --prepare whenever the script is updated."
  exit 0
fi

# ---------- Mode: --status (read-only; what the icon shows after a successful setup) ----------
if [ "${1:-}" = "--status" ]; then
  trap - ERR
  set +e
  [ -f "$CONFIG_FILE" ] || die "Setup hasn't been completed on this device yet."
  # Read the saved configuration as plain values only — never run it as code
  SETUP="" UPLINK_IFACE="" HOTSPOT_IFACE="" ONBOARD_IFACE="" HOTSPOT_PREFIX="" CACHEWAVE_PORT=""
  while IFS='=' read -r KEY VALUE; do
    VALUE="${VALUE%\"}"; VALUE="${VALUE#\"}"
    [[ "$VALUE" =~ ^[A-Za-z0-9._-]*$ ]] || die "The saved configuration file looks damaged ($CONFIG_FILE). Re-run setup."
    case "$KEY" in
      SETUP) SETUP="$VALUE" ;;
      UPLINK_IFACE) UPLINK_IFACE="$VALUE" ;;
      HOTSPOT_IFACE) HOTSPOT_IFACE="$VALUE" ;;
      ONBOARD_IFACE) ONBOARD_IFACE="$VALUE" ;;
      HOTSPOT_PREFIX) HOTSPOT_PREFIX="$VALUE" ;;
      CACHEWAVE_PORT) CACHEWAVE_PORT="$VALUE" ;;
    esac
  done < "$CONFIG_FILE"
  FAILS=0
  ok()  { echo "OK   - $1"; }
  bad() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }
  mac_of() { cat "/sys/class/net/$1/address" 2>/dev/null || echo "not present"; }

  echo "=== CacheWave Hotspot Status — $(date) ==="
  echo
  SSID=$(nmcli -g 802-11-wireless.ssid connection show cachewave-ap 2>/dev/null)
  CLIENTS=$(iw dev "$HOTSPOT_IFACE" station dump 2>/dev/null | grep -c '^Station' || true)
  echo "Hotspot name:       ${SSID:-unknown}"
  echo "CacheWave address:  http://$HOTSPOT_PREFIX.1:$CACHEWAVE_PORT"
  echo "Devices connected:  $CLIENTS"
  echo "Setup type:         $SETUP (internet: $UPLINK_IFACE, hotspot: $HOTSPOT_IFACE)"
  echo "Hotspot security:   $(wifi_security_mode "$HOTSPOT_IFACE")"
  echo

  if [ "$SETUP" = "B" ] || [ "$SETUP" = "C" ]; then
    if [ -e "/sys/class/net/$HOTSPOT_IFACE" ]; then ok "USB hotspot adapter is plugged in ($HOTSPOT_IFACE)"; else bad "USB hotspot adapter is missing — plug it back in, wait a minute, then check this screen again"; fi
  fi
  if [ "$SETUP" = "C" ]; then
    ONBOARD_STATE=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: -v d="$ONBOARD_IFACE" '$1 == d {print $2}')
    if [ "$ONBOARD_STATE" = "unmanaged" ]; then ok "Onboard Wi-Fi is off (not used in this setup)"; else bad "Onboard Wi-Fi ($ONBOARD_IFACE) is not off"; fi
  fi
  if [ "$(nmcli -g GENERAL.STATE connection show cachewave-ap 2>/dev/null)" = "activated" ]; then ok "Hotspot is on"; else bad "Hotspot is not on"; fi
  UPLINK_STATE=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: -v d="$UPLINK_IFACE" '$1 == d {print $2}')
  if [ "$UPLINK_STATE" = "connected" ]; then ok "Internet connection is up"; else bad "Internet connection ($UPLINK_IFACE) is down"; fi
  if systemctl is-active --quiet dnsmasq; then ok "dnsmasq is running"; else bad "dnsmasq is not running"; fi
  EXTRA_ROUTES=$(ip route show dev "$HOTSPOT_IFACE" 2>/dev/null | awk -v n="$HOTSPOT_PREFIX.0/24" '$1 != n')
  if [ -z "$EXTRA_ROUTES" ]; then ok "No gateway route on the hotspot"; else bad "Unexpected route on the hotspot: $EXTRA_ROUTES"; fi
  for CHAIN in INPUT FORWARD; do
    if [ "$(iptables -S "$CHAIN" | head -1)" = "-P $CHAIN DROP" ]; then ok "IPv4 $CHAIN policy is DROP"; else bad "IPv4 $CHAIN policy is not DROP"; fi
    if [ "$(ip6tables -S "$CHAIN" | head -1)" = "-P $CHAIN DROP" ]; then ok "IPv6 $CHAIN policy is DROP"; else bad "IPv6 $CHAIN policy is not DROP"; fi
  done
  if iptables -C INPUT -i "$HOTSPOT_IFACE" -p tcp --dport "$CACHEWAVE_PORT" -j ACCEPT 2>/dev/null; then ok "CacheWave port rule is in place"; else bad "CacheWave port rule is missing"; fi
  if iptables -C FORWARD -i "$HOTSPOT_IFACE" -o "$UPLINK_IFACE" -j DROP 2>/dev/null; then ok "Hotspot-to-internet block is in place"; else bad "Hotspot-to-internet block is missing"; fi
  if [ "$(sysctl -n net.ipv4.ip_forward)" = "0" ]; then ok "IPv4 forwarding is off"; else bad "IPv4 forwarding is ON"; fi
  if [ "$(sysctl -n net.ipv6.conf.all.forwarding)" = "0" ]; then ok "IPv6 forwarding is off"; else bad "IPv6 forwarding is ON"; fi
  if [ -z "$(ip -6 addr show dev "$HOTSPOT_IFACE" 2>/dev/null)$(ip -6 addr show dev "$UPLINK_IFACE" 2>/dev/null)" ]; then ok "No IPv6 addresses on the radios"; else bad "A radio has an IPv6 address"; fi
  if [ -x /etc/NetworkManager/dispatcher.d/99-disable-forwarding ]; then ok "Self-healing script is in place"; else bad "Self-healing script is missing"; fi
  if ! systemctl is-active --quiet rpcbind && ! systemctl is-active --quiet avahi-daemon; then ok "rpcbind and avahi are off"; else bad "rpcbind or avahi is running"; fi
  REMOTE_PROBLEMS=$(remote_access_problems)
  if [ -z "$REMOTE_PROBLEMS" ]; then ok "Remote access is locked off (SSH, VNC, xrdp, Raspberry Pi Connect)"; else bad "Remote access is not fully locked off: $(echo "$REMOTE_PROBLEMS" | paste -sd ';' - | sed 's/;/; /g')"; fi
  if ss -tln 2>/dev/null | grep -q ":$CACHEWAVE_PORT "; then
    ok "CacheWave is running on port $CACHEWAVE_PORT"
  else
    echo "NOTE - Nothing is listening on port $CACHEWAVE_PORT — CacheWave may not be installed or running yet."
  fi

  echo
  if [ "$FAILS" -eq 0 ]; then echo "RESULT: everything looks correct."; else echo "RESULT: $FAILS item(s) need attention — contact IEI."; fi
  echo
  echo "Hardware (MAC) addresses:"
  printf '  %-32s %s\n' "Ethernet (eth0):" "$(mac_of eth0)"
  printf '  %-32s %s\n' "Onboard Wi-Fi ($ONBOARD_IFACE):" "$(mac_of "$ONBOARD_IFACE")"
  if [ "$SETUP" = "B" ] || [ "$SETUP" = "C" ]; then
    printf '  %-32s %s\n' "USB Wi-Fi adapter ($HOTSPOT_IFACE):" "$(mac_of "$HOTSPOT_IFACE")"
  fi
  echo
  LAST=$(grep '^RESULT' "$POSTBOOT_LOG" 2>/dev/null)
  echo "Last post-reboot check: ${LAST:-not found}"
  echo
  echo "To run setup again (this rebuilds the hotspot): sudo $INSTALLED_SCRIPT"
  exit 0
fi

echo "=== CacheWave Hotspot Setup ==="
echo
secure_state_dir
rm -f "$COMPLETE_MARKER"
set_icon_label setup

# ----------
step "Step 1: Checking for an existing internet connection..."
if ping -c 2 -W 3 8.8.8.8 &>/dev/null; then
  print_ok "Internet connection confirmed."
else
  print_note "Ping to 8.8.8.8 failed. Some networks block ping, so setup will continue. Step 2 will confirm internet access."
fi
echo

# ----------
step "Step 2: Installing required software..."
if packages_installed; then
  print_ok "Required software is already installed (device was prepared) — skipping downloads."
  systemctl stop dnsmasq &>/dev/null || true
  systemctl disable dnsmasq &>/dev/null || true
else
  # Pre-answer iptables-persistent's install questions so it doesn't wait for input
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
  print_info "This can take a few minutes, especially right after a fresh install."

  # A wrong clock makes software downloads and secure websites fail, so check it first.
  # Some facilities block internet time sync; give it up to 30 seconds to catch up.
  CLOCK_SYNCED=false
  for _ in $(seq 1 30); do
    if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ]; then
      CLOCK_SYNCED=true
      break
    fi
    sleep 1
  done
  if [ "$CLOCK_SYNCED" = true ]; then
    print_ok "System clock is synced: $(date)"
  else
    print_note "System clock hasn't synced with internet time — it reads: $(date). If that's wrong, the facility may block time sync, and downloads below will fail."
  fi

  if ! apt-get -o DPkg::Lock::Timeout=120 update -qq &>/dev/null; then
    echo "FAIL - Couldn't reach the software repositories. Nothing has been changed. Possible causes:"
    echo "       - No internet connection."
    echo "       - A sign-in page on the network that needs accepting in the web browser first."
    echo "       - A facility content filter or proxy blocking software downloads (ask the facility)."
    echo "       - A wrong system clock. It currently reads: $(date)"
    echo "         If that's wrong, set it (example): sudo date -s '2026-10-09 14:30'"
    echo "       Fix the cause, then re-run the script."
    exit 1
  fi
  # shellcheck disable=SC2086
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y $REQUIRED_PACKAGES &>/dev/null || true
  packages_installed || die "Couldn't install the required software ($REQUIRED_PACKAGES). Check the internet connection (or wait for any system update to finish), then re-run. Nothing has been changed."
  # dnsmasq starts itself on install with default settings — stop it until it's configured
  systemctl stop dnsmasq &>/dev/null || true
  systemctl disable dnsmasq &>/dev/null || true
  print_ok "Required software installed — internet access confirmed."
fi
echo

# ---------- Step: Wi-Fi on, country set permanently ----------
step "Step 3: Turning Wi-Fi on and setting the Wi-Fi country to US..."
# On a fresh install Wi-Fi stays switched off until a country is set
if command -v raspi-config &>/dev/null; then
  raspi-config nonint do_wifi_country US &>/dev/null || true
fi
iw reg set US &>/dev/null || true
rfkill unblock wifi &>/dev/null || true
nmcli radio wifi on &>/dev/null || true
sleep 3
print_ok "Wi-Fi is on and set to US (some USB adapters manage their country setting independently — not a blocking issue)."
echo

# ----------
step "Step 4: Detecting setup type..."

# Identify the onboard Wi-Fi chip by how it's connected: the onboard chip is wired
# internally, while any adapter is plugged in over USB. Names like wlan0/wlan1 depend
# on which radio the system happened to detect first, so they can't be trusted here.
ONBOARD_IFACE=""
for DEV in /sys/class/net/*; do
  [ -d "$DEV/wireless" ] || continue
  if ! readlink -f "$DEV/device" 2>/dev/null | grep -q "/usb"; then
    ONBOARD_IFACE=$(basename "$DEV")
    break
  fi
done
if [ -z "$ONBOARD_IFACE" ]; then
  ONBOARD_IFACE="wlan0"
  print_note "Couldn't identify the onboard Wi-Fi chip — assuming wlan0."
else
  print_info "Onboard Wi-Fi chip is $ONBOARD_IFACE."
fi

dev_state() { nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: -v d="$1" '$1==d {print $2}'; }
dev_conn() { nmcli -e no -g GENERAL.CONNECTION device show "$1" 2>/dev/null || true; }
# A device counts as an internet connection only if it's connected to something other than
# this device's own hotspot — on a re-run, the hotspot radio also shows as "connected"
is_uplink() { [ "$(dev_state "$1")" = "connected" ] && [ "$(dev_conn "$1")" != "cachewave-ap" ]; }
# Wi-Fi devices other than the onboard chip (i.e. USB adapters)
other_wifi() { nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: -v o="$ONBOARD_IFACE" '$2=="wifi" && $1!=o {print $1}'; }

# Helpers for the USB hotspot adapter's permanent name
permanent_mac() {
  local IF="$1" MAC=""
  if command -v ethtool &>/dev/null; then
    MAC=$(ethtool -P "$IF" 2>/dev/null | awk '{print $NF}' || true)
  fi
  if [ -z "$MAC" ] || [ "$MAC" = "00:00:00:00:00:00" ]; then
    # Fall back to the current address only if the kernel reports it as the built-in one
    if [ "$(cat "/sys/class/net/$IF/addr_assign_type" 2>/dev/null || true)" = "0" ]; then
      MAC=$(cat "/sys/class/net/$IF/address" 2>/dev/null || true)
    fi
  fi
  echo "$MAC" | tr 'A-F' 'a-f'
}

# Undo the previous run's Setup C change, so this run can choose any setup type
if [ -f "$ONBOARD_OFF_CONF" ]; then
  print_info "Turning the onboard Wi-Fi chip back on (a previous Setup C turned it off)."
  rm -f "$ONBOARD_OFF_CONF"
  nmcli general reload conf &>/dev/null || true
  nmcli device set "$ONBOARD_IFACE" managed yes &>/dev/null || true
  sleep 3
fi

# If an ethernet cable is plugged in, give ethernet time to connect before deciding,
# so a Wi-Fi network that happens to connect first can't decide the setup type
if [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null || true)" = "1" ]; then
  print_info "Ethernet cable detected — waiting up to 30 seconds for it to connect..."
  for _ in $(seq 1 30); do
    is_uplink eth0 && break
    sleep 1
  done
  is_uplink eth0 || print_note "Ethernet is plugged in but didn't connect — checking for a Wi-Fi connection instead."
fi

# A connection may still be coming back after Step 3 — wait up to 30 seconds for one
UPLINK_FOUND=false
for _ in $(seq 1 30); do
  if is_uplink eth0 || is_uplink "$ONBOARD_IFACE"; then
    UPLINK_FOUND=true; break
  fi
  for W in $(other_wifi); do
    is_uplink "$W" && UPLINK_FOUND=true
  done
  [ "$UPLINK_FOUND" = true ] && break
  sleep 1
done
[ "$UPLINK_FOUND" = true ] || die "No active internet connection found on ethernet or Wi-Fi. Connect to the internet first, then re-run this script."

if is_uplink eth0; then
  UPLINK_IFACE="eth0"
  # A USB adapter can take several seconds to appear after it's plugged in
  print_info "Ethernet is the internet connection. Checking for a USB Wi-Fi adapter (up to 15 seconds)..."
  USB_ADAPTER=""
  for _ in $(seq 1 15); do
    USB_ADAPTER=$(other_wifi | head -1)
    [ -n "$USB_ADAPTER" ] && break
    sleep 1
  done

  if [ -n "$USB_ADAPTER" ]; then
    SETUP="C"
    HOTSPOT_IFACE="$USB_ADAPTER"
    print_ok "Setup C detected: ethernet uplink, USB adapter ($HOTSPOT_IFACE) will be the hotspot, onboard chip will be turned off."
    # There's no Wi-Fi uplink in this setup, so no saved Wi-Fi network should connect on its
    # own — one could otherwise take the adapter at boot before the hotspot does
    while IFS= read -r CONN; do
      { [ -z "$CONN" ] || [ "$CONN" = "cachewave-ap" ]; } && continue
      nmcli connection down "$CONN" &>/dev/null || true
      nmcli connection modify "$CONN" connection.autoconnect no &>/dev/null || true
      print_info "Saved Wi-Fi network '$CONN' set not to connect automatically."
    done < <(nmcli -t -e no -f TYPE,NAME connection show 2>/dev/null | awk '/^802-11-wireless:/ {sub(/^[^:]*:/, ""); print}')
  else
    SETUP="A"
    HOTSPOT_IFACE="$ONBOARD_IFACE"
    print_ok "Setup A detected: ethernet uplink, onboard chip ($HOTSPOT_IFACE) will be the hotspot."

    # Free up the onboard chip if it's on a Wi-Fi network from imaging
    # (skip this device's own hotspot on a re-run — it gets rebuilt later anyway)
    ONBOARD_CONN=$(dev_conn "$ONBOARD_IFACE")
    if [ -n "$ONBOARD_CONN" ] && [ "$ONBOARD_CONN" != "--" ] && [ "$ONBOARD_CONN" != "cachewave-ap" ]; then
      print_info "Disconnecting $ONBOARD_IFACE from '$ONBOARD_CONN' — not needed, ethernet is the uplink."
      nmcli connection down "$ONBOARD_CONN" &>/dev/null || true
      # Otherwise it could reconnect at boot and take the radio before the hotspot does
      nmcli connection modify "$ONBOARD_CONN" connection.autoconnect no &>/dev/null || true
    fi
  fi
else
  SETUP="B"
  UPLINK_IFACE="$ONBOARD_IFACE"

  # If the facility Wi-Fi came up on the USB adapter instead, move it to the onboard chip
  if ! is_uplink "$ONBOARD_IFACE"; then
    for W in $(other_wifi); do
      if is_uplink "$W"; then
        MOVE_CONN=$(dev_conn "$W")
        print_info "Facility Wi-Fi '$MOVE_CONN' is on the USB adapter ($W) — moving it to the onboard chip ($ONBOARD_IFACE)."
        nmcli connection modify "$MOVE_CONN" connection.interface-name "$ONBOARD_IFACE"
        if ! NM_OUT=$(nmcli connection up "$MOVE_CONN" 2>&1); then
          die "Couldn't move the Wi-Fi connection to $ONBOARD_IFACE. NetworkManager said: $NM_OUT"
        fi
        break
      fi
    done
    for _ in $(seq 1 30); do
      is_uplink "$ONBOARD_IFACE" && break
      sleep 1
    done
    is_uplink "$ONBOARD_IFACE" || die "The facility Wi-Fi didn't reconnect on the onboard chip ($ONBOARD_IFACE) within 30 seconds. Check it with 'nmcli device status', then re-run."
    print_ok "Facility Wi-Fi moved to the onboard chip."
  fi
  print_ok "Setup B detected: onboard chip ($UPLINK_IFACE) is the uplink, looking for a USB hotspot adapter..."

  HOTSPOT_IFACE=$(other_wifi | head -1)
  if [ -z "$HOTSPOT_IFACE" ]; then
    die "Setup B requires a second Wi-Fi adapter, but none was found. Plug one in and re-run."
  fi
  print_ok "Found hotspot adapter: $HOTSPOT_IFACE"
fi

# Permanent name for a USB hotspot adapter (Setups B and C); none needed in Setup A
if [ "$SETUP" = "A" ]; then
  if [ -f "$NAME_RULE" ]; then
    rm -f "$NAME_RULE"
    udevadm control --reload-rules &>/dev/null || true
    print_info "Removed the USB adapter's permanent name from a previous setup (not needed in Setup A)."
  fi
else
  HOTSPOT_MAC=$(permanent_mac "$HOTSPOT_IFACE")
  [[ "$HOTSPOT_MAC" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || die "Couldn't read the USB adapter's hardware address, so it can't be given a permanent name. Try a different USB port, then re-run."
  cat > "$NAME_RULE" <<EOF
# CacheWave: always give this USB Wi-Fi adapter the same name, so the hotspot, DHCP
# and firewall settings keep matching it after a reboot or re-plug. Written by setup.
SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="$HOTSPOT_MAC", ATTR{type}=="1", NAME="$HOTSPOT_NAME"
EOF
  udevadm control --reload-rules &>/dev/null || true
  if [ "$HOTSPOT_IFACE" != "$HOTSPOT_NAME" ]; then
    # Apply the name now as well, so the rest of setup configures the final name
    # NetworkManager lets go of the adapter during the rename, so it can't bring it back up mid-change
    nmcli device disconnect "$HOTSPOT_IFACE" &>/dev/null || true
    nmcli device set "$HOTSPOT_IFACE" managed no &>/dev/null || true
    ip link set "$HOTSPOT_IFACE" down
    ip link set "$HOTSPOT_IFACE" name "$HOTSPOT_NAME" || die "Couldn't rename the USB adapter ($HOTSPOT_IFACE) to $HOTSPOT_NAME. Reboot, then re-run."
    sleep 1
    nmcli device set "$HOTSPOT_NAME" managed yes &>/dev/null || true
    RENAMED=false
    for _ in $(seq 1 10); do
      if nmcli -t -f DEVICE device status 2>/dev/null | grep -qx "$HOTSPOT_NAME"; then RENAMED=true; break; fi
      sleep 1
    done
    [ "$RENAMED" = true ] || die "NetworkManager didn't pick up the renamed USB adapter ($HOTSPOT_NAME). Reboot, then re-run."
    print_ok "USB adapter renamed from $HOTSPOT_IFACE to $HOTSPOT_NAME — permanent, tied to its hardware address ($HOTSPOT_MAC)."
    HOTSPOT_IFACE="$HOTSPOT_NAME"
  else
    print_ok "USB adapter already has its permanent name ($HOTSPOT_NAME, hardware address $HOTSPOT_MAC)."
  fi
fi

# Setup C: turn the unused onboard chip off, so no saved network can ever connect on it
if [ "$SETUP" = "C" ]; then
  ONBOARD_MAC=$(cat "/sys/class/net/$ONBOARD_IFACE/address" 2>/dev/null || true)
  [[ "$ONBOARD_MAC" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || die "Couldn't read the onboard chip's hardware address to turn it off."
  nmcli device disconnect "$ONBOARD_IFACE" &>/dev/null || true
  cat > "$ONBOARD_OFF_CONF" <<EOF
# CacheWave Setup C: the onboard Wi-Fi chip isn't used, so NetworkManager leaves it off.
# Removed automatically whenever setup is re-run.
[keyfile]
unmanaged-devices=mac:$ONBOARD_MAC
EOF
  nmcli general reload conf &>/dev/null || true
  nmcli device set "$ONBOARD_IFACE" managed no &>/dev/null || true
  ip link set "$ONBOARD_IFACE" down &>/dev/null || true
  print_ok "Onboard Wi-Fi chip ($ONBOARD_IFACE) turned off — not used in Setup C."
fi
echo

# ----------
step "Step 5: Confirming $HOTSPOT_IFACE supports access-point mode..."
PHY=$(iw dev "$HOTSPOT_IFACE" info 2>/dev/null | awk '/wiphy/{print $2}')
if [ -z "$PHY" ]; then
  die "Could not identify the radio behind $HOTSPOT_IFACE."
fi
if ! iw phy "phy${PHY}" info 2>/dev/null | grep -A 10 "Supported interface modes" | grep -q " AP$"; then
  if [ "$SETUP" = "C" ]; then
    die "The USB adapter ($HOTSPOT_IFACE) doesn't support hotspot mode. Unplug it to use the onboard chip instead (Setup A), or use a different adapter, then re-run."
  fi
  die "$HOTSPOT_IFACE does not support AP mode. Use a different adapter."
fi
print_ok "AP mode supported."
echo

# ----------
step "Step 6: Choosing hotspot band..."
if [ "$SETUP" = "A" ] || [ "$SETUP" = "C" ]; then
  HOTSPOT_BAND="bg"
  print_ok "Setup $SETUP: hotspot set to 2.4GHz (no second radio to conflict with)."
else
  UPLINK_FREQ=$(iw dev "$UPLINK_IFACE" link 2>/dev/null | grep -oE 'freq: [0-9]+' | grep -oE '[0-9]+' || true)
  if [ -z "$UPLINK_FREQ" ]; then
    die "Could not determine the uplink's current Wi-Fi band."
  fi
  if [ "$UPLINK_FREQ" -lt 2500 ]; then
    HOTSPOT_BAND="a"
    print_ok "Uplink is on 2.4GHz — hotspot set to 5GHz to avoid interference."
  else
    HOTSPOT_BAND="bg"
    print_ok "Uplink is on 5GHz — hotspot set to 2.4GHz (the range band)."
  fi
fi
echo

# ----------
step "Step 7: Scanning for the best channel..."
# The hotspot radio can't scan while it's acting as a hotspot, so turn off any existing one first
nmcli connection down cachewave-ap &>/dev/null || true
nmcli device wifi rescan ifname "$HOTSPOT_IFACE" &>/dev/null || true
sleep 3
# Nearby networks as "channel:signal" lines (signal 0-100). A strong neighbour counts for more than
# a faint one. On 2.4GHz, channels overlap, so networks within 4 channels count partially.
SCAN=$(nmcli -t -f CHAN,SIGNAL device wifi list ifname "$HOTSPOT_IFACE" 2>/dev/null || true)
interference() {
  echo "$SCAN" | awk -F: -v c="$1" -v span="$2" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      d = $1 - c; if (d < 0) d = -d
      if (d < span) s += $2 * (span - d) / span
    }
    END { printf "%d", s }'
}
if [ "$HOTSPOT_BAND" = "bg" ]; then
  CANDIDATES="1 6 11"; SPAN=5
else
  # Non-DFS 5GHz channels; 20MHz-wide channels here don't overlap
  CANDIDATES="36 40 44 48"; SPAN=1
fi
BEST_CHANNEL=""
BEST_SCORE=0
for CH in $CANDIDATES; do
  SCORE=$(interference "$CH" "$SPAN")
  if [ -z "$BEST_CHANNEL" ] || [ "$SCORE" -lt "$BEST_SCORE" ]; then
    BEST_CHANNEL=$CH
    BEST_SCORE=$SCORE
  fi
done
HOTSPOT_CHANNEL=$BEST_CHANNEL
if [ "$HOTSPOT_BAND" = "bg" ]; then
  print_ok "Selected channel $HOTSPOT_CHANNEL (2.4GHz; least interference from nearby networks, weighted by signal strength)."
else
  print_ok "Selected channel $HOTSPOT_CHANNEL (5GHz; least interference from nearby networks, weighted by signal strength)."
fi
echo

# ----------
step "Step 8: Set the hotspot password."
while true; do
  echo "Hotspot password: 12-63 characters; letters, numbers, and standard symbols except ! \` \$ and quote marks."
  echo "It's shown as you type, and cleared from the screen once accepted."
  read -rp "Enter hotspot password:   " HOTSPOT_PSK
  read -rp "Confirm hotspot password: " HOTSPOT_PSK_CONFIRM

  if [ "$HOTSPOT_PSK" != "$HOTSPOT_PSK_CONFIRM" ]; then
    echo "Passwords didn't match — try again."
    echo
    continue
  fi
  if printf '%s' "$HOTSPOT_PSK" | LC_ALL=C grep -q '[^ -~]'; then
    echo "Password can only use standard keyboard characters (no emoji or accented letters) — try again."
    echo
    continue
  fi
  if [ "${#HOTSPOT_PSK}" -lt 12 ]; then
    echo "Password must be at least 12 characters — try again."
    echo
    continue
  fi
  if [ "${#HOTSPOT_PSK}" -gt 63 ]; then
    echo "Password can be at most 63 characters (a Wi-Fi limit) — try again."
    echo
    continue
  fi
  if [[ "$HOTSPOT_PSK" =~ [\!\`\$\'\"] ]]; then
    echo "Password contains a disallowed character (! \` \$ ' \") — try again."
    echo
    continue
  fi
  break
done
# Clear the visible password from the screen
clear
echo "=== CacheWave Hotspot Setup (continued) ==="
echo
print_ok "Password accepted and cleared from the screen."
echo

# ----------
step "Step 9: Generating hotspot name..."
RAW_HOSTNAME=$(hostname -s)
TRIMMED_HOSTNAME=$(echo "$RAW_HOSTNAME" | sed -E 's/^[Cc][Aa][Cc][Hh][Ee][Ww][Aa][Vv][Ee]-?//')
if [ -z "$TRIMMED_HOSTNAME" ]; then
  TRIMMED_HOSTNAME="$RAW_HOSTNAME"
fi
HOTSPOT_SSID="CacheWave-${TRIMMED_HOSTNAME}"
HOTSPOT_SSID="${HOTSPOT_SSID:0:32}"
print_ok "Hotspot will be named: $HOTSPOT_SSID"
echo

# ---------- Fixed values ----------
CACHEWAVE_PORT="8080"

# ---------- Pick the hotspot address range ----------
# Default is 192.168.50.x. If the facility network (or anything else on this device)
# already uses an overlapping range, pick the next free one so the two never collide.
ip2int() { local IFS=.; local a b c d; read -r a b c d <<< "$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
overlaps() {
  local N1="${1%/*}" N2="${2%/*}" P1=32 P2=32 P MASK
  [[ "$1" == */* ]] && P1="${1#*/}"
  [[ "$2" == */* ]] && P2="${2#*/}"
  P=$(( P1 < P2 ? P1 : P2 ))
  MASK=$(( P == 0 ? 0 : (0xFFFFFFFF << (32 - P)) & 0xFFFFFFFF ))
  [ $(( $(ip2int "$N1") & MASK )) -eq $(( $(ip2int "$N2") & MASK )) ]
}
# Every IPv4 network in use on this device, except the hotspot's own
EXISTING_NETS=$( {
  ip -4 -o addr show | awk -v h="$HOTSPOT_IFACE" '$2 != h && $2 != "lo" {print $4}'
  ip -4 route show | awk -v h="$HOTSPOT_IFACE" '$1 != "default" && $0 !~ (" dev " h "( |$)") {print $1}'
} | sort -u )

HOTSPOT_PREFIX=""
for CANDIDATE in 192.168.50 192.168.51 192.168.52 192.168.53 192.168.54 172.20.50 10.123.50; do
  CONFLICT=false
  for NET in $EXISTING_NETS; do
    if overlaps "$CANDIDATE.0/24" "$NET"; then CONFLICT=true; break; fi
  done
  if [ "$CONFLICT" = false ]; then HOTSPOT_PREFIX="$CANDIDATE"; break; fi
done
if [ -z "$HOTSPOT_PREFIX" ]; then
  echo "FAIL - Couldn't choose an address range for the hotspot."
  echo "       The hotspot needs its own range of addresses that the facility network doesn't use."
  echo "       If the two overlap, the device can't tell which network to send traffic to, which"
  echo "       would break its internet connection. The facility network uses these ranges:"
  for NET in $EXISTING_NETS; do echo "         $NET"; done
  echo "       They overlap every range this script can choose from:"
  echo "         192.168.50.x through 192.168.54.x, 172.20.50.x, and 10.123.50.x"
  echo "       The hotspot has not been built. Send the ranges above to IEI so a custom hotspot"
  echo "       range can be chosen for this site, then re-run the script."
  exit 1
fi

HOTSPOT_SUBNET="$HOTSPOT_PREFIX.1/24"
DHCP_RANGE_START="$HOTSPOT_PREFIX.10"
DHCP_RANGE_END="$HOTSPOT_PREFIX.200"
HOTSPOT_ADDRESS_CHANGED=false
if [ "$HOTSPOT_PREFIX" != "192.168.50" ]; then
  HOTSPOT_ADDRESS_CHANGED=true
  print_note "The facility network overlaps the default hotspot range (192.168.50.x). Using $HOTSPOT_PREFIX.x instead."
fi

step "Step 10: Locking down the firewall..."
# Applied before the hotspot exists, so the hotspot is never available without protection.
# The rules refer to the hotspot by name, so they work before it is created.
iptables -F INPUT
iptables -F FORWARD
ip6tables -F INPUT
ip6tables -F FORWARD

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

iptables -A INPUT -i "$HOTSPOT_IFACE" -p udp --dport 67 -j ACCEPT
iptables -A INPUT -i "$HOTSPOT_IFACE" -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i "$HOTSPOT_IFACE" -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -i "$HOTSPOT_IFACE" -p tcp --dport "$CACHEWAVE_PORT" -j ACCEPT
iptables -A FORWARD -i "$HOTSPOT_IFACE" -o "$UPLINK_IFACE" -j DROP
iptables -A FORWARD -i "$UPLINK_IFACE" -o "$HOTSPOT_IFACE" -j DROP

iptables -P INPUT DROP
iptables -P FORWARD DROP
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP

if ping -c 2 -W 3 8.8.8.8 &>/dev/null; then
  print_ok "Firewall applied — connectivity still confirmed."
else
  print_note "Firewall applied. Ping to 8.8.8.8 failed, but the firewall doesn't block the device's own outgoing traffic — likely blocked by the network."
fi

netfilter-persistent save &>/dev/null
print_ok "Firewall rules saved — will survive a reboot."
echo

# ----------
# ---------- Step 9: build the manually-addressed AP ----------
step "Step 11: Creating the hotspot connection..."
if nmcli connection show cachewave-ap &>/dev/null; then
  print_info "Existing cachewave-ap connection found — removing before rebuilding."
  nmcli connection delete cachewave-ap &>/dev/null
fi

if ! NM_OUT=$(nmcli connection add type wifi ifname "$HOTSPOT_IFACE" con-name cachewave-ap ssid "$HOTSPOT_SSID" mode ap connection.autoconnect no 2>&1); then
  die "Couldn't create the hotspot connection. NetworkManager said: $NM_OUT"
fi
# From here on, any failure turns the hotspot off and keeps it from starting at boot
HOTSPOT_LIVE=true

if ! NM_OUT=$(nmcli connection modify cachewave-ap \
  802-11-wireless.band "$HOTSPOT_BAND" \
  802-11-wireless.channel "$HOTSPOT_CHANNEL" \
  802-11-wireless.ap-isolation 1 \
  wifi-sec.key-mgmt wpa-psk \
  wifi-sec.proto rsn \
  wifi-sec.pairwise ccmp \
  wifi-sec.group ccmp \
  wifi-sec.pmf optional \
  wifi-sec.psk "$HOTSPOT_PSK" \
  ipv4.method manual \
  ipv4.addresses "$HOTSPOT_SUBNET" \
  ipv6.method disabled 2>&1); then
  unset HOTSPOT_PSK HOTSPOT_PSK_CONFIRM
  die "Couldn't configure the hotspot. NetworkManager said: $NM_OUT"
fi

unset HOTSPOT_PSK HOTSPOT_PSK_CONFIRM

if ! NM_OUT=$(nmcli connection up cachewave-ap 2>&1); then
  die "The hotspot failed to start. NetworkManager said: $NM_OUT"
fi

ATTEMPTS=0
MAX_ATTEMPTS=10
until ip addr show "$HOTSPOT_IFACE" 2>/dev/null | grep -q "${HOTSPOT_SUBNET%/*}"; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    die "Hotspot did not come up with the expected address within ${MAX_ATTEMPTS} seconds."
  fi
  sleep 1
done
print_ok "Hotspot is up at $HOTSPOT_SUBNET"

UNEXPECTED_ROUTES=$(ip route show dev "$HOTSPOT_IFACE" | grep -v "^${HOTSPOT_SUBNET%.*}.0/24" || true)
if [ -n "$UNEXPECTED_ROUTES" ]; then
  print_fail "Unexpected route(s) found on $HOTSPOT_IFACE — expected only the local subnet:"
  echo "$UNEXPECTED_ROUTES"
else
  print_ok "No gateway route present — only the local subnet."
fi
echo

# ----------
step "Step 12: Setting up DHCP and DNS..."
systemctl stop dnsmasq &>/dev/null || true
systemctl disable dnsmasq &>/dev/null || true

tee /etc/dnsmasq.d/cachewave-hotspot.conf > /dev/null <<EOF
interface=${HOTSPOT_IFACE}
bind-interfaces
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},12h
dhcp-option=3
no-resolv
no-poll
EOF

systemctl enable dnsmasq &>/dev/null
systemctl start dnsmasq

sleep 1
if systemctl is-active --quiet dnsmasq; then
  print_ok "dnsmasq running, bound to $HOTSPOT_IFACE, no upstream DNS."
else
  die "dnsmasq failed to start — check 'journalctl -u dnsmasq'."
fi
echo


# ----------
step "Step 13: Turning off IPv6 and forwarding..."
tee /etc/sysctl.d/99-cachewave-noforward.conf > /dev/null <<EOF
net.ipv4.ip_forward=0
net.ipv6.conf.all.forwarding=0
net.ipv6.conf.default.forwarding=0
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=0
EOF
sysctl -p /etc/sysctl.d/99-cachewave-noforward.conf &>/dev/null
print_ok "IPv6 and forwarding disabled at the system level, saved across reboots."

# NetworkManager can turn IPv6 back on for a connection, so disable it on the uplink connection too
UPLINK_CONN=$(nmcli -e no -g GENERAL.CONNECTION device show "$UPLINK_IFACE" 2>/dev/null || true)
if [ -n "$UPLINK_CONN" ] && [ "$UPLINK_CONN" != "--" ]; then
  nmcli connection modify "$UPLINK_CONN" ipv6.method disabled
  if [ "$SETUP" = "B" ]; then
    # Keep the facility Wi-Fi on the onboard chip, and on its current band, so it can't drift onto the hotspot's radio or band
    if [ "$UPLINK_FREQ" -lt 2500 ]; then UPLINK_BAND="bg"; else UPLINK_BAND="a"; fi
    nmcli connection modify "$UPLINK_CONN" connection.interface-name "$ONBOARD_IFACE" 802-11-wireless.band "$UPLINK_BAND"
    print_info "Facility Wi-Fi tied to $ONBOARD_IFACE and locked to $([ "$UPLINK_BAND" = "bg" ] && echo "2.4GHz" || echo "5GHz")."
  fi
  print_info "Reconnecting '$UPLINK_CONN' to apply — the internet connection will drop for a few seconds."
  nmcli connection up "$UPLINK_CONN" &>/dev/null || true
  RECONNECTED=false
  for _ in $(seq 1 30); do
    if [ "$(nmcli -t -f GENERAL.STATE device show "$UPLINK_IFACE" 2>/dev/null | grep -c '(connected)')" -gt 0 ]; then
      RECONNECTED=true
      break
    fi
    sleep 1
  done
  if [ "$RECONNECTED" = true ]; then
    print_ok "Uplink connection updated and reconnected."
  else
    print_fail "The uplink connection did not reconnect within 30 seconds — check it manually."
  fi
else
  print_fail "Could not identify the uplink connection to disable IPv6 on — check it manually."
fi
echo

# ---------- Step 12: self-healing dispatcher ----------
step "Step 14: Installing the self-healing dispatcher script..."
tee /etc/NetworkManager/dispatcher.d/99-disable-forwarding > /dev/null <<EOF
#!/bin/bash
sysctl -w net.ipv4.ip_forward=0
sysctl -w net.ipv6.conf.all.forwarding=0

if [ "\$1" = "${HOTSPOT_IFACE}" ] && [ "\$2" = "up" ]; then
    systemctl restart dnsmasq
fi
EOF
chmod +x /etc/NetworkManager/dispatcher.d/99-disable-forwarding

OLD_PID=$(systemctl show -p MainPID --value dnsmasq)
nmcli connection down cachewave-ap &>/dev/null
nmcli connection up cachewave-ap &>/dev/null

RESTARTED=false
for _ in $(seq 1 10); do
  NEW_PID=$(systemctl show -p MainPID --value dnsmasq)
  if systemctl is-active --quiet dnsmasq && [ "$NEW_PID" != "0" ] && [ "$NEW_PID" != "$OLD_PID" ]; then
    RESTARTED=true
    break
  fi
  sleep 1
done
if [ "$RESTARTED" = true ]; then
  print_ok "Dispatcher script confirmed working — dnsmasq restarted automatically."
else
  print_fail "Dispatcher test did not restart dnsmasq within 10 seconds — check manually."
fi
echo

# ----------
step "Step 15: Turning off services and remote access this device doesn't need..."
# rpcbind (network file sharing) and avahi (local .local name discovery) aren't used here.
# The firewall already blocks them; turning them off removes them entirely.
# Masking stops other software from quietly starting them again.
for UNIT in rpcbind.socket rpcbind.service avahi-daemon.socket avahi-daemon.service; do
  systemctl disable --now "$UNIT" &>/dev/null || true
  systemctl mask "$UNIT" &>/dev/null || true
done
if systemctl is-active --quiet rpcbind || systemctl is-active --quiet avahi-daemon; then
  print_fail "rpcbind or avahi-daemon is still running — check manually."
else
  print_ok "rpcbind and avahi-daemon are off."
fi

# Remote access (SSH, VNC, xrdp, Raspberry Pi Connect): units are deployed without any.
# Each is stopped and masked, which also blocks it if it's installed later. Undo one with
# "sudo systemctl unmask <name>" (or remove /etc/systemd/user/<name> for Raspberry Pi Connect).
for UNIT in $REMOTE_SYSTEM_UNITS; do
  systemctl disable --now "$UNIT" &>/dev/null || true
  systemctl mask "$UNIT" &>/dev/null || true
done
# Raspberry Pi Connect runs as a per-user service: stop it for anyone logged in,
# then mask it for every user (the same thing "systemctl --global mask" does)
for LOGIN_USER in $(loginctl list-users --no-legend 2>/dev/null | awk '{print $2}'); do
  # shellcheck disable=SC2086
  systemctl --user -M "$LOGIN_USER@" stop $REMOTE_USER_UNITS &>/dev/null || true
done
mkdir -p /etc/systemd/user
for UNIT in $REMOTE_USER_UNITS; do
  ln -sfn /dev/null "/etc/systemd/user/$UNIT"
done
pkill -f rpi-connect &>/dev/null || true
sleep 1
REMOTE_PROBLEMS=$(remote_access_problems)
if [ -z "$REMOTE_PROBLEMS" ]; then
  print_ok "Remote access is off and locked: SSH, VNC, xrdp and Raspberry Pi Connect."
else
  while IFS= read -r LINE; do print_fail "Remote access: $LINE"; done <<< "$REMOTE_PROBLEMS"
fi
echo

# ----------
step "Step 16: Confirming forwarding and IPv6 are off..."
if [ "$(sysctl -n net.ipv4.ip_forward)" = "0" ]; then
  print_ok "IPv4 forwarding is off."
else
  print_fail "IPv4 forwarding is ON — investigate before deploying."
fi
if [ "$(sysctl -n net.ipv6.conf.all.forwarding)" = "0" ]; then
  print_ok "IPv6 forwarding is off."
else
  print_fail "IPv6 forwarding is ON — investigate before deploying."
fi
for IFACE in "$HOTSPOT_IFACE" "$UPLINK_IFACE"; do
  if [ -z "$(ip -6 addr show dev "$IFACE" 2>/dev/null)" ]; then
    print_ok "No IPv6 address on $IFACE."
  else
    print_fail "$IFACE has an IPv6 address — investigate before deploying."
  fi
done
echo

# Save this unit's configuration so the status screen can read it later
secure_state_dir
cat > "$CONFIG_FILE" <<EOF
SETUP="$SETUP"
UPLINK_IFACE="$UPLINK_IFACE"
HOTSPOT_IFACE="$HOTSPOT_IFACE"
ONBOARD_IFACE="$ONBOARD_IFACE"
HOTSPOT_PREFIX="$HOTSPOT_PREFIX"
CACHEWAVE_PORT="$CACHEWAVE_PORT"
EOF

# ---------- Done ----------
trap - ERR
if [ "$WARNINGS" -eq 0 ]; then
  echo "=== Setup complete — all checks passed ==="
else
  echo "=== Setup completed with $WARNINGS warning(s) — review the FAIL lines above ==="
fi
echo "Setup type:      $SETUP"
echo "Uplink:          $UPLINK_IFACE"
echo "Hotspot radio:   $HOTSPOT_IFACE"
echo "Hotspot name:    $HOTSPOT_SSID"
echo "Hotspot band:    $([ "$HOTSPOT_BAND" = "bg" ] && echo "2.4GHz" || echo "5GHz"), channel $HOTSPOT_CHANNEL"
echo "Hotspot security: $(wifi_security_mode "$HOTSPOT_IFACE")"
echo "CacheWave address for Chromebooks: http://$HOTSPOT_PREFIX.1:$CACHEWAVE_PORT"
echo
mac_of() { cat "/sys/class/net/$1/address" 2>/dev/null || echo "not present"; }
case "$SETUP" in
  A) ETH_ROLE="internet connection"; ONBOARD_ROLE="hotspot" ;;
  B) ETH_ROLE="not used";            ONBOARD_ROLE="internet connection" ;;
  C) ETH_ROLE="internet connection"; ONBOARD_ROLE="turned off" ;;
esac
MAC_LINES=$(printf '  %-32s %s  (%s)' "Ethernet (eth0):" "$(mac_of eth0)" "$ETH_ROLE")
MAC_LINES="$MAC_LINES
$(printf '  %-32s %s  (%s)' "Onboard Wi-Fi ($ONBOARD_IFACE):" "$(mac_of "$ONBOARD_IFACE")" "$ONBOARD_ROLE")"
if [ "$SETUP" = "B" ] || [ "$SETUP" = "C" ]; then
  MAC_LINES="$MAC_LINES
$(printf '  %-32s %s  (%s)' "USB Wi-Fi adapter ($HOTSPOT_IFACE):" "$(mac_of "$HOTSPOT_IFACE")" "hotspot")"
fi
echo "Hardware (MAC) addresses:"
echo "$MAC_LINES"
if [ "$HOTSPOT_ADDRESS_CHANGED" = true ]; then
  echo
  echo "!!! IMPORTANT: this unit uses a NON-DEFAULT address because the facility network overlapped 192.168.50.x."
  echo "!!! Chromebooks must use http://$HOTSPOT_PREFIX.1:$CACHEWAVE_PORT for CacheWave — not 192.168.50.1."
fi
echo
echo "Remember: the hotspot password you entered was not stored anywhere by this script — record it now if you haven't already."
echo "CacheWave itself still needs to be installed separately."
echo

if [ "$WARNINGS" -gt 0 ]; then
  echo "Automatic reboot check skipped because of the warning(s) above. Resolve them, then re-run the script."
  hotspot_off_on_failure
  exit 1
fi

# ---------- Step 14: set up the one-time post-reboot check ----------
step "Step 17: Preparing the post-reboot check..."
LOG_FILE="/var/log/cachewave-postboot-check.log"
FLAG_DIR="/var/lib/cachewave-results"
FLAG_FILE="$FLAG_DIR/results-pending"
CHECK_SCRIPT="/usr/local/sbin/cachewave-postboot-check.sh"
SHOW_SCRIPT="/usr/local/bin/cachewave-show-results"
UNIT_FILE="/etc/systemd/system/cachewave-postboot-check.service"
DESKTOP_USER="${SUDO_USER:-}"

mkdir -p "$FLAG_DIR"
rm -f "$LOG_FILE"

# The check itself — runs once, in the background, after the next boot
cat > "$CHECK_SCRIPT" <<CHECKEOF
#!/bin/bash
SETUP="$SETUP"
HOTSPOT_IFACE="$HOTSPOT_IFACE"
UPLINK_IFACE="$UPLINK_IFACE"
ONBOARD_IFACE="$ONBOARD_IFACE"
CACHEWAVE_PORT="$CACHEWAVE_PORT"
LOG_FILE="$LOG_FILE"
HOTSPOT_NET="$HOTSPOT_PREFIX.0/24"
CACHEWAVE_URL="http://$HOTSPOT_PREFIX.1:$CACHEWAVE_PORT"
MAC_LINES="$MAC_LINES"
COMPLETE_MARKER="$COMPLETE_MARKER"
ICON_PATH_FILE="$ICON_PATH_FILE"
CHECKEOF
# Same remote-access and security-mode checks the setup and status screen use
{
  declare -p REMOTE_SYSTEM_UNITS REMOTE_USER_UNITS REMOTE_PORTS
  declare -f remote_access_problems wifi_security_mode
} >> "$CHECK_SCRIPT"
cat >> "$CHECK_SCRIPT" <<'CHECKEOF'
FAILS=0
exec > "$LOG_FILE" 2>&1
pass() { echo "OK   - $1"; }
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }

echo "=== CacheWave post-reboot check — $(date) ==="
echo

# Give the network up to 2 minutes to come up after boot
for _ in $(seq 1 120); do
  [ "$(nmcli -g GENERAL.STATE connection show cachewave-ap 2>/dev/null)" = "activated" ] && break
  sleep 1
done

[ "$(nmcli -g GENERAL.STATE connection show cachewave-ap 2>/dev/null)" = "activated" ] \
  && pass "Hotspot is on" || fail "Hotspot did not come up"
if [ "$SETUP" = "B" ] || [ "$SETUP" = "C" ]; then
  [ -e "/sys/class/net/$HOTSPOT_IFACE" ] \
    && pass "USB adapter kept its permanent name ($HOTSPOT_IFACE)" \
    || fail "USB adapter not found as $HOTSPOT_IFACE — it's unplugged, or its permanent name didn't apply after the reboot"
fi
if [ "$SETUP" = "C" ]; then
  ONBOARD_STATE=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: -v d="$ONBOARD_IFACE" '$1 == d {print $2}')
  [ "$ONBOARD_STATE" = "unmanaged" ] \
    && pass "Onboard Wi-Fi stayed off" || fail "Onboard Wi-Fi ($ONBOARD_IFACE) is not off (state: ${ONBOARD_STATE:-unknown})"
fi
SECURITY_MODE=$(wifi_security_mode "$HOTSPOT_IFACE")
if [ "$SECURITY_MODE" = "unknown" ]; then
  echo "NOTE - Couldn't read the hotspot's Wi-Fi security mode"
else
  pass "Hotspot security: $SECURITY_MODE"
fi
REMOTE_PROBLEMS=$(remote_access_problems)
if [ -z "$REMOTE_PROBLEMS" ]; then
  pass "Remote access stayed off and locked (SSH, VNC, xrdp, Raspberry Pi Connect)"
else
  while IFS= read -r LINE; do fail "Remote access: $LINE"; done <<< "$REMOTE_PROBLEMS"
fi
# The self-healing script may be restarting dnsmasq right now — allow a few seconds
for _ in $(seq 1 15); do
  systemctl is-active --quiet dnsmasq && break
  sleep 1
done
systemctl is-active --quiet dnsmasq \
  && pass "dnsmasq is running" || fail "dnsmasq is not running"

UNEXPECTED=$(ip route show dev "$HOTSPOT_IFACE" 2>/dev/null | awk -v n="$HOTSPOT_NET" '$1 != n' || true)
[ -z "$UNEXPECTED" ] && pass "No gateway route on the hotspot" || fail "Unexpected route on the hotspot: $UNEXPECTED"

for CHAIN in INPUT FORWARD; do
  [ "$(iptables -S "$CHAIN" | head -1)" = "-P $CHAIN DROP" ] \
    && pass "IPv4 $CHAIN policy is DROP" || fail "IPv4 $CHAIN policy is not DROP"
  [ "$(ip6tables -S "$CHAIN" | head -1)" = "-P $CHAIN DROP" ] \
    && pass "IPv6 $CHAIN policy is DROP" || fail "IPv6 $CHAIN policy is not DROP"
done
iptables -C INPUT -i "$HOTSPOT_IFACE" -p tcp --dport "$CACHEWAVE_PORT" -j ACCEPT 2>/dev/null \
  && pass "CacheWave port rule is in place" || fail "CacheWave port rule is missing"
iptables -C FORWARD -i "$HOTSPOT_IFACE" -o "$UPLINK_IFACE" -j DROP 2>/dev/null \
  && pass "Hotspot-to-uplink block is in place" || fail "Hotspot-to-uplink block is missing"
iptables -C FORWARD -i "$UPLINK_IFACE" -o "$HOTSPOT_IFACE" -j DROP 2>/dev/null \
  && pass "Uplink-to-hotspot block is in place" || fail "Uplink-to-hotspot block is missing"

[ "$(sysctl -n net.ipv4.ip_forward)" = "0" ] && pass "IPv4 forwarding is off" || fail "IPv4 forwarding is ON"
[ "$(sysctl -n net.ipv6.conf.all.forwarding)" = "0" ] && pass "IPv6 forwarding is off" || fail "IPv6 forwarding is ON"
for IFACE in "$HOTSPOT_IFACE" "$UPLINK_IFACE"; do
  [ -z "$(ip -6 addr show dev "$IFACE" 2>/dev/null)" ] \
    && pass "No IPv6 address on $IFACE" || fail "$IFACE has an IPv6 address"
done

for SVC in rpcbind avahi-daemon; do
  systemctl is-active --quiet "$SVC" && fail "$SVC is running" || pass "$SVC is off"
done
[ -x /etc/NetworkManager/dispatcher.d/99-disable-forwarding ] \
  && pass "Self-healing script is in place" || fail "Self-healing script is missing"

if ping -c 2 -W 3 8.8.8.8 &>/dev/null; then
  pass "Device can reach the internet"
else
  echo "NOTE - Ping to 8.8.8.8 failed (may be blocked by the network)"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "RESULT: PASSED — everything survived the reboot."
else
  echo "RESULT: $FAILS check(s) FAILED — review the lines above before deploying."
fi
echo "CacheWave address for Chromebooks: $CACHEWAVE_URL"
echo
echo "Hardware (MAC) addresses:"
echo "$MAC_LINES"
echo "=== CHECK COMPLETE ==="

# On a full pass, mark setup complete and switch the desktop icon (if any) to the status screen
if [ "$FAILS" -eq 0 ]; then
  touch "$COMPLETE_MARKER"
  ICON_FILE=$(cat "$ICON_PATH_FILE" 2>/dev/null)
  if [ -n "$ICON_FILE" ] && [ -f "$ICON_FILE" ] && [ ! -L "$ICON_FILE" ]; then
    OWNER=$(stat -c %U "$ICON_FILE")
    runuser -u "$OWNER" -- sed -i 's/^Name=.*/Name=CacheWave hotspot status/; s/^Comment=.*/Comment=Shows whether the CacheWave hotspot is set up correctly/' "$ICON_FILE" 2>/dev/null || true
  fi
fi

# One-time only: remove the service so it never runs again
systemctl disable cachewave-postboot-check.service &>/dev/null
rm -f /etc/systemd/system/cachewave-postboot-check.service
systemctl daemon-reload
chmod 644 "$LOG_FILE"
CHECKEOF
chmod 755 "$CHECK_SCRIPT"

cat > "$UNIT_FILE" <<EOF
[Unit]
Description=CacheWave one-time post-reboot check
After=NetworkManager.service netfilter-persistent.service dnsmasq.service
Wants=NetworkManager.service

[Service]
Type=simple
ExecStart=$CHECK_SCRIPT

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable cachewave-postboot-check.service &>/dev/null

# The pop-up: shows the results once, then removes itself
cat > "$SHOW_SCRIPT" <<SHOWEOF
#!/bin/bash
LOG_FILE="$LOG_FILE"
FLAG_FILE="$FLAG_FILE"
SHOWEOF
cat >> "$SHOW_SCRIPT" <<'SHOWEOF'
echo "Waiting for the CacheWave post-reboot check to finish..."
for _ in $(seq 1 180); do
  grep -q "=== CHECK COMPLETE ===" "$LOG_FILE" 2>/dev/null && break
  sleep 1
done
clear
cat "$LOG_FILE" 2>/dev/null || echo "No results found — the check may not have run. See $LOG_FILE."
echo
echo "These results are saved in $LOG_FILE"
rm -f "$FLAG_FILE" "$HOME/.config/autostart/cachewave-results.desktop"
read -rp "Press Enter to close this window."
SHOWEOF
chmod 755 "$SHOW_SCRIPT"

# Fallback: also show results once in the next terminal opened, for any login type
cat > /etc/cachewave-results.sh <<EOF
if [ -n "\$PS1" ] && [ -f "$FLAG_FILE" ] && grep -q "=== CHECK COMPLETE ===" "$LOG_FILE" 2>/dev/null; then
  cat "$LOG_FILE"
  echo "(Saved in $LOG_FILE)"
  rm -f "$FLAG_FILE" 2>/dev/null
fi
EOF
grep -q "cachewave-results.sh" /etc/bash.bashrc 2>/dev/null || \
  echo '[ -f /etc/cachewave-results.sh ] && . /etc/cachewave-results.sh' >> /etc/bash.bashrc

touch "$FLAG_FILE"
if [ -n "$DESKTOP_USER" ]; then
  chown "$DESKTOP_USER" "$FLAG_DIR" "$FLAG_FILE"
fi
if [ -n "$DESKTOP_USER" ] && command -v lxterminal &>/dev/null; then
  USER_HOME=$(getent passwd "$DESKTOP_USER" | cut -d: -f6)
  mkdir -p "$USER_HOME/.config/autostart"
  cat > "$USER_HOME/.config/autostart/cachewave-results.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=CacheWave post-reboot results
Exec=lxterminal -e $SHOW_SCRIPT
EOF
  chown -R "$DESKTOP_USER" "$USER_HOME/.config/autostart"
  print_ok "Post-reboot check ready — results will pop up on the desktop after reboot."
else
  print_ok "Post-reboot check ready — results will show when you open a terminal after reboot."
fi
echo

# Setup succeeded: let the hotspot start on its own at boot (and after an adapter is re-plugged)
if ! NM_OUT=$(nmcli connection modify cachewave-ap connection.autoconnect yes 2>&1); then
  die "Couldn't set the hotspot to start at boot. NetworkManager said: $NM_OUT"
fi
HOTSPOT_LIVE=false

# ----------
step "Step 18: Rebooting to confirm everything survives a restart..."
echo "Rebooting in 10 seconds to confirm everything survives a restart."
echo "Press Ctrl+C to cancel (the check will then run the next time the device restarts)."
trap 'echo; echo "Reboot cancelled."; exit 0' INT
for i in $(seq 10 -1 1); do
  printf "\r  %2d " "$i"
  sleep 1
done
echo
systemctl reboot
