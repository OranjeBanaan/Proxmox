#!/bin/bash
set -e

# Execute with: bash <(curl -fsSL https://raw.githubusercontent.com/OranjeBanaan/Proxmox/main/InstallScriptNewNode.sh) 
echo "🔧 Replacing Proxmox and Ceph enterprise repos with no-subscription versions..."

# Backup and replace pve-enterprise.list
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    cp /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak
    echo "# Replaced by script" > /etc/apt/sources.list.d/pve-enterprise.list
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" >> /etc/apt/sources.list.d/pve-enterprise.list
fi

# Backup and replace ceph.list
if [ -f /etc/apt/sources.list.d/ceph.list ]; then
    cp /etc/apt/sources.list.d/ceph.list /etc/apt/sources.list.d/ceph.list.bak
    echo "# Replaced by script" > /etc/apt/sources.list.d/ceph.list
    echo "deb http://download.proxmox.com/debian/ceph-quincy bookworm pve-no-subscription" >> /etc/apt/sources.list.d/ceph.list
fi

# Update and upgrade
echo "📦 Updating system..."
apt update && apt upgrade -y

# Install nginx
echo "📥 Installing nginx..."
apt install -y nginx

# Remove default config
echo "🧹 Removing default nginx site..."
rm -f /etc/nginx/sites-enabled/default

# Get Proxmox hostname
HOSTNAME=$(hostname -f)

# Create proxmox.conf
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

# Test nginx config
echo "🔍 Testing nginx configuration..."
if ! nginx -t; then
    echo "❌ NGINX configuration test failed. Aborting."
    exit 1
fi

# Restart nginx
echo "🔄 Restarting nginx..."
systemctl restart nginx

# Modify systemd unit
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

# Download and run TemplateGenerator
echo "📥 Downloading TemplateGenerator..."
curl -fsSL https://raw.githubusercontent.com/OranjeBanaan/Proxmox/main/TemplateGenerator.txt -o /usr/local/bin/TemplateGenerator
chmod +x /usr/local/bin/TemplateGenerator
echo "🚀 Running TemplateGenerator..."
/usr/local/bin/TemplateGenerator

echo "✅ All done!"
