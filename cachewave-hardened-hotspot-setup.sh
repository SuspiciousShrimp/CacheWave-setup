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

echo "=== CacheWave Hotspot Setup ==="
echo

# ----------
step "Step 1: Checking for an existing internet connection..."
if ping -c 2 -W 3 8.8.8.8 &>/dev/null; then
  print_ok "Internet connection confirmed."
else
  print_note "Ping to 8.8.8.8 failed. Some networks block ping, so setup will continue. The software download in Step 1b will confirm internet access."
fi
echo

# ----------
step "Step 2: Installing required software..."
# Pre-answer iptables-persistent's install questions so it doesn't wait for input
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
print_info "This can take a few minutes, especially right after a fresh install."
if ! apt-get -o DPkg::Lock::Timeout=120 update -qq &>/dev/null; then
  die "Couldn't reach the software repositories. Check the internet connection, then re-run. Nothing has been changed."
fi
DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y dnsmasq iptables iptables-persistent &>/dev/null || true
for PKG in dnsmasq iptables iptables-persistent; do
  if ! dpkg-query -W -f='${Status}' "$PKG" 2>/dev/null | grep -q "install ok installed"; then
    die "Couldn't install $PKG. Check the internet connection (or wait for any system update to finish), then re-run. Nothing has been changed."
  fi
done
# dnsmasq starts itself on install with default settings — stop it until it's configured
systemctl stop dnsmasq &>/dev/null || true
systemctl disable dnsmasq &>/dev/null || true
print_ok "Required software installed — internet access confirmed."
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

ETH0_STATE=$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | grep '^eth0:ethernet:' | cut -d: -f3 || true)
WLAN0_STATE=$(nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null | grep '^wlan0:wifi:' | cut -d: -f3 || true)

if [ "$ETH0_STATE" = "connected" ]; then
  SETUP="A"
  UPLINK_IFACE="eth0"
  HOTSPOT_IFACE="wlan0"
  print_ok "Setup A detected: ethernet uplink, onboard chip will be the hotspot."

  # Free up wlan0 if it's lingering on some client network from imaging
  WLAN0_CONN=$(nmcli -g GENERAL.CONNECTION -e no device show wlan0 2>/dev/null || true)
  if [ -n "$WLAN0_CONN" ] && [ "$WLAN0_CONN" != "--" ]; then
    print_info "Disconnecting wlan0 from '$WLAN0_CONN' — not needed, ethernet is the uplink."
    nmcli connection down "$WLAN0_CONN" &>/dev/null || true
    # Otherwise it could reconnect at boot and take wlan0 before the hotspot does
    nmcli connection modify "$WLAN0_CONN" connection.autoconnect no &>/dev/null || true
  fi

elif [ "$WLAN0_STATE" = "connected" ]; then
  SETUP="B"
  UPLINK_IFACE="wlan0"
  print_ok "Setup B detected: onboard chip is the uplink, looking for a USB hotspot adapter..."

  HOTSPOT_IFACE=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi" && $1!="wlan0" {print $1; exit}')
  if [ -z "$HOTSPOT_IFACE" ]; then
    die "Setup B requires a second Wi-Fi adapter, but none was found. Plug one in and re-run."
  fi
  print_ok "Found hotspot adapter: $HOTSPOT_IFACE"

else
  die "No active uplink found on eth0 or wlan0. Connect to the internet first, then re-run this script."
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
  read -rsp "Enter hotspot password (12-63 characters; letters, numbers, and standard symbols except ! \` \$ and quote marks): " HOTSPOT_PSK; echo
  read -rsp "Confirm password: " HOTSPOT_PSK_CONFIRM; echo

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
print_ok "Password accepted."
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
HOTSPOT_SUBNET="192.168.50.1/24"
DHCP_RANGE_START="192.168.50.10"
DHCP_RANGE_END="192.168.50.200"
CACHEWAVE_PORT="8080"

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
    nmcli connection modify "$UPLINK_CONN" connection.interface-name wlan0 802-11-wireless.band "$UPLINK_BAND"
    print_info "Facility Wi-Fi tied to wlan0 and locked to $([ "$UPLINK_BAND" = "bg" ] && echo "2.4GHz" || echo "5GHz")."
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
step "Step 15: Confirming forwarding and IPv6 are off..."
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
echo
echo "Remember: the hotspot password you entered was not stored anywhere by this script — record it now if you haven't already."
echo "CacheWave itself still needs to be installed separately."
echo

if [ "$WARNINGS" -gt 0 ]; then
  echo "Automatic reboot check skipped because of the warning(s) above. Resolve them, then re-run the script."
  exit 1
fi

# ---------- Step 14: set up the one-time post-reboot check ----------
step "Step 16: Preparing the post-reboot check..."
LOG_FILE="/var/log/cachewave-postboot-check.log"
FLAG_DIR="/var/lib/cachewave"
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

UNEXPECTED=$(ip route show dev "$HOTSPOT_IFACE" 2>/dev/null | grep -v '^192\.168\.50\.0/24' || true)
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
echo "=== CHECK COMPLETE ==="

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
step "Step 17: Rebooting to confirm everything survives a restart..."
echo "Rebooting in 10 seconds to confirm everything survives a restart."
echo "Press Ctrl+C to cancel (the check will then run the next time the device restarts)."
trap 'echo; echo "Reboot cancelled."; exit 0' INT
for i in $(seq 10 -1 1); do
  printf "\r  %2d " "$i"
  sleep 1
done
echo
systemctl reboot
