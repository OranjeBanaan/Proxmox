#!/bin/bash

set -e

# Install nginx
echo "Installing nginx..."
apt update && apt install -y nginx

# Remove default config
echo "Removing default site..."
rm -f /etc/nginx/sites-enabled/default

# Get the Proxmox hostname
HOSTNAME=$(hostname -f)

# Create proxy config
echo "Creating /etc/nginx/conf.d/proxmox.conf..."
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
echo "Testing nginx configuration..."
if ! nginx -t; then
    echo "❌ NGINX configuration test failed. Aborting."
    exit 1
fi

# Restart nginx
echo "Restarting nginx..."
systemctl restart nginx

# Inject dependency into systemd unit
echo "Modifying nginx.service systemd override..."
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/override.conf <<EOF
[Unit]
Requires=pve-cluster.service
After=pve-cluster.service
EOF

# Reload systemd and nginx
systemctl daemon-reexec
systemctl daemon-reload
systemctl restart nginx

echo "✅ NGINX reverse proxy for Proxmox has been configured."
