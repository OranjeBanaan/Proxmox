#!/bin/bash
set -e

# Execute with: bash <(curl -fsSL https://raw.githubusercontent.com/OranjeBanaan/Proxmox/main/InstallScriptNewNode.sh)
# or with bash <(curl -fsSL "https://raw.githubusercontent.com/OranjeBanaan/Proxmox/main/InstallScriptNewNode.sh?$(date +%s)")

echo "🛍️ Proxmox Setup Script with Menu"
echo "1) Update (no-subscription repos + apt upgrade)"
echo "2) Add Templates (mount SMB, restore Windows VM, run generator)"
echo "3) Install NGINX (reverse proxy for web interface)"
echo "4) All of the above"
echo "5) Just run TemplateGenerator script"
echo "6) Add SMB + restore Windows template only"
echo "7) Migrate vmbr0 port to vmbr1 (no reload yet)"
echo "0) Exit"
read -rp "➞️  Select an option: " option

update_system() {
    echo "🔧 Replacing Proxmox and Ceph enterprise repos with no-subscription versions..."

    if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
        cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak
        echo "# Replaced by script" > /etc/apt/sources.list.d/pve-enterprise.list
        echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" >> /etc/apt/sources.list.d/pve-enterprise.list
    fi

    if [ -f /etc/apt/sources.list.d/ceph.list ]; then
        cp /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.list.bak
        echo "# Replaced by script" > /etc/apt/sources.list.d/ceph.list
        echo "deb http://download.proxmox.com/debian/ceph-quincy bookworm pve-no-subscription" >> /etc/apt/sources.list.d/ceph.list
    fi

    echo "📆 Updating system..."
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
    echo "📅 Installing nginx..."
    apt install -y nginx

    echo "🛉 Removing default nginx site..."
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

restore_vm_8001() {
    VMID=8001
    BACKUP_DIR="/mnt/pve/Templates/dump"

    echo "🔍 Searching for the newest vzdump backup of VM ${VMID} in ${BACKUP_DIR} …"
    LATEST_BACKUP=$(ls -1t ${BACKUP_DIR}/vzdump-qemu-${VMID}-*.vma.zst 2>/dev/null | head -n 1)

    if [[ -z "$LATEST_BACKUP" ]]; then
        echo "❌ No vzdump backup files found for VM ${VMID} in ${BACKUP_DIR}"
        exit 1
    fi

    echo "✅ Latest backup found: $LATEST_BACKUP"
    echo "↩️  Restoring to VMID ${VMID} on storage local-lvm …"
    qmrestore "$LATEST_BACKUP" "$VMID" --storage local-lvm --unique
    echo "🎉 VM ${VMID} has been restored from $LATEST_BACKUP"
}

add_templates() {
    echo "🔗 Adding CIFS (SMB) storage named 'Templates'..."
    pvesm add cifs Templates \
      --server 192.168.1.21 \
      --share Templates \
      --username Templates \
      --password 'Xo8YYu75saY5' \
      --content backup \
      --smbversion 3

    restore_vm_8001

    run_template_generator
}

run_template_generator() {
    echo "📅 Downloading TemplateGenerator..."
    curl -fsSL https://raw.githubusercontent.com/OranjeBanaan/Proxmox/main/TemplateGenerator.txt -o /usr/local/bin/TemplateGenerator
    chmod +x /usr/local/bin/TemplateGenerator
    echo "🚀 Running TemplateGenerator..."
    /usr/local/bin/TemplateGenerator
}

just_restore_windows() {
    echo "🔗 Adding CIFS (SMB) storage named 'Templates'..."
    pvesm add cifs Templates \
      --server 192.168.1.21 \
      --share Templates \
      --username Templates \
      --password 'Xo8YYu75saY5' \
      --content backup \
      --smbversion 3

    restore_vm_8001
}

split_vmbr0_to_vmbr1_no_reload() {
    local IF_FILE="/etc/network/interfaces"
    local BACKUP="${IF_FILE}.bak.$(date +%F-%H%M%S)"

    echo "🧷 Backing up ${IF_FILE} → ${BACKUP}"
    cp "$IF_FILE" "$BACKUP" || { echo "❌ Backup failed"; return 1; }

    local PORT=$(awk '/^iface vmbr0/{f=1;next} /^iface/{f=0} f && /(bridge[-_]ports)/ {for(i=2;i<=NF;i++) print $i; exit}' "$IF_FILE")
    local ADDR=$(awk '/^iface vmbr0/{f=1;next} /^iface/{f=0} f && /address/   {print $2; exit}' "$IF_FILE")
    local NETMASK=$(awk '/^iface vmbr0/{f=1;next} /^iface/{f=0} f && /netmask/  {print $2; exit}' "$IF_FILE")
    local GATEWAY=$(awk '/^iface vmbr0/{f=1;next} /^iface/{f=0} f && /gateway/  {print $2; exit}' "$IF_FILE")

    if [[ -z "$PORT" || -z "$ADDR" || -z "$NETMASK" ]]; then
        echo "❌ Missing one of: port, address, or netmask. Aborting."
        return 1
    fi

    echo "➡️ Moving port $PORT from vmbr0 to vmbr1"

    sed -i \
        -e "/^iface vmbr0/,/^iface/{s/^\( *\(address\|netmask\|gateway\)\)/#\1/}" \
        -e "/^iface vmbr0/,/^iface/{/(bridge[-_]ports)/ s/\b${PORT}\b//}" \
        -e "/^iface vmbr0/,/^iface/{/(bridge[-_]ports)/ s/  */ /g}" \
        -e "/^iface vmbr0/,/^iface/{/(bridge[-_]ports)/ s/bridge[-_]ports *\$/bridge-ports none/}" \
        "$IF_FILE"

    cat >> "$IF_FILE" <<EOF

# --- Added by split_vmbr0_to_vmbr1_no_reload ---
auto vmbr1
iface vmbr1 inet manual
    bridge-ports ${PORT}
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes

auto vmbr1.101
iface vmbr1.101 inet static
    address ${ADDR}
    netmask ${NETMASK}
    gateway ${GATEWAY}
    vlan-raw-device vmbr1
    # HostingNetwork

auto vmbr1.104
iface vmbr1.104 inet manual
    vlan-raw-device vmbr1
    # HostingNetworkv2
# ------------------------------------------------
EOF

    echo "✅ Config updated. Reboot or run 'ifreload -a' to apply manually."
}

case "$option" in
    1) update_system ;;
    2) add_templates ;;
    3) install_nginx ;;
    4) update_system; install_nginx; add_templates ;;
    5) run_template_generator ;;
    6) just_restore_windows ;;
    7) split_vmbr0_to_vmbr1_no_reload ;;
    0) echo "👋 Exiting."; exit 0 ;;
    *) echo "❌ Invalid option."; exit 1 ;;
esac

echo "✅ Done!"

        ;;
esac

echo "✅ Done!"
