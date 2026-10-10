#!/bin/bash
# Disable strict error checking for reliable installation
set +e

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

clear
echo "============================================================"
echo "      Guruz GH - Standalone VPN Installer                   "
echo "    (Hysteria + UDP Custom + ZiVPN + SocksIP)               "
echo "============================================================"
echo ""

# Get Server IP
IPADDR=$(curl -4 -s --max-time 2 ipv4.icanhazip.com || hostname -I | awk '{print $1}')

# Variables & Prompts
HYST_PORT="36712"
UDP_CUSTOM_PORT="36717"
ZIVPN_PORT="5667"
_default_obfs=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
_default_password="user:$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"

read -e -p "Enter your Domain/Subdomain [${IPADDR}]: " -i "${IPADDR}" DOMAIN
DOMAIN="${DOMAIN:-${IPADDR}}"

read -e -p "Enter Hysteria & ZiVPN obfuscation string [${_default_obfs}]: " -i "${_default_obfs}" OBFS
OBFS="${OBFS:-${_default_obfs}}"

read -e -p "Enter Hysteria auth_str (name:password) [${_default_password}]: " -i "${_default_password}" PASSWORD
PASSWORD="${PASSWORD:-${_default_password}}"
if [[ "$PASSWORD" != *:* || "$PASSWORD" == :* || "$PASSWORD" == *: ]]; then
  echo "Invalid Hysteria auth_str: enter it as name:password (both parts required)."
  exit 1
fi

echo ""
echo "Installing dependencies..."
apt-get update -y
apt-get install -y curl jq iptables iptables-persistent netfilter-persistent gnupg2 lsb-release cron openssl

# Setup Directories Early
mkdir -p /etc/hysteria
mkdir -p /etc/zivpn
echo "$DOMAIN" > /etc/hysteria/domain.txt

# ==========================================
# AGGRESSIVE SYSTEM & CONNTRACK TUNING
# ==========================================
echo "Applying Aggressive System & Conntrack Tuning..."
modprobe nf_conntrack 2>/dev/null || true
echo "nf_conntrack" > /etc/modules-load.d/freenet.conf

cat <<'SYSCTL' > /etc/sysctl.d/99-freenet-tuning.conf
# File Descriptors
fs.file-max = 1048576

# Network Core
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384

# TCP Settings
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 10

# SOCKS / WARP Local Loopback Optimization
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_mtu_probing = 1

# Connection Tracking Limits
net.netfilter.nf_conntrack_max = 2097152
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.netfilter.nf_conntrack_udp_timeout = 60

# ZiVPN Required Socket Buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216

# Native BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
sysctl --system >/dev/null 2>&1 || true

mkdir -p /etc/security/limits.d
cat <<'LIMITS' > /etc/security/limits.d/99-freenet.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
LIMITS

# 1. Install & Configure Cloudflare WARP
echo "Installing Cloudflare WARP..."
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
apt-get update -y && apt-get install -y cloudflare-warp

echo "Registering WARP and setting to proxy mode..."
warp-cli --accept-tos registration delete 2>/dev/null || true
warp-cli --accept-tos registration new 2>/dev/null || warp-cli --accept-tos register
warp-cli --accept-tos mode proxy
warp-cli --accept-tos proxy port 40000
warp-cli --accept-tos connect
sleep 2

# 2. Install Sing-box (Pinned version)
echo "Installing Stable Sing-box v1.12.22..."
wget -qO /tmp/sing-box.deb "https://github.com/SagerNet/sing-box/releases/download/v1.12.22/sing-box_1.12.22_linux_amd64.deb"
dpkg -i /tmp/sing-box.deb
apt-mark hold sing-box
rm -f /tmp/sing-box.deb
systemctl disable sing-box 2>/dev/null || true

# 3. Setup Certificates (Shared between Hysteria and ZiVPN)
touch /etc/hysteria/users.txt
touch /etc/zivpn/users.txt

