#!/bin/bash
set -e
set -o pipefail

# Execute with: bash <(curl -fsSL https://raw.githubusercontent.com/OranjeBanaan/Proxmox/main/InstallScriptNewNode.sh)
# or with:      bash <(curl -fsSL "https://raw.githubusercontent.com/OranjeBanaan/Proxmox/main/InstallScriptNewNode.sh?$(date +%s)")

echo "🧭 Proxmox Setup Script with Multi-Select Menu"
echo "You can run multiple steps at once. Examples: '1 3 6' or '1,3,6'"
echo
echo "1) Update (no-subscription repos + apt upgrade)"
echo "2) Add Templates (mount SMB, restore Windows VM 8001 (latest), run generator)"
echo "3) Install NGINX (reverse proxy for web interface)"
echo "4) All of the above (1,2,3)"
echo "5) Just run TemplateGenerator script"
echo "6) Add SMB + interactively choose a backup from SMB to restore (shows backup NOTES)"
echo "0) Exit"
read -rp "➡️  Select option(s): " options_raw

# ---------- Configurable defaults (override via env) ----------
TARGET_STORAGE=${TARGET_STORAGE:-local-lvm}   # Storage to restore VMs to
SMB_NAME=${SMB_NAME:-Templates}
SMB_SERVER=${SMB_SERVER:-192.168.1.21}
SMB_SHARE=${SMB_SHARE:-Templates}
SMB_USER=${SMB_USER:-Templates}
SMB_PASS=${SMB_PASS:-Xo8YYu75saY5}           # Prefer a credentials file in production
MOUNT_BASE="/mnt/pve/${SMB_NAME}"
BACKUP_DIR="${MOUNT_BASE}/dump"

# ---------- Helpers ----------
add_or_activate_smb_storage() {
  echo "🔗 Ensuring CIFS (SMB) storage '${SMB_NAME}' is present and active..."
  if pvesm config "${SMB_NAME}" >/dev/null 2>&1; then
    echo "ℹ️ Storage '${SMB_NAME}' already configured."

    # Enable if disabled (match both `disable: 1` and `disable 1`)
    if pvesm config "${SMB_NAME}" | grep -Eq '^disable(:|)\s*1'; then
      echo "✅ Enabling previously disabled storage '${SMB_NAME}'..."
      pvesm set "${SMB_NAME}" --disable 0
    fi

    # Ensure 'backup' is part of the content types
    local current_content
    current_content="$(pvesm config "${SMB_NAME}" | awk -F': ' '/^content/ {print $2}')"
    if [[ -z "$current_content" ]]; then
      echo "🧩 Adding 'backup' to storage content types..."
      pvesm set "${SMB_NAME}" --content backup
    elif ! echo "$current_content" | grep -qw backup; then
      echo "🧩 Appending 'backup' to content types: ${current_content}"
      pvesm set "${SMB_NAME}" --content "${current_content},backup"
    fi
  else
    pvesm add cifs "${SMB_NAME}" \
      --server "${SMB_SERVER}" \
      --share "${SMB_SHARE}" \
      --username "${SMB_USER}" \
      --password "${SMB_PASS}" \
      --content backup \
      --smbversion 3
    echo "✅ Storage '${SMB_NAME}' added."
  fi

  # Make sure mount path exists and trigger automounts/refresh
  mkdir -p "${MOUNT_BASE}" "${BACKUP_DIR}"
  # Ask Proxmox to touch the storage (triggers/refreshes mount)
  pvesm list "${SMB_NAME}" --content backup >/dev/null 2>&1 || true
  # Touch the paths to trigger systemd automount if used
  ls -ld "${MOUNT_BASE}" "${BACKUP_DIR}" >/dev/null 2>&1 || true
  # Nudge the storage daemon and give it a moment
  systemctl restart pvestatd >/dev/null 2>&1 || true
  sleep 1

  if mountpoint -q "${MOUNT_BASE}"; then
    echo "✅ Storage '${SMB_NAME}' mounted at ${MOUNT_BASE}"
  else
    echo "ℹ️ '${SMB_NAME}' not detected as a mountpoint yet; continuing (pvesm will still resolve paths)."
  fi
}

get_next_free_vmid() {
  if command -v pvesh >/dev/null 2>&1; then
    pvesh get /cluster/nextid
  else
    local id=100
    while qm status "$id" >/dev/null 2>&1; do id=$((id+1)); done
    echo "$id"
  fi
}

# Produce a human label for a backup: prefer vzdump NOTES, then VM Name, else filename
backup_label_from_metadata() {
  local f="$1"
  local log="${f%.*}"     # strip last extension (zst/gz/lzo) -> ends with .vma
  log="${log%.vma}.log"   # turn ...vma -> .log

  local label=""
  if [[ -f "$log" ]]; then
    # 1) Notes (case-insensitive), print text after the last ": "
    label="$(grep -iE '^INFO: *notes?' "$log" | head -n1 | awk -F': ' '{print $NF}')"
    # 2) Fallback: VM Name
    if [[ -z "$label" ]]; then
      label="$(grep -iE '^INFO: *VM Name:' "$log" | head -n1 | awk -F': ' '{print $NF}')"
    fi
  fi

  [[ -z "$label" ]] && label="$(basename "$f")"
  printf '%s\n' "$label"
}

scan_backups_fs() {
  # Filesystem scan under the expected dump directory (newest first)
  find "${BACKUP_DIR}" -maxdepth 1 -type f \
    -regextype posix-extended \
    -regex ".*/vzdump-qemu-[0-9]+-.*\.vma\.(zst|gz|lzo)" \
    -printf "%T@ %p\n" 2>/dev/null | sort -nr | awk '{ $1=""; sub(/^ /,""); print }'
}

scan_backups_with_retry() {
  mapfile -t backups < <(scan_backups_fs || true)
  if [ ${#backups[@]} -eq 0 ]; then
    echo "⏳ No backups found on first pass; refreshing storage state and retrying..."
    pvesm list "${SMB_NAME}" --content backup >/dev/null 2>&1 || true
    ls -ld "${MOUNT_BASE}" "${BACKUP_DIR}" >/dev/null 2>&1 || true
    systemctl restart pvestatd >/dev/null 2>&1 || true
    sleep 2
    mapfile -t backups < <(scan_backups_fs || true)
  fi
}

select_backup_from_smb() {
  echo "🔎 Looking for backups in ${BACKUP_DIR} ..."
  mkdir -p "${BACKUP_DIR}"

  scan_backups_with_retry

  if [ ${#backups[@]} -eq 0 ]; then
    echo "❌ No vzdump backups found in ${BACKUP_DIR}"
    echo "   Tip: ensure the CIFS share contains a 'dump' folder with vzdump-qemu-*.vma.(zst|gz|lzo) files and their .log files."
    exit 1
  fi

  echo "📋 Available backups (newest first):"
  local i=1
  for f in "${backups[@]}"; do
    echo "  $i) $(backup_label_from_metadata "$f")"
    i=$((i+1))
  done

  local sel
  while true; do
    read -rp "➡️  Enter the n
