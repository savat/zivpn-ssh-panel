#!/usr/bin/env bash
# Hysteria 1 UDP server installer and account manager for Ubuntu 20.04.
# Uses official Hysteria v1.3.5 binary; no install key is required.
set -Eeuo pipefail

APP="hysteria1"
VERSION="v1.3.5"
BASE_DIR="/etc/hysteria1"
SETTINGS_FILE="$BASE_DIR/settings.json"
DB_FILE="$BASE_DIR/accounts.json"
CONFIG_FILE="$BASE_DIR/server.json"
CERT_FILE="$BASE_DIR/server.crt"
KEY_FILE="$BASE_DIR/server.key"
BIN_FILE="/usr/local/bin/hysteria1"
MANAGER_FILE="/usr/local/sbin/hysteria1-manager"

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[hysteria1] $*"; }
need_root() {
  local mode="$1"; shift
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || fail "ต้องใช้ root หรือ sudo"
    exec sudo -E bash "$0" "$mode" "$@"
  fi
}

is_installed() { [[ -x "$BIN_FILE" && -f "$SETTINGS_FILE" && -f "$DB_FILE" ]]; }
load_settings() {
  [[ -r "$SETTINGS_FILE" ]] || fail "ยังไม่ได้ติดตั้ง ใช้: sudo bash $0 install"
  LISTEN_PORT=$(jq -r '.listen_port' "$SETTINGS_FILE")
  RANGE_START=$(jq -r '.range_start' "$SETTINGS_FILE")
  RANGE_END=$(jq -r '.range_end' "$SETTINGS_FILE")
  OBFS=$(jq -r '.obfs' "$SETTINGS_FILE")
}

valid_user() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,48}$ ]]; }
valid_days() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 36500 )); }

write_db_from_stdin() {
  local tmp
  tmp=$(mktemp "$BASE_DIR/accounts.XXXXXX")
  cat > "$tmp"
  jq -e '.users | type == "array"' "$tmp" >/dev/null || { rm -f "$tmp"; fail "รูปแบบฐานข้อมูลบัญชีไม่ถูกต้อง"; }
  chown root:root "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$DB_FILE"
}

render_config() {
  load_settings
  local now auth_list tmp
  now=$(date +%s)
  auth_list=$(jq -c --argjson now "$now" '[.users[] | select(.expires_at > $now) | (.username + ":" + .password)]' "$DB_FILE")
  tmp=$(mktemp "$BASE_DIR/server.XXXXXX")
  jq -n \
    --arg listen "0.0.0.0:${LISTEN_PORT}" \
    --arg cert "$CERT_FILE" \
    --arg key "$KEY_FILE" \
    --arg obfs "$OBFS" \
    --argjson accounts "$auth_list" \
    '{listen:$listen, cert:$cert, key:$key, obfs:$obfs, auth:{mode:"passwords",config:$accounts}}' > "$tmp"
  chown root:hysteria1 "$tmp"
  chmod 640 "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}

restart_server() {
  render_config
  systemctl restart hysteria1.service
  info "อัปเดต config และรีสตาร์ตบริการแล้ว"
}

expire_accounts() {
  is_installed || exit 0
  local now before after tmp
  now=$(date +%s)
  before=$(jq '.users | length' "$DB_FILE")
  tmp=$(mktemp "$BASE_DIR/accounts.XXXXXX")
  jq --argjson now "$now" '{users:[.users[] | select(.expires_at > $now)]}' "$DB_FILE" > "$tmp"
  after=$(jq '.users | length' "$tmp")
  if (( after != before )); then
    chown root:root "$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$DB_FILE"
    render_config
    systemctl restart hysteria1.service
    info "นำบัญชีหมดอายุออกแล้ว ($((before-after)) บัญชี)"
  else
    rm -f "$tmp"
  fi
}

port_forward() {
  load_settings
  local action="$1"
  case "$action" in
    apply)
      iptables -t nat -C PREROUTING -p udp --dport "${RANGE_START}:${RANGE_END}" -j REDIRECT --to-ports "$LISTEN_PORT" 2>/dev/null || \
        iptables -t nat -A PREROUTING -p udp --dport "${RANGE_START}:${RANGE_END}" -j REDIRECT --to-ports "$LISTEN_PORT"
      ;;
    remove)
      while iptables -t nat -C PREROUTING -p udp --dport "${RANGE_START}:${RANGE_END}" -j REDIRECT --to-ports "$LISTEN_PORT" 2>/dev/null; do
        iptables -t nat -D PREROUTING -p udp --dport "${RANGE_START}:${RANGE_END}" -j REDIRECT --to-ports "$LISTEN_PORT"
      done
      ;;
    *) fail "คำสั่ง port-forward ไม่ถูกต้อง" ;;
  esac
}

