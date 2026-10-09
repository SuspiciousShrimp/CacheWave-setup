#!/bin/bash
#
# cachewave-hardened-hotspot-setup.sh
#
# Builds the isolated CacheWave Chromebook hotspot on a device that is
# ALREADY connected to the internet (facility Wi-Fi or ethernet).
# This script does NOT configure the uplink itself, and does NOT install
# CacheWave — both are handled separately.
#
# Safe to re-run: cleans up and rebuilds its own prior configuration.

set -Eeuo pipefail

# ---------- Output helpers ----------
WARNINGS=0
CURRENT_STEP="Starting up"
print_info() { echo "  -> $1"; }
print_note() { echo "NOTE - $1"; }
print_ok()   { echo "OK  - $1"; }
print_fail() { echo "FAIL - $1"; WARNINGS=$((WARNINGS + 1)); }
die()        { echo "FAIL - $1"; exit 1; }
step()       { CURRENT_STEP="$1"; echo "$1"; }

# If any command fails unexpectedly, say where instead of stopping silently
on_error() {
  echo
  echo "FAIL - Setup stopped unexpectedly during: ${CURRENT_STEP} (script line $1)."
  echo "       Nothing after this point was applied. Fix the issue above, then re-run the script."
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
  echo

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
  [ "$SETUP" = "B" ] && printf '  %-32s %s\n' "USB Wi-Fi adapter ($HOTSPOT_IFACE):" "$(mac_of "$HOTSPOT_IFACE")"
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
    echo "       - A facility content filter or proxy blocking software downloads (ask facility IT)."
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
  SETUP="A"
  UPLINK_IFACE="eth0"
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
echo

# ----------
step "Step 5: Confirming $HOTSPOT_IFACE supports access-point mode..."
PHY=$(iw dev "$HOTSPOT_IFACE" info 2>/dev/null | awk '/wiphy/{print $2}')
if [ -z "$PHY" ]; then
  die "Could not identify the radio behind $HOTSPOT_IFACE."
fi
if ! iw phy "phy${PHY}" info 2>/dev/null | grep -A 10 "Supported interface modes" | grep -q " AP$"; then
  die "$HOTSPOT_IFACE does not support AP mode. Use a different adapter."
fi
print_ok "AP mode supported."
echo

# ----------
step "Step 6: Choosing hotspot band..."
if [ "$SETUP" = "A" ]; then
  HOTSPOT_BAND="bg"
  print_ok "Setup A: hotspot set to 2.4GHz (no second radio to conflict with)."
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
if [ "$HOTSPOT_BAND" = "bg" ]; then
  BEST_CHANNEL=1
  BEST_COUNT=999999
  for CH in 1 6 11; do
    COUNT=$(nmcli -f CHAN device wifi list ifname "$HOTSPOT_IFACE" 2>/dev/null | grep -c "^\s*${CH}\b" || true)
    if [ "$COUNT" -lt "$BEST_COUNT" ]; then
      BEST_COUNT=$COUNT
      BEST_CHANNEL=$CH
    fi
  done
  HOTSPOT_CHANNEL=$BEST_CHANNEL
  print_ok "Selected channel $HOTSPOT_CHANNEL (2.4GHz, least congested of 1/6/11)."
else
  HOTSPOT_CHANNEL=36
  print_ok "Selected channel $HOTSPOT_CHANNEL (5GHz default)."
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

# ---------- Step 9: build the manually-addressed AP ----------
step "Step 10: Creating the hotspot connection..."
if nmcli connection show cachewave-ap &>/dev/null; then
  print_info "Existing cachewave-ap connection found — removing before rebuilding."
  nmcli connection delete cachewave-ap &>/dev/null
fi

if ! NM_OUT=$(nmcli connection add type wifi ifname "$HOTSPOT_IFACE" con-name cachewave-ap ssid "$HOTSPOT_SSID" mode ap 2>&1); then
  die "Couldn't create the hotspot connection. NetworkManager said: $NM_OUT"
fi

if ! NM_OUT=$(nmcli connection modify cachewave-ap \
  802-11-wireless.band "$HOTSPOT_BAND" \
  802-11-wireless.channel "$HOTSPOT_CHANNEL" \
  802-11-wireless.ap-isolation 1 \
  wifi-sec.key-mgmt wpa-psk \
  wifi-sec.proto rsn \
  wifi-sec.pairwise ccmp \
  wifi-sec.group ccmp \
  wifi-sec.psk "$HOTSPOT_PSK" \
  ipv4.method manual \
  ipv4.addresses "$HOTSPOT_SUBNET" \
  ipv6.method disabled \
  connection.autoconnect yes 2>&1); then
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
step "Step 11: Setting up DHCP and DNS..."
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
step "Step 12: Locking down the firewall..."
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
step "Step 15: Turning off services this device doesn't need..."
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
echo "CacheWave address for Chromebooks: http://$HOTSPOT_PREFIX.1:$CACHEWAVE_PORT"
echo
mac_of() { cat "/sys/class/net/$1/address" 2>/dev/null || echo "not present"; }
if [ "$SETUP" = "A" ]; then
  ETH_ROLE="internet connection"; ONBOARD_ROLE="hotspot"
else
  ETH_ROLE="not used"; ONBOARD_ROLE="internet connection"
fi
MAC_LINES=$(printf '  %-32s %s  (%s)' "Ethernet (eth0):" "$(mac_of eth0)" "$ETH_ROLE")
MAC_LINES="$MAC_LINES
$(printf '  %-32s %s  (%s)' "Onboard Wi-Fi ($ONBOARD_IFACE):" "$(mac_of "$ONBOARD_IFACE")" "$ONBOARD_ROLE")"
if [ "$SETUP" = "B" ]; then
  MAC_LINES="$MAC_LINES
$(printf '  %-32s %s  (%s)' "USB Wi-Fi adapter ($HOTSPOT_IFACE):" "$(mac_of "$HOTSPOT_IFACE")" "hotspot")"
fi
echo "Hardware (MAC) addresses — for the facility IT checklist:"
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
HOTSPOT_IFACE="$HOTSPOT_IFACE"
UPLINK_IFACE="$UPLINK_IFACE"
CACHEWAVE_PORT="$CACHEWAVE_PORT"
LOG_FILE="$LOG_FILE"
HOTSPOT_NET="$HOTSPOT_PREFIX.0/24"
CACHEWAVE_URL="http://$HOTSPOT_PREFIX.1:$CACHEWAVE_PORT"
MAC_LINES="$MAC_LINES"
COMPLETE_MARKER="$COMPLETE_MARKER"
ICON_PATH_FILE="$ICON_PATH_FILE"
CHECKEOF
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
echo "Hardware (MAC) addresses — for the facility IT checklist:"
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
