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
BACKUP_DIR="/mnt/pve/${SMB_NAME}/dump"

# ---------- Helpers ----------
add_smb_storage() {
  echo "🔗 Ensuring CIFS (SMB) storage '${SMB_NAME}' exists..."
  if pvesm config "${SMB_NAME}" >/dev/null 2>&1; then
    echo "✅ Storage '${SMB_NAME}' already configured."
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
    # Prefer explicit Notes captured by vzdump hooks or UI
    label="$(sed -nE 's/^INFO: *notes?: *//Ip' "$log" | head -n1)"
    if [[ -z "$label" ]]; then
      # Fallback to VM Name line if present
      label="$(sed -nE 's/^INFO: *VM Name: *//Ip' "$log" | head -n1)"
    fi
  fi

  [[ -z "$label" ]] && label="$(basename "$f")"
  printf '%s\n' "$label"
}

select_backup_from_smb() {
  echo "🔎 Looking for backups in ${BACKUP_DIR} ..."
  if [ ! -d "${BACKUP_DIR}" ]; then
    echo "❌ Backup directory '${BACKUP_DIR}' not found. Does the SMB share contain a 'dump' folder?"
    exit 1
  fi

  # Gather backups (newest first). Match common formats: .vma.zst/.gz/.lzo
  mapfile -t backups < <(find "${BACKUP_DIR}" -maxdepth 1 -type f \
    -regextype posix-extended \
    -regex ".*/vzdump-qemu-[0-9]+-.*\.vma\.(zst|gz|lzo)" \
    -printf "%T@ %p\n" | sort -nr | awk '{ $1=""; sub(/^ /,""); print }')

  if [ ${#backups[@]} -eq 0 ]; then
    echo "❌ No vzdump backups found in ${BACKUP_DIR}"
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
    read -rp "➡️  Enter the number to restore [1-${#backups[@]}]: " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel>=1 && sel<=${#backups[@]} )); then
      break
    fi
    echo "↩️  Invalid choice. Try again."
  done

  CHOSEN="${backups[$((sel-1))]}"
  echo "✅ Selected file: $(basename "$CHOSEN")"

  # Parse VMID from filename: vzdump-qemu-<vmid>-...
  if [[ "$(basename "$CHOSEN")" =~ vzdump-qemu-([0-9]+)- ]]; then
    SRC_VMID="${BASH_REMATCH[1]}"
  else
    SRC_VMID="8001"  # fallback
  fi

  # If VMID exists, pick next free ID
  if qm status "$SRC_VMID" >/dev/null 2>&1; then
    echo "ℹ️  VMID ${SRC_VMID} already exists. Selecting next free VMID..."
    TARGET_VMID="$(get_next_free_vmid)"
  else
    TARGET_VMID="$SRC_VMID"
  fi

  echo "↩️  Restoring to VMID ${TARGET_VMID} on storage ${TARGET_STORAGE} …"
  qmrestore "$CHOSEN" "$TARGET_VMID" --storage "${TARGET_STORAGE}" --unique
  echo "🎉 VM ${TARGET_VMID} restored from $(basename "$CHOSEN")"
}

restore_vm_8001_latest() {
  VMID=8001
  echo "🔍 Searching for the newest vzdump backup of VM ${VMID} in ${BACKUP_DIR} …"
  LATEST_BACKUP=$(ls -1t ${BACKUP_DIR}/vzdump-qemu-${VMID}-*.vma.* 2>/dev/null | head -n 1 || true)
  if [[ -z "$LATEST_BACKUP" ]]; then
    echo "❌ No vzdump backup files found for VM ${VMID} in ${BACKUP_DIR}"
    exit 1
  fi
  echo "✅ Latest backup found: $LATEST_BACKUP"
  echo "↩️  Restoring to VMID ${VMID} on storage ${TARGET_STORAGE} …"
  qmrestore "$LATEST_BACKUP" "$VMID" --storage "${TARGET_STORAGE}" --unique
  echo "🎉 VM ${VMID} has been restored from $LATEST_BACKUP"
}

run_template_generator() {
  echo "📥 Downloading TemplateGenerator..."
  curl -fsSL https://raw.githubusercontent.com/OranjeBanaan/Proxmox/main/TemplateGenerator.txt -o /usr/local/bin/TemplateGenerator
  chmod +x /usr/local/bin/TemplateGenerator
  echo "🚀 Running TemplateGenerator..."
  /usr/local/bin/TemplateGenerator
}

# ---------- Original actions (kept) ----------
update_system() {
  echo "🔧 Replacing Proxmox and Ceph enterprise repos with no-subscription versions..."

  if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak
    {
      echo "# Replaced by script"
      echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription"
    } > /etc/apt/sources.list.d/pve-enterprise.list
  fi

  if [ -f /etc/apt/sources.list.d/ceph.list ]; then
    cp /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.list.bak
    {
      echo "# Replaced by script"
      echo "deb http://download.proxmox.com/debian/ceph-quincy bookworm pve-no-subscription"
    } > /etc/apt/sources.list.d/ceph.list
  fi

  echo "📦 Updating system..."
  apt update && apt upgrade -y

  echo "🛠️ Updating GRUB config..."
  cp /etc/default/grub /etc/default/grub.bak
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt pcie_acs_override=downstream,multifunction"/' /etc/default/grub

  echo "🔧 Adding VFIO modules to /etc/modules if not already present..."
  for module in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
    grep -qxF "$module" /etc/modules || echo "$module" >> /etc/modules
  done

  echo "🔄 Updating initramfs for all kernels..."
  update-initramfs -u -k all

  echo "📝 Writing kvm modprobe config..."
  echo "options kvm ignore_msrs=1 report_ignored_msrs=0" > /etc/modprobe.d/kvm.conf
}

install_nginx() {
  echo "📥 Installing nginx..."
  apt install -y nginx

  echo "🧹 Removing default nginx site..."
  rm -f /etc/nginx/sites-enabled/default

  HOSTNAME=$(hostname -f)
  echo "🛠️ Creating /etc/nginx/conf.d/proxmox.conf..."
  cat > /etc/nginx/conf.d/proxmox.conf <<EOF
upstream proxmox {
    server "$HOSTNAME";
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    rewrite ^(.*) https://\$host\$1 permanent;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name _;
    ssl_certificate /etc/pve/local/pve-ssl.pem;
    ssl_certificate_key /etc/pve/local/pve-ssl.key;
    proxy_redirect off;
    location / {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass https://localhost:8006;
        proxy_buffering off;
        client_max_body_size 0;
        proxy_connect_timeout  3600s;
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
        send_timeout  3600s;
    }
}
EOF

  echo "🔍 Testing nginx configuration..."
  if ! nginx -t; then
    echo "❌ NGINX configuration test failed. Aborting."
    exit 1
  fi

  echo "🔄 Restarting nginx..."
  systemctl restart nginx

  echo "🔧 Creating systemd override for nginx..."
  mkdir -p /etc/systemd/system/nginx.service.d
  cat > /etc/systemd/system/nginx.service.d/override.conf <<EOF
[Unit]
Requires=pve-cluster.service
After=pve-cluster.service
EOF

  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl restart nginx
}

add_templates() {
  add_smb_storage
  restore_vm_8001_latest
  run_template_generator
}

run_template_generator_only() {
  run_template_generator
}

restore_from_smb_interactive() {
  add_smb_storage
  select_backup_from_smb
}

# ---------- Execute selections (multi) ----------
# Normalize separators: turn commas into spaces
options_norm="${options_raw//,/ }"

# If user selected 4, expand it to 1 2 3 (still allows combos like "4 5")
expanded_opts=()
for token in $options_norm; do
  case "$token" in
    4) expanded_opts+=(1 2 3) ;;
    *) expanded_opts+=("$token") ;;
  esac
done

for option in "${expanded_opts[@]}"; do
  case "$option" in
    1) update_system ;;
    2) add_templates ;;
    3) install_nginx ;;
    5) run_template_generator_only ;;
    6) restore_from_smb_interactive ;;
    0) echo "👋 Exiting."; exit 0 ;;
    *) echo "❌ Invalid option: $option"; exit 1 ;;
  esac
done

echo "✅ Done!"
