#!/usr/bin/env bash
set -euo pipefail

# Execute with: bash <(curl -fsSL https://raw.githubusercontent.com/OranjeBanaan/Proxmox/main/WOLscript.sh)
# or with:      bash <(curl -fsSL "https://raw.githubusercontent.com/OranjeBanaan/Proxmox/main/WOLscript.sh?$(date +%s)")

# Ensure we're root
if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (e.g., sudo $0)"
  exit 1
fi

# Find a suitable ethtool path
ETHTOOL_BIN="$(command -v ethtool || true)"
if [[ -z "${ETHTOOL_BIN}" ]]; then
  echo "ethtool is not installed. Please install it first (apt/dnf/yum/zypper/pacman) and re-run."
  exit 1
fi

# Helper: check if iface is up and matches eno|enp
is_en_up() {
  local dev="$1"
  [[ "$dev" =~ ^en(o|p) ]] || return 1
  # Use terse output to check operational state
  ip -br link show dev "$dev" 2>/dev/null | awk '{print $2}' | grep -q "UP"
}

# Prefer the default-route interface if it matches
DEFAULT_IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -n1 || true)"
IFACE=""

if [[ -n "${DEFAULT_IFACE}" ]] && is_en_up "${DEFAULT_IFACE}"; then
  IFACE="${DEFAULT_IFACE}"
else
  # Fall back: any UP eno|enp device
  while read -r cand; do
    if is_en_up "$cand"; then
      IFACE="$cand"
      break
    fi
  done < <(ip -o link show | awk -F': ' '{print $2}')
fi

if [[ -z "${IFACE}" ]]; then
  echo "No UP ethernet interface matching eno*/enp* was found."
  exit 1
fi

echo "Using interface: ${IFACE}"

SERVICE_PATH="/etc/systemd/system/wol.service"

# Create systemd unit with the resolved ethtool path and interface
cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=Enable Wake-on-LAN on ${IFACE}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${ETHTOOL_BIN} -s ${IFACE} wol g

[Install]
WantedBy=multi-user.target
EOF

# Make it take effect now and on boot
systemctl daemon-reload
systemctl enable wol.service
systemctl start wol.service

# Also apply immediately in the current session (useful before next boot)
${ETHTOOL_BIN} -s "${IFACE}" wol g

echo "Wake-on-LAN enabled on ${IFACE}. Service installed at ${SERVICE_PATH} and started."