echo "Generating a fresh certificate for this server..."
if [[ "$DOMAIN" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  TLS_SAN="IP:$DOMAIN"
else
  TLS_SAN="DNS:$DOMAIN"
fi
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -keyout /etc/hysteria/hysteria.key -out /etc/hysteria/hysteria.crt \
  -subj "/CN=$DOMAIN" \
  -addext "subjectAltName=$TLS_SAN" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth"
cp /etc/hysteria/hysteria.crt /etc/zivpn/zivpn.crt
cp /etc/hysteria/hysteria.key /etc/zivpn/zivpn.key
chmod 644 /etc/hysteria/hysteria.crt /etc/zivpn/zivpn.crt
chmod 600 /etc/hysteria/hysteria.key /etc/zivpn/zivpn.key

# 4. Generate Sing-box Configuration
echo "Generating Sing-box Configuration..."
cat > /etc/hysteria/config.json <<EOF
{
  "log": { "level": "fatal" },
  "inbounds": [
    {
      "type": "hysteria",
      "tag": "hy1-inbound",
      "listen": "::",
      "listen_port": $HYST_PORT,
      "up_mbps": 100,
      "down_mbps": 100,
      "obfs": "$OBFS",
      "users": [ { "auth_str": "$PASSWORD" } ],
      "tls": {
        "enabled": true,
        "certificate_path": "/etc/hysteria/hysteria.crt",
        "key_path": "/etc/hysteria/hysteria.key"
      }
    }
  ],
  "outbounds": [
    {
      "type": "socks",
      "tag": "warp-proxy",
      "server": "127.0.0.1",
      "server_port": 40000
    },
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "rules": [
      {
        "inbound": "hy1-inbound",
        "network": "tcp",
        "outbound": "warp-proxy"
      },
      {
        "inbound": "hy1-inbound",
        "network": "udp",
        "outbound": "direct"
      }
    ],
    "auto_detect_interface": true
  }
}
EOF
chmod 600 /etc/hysteria/config.json

# Populate initial user in database
exp_date=$(date -d "+365 days" +"%Y-%m-%d")
echo "$PASSWORD $exp_date" > /etc/hysteria/users.txt
chmod 600 /etc/hysteria/users.txt

# 5. Create Systemd Service
echo "Creating Hysteria Systemd Service..."
cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Sing-Box Hysteria v1 Core
After=network.target
[Service]
User=root
ExecStart=/usr/bin/sing-box run -c /etc/hysteria/config.json
Restart=on-failure
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

# 6. Apply Port Forwarding & NAT Rules
echo "Setting up NAT and IPtables Rules..."
IFACE="$(ip -4 route ls|grep default|grep -Po '(?<=dev )(\S+)'|head -1)"
iptables -C INPUT -p udp --dport "$HYST_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$HYST_PORT" -j ACCEPT
iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport 10000:65000 -j DNAT --to-destination :$HYST_PORT 2>/dev/null || \
  iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport 10000:65000 -j DNAT --to-destination :$HYST_PORT
iptables -t nat -C PREROUTING -i "$IFACE" -p udp --dport 443 -j DNAT --to-destination :$HYST_PORT 2>/dev/null || \
  iptables -t nat -I PREROUTING 1 -i "$IFACE" -p udp --dport 443 -j DNAT --to-destination :$HYST_PORT

cat > /etc/systemd/system/hysteria-nat.service <<EOF
[Unit]
Description=Restore Hysteria UDP NAT rule
After=network-online.target
Wants=network-online.target
Before=hysteria-server.service
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'IFACE=\$(ip -4 route ls|grep default|grep -Po "(?<=dev )(\\\\S+)"|head -1); [ -n "\$IFACE" ] && (iptables -t nat -C PREROUTING -i "\$IFACE" -p udp --dport 10000:65000 -j DNAT --to-destination :$HYST_PORT 2>/dev/null || iptables -t nat -A PREROUTING -i "\$IFACE" -p udp --dport 10000:65000 -j DNAT --to-destination :$HYST_PORT)'
ExecStart=/bin/bash -c 'IFACE=\$(ip -4 route ls|grep default|grep -Po "(?<=dev )(\\\\S+)"|head -1); [ -n "\$IFACE" ] && (iptables -t nat -C PREROUTING -i "\$IFACE" -p udp --dport 443 -j DNAT --to-destination :$HYST_PORT 2>/dev/null || iptables -t nat -I PREROUTING 1 -i "\$IFACE" -p udp --dport 443 -j DNAT --to-destination :$HYST_PORT)'
ExecStart=/bin/bash -c 'iptables -C INPUT -p udp --dport $HYST_PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport $HYST_PORT -j ACCEPT'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

# ==========================================
# Install UDP Custom (GitHub Version)
# ==========================================
echo "Installing UDP Custom from GitHub..."

mkdir -p /root/udp
mkdir -p /etc/UDPCustom

# Keep the existing server timezone so account expiry dates remain predictable.

wget -q -O /etc/UDPCustom/module 'https://raw.githubusercontent.com/mahpud896/UDP-Custom/main/module/module' || echo "Skipping module download..."
chmod +x /etc/UDPCustom/module 2>/dev/null || true

wget -q -O /root/udp/udp-custom "https://raw.githubusercontent.com/mahpud896/UDP-Custom/main/bin/udp-custom-linux-amd64" || echo "Skipping UDP-Custom binary..."
chmod +x /root/udp/udp-custom 2>/dev/null || true

wget -q -O /root/udp/config.json "https://raw.githubusercontent.com/mahpud896/UDP-Custom/main/config/config.json" || echo "Skipping config..."
sed -i "s/\":36712\"/\":$UDP_CUSTOM_PORT\"/g" /root/udp/config.json 2>/dev/null || true
chmod 644 /root/udp/config.json 2>/dev/null || true

wget -q -O /etc/UDPCustom/limiter.sh 'https://raw.githubusercontent.com/mahpud896/UDP-Custom/main/module/limiter.sh' || true
wget -q -O /etc/UDPCustom/cek.sh 'https://raw.githubusercontent.com/mahpud896/UDP-Custom/main/module/cek.sh' || true
chmod +x /etc/UDPCustom/limiter.sh /etc/UDPCustom/cek.sh 2>/dev/null || true

wget -q -O /bin/udpgw 'https://raw.githubusercontent.com/mahpud896/UDP-Custom/main/module/udpgw' || true
chmod +x /bin/udpgw 2>/dev/null || true

wget -q -O /usr/bin/udp 'https://raw.githubusercontent.com/mahpud896/UDP-Custom/main/module/udp' || true
chmod +x /usr/bin/udp 2>/dev/null || true

wget -q -O /etc/systemd/system/udpgw.service 'https://raw.githubusercontent.com/mahpud896/UDP-Custom/main/config/udpgw.service' || true
wget -q -O /etc/systemd/system/udp-custom.service 'https://raw.githubusercontent.com/mahpud896/UDP-Custom/main/config/udp-custom.service' || true
chmod 640 /etc/systemd/system/udpgw.service /etc/systemd/system/udp-custom.service 2>/dev/null || true

# ==========================================
# Install ZiVPN (GitHub Version)
# ==========================================
echo "Installing ZiVPN from GitHub..."

wget -q -O /usr/local/bin/zivpn "https://github.com/zahidbd2/udp-zivpn/releases/download/udp-zivpn_1.4.9/udp-zivpn-linux-amd64" || echo "Skipping ZiVPN binary..."
chmod +x /usr/local/bin/zivpn 2>/dev/null || true

cat > /etc/zivpn/config.json <<EOF
{
  "listen": ":$ZIVPN_PORT",
   "cert": "/etc/zivpn/zivpn.crt",
   "key": "/etc/zivpn/zivpn.key",
   "obfs":"$OBFS",
   "auth": {
    "mode": "passwords", 
    "config": ["$PASSWORD"]
  }
}
EOF
chmod 600 /etc/zivpn/config.json 2>/dev/null || true
echo "$PASSWORD $exp_date" > /etc/zivpn/users.txt
chmod 600 /etc/zivpn/users.txt

cat > /etc/systemd/system/zivpn.service <<EOF
[Unit]
Description=zivpn VPN Server
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn
ExecStart=/usr/local/bin/zivpn server -c /etc/zivpn/config.json
Restart=always
RestartSec=3
Environment=ZIVPN_LOG_LEVEL=fatal
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/zivpn-nat.service <<EOF
[Unit]
Description=Restore ZiVPN UDP NAT rules
After=network-online.target
Wants=network-online.target
Before=zivpn.service
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'IFACE=\$(ip -4 route ls|grep default|grep -Po "(?<=dev )(\\\\S+)"|head -1); [ -n "\$IFACE" ] && (iptables -t nat -C PREROUTING -i "\$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :$ZIVPN_PORT 2>/dev/null || iptables -t nat -A PREROUTING -i "\$IFACE" -p udp --dport 6000:19999 -j DNAT --to-destination :$ZIVPN_PORT)'
ExecStart=/bin/bash -c 'iptables -C INPUT -p udp --dport $ZIVPN_PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport $ZIVPN_PORT -j ACCEPT'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

# ==========================================
# Install SocksIP UDP Server
# ==========================================
echo "Installing SocksIP UDP Server..."

wget -q -O /usr/bin/udpServer "https://bitbucket.org/iopmx/udprequestserver/downloads/udpServer" || echo "Skipping SocksIP binary..."
chmod +x /usr/bin/udpServer 2>/dev/null || true

# Fetch the active network interface
IFACE="$(ip -4 route ls|grep default|grep -Po '(?<=dev )(\S+)'|head -1)"

cat > /etc/systemd/system/udp-socksip.service <<EOF
[Unit]
Description=SocksIP UDP Server
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/udpServer -ip=$IPADDR -net=\${IFACE} -mode=system -exclude=53,443,$HYST_PORT,$UDP_CUSTOM_PORT,$ZIVPN_PORT
Restart=always
RestartSec=3s
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

# Start and Enable All Additional Services (Allow errors to output without aborting)
echo "Starting services..."
systemctl daemon-reload
systemctl enable --now udpgw || echo "Warning: udpgw failed to start."
systemctl enable --now udp-custom || echo "Warning: udp-custom failed to start."
systemctl enable --now zivpn-nat.service || echo "Warning: zivpn-nat failed to start."
systemctl enable --now zivpn.service || echo "Warning: zivpn failed to start."
systemctl enable --now udp-socksip || echo "Warning: udp-socksip failed to start."

# 7. Create the Command Line Menu (vc)
echo "Installing Custom Menu (vc)..."
cat << 'EOF_MENU' > /usr/local/bin/vc
#!/bin/bash
umask 077

# --- System Variables ---
MY_OBFS="OBFS_PLACEHOLDER"
MY_PORT="PORT_PLACEHOLDER"

# --- Styling ---
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'

CONFIG="/etc/hysteria/config.json"
USER_DB="/etc/hysteria/users.txt"
ZIVPN_CONFIG="/etc/zivpn/config.json"
ZIVPN_USER_DB="/etc/zivpn/users.txt"
touch "$USER_DB" "$ZIVPN_USER_DB" 2>/dev/null

# Dynamically fetch domain
MY_DOMAIN=$(cat /etc/hysteria/domain.txt 2>/dev/null || curl -4 -s --max-time 2 ipv4.icanhazip.com)

# --- Header Functions ---
get_ip() { curl -4 -s --max-time 2 ipv4.icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}'; }
get_os() { source /etc/os-release 2>/dev/null; echo "${ID^^} ${VERSION_ID}"; }
get_arch() { uname -m; }
get_cores() { nproc 2>/dev/null || echo "1"; }
get_time() { date '+%H:%M %Z'; }
get_ram() { free 2>/dev/null | awk '/Mem:/ { if ($2>0) printf "%.1f%%", ($3/$2)*100; else print "0.0%" }'; }
get_buffer() { free -m 2>/dev/null | awk '/Mem:/ {print $6 "MB"}'; }
check_status() { 
    local ok=0
    systemctl is-active --quiet hysteria-server 2>/dev/null && ok=$((ok+1))
    systemctl is-active --quiet udp-custom 2>/dev/null && ok=$((ok+1))
    systemctl is-active --quiet zivpn 2>/dev/null && ok=$((ok+1))
    systemctl is-active --quiet udp-socksip 2>/dev/null && ok=$((ok+1))
    [ "$ok" -ge 3 ] && echo -e "${GREEN}ONLINE${NC}" || echo -e "${RED}DEGRADED${NC}"
}
pause_return() { echo ""; read -rp "Press ENTER to return to menu... " _; }

# --- Menu Functions: Hysteria ---
add_hysteria_user() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                 ${BOLD}CREATE HYSTERIA USER${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    read -rp " Enter Hysteria auth_str (name:password): " new_pass
    if [[ "$new_pass" != *:* || "$new_pass" == :* || "$new_pass" == *: ]]; then
        echo -e "${RED}Use auth_str format name:password.${NC}"
        pause_return; return
    fi
    
    if grep -qw "^$new_pass" "$USER_DB" 2>/dev/null || jq -e ".inbounds[0].users[] | select(.auth_str == \"$new_pass\")" "$CONFIG" >/dev/null; then
        echo -e "\n${RED}Error: User/Password already exists!${NC}"
        pause_return; return
    fi

    read -rp " Validity (Days): " days
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then echo -e "${RED}Invalid number.${NC}"; pause_return; return; fi
    exp_date=$(date -d "+${days} days" +"%Y-%m-%d")
    
    jq ".inbounds[0].users += [{\"auth_str\": \"$new_pass\"}]" "$CONFIG" > /tmp/h.json && mv /tmp/h.json "$CONFIG"
    echo "$new_pass $exp_date" >> "$USER_DB"
    systemctl restart hysteria-server
    
    echo -e "\n${GREEN}✔ User created successfully!${NC}"
    echo -e "${CYAN}--------------------------------------------------------------${NC}"
    echo -e " ${BOLD}IP:${NC}          ${YELLOW}$(get_ip)${NC}"
    echo -e " ${BOLD}Domain:${NC}      ${YELLOW}${MY_DOMAIN}${NC}"
    echo -e " ${BOLD}Ports:${NC}       ${YELLOW}UDP 443, 10000-65000 (-> ${MY_PORT})${NC}"
    echo -e " ${BOLD}User (Pass):${NC} ${YELLOW}${new_pass}${NC}"
    echo -e " ${BOLD}Obfs:${NC}        ${YELLOW}${MY_OBFS}${NC}"
    echo -e " ${BOLD}Expiry Date:${NC} ${YELLOW}${exp_date}${NC}"
    echo -e "${CYAN}--------------------------------------------------------------${NC}"
    pause_return
}

del_hysteria_user() {
    clear
    echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                 ${BOLD}DELETE HYSTERIA USER${NC}"
    echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
    if [ ! -s "$USER_DB" ]; then echo -e "No users found."; pause_return; return; fi
    
    cat -n "$USER_DB" | awk '{print " ["$1"] User: "$2" | Exp: "$3}'
    echo ""
    read -rp " Enter the ID number of the user to delete: " del_id
    if ! [[ "$del_id" =~ ^[0-9]+$ ]]; then echo -e "${RED}Invalid ID.${NC}"; pause_return; return; fi

    del_pass=$(sed -n "${del_id}p" "$USER_DB" | awk '{print $1}')
    if [ -z "$del_pass" ]; then echo -e "${RED}User ID not found.${NC}"; pause_return; return; fi

    jq ".inbounds[0].users |= map(select(.auth_str != \"$del_pass\"))" "$CONFIG" > /tmp/h.json && mv /tmp/h.json "$CONFIG"
    sed -i "${del_id}d" "$USER_DB"
    systemctl restart hysteria-server
    echo -e "\n${GREEN}✔ User '$del_pass' deleted successfully!${NC}"
    pause_return
}

extend_hysteria_user() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                 ${BOLD}EXTEND HYSTERIA USER${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    if [ ! -s "$USER_DB" ]; then echo -e "No users found."; pause_return; return; fi

    cat -n "$USER_DB" | awk '{print " ["$1"] User: "$2" | Exp: "$3}'
    echo ""
    read -rp " Enter the ID number of the user to extend: " ext_id
    if ! [[ "$ext_id" =~ ^[0-9]+$ ]]; then echo -e "${RED}Invalid ID.${NC}"; pause_return; return; fi
    
    ext_pass=$(sed -n "${ext_id}p" "$USER_DB" | awk '{print $1}')
    current_exp=$(sed -n "${ext_id}p" "$USER_DB" | awk '{print $2}')
    if [ -z "$ext_pass" ]; then echo -e "${RED}User ID not found.${NC}"; pause_return; return; fi
    
    read -rp " Add Validity (Days): " days
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then echo -e "${RED}Invalid number.${NC}"; pause_return; return; fi
    
    new_exp=$(date -d "$current_exp + $days days" +"%Y-%m-%d")
    sed -i "${ext_id}s/.*/$ext_pass $new_exp/" "$USER_DB"
    
    echo -e "\n${GREEN}✔ User '$ext_pass' extended successfully!${NC}"
    echo -e " New Expiry: ${YELLOW}$new_exp${NC}"
    pause_return
}

list_hysteria_users() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                   ${BOLD}HYSTERIA USERS LIST${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    if [ ! -s "$USER_DB" ]; then echo -e "\n No active users found.\n"
    else
        printf " %-5s | %-25s | %-15s\n" "ID" "AUTH STRING" "EXPIRY DATE"
        echo -e "${CYAN}--------------------------------------------------------------${NC}"
        cat -n "$USER_DB" | while read -r num user exp; do
            printf " [%-3s] | %-25s | %-15s\n" "$num" "$user" "$exp"
        done
        echo -e "${CYAN}--------------------------------------------------------------${NC}"
        echo -e " Total Active Users: ${YELLOW}$(wc -l < "$USER_DB")${NC}"
    fi
    pause_return
}

# --- Menu Functions: ZiVPN ---
add_zivpn_user() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                 ${BOLD}CREATE ZIVPN USER${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    read -rp " Enter Password: " new_pass
    
    if grep -qw "^$new_pass" "$ZIVPN_USER_DB" 2>/dev/null; then
        echo -e "\n${RED}Error: User/Password already exists!${NC}"
        pause_return; return
    fi

    read -rp " Validity (Days): " days
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then echo -e "${RED}Invalid number.${NC}"; pause_return; return; fi
    exp_date=$(date -d "+${days} days" +"%Y-%m-%d")
    
    jq ".auth.config += [\"$new_pass\"]" "$ZIVPN_CONFIG" > /tmp/z.json && mv /tmp/z.json "$ZIVPN_CONFIG"
    echo "$new_pass $exp_date" >> "$ZIVPN_USER_DB"
    systemctl restart zivpn.service
    
    echo -e "\n${GREEN}✔ ZiVPN User created successfully!${NC}"
    echo -e "${CYAN}--------------------------------------------------------------${NC}"
    echo -e " ${BOLD}IP:${NC}          ${YELLOW}$(get_ip)${NC}"
    echo -e " ${BOLD}Domain:${NC}      ${YELLOW}${MY_DOMAIN}${NC}"
    echo -e " ${BOLD}Port Range:${NC}  ${YELLOW}6000-19999 (-> 5667)${NC}"
    echo -e " ${BOLD}Auth String:${NC} ${YELLOW}${new_pass}${NC}"
    echo -e " ${BOLD}Obfs:${NC}        ${YELLOW}${MY_OBFS}${NC}"
    echo -e " ${BOLD}Expiry Date:${NC} ${YELLOW}${exp_date}${NC}"
    echo -e "${CYAN}--------------------------------------------------------------${NC}"
    pause_return
}

del_zivpn_user() {
    clear
    echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                 ${BOLD}DELETE ZIVPN USER${NC}"
    echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
    if [ ! -s "$ZIVPN_USER_DB" ]; then echo -e "No users found."; pause_return; return; fi
    
    cat -n "$ZIVPN_USER_DB" | awk '{print " ["$1"] User: "$2" | Exp: "$3}'
    echo ""
    read -rp " Enter the ID number of the user to delete: " del_id
    if ! [[ "$del_id" =~ ^[0-9]+$ ]]; then echo -e "${RED}Invalid ID.${NC}"; pause_return; return; fi

    del_pass=$(sed -n "${del_id}p" "$ZIVPN_USER_DB" | awk '{print $1}')
    if [ -z "$del_pass" ]; then echo -e "${RED}User ID not found.${NC}"; pause_return; return; fi

    jq ".auth.config |= map(select(. != \"$del_pass\"))" "$ZIVPN_CONFIG" > /tmp/z.json && mv /tmp/z.json "$ZIVPN_CONFIG"
    sed -i "${del_id}d" "$ZIVPN_USER_DB"
    systemctl restart zivpn.service
    echo -e "\n${GREEN}✔ User '$del_pass' deleted successfully!${NC}"
    pause_return
}

extend_zivpn_user() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                 ${BOLD}EXTEND ZIVPN USER${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    if [ ! -s "$ZIVPN_USER_DB" ]; then echo -e "No users found."; pause_return; return; fi

    cat -n "$ZIVPN_USER_DB" | awk '{print " ["$1"] User: "$2" | Exp: "$3}'
    echo ""
    read -rp " Enter the ID number of the user to extend: " ext_id
    if ! [[ "$ext_id" =~ ^[0-9]+$ ]]; then echo -e "${RED}Invalid ID.${NC}"; pause_return; return; fi
    
    ext_pass=$(sed -n "${ext_id}p" "$ZIVPN_USER_DB" | awk '{print $1}')
    current_exp=$(sed -n "${ext_id}p" "$ZIVPN_USER_DB" | awk '{print $2}')
    if [ -z "$ext_pass" ]; then echo -e "${RED}User ID not found.${NC}"; pause_return; return; fi
    
    read -rp " Add Validity (Days): " days
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then echo -e "${RED}Invalid number.${NC}"; pause_return; return; fi
    
    new_exp=$(date -d "$current_exp + $days days" +"%Y-%m-%d")
    sed -i "${ext_id}s/.*/$ext_pass $new_exp/" "$ZIVPN_USER_DB"
    
    echo -e "\n${GREEN}✔ User '$ext_pass' extended successfully!${NC}\n New Expiry: ${YELLOW}$new_exp${NC}"
    pause_return
}

list_zivpn_users() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                   ${BOLD}ZIVPN USERS LIST${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    if [ ! -s "$ZIVPN_USER_DB" ]; then echo -e "\n No active users found.\n"
    else
        printf " %-5s | %-25s | %-15s\n" "ID" "PASSWORD" "EXPIRY DATE"
        echo -e "${CYAN}--------------------------------------------------------------${NC}"
        cat -n "$ZIVPN_USER_DB" | while read -r num user exp; do
            printf " [%-3s] | %-25s | %-15s\n" "$num" "$user" "$exp"
        done
        echo -e "${CYAN}--------------------------------------------------------------${NC}"
        echo -e " Total Active Users: ${YELLOW}$(wc -l < "$ZIVPN_USER_DB")${NC}"
    fi
    pause_return
}

# --- Menu Functions: UDP Custom & SocksIP (SSH) ---
list_real_users() { awk -F: '$3 >= 1000 && $1 != "nobody" && $1 != "systemd-network" && $1 != "messagebus" {print $1}' /etc/passwd 2>/dev/null; }

create_ssh_user() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                 ${BOLD}CREATE SSH USER (UDP CUSTOM & SOCKSIP)${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    read -rp " Username: " user
    read -rp " Password: " pass
    read -rp " Validity (Days): " days

    if [ -z "$user" ] || [ -z "$pass" ] || [ -z "$days" ]; then echo -e "\n${RED}Error: All fields are required.${NC}"; pause_return; return; fi
    if id "$user" >/dev/null 2>&1; then echo -e "\n${RED}Error: User '$user' already exists.${NC}"; pause_return; return; fi

    useradd -e "$(date -d "+$days days" +%Y-%m-%d)" -s /bin/false -M "$user" && echo "$user:$pass" | chpasswd
    
    echo -e "\n${GREEN}✔ SSH User created successfully!${NC}"
    echo -e "${CYAN}--------------------------------------------------------------${NC}"
    echo -e " ${BOLD}IP/Domain:${NC}   ${YELLOW}${MY_DOMAIN}${NC}"
    echo -e " ${BOLD}Username:${NC}    ${YELLOW}${user}${NC}"
    echo -e " ${BOLD}Password:${NC}    ${YELLOW}${pass}${NC}"
    echo -e " ${BOLD}UDP Custom:${NC}  ${YELLOW}Port 1-65535${NC}"
    echo -e " ${BOLD}SocksIP:${NC}     ${YELLOW}1-65535${NC}"
    echo -e " ${BOLD}Expiry Date:${NC} ${YELLOW}$(date -d "+$days days" +%Y-%m-%d)${NC}"
    echo -e "${CYAN}--------------------------------------------------------------${NC}"
    pause_return
}

delete_ssh_user() {
    clear
    echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                 ${BOLD}DELETE SSH USER${NC}"
    echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
    mapfile -t USERS < <(list_real_users)
    if [ "${#USERS[@]}" -eq 0 ]; then echo -e "${RED}No active user accounts found.${NC}"; pause_return; return; fi
    
    for i in "${!USERS[@]}"; do printf "  [${YELLOW}%02d${NC}] %s\n" $((i+1)) "${USERS[$i]}"; done
    echo -e "\n  [${YELLOW}00${NC}] Cancel\n"
    
    read -rp "  Select user to delete: " idx
    if [[ "$idx" == "00" || "$idx" == "0" ]]; then return; fi
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#USERS[@]}" ]; then echo -e "${RED}Invalid selection.${NC}"; pause_return; return; fi
    
    SELECTED_USER="${USERS[$((idx-1))]}"
    pkill -u "$SELECTED_USER" 2>/dev/null
    userdel -f "$SELECTED_USER" 2>/dev/null
    echo -e "\n${GREEN}✔ User $SELECTED_USER deleted successfully.${NC}"
    pause_return
}

extend_ssh_user() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                 ${BOLD}EXTEND SSH USER${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    mapfile -t USERS < <(list_real_users)
    if [ "${#USERS[@]}" -eq 0 ]; then echo -e "${RED}No active user accounts found.${NC}"; pause_return; return; fi
    
    for i in "${!USERS[@]}"; do printf "  [${YELLOW}%02d${NC}] %s\n" $((i+1)) "${USERS[$i]}"; done
    echo -e "\n  [${YELLOW}00${NC}] Cancel\n"
    
    read -rp "  Select user to extend: " idx
    if [[ "$idx" == "00" || "$idx" == "0" ]]; then return; fi
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "${#USERS[@]}" ]; then echo -e "${RED}Invalid selection.${NC}"; pause_return; return; fi
    
    SELECTED_USER="${USERS[$((idx-1))]}"
    read -rp "  Add Validity (Days): " days
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then echo -e "${RED}Invalid number.${NC}"; pause_return; return; fi
    
    current=$(chage -l "$SELECTED_USER" 2>/dev/null | awk -F": " '/Account expires/ {print $2}')
    if [ "$current" = "never" ] || [ -z "$current" ]; then new_exp=$(date -d "+$days days" +%Y-%m-%d)
    else new_exp=$(date -d "$current +$days days" +%Y-%m-%d); fi
    
    chage -E "$new_exp" "$SELECTED_USER"
    echo -e "\n${GREEN}✔ User '$SELECTED_USER' extended successfully!${NC}\n New Expiry: ${YELLOW}$new_exp${NC}"
    pause_return
}

udp_custom_menu() {
    while true; do
        clear; draw_header
        echo -e "  --- 🚀 ${BOLD}UDP CUSTOM & SOCKSIP MANAGEMENT${NC} ---"
        echo -e "  [${YELLOW}1${NC}] Create SSH User (For UDP Custom & SocksIP)"
        echo -e "  [${YELLOW}2${NC}] Delete SSH User"
        echo -e "  [${YELLOW}3${NC}] Extend SSH User"
        echo -e "  [${YELLOW}4${NC}] List All Active SSH Users"
        echo -e "  [${CYAN}5${NC}] Open Advanced GitHub UDP Module"
        echo -e "  [${YELLOW}0${NC}] Back to Main Menu\n"
        read -rp "  ► Select an option: " opt
        case "$opt" in
            1) create_ssh_user ;; 2) delete_ssh_user ;; 3) extend_ssh_user ;; 4) list_real_users | nl -w2 -s'. '; pause_return ;;
            5) if [ -x /usr/bin/udp ]; then /usr/bin/udp; else echo "Not installed"; sleep 2; fi ;;
            0) break ;; *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