print_client_config() {
  local host="$1" username="$2" password="$3"
  load_settings
  jq -n \
    --arg server "${host}:${RANGE_START}-${RANGE_END}" \
    --arg auth "${username}:${password}" \
    --arg obfs "$OBFS" \
    '{server:$server,auth_str:$auth,obfs:$obfs,up_mbps:100,down_mbps:100,hop_interval:10,insecure:true,socks5:{listen:"127.0.0.1:1080"}}'
}

install_server() {
  need_root install
  [[ -r /etc/os-release ]] || fail "ตรวจรุ่น Ubuntu ไม่ได้"
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "20.04" ]] || fail "สคริปต์นี้กำหนดเป้าหมาย Ubuntu 20.04; ระบบปัจจุบันคือ ${PRETTY_NAME:-unknown}"
  [[ ! -e "$SETTINGS_FILE" ]] || fail "พบการติดตั้งเดิมที่ $BASE_DIR; เรียก sudo hysteria1-manager เพื่อจัดการ"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl jq openssl iptables ufw

  local arch asset url start end listen obfs username password days now expiry
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv7l|armv6l) arch="arm" ;;
    *) fail "ไม่รองรับสถาปัตยกรรม $(uname -m); ตรวจรายการไบนารี v1.3.5 ทางการก่อน" ;;
  esac
  asset="hysteria-linux-${arch}"
  url="https://github.com/HyNetworks/hysteria/releases/download/${VERSION}/${asset}"
  info "ดาวน์โหลดไบนารีทางการ $VERSION ($asset)"
  curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$url" -o /tmp/hysteria1-download
  install -o root -g root -m 0755 /tmp/hysteria1-download "$BIN_FILE"
  rm -f /tmp/hysteria1-download

  read -r -p "พอร์ตเริ่มต้นช่วง UDP ภายนอก [10000]: " start
  start=${start:-10000}
  read -r -p "พอร์ตสิ้นสุดช่วง UDP ภายนอก [65000]: " end
  end=${end:-65000}
  [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ ]] || fail "พอร์ตต้องเป็นตัวเลข"
  start=$((10#$start)); end=$((10#$end))
  (( start >= 10000 && end <= 65000 && start <= end )) || fail "ช่วงพอร์ตต้องอยู่ใน 10000-65000 และเริ่มไม่เกินสิ้นสุด"
  listen=$(shuf -i "$start-$end" -n 1)
  info "จะฟังจริงบน UDP $listen และ redirect ช่วง $start-$end มายังพอร์ตนี้"

  read -r -s -p "รหัส obfs (เว้นว่างเพื่อสุ่มให้): " obfs; echo
  obfs=${obfs:-$(openssl rand -hex 16)}
  [[ "$obfs" != *$'\n'* && -n "$obfs" ]] || fail "ค่า obfs ไม่ถูกต้อง"

  read -r -p "ชื่อบัญชีแรก: " username
  valid_user "$username" || fail "ชื่อบัญชีใช้ได้เฉพาะ A-Z a-z 0-9 _ . - ความยาว 1-48 ตัว"
  read -r -s -p "รหัสผ่าน (เว้นว่างเพื่อสุ่ม): " password; echo
  password=${password:-$(openssl rand -hex 16)}
  [[ "$password" =~ ^[A-Za-z0-9_@#%+=.-]{8,128}$ ]] || fail "รหัสผ่านต้องยาว 8-128 ตัว และใช้ A-Z a-z 0-9 _ @ # % + = . - เท่านั้น"
  read -r -p "อายุบัญชีเป็นวัน [30]: " days
  days=${days:-30}
  valid_days "$days" || fail "จำนวนวันต้องเป็นจำนวนเต็ม 1-36500"
  days=$((10#$days))

  install -d -o root -g root -m 0750 "$BASE_DIR"
  if ! id hysteria1 >/dev/null 2>&1; then
    useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin hysteria1
  fi
  cat > "$SETTINGS_FILE" <<EOF
{"listen_port":$listen,"range_start":$start,"range_end":$end,"obfs":$(jq -Rn --arg x "$obfs" '$x')}
EOF
  chown root:root "$SETTINGS_FILE"; chmod 600 "$SETTINGS_FILE"
  now=$(date +%s); expiry=$((now + days * 86400))
  jq -n --arg u "$username" --arg p "$password" --argjson e "$expiry" '{users:[{username:$u,password:$p,expires_at:$e}]}' | write_db_from_stdin

  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
    -subj "/CN=hysteria.local" -keyout "$KEY_FILE" -out "$CERT_FILE" >/dev/null 2>&1
  chown root:hysteria1 "$KEY_FILE" "$CERT_FILE"
  chmod 640 "$KEY_FILE"; chmod 644 "$CERT_FILE"
  "$BIN_FILE" -v >/dev/null 2>&1 || true

  install -o root -g root -m 0755 "$0" "$MANAGER_FILE"
  cat > /etc/systemd/system/hysteria1.service <<'UNIT'
[Unit]
Description=Hysteria v1 UDP proxy server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hysteria1
Group=hysteria1
ExecStart=/usr/local/bin/hysteria1 -c /etc/hysteria1/server.json server
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/etc/hysteria1

[Install]
WantedBy=multi-user.target
UNIT
  cat > /etc/systemd/system/hysteria1-port-forward.service <<'UNIT'
[Unit]
Description=Hysteria v1 UDP port-range redirect
After=network-online.target hysteria1.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/hysteria1-manager port-forward apply
ExecStop=/usr/local/sbin/hysteria1-manager port-forward remove

[Install]
WantedBy=multi-user.target
UNIT
  cat > /etc/systemd/system/hysteria1-expiry.service <<'UNIT'
[Unit]
Description=Expire Hysteria v1 accounts

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hysteria1-manager expire
UNIT
  cat > /etc/systemd/system/hysteria1-expiry.timer <<'UNIT'
[Unit]
Description=Check Hysteria v1 account expiry periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=hysteria1-expiry.service

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  render_config
  systemctl enable --now hysteria1.service
  systemctl enable --now hysteria1-port-forward.service
  systemctl enable --now hysteria1-expiry.timer
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${start}:${end}/udp" comment 'Hysteria v1 UDP range' >/dev/null || true
    info "เพิ่มกฎ UFW ให้ UDP ${start}-${end} แล้ว (หาก UFW มีนโยบายเฉพาะ โปรดตรวจซ้ำ)"
  fi

  echo
  info "ติดตั้งเสร็จแล้ว"
  echo "พอร์ตภายนอกสำหรับ client: <IP-หรือ-domain>:${start}-${end}"
  echo "พอร์ตฟังภายใน: UDP ${listen} | บัญชี: $username | หมดอายุ: $(date -u -d "@$expiry" '+%Y-%m-%d %H:%M UTC')"
  echo "รหัสผ่านบัญชี: $password"
  echo "รหัส obfs: $obfs"
  echo
  echo "Client config (ตั้ง insecure:true เพราะใบรับรองเป็น self-signed):"
  print_client_config "YOUR_SERVER_IP_OR_DOMAIN" "$username" "$password"
  echo
  echo "ตั้งค่า firewall ของผู้ให้บริการ VPS ให้รับ UDP ${start}-${end}; จากนั้นใช้ sudo hysteria1-manager จัดการบัญชี"
  echo "ดู log: sudo journalctl -u hysteria1 -f"
}

add_account() {
  local username password days now expiry
  read -r -p "ชื่อบัญชี: " username
  valid_user "$username" || { echo "ชื่อบัญชีไม่ถูกต้อง"; return 1; }
  if jq -e --arg u "$username" '.users[] | select(.username==$u)' "$DB_FILE" >/dev/null; then
    echo "ชื่อนี้มีอยู่แล้ว"; return 1
  fi
  read -r -s -p "รหัสผ่าน (เว้นว่างเพื่อสุ่ม): " password; echo
  password=${password:-$(openssl rand -hex 16)}
  [[ "$password" =~ ^[A-Za-z0-9_@#%+=.-]{8,128}$ ]] || { echo "รหัสผ่านไม่ผ่านเงื่อนไข"; return 1; }
  read -r -p "อายุบัญชีเป็นวัน: " days
  valid_days "$days" || { echo "จำนวนวันไม่ถูกต้อง"; return 1; }
  days=$((10#$days))
  now=$(date +%s); expiry=$((now + days * 86400))
  local tmp; tmp=$(mktemp "$BASE_DIR/accounts.XXXXXX")
  jq --arg u "$username" --arg p "$password" --argjson e "$expiry" '.users += [{username:$u,password:$p,expires_at:$e}]' "$DB_FILE" > "$tmp"
  chown root:root "$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$DB_FILE"
  restart_server
  echo "บัญชีเพิ่มแล้ว หมดอายุ $(date -u -d "@$expiry" '+%Y-%m-%d %H:%M UTC')"
  echo "auth_str: ${username}:${password}"
}

list_accounts() {
  local now u exp pw
  now=$(date +%s)
  printf '\n%-22s %-25s %s\n' 'ชื่อ' 'หมดอายุ (UTC)' 'สถานะ'
  while IFS=$'\t' read -r u exp; do
    [[ -n "$u" ]] || continue
    if (( exp <= now )); then printf '%-22s %-25s %s\n' "$u" "$(date -u -d "@$exp" '+%Y-%m-%d %H:%M')" 'หมดอายุ';
    else printf '%-22s %-25s %s\n' "$u" "$(date -u -d "@$exp" '+%Y-%m-%d %H:%M')" 'ใช้งาน'; fi
  done < <(jq -r '.users[] | [.username, (.expires_at|tostring)] | @tsv' "$DB_FILE")
  echo
}

extend_account() {
  local username days now tmp old new
  read -r -p "ชื่อบัญชีที่ต้องการต่ออายุ: " username
  read -r -p "เพิ่มอีกกี่วัน: " days
  valid_days "$days" || { echo "จำนวนวันไม่ถูกต้อง"; return 1; }
  days=$((10#$days))
  old=$(jq -r --arg u "$username" '[.users[] | select(.username==$u) | .expires_at] | first // empty' "$DB_FILE")
  [[ -n "$old" ]] || { echo "ไม่พบบัญชี"; return 1; }
  now=$(date +%s); (( old > now )) || old=$now
  new=$((old + days * 86400))
  tmp=$(mktemp "$BASE_DIR/accounts.XXXXXX")
  jq --arg u "$username" --argjson e "$new" '(.users[] | select(.username==$u) | .expires_at) = $e' "$DB_FILE" > "$tmp"
  chown root:root "$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$DB_FILE"
  restart_server
  echo "ต่ออายุแล้ว หมดอายุ $(date -u -d "@$new" '+%Y-%m-%d %H:%M UTC')"
}

delete_account() {
  local username tmp before after
  read -r -p "ชื่อบัญชีที่ต้องการลบ: " username
  before=$(jq '.users|length' "$DB_FILE")
  tmp=$(mktemp "$BASE_DIR/accounts.XXXXXX")
  jq --arg u "$username" '{users:[.users[] | select(.username!=$u)]}' "$DB_FILE" > "$tmp"
  after=$(jq '.users|length' "$tmp")
  if (( before == after )); then rm -f "$tmp"; echo "ไม่พบบัญชี"; return 1; fi
  chown root:root "$tmp"; chmod 600 "$tmp"; mv -f "$tmp" "$DB_FILE"
  restart_server
  echo "ลบบัญชี $username แล้ว"
}

show_client_config() {
  local username password host
  read -r -p "ชื่อบัญชี: " username
  password=$(jq -r --arg u "$username" '[.users[] | select(.username==$u) | .password] | first // empty' "$DB_FILE")
  [[ -n "$password" ]] || { echo "ไม่พบบัญชี"; return 1; }
  read -r -p "IP หรือ domain ของเซิร์ฟเวอร์: " host
  print_client_config "$host" "$username" "$password"
}

menu() {
  need_root menu
  is_installed || fail "ยังไม่ได้ติดตั้ง ใช้: sudo bash $0 install"
  while true; do
    echo ""
    echo "===== Hysteria v1 Account Manager ====="
    echo "1) แสดงบัญชีและวันหมดอายุ"
    echo "2) เพิ่มบัญชี"
    echo "3) ต่ออายุบัญชี"
    echo "4) ลบบัญชี"
    echo "5) แสดง client config"
    echo "6) ตรวจสถานะบริการ"
    echo "0) ออก"
    read -r -p "เลือกเมนู: " choice
    case "$choice" in
      1) list_accounts ;;
      2) add_account ;;
      3) extend_account ;;
      4) delete_account ;;
      5) show_client_config ;;
      6) systemctl --no-pager --full status hysteria1.service || true ;;
      0) exit 0 ;;
      *) echo "เลือก 0-6" ;;
    esac
  done
}

case "${1:-menu}" in
  install) shift; install_server "$@" ;;
  menu) shift || true; menu "$@" ;;
  expire) need_root expire; expire_accounts ;;
  port-forward) need_root port-forward "${2:-}"; [[ $# -ge 2 ]] || fail "ระบุ apply หรือ remove"; port_forward "$2" ;;
  *) echo "การใช้งาน: sudo bash $0 [install|menu]"; exit 2 ;;
esac