# --- Menu Functions: System ---
edit_speed() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                 ${BOLD}EDIT HYSTERIA UP/DOWN SPEEDS${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    current_up=$(jq -r '.inbounds[0].up_mbps' "$CONFIG")
    current_down=$(jq -r '.inbounds[0].down_mbps' "$CONFIG")
    
    echo -e " Current Upload:   ${YELLOW}${current_up} Mbps${NC}"
    echo -e " Current Download: ${YELLOW}${current_down} Mbps${NC}\n"
    read -rp " Enter New Upload Speed (Mbps): " new_up
    read -rp " Enter New Download Speed (Mbps): " new_down
    
    if [[ "$new_up" =~ ^[0-9]+$ ]] && [[ "$new_down" =~ ^[0-9]+$ ]]; then
        jq ".inbounds[0].up_mbps = $new_up | .inbounds[0].down_mbps = $new_down" "$CONFIG" > /tmp/h.json && mv /tmp/h.json "$CONFIG"
        systemctl restart hysteria-server
        echo -e "\n${GREEN}✔ Speeds updated successfully!${NC}"
    else echo -e "\n${RED}Invalid input. Numbers only.${NC}"; fi
    pause_return
}

change_domain() {
    clear
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                 ${BOLD}CHANGE SERVER DOMAIN${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    current_dom=$(cat /etc/hysteria/domain.txt 2>/dev/null || echo "Not Set")
    echo -e " Current Domain/IP: ${YELLOW}$current_dom${NC}\n"
    read -rp " Enter New Domain or IP: " new_dom
    if [ -n "$new_dom" ]; then
        echo "$new_dom" > /etc/hysteria/domain.txt; MY_DOMAIN="$new_dom"
        echo -e "\n${GREEN}✔ Domain successfully updated to: $new_dom${NC}"
    else echo -e "\n${RED}Action cancelled.${NC}"; fi
    pause_return
}

uninstall_services() {
    clear
    echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
    echo -e "                   ${BOLD}UNINSTALL ALL SERVICES${NC}"
    echo -e "${RED}══════════════════════════════════════════════════════════════${NC}"
    read -rp " Are you absolutely sure? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        systemctl stop hysteria-server hysteria-nat udp-custom udpgw zivpn zivpn-nat udp-socksip 2>/dev/null || true
        systemctl disable hysteria-server hysteria-nat udp-custom udpgw zivpn zivpn-nat udp-socksip 2>/dev/null || true
        rm -rf /etc/hysteria /root/udp /etc/UDPCustom /etc/zivpn /usr/local/bin/zivpn /usr/bin/udpServer
        rm -f /etc/systemd/system/hysteria-*.service /etc/systemd/system/udp*.service /etc/systemd/system/zivpn*.service /etc/systemd/system/udp-socksip.service
        rm -f /etc/cron.d/hysteria-expiry /etc/cron.d/vpn-expiry /etc/cron.d/drop-cache
        warp-cli --accept-tos disconnect 2>/dev/null || true
        warp-cli --accept-tos registration delete 2>/dev/null || true
        apt-get remove --purge -y cloudflare-warp 2>/dev/null || true
        systemctl daemon-reload
        echo -e "\n${GREEN}✔ Hysteria, UDP Custom, ZiVPN, SocksIP, and WARP completely removed.${NC}"
        rm -f /usr/local/bin/vc
        exit 0
    fi
}

draw_header() {
    local ip=$(get_ip)
    local os=$(get_os)
    local arch=$(get_arch)
    local cores=$(get_cores)
    local time=$(get_time)
    local ram=$(get_ram)
    local buf=$(get_buffer)

    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}        >>>>>  🐉  ${YELLOW}${BOLD}Guruz GH Server Menu${NC}${BLUE}  🐉  <<<<<${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    printf "  ${WHITE}%-7s${NC} ${YELLOW}%-20s${NC} ${WHITE}%-8s${NC} ${YELLOW}%s${NC}\n" "IP:" "$ip" "Domain:" "${MY_DOMAIN:-Not Set}"
    printf "  ${WHITE}%-7s${NC} ${YELLOW}%-20s${NC} ${WHITE}%-8s${NC} ${YELLOW}%s${NC}\n" "OS:" "$os" "Arch:" "$arch ($cores Cores)"
    printf "  ${WHITE}%-7s${NC} ${YELLOW}%-20s${NC} ${WHITE}%-8s${NC} %s\n" "Time:" "$time" "Status:" "$(check_status)"
    printf "  ${WHITE}%-7s${NC} ${YELLOW}%-20s${NC} ${WHITE}%-8s${NC} ${YELLOW}%s${NC}\n" "RAM:" "$ram" "Buffer:" "$buf"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
}

system_menu() {
    while true; do
        clear; draw_header
        echo -e "  --- ⚙️ ${BOLD}SERVER SETTINGS${NC} ---"
        echo -e "  [${YELLOW}1${NC}] Restart All Services"
        echo -e "  [${YELLOW}2${NC}] Change Server Domain/IP"
        echo -e "  [${YELLOW}3${NC}] Edit Hysteria Up/Down Speeds"
        echo -e "  [${RED}4${NC}] Uninstall All VPN Services"
        echo -e "  [${RED}5${NC}] Reboot Server"
        echo -e "  [${YELLOW}0${NC}] Back to Main Menu\n"
        read -rp "  ► Select an option: " opt
        case "$opt" in
            1) systemctl restart hysteria-server udp-custom.service udpgw.service zivpn.service zivpn-nat.service udp-socksip.service; echo -e "${GREEN}✔ Services Restarted!${NC}"; pause_return ;;
            2) change_domain ;; 3) edit_speed ;; 4) uninstall_services ;;
            5) read -rp "Reboot server now? [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]] && reboot ;;
            0) break ;; *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
        esac
    done
}

# --- Main Loop ---
while true; do
    clear
    draw_header
    echo -e "  [${YELLOW}1${NC}] 🐉 Hysteria Protocol Management"
    echo -e "  [${YELLOW}2${NC}] 🚀 UDP Custom & SocksIP Management"
    echo -e "  [${YELLOW}3${NC}] 🟢 ZiVPN Protocol Management"
    echo -e "  [${YELLOW}4${NC}] ⚙️ Server & Service Settings"
    echo -e "  [${RED}0${NC}] Exit\n"
    read -rp "  ► Select an option: " main_opt

    case "$main_opt" in
        1) hysteria_menu ;;
        2) udp_custom_menu ;;
        3) zivpn_menu ;;
        4) system_menu ;;
        0) clear; exit 0 ;;
        *) echo -e "${RED}Invalid option.${NC}"; sleep 1 ;;
    esac
done
EOF_MENU

# Inject Variables into Menu
sed -i "s|OBFS_PLACEHOLDER|$OBFS|g" /usr/local/bin/vc
sed -i "s|PORT_PLACEHOLDER|$HYST_PORT|g" /usr/local/bin/vc

chmod +x /usr/local/bin/vc

# 8. Automated Expiry & Maintenance Tracking (Now covering Hysteria & ZiVPN)
echo "Setting up Automated Expiry tracking..."
cat << 'EOF_EXP' > /usr/local/bin/vpn-expiry-check
#!/bin/bash
umask 077
now=$(date +%Y-%m-%d)

# 1. HYSTERIA EXPIRY
HYST_USER_DB="/etc/hysteria/users.txt"
HYST_CONFIG="/etc/hysteria/config.json"
h_changed=0

if [ -f "$HYST_USER_DB" ]; then
  mapfile -t expired_users < <(awk -v d="$now" '$2 < d {print $1}' "$HYST_USER_DB")
  for user in "${expired_users[@]}"; do
    jq ".inbounds[0].users |= map(select(.auth_str != \"$user\"))" "$HYST_CONFIG" > /tmp/h.json && mv /tmp/h.json "$HYST_CONFIG"
    sed -i "/^$user /d" "$HYST_USER_DB"
    h_changed=1
  done
  if [ "$h_changed" -eq 1 ]; then
    systemctl restart hysteria-server
  fi
fi

# 2. ZIVPN EXPIRY
ZIVPN_USER_DB="/etc/zivpn/users.txt"
ZIVPN_CONFIG="/etc/zivpn/config.json"
z_changed=0

if [ -f "$ZIVPN_USER_DB" ]; then
  mapfile -t z_expired_users < <(awk -v d="$now" '$2 < d {print $1}' "$ZIVPN_USER_DB")
  for user in "${z_expired_users[@]}"; do
    jq ".auth.config |= map(select(. != \"$user\"))" "$ZIVPN_CONFIG" > /tmp/z.json && mv /tmp/z.json "$ZIVPN_CONFIG"
    sed -i "/^$user /d" "$ZIVPN_USER_DB"
    z_changed=1
  done
  if [ "$z_changed" -eq 1 ]; then
    systemctl restart zivpn.service
  fi
fi
EOF_EXP

chmod +x /usr/local/bin/vpn-expiry-check
echo "0 0 * * * root /usr/local/bin/vpn-expiry-check >/dev/null 2>&1" > /etc/cron.d/vpn-expiry

# Save rules to persist on reboot
netfilter-persistent save >/dev/null 2>&1 || true

echo ""
echo "============================================================"
echo "              Installation Complete!                        "
echo "============================================================"
echo "Domain:             $DOMAIN"
echo "Hysteria UDP:       443 and 10000-65000 (Forwarded to $HYST_PORT)"
echo "Hysteria Obfs:      $OBFS"
echo "UDP Custom Port:    $UDP_CUSTOM_PORT"
echo "ZiVPN Port:         6000-19999 (Forwarded to $ZIVPN_PORT)"
echo "ZiVPN Obfs:         $OBFS"
echo "SocksIP UDP:        System Mode (Excluded Ports: 53, 443, $HYST_PORT, $UDP_CUSTOM_PORT, $ZIVPN_PORT)"
echo "Default Hysteria auth_str: $PASSWORD"
echo "============================================================"
echo "          Type 'vc' from anywhere to access menu!           "
echo "============================================================"
