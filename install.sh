#!/bin/sh
# ZIVPN - one-file installer (pure POSIX sh: no web panel, no python, no database server)
#
#   sh install.sh
#
# Non-interactive:  ZP_YES=1 ZP_HOST=vpn.example.com ZP_RANGE=6000:9999 sh install.sh
#   ZP_HOST   address shown to clients        (default: detected public IP)
#   ZP_RANGE  UDP port-hopping range -> 5667  (default: 6000:9999, "off" = disable)
#   ZP_YES=1  never ask questions
#   ZP_MENU   path to menu.sh      (default: menu.sh next to install.sh)
#   ZP_MENU_URL  download menu.sh from here if no local file
#
# Files: install.sh + menu.sh must sit in the same folder.
#
# Installs only what is needed: curl, openssl, iptables (+ iproute2 / ca-certificates if missing).
VERSION="1.0.0"
set -u
umask 022
LC_COLLATE=C; export LC_COLLATE

REL="udp-zivpn_1.4.9"                       # upstream: github.com/zahidbd2/udp-zivpn
BASE="https://github.com/zahidbd2/udp-zivpn/releases/download/$REL"
PORT=5667

ETC="${ZP_ETC:-/etc/zivpn}"
BIN="${ZP_BIN:-/usr/local/bin/zivpn}"
UNITS="${ZP_UNITS:-/etc/systemd/system}"
SELF="${ZP_SELF:-/usr/local/bin/m}"
LOG="${ZP_LOG:-/var/log/zivpn-install.log}"
DRY="${ZP_DRY:-0}"
YES="${ZP_YES:-0}"
OBFS='hu``hqb`c'

# ------------------------------------------------------------------ ui
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  ESC=$(printf '\033'); TTY=1
  RED="$ESC[1;31m"; GRN="$ESC[1;32m"; YEL="$ESC[1;33m"; CYN="$ESC[1;36m"
  BLD="$ESC[1m"; DIM="$ESC[2m"; RST="$ESC[0m"
else
  ESC=""; TTY=0; RED=""; GRN=""; YEL=""; CYN=""; BLD=""; DIM=""; RST=""
fi
_BAR=""; _i=0
while [ "$_i" -lt 40 ]; do _BAR="$_BAR─"; _i=$((_i + 1)); done

ok()   { printf '  %s✔%s %s\n' "$GRN" "$RST" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$RED" "$RST" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$YEL" "$RST" "$*"; }
info() { printf '  %s•%s %s\n' "$CYN" "$RST" "$*"; }
die()  { [ "$TTY" = 1 ] && printf '\r\033[K'; bad "$*"; printf '  %sดู log: %s%s\n\n' "$DIM" "$LOG" "$RST" >&2; exit 1; }
step() { printf '\n  %s[%s/%s]%s %s%s%s\n' "$CYN" "$1" "$2" "$RST" "$BLD" "$3" "$RST"; }
kv()   { printf '  %s│%s %s%-11s%s %s\n' "$CYN" "$RST" "$DIM" "$1" "$RST" "$2"; }

ask() { # ask "prompt" "default" -> $ANS
  ANS="${2:-}"
  [ "$YES" = 1 ] && return 0
  [ -t 0 ] || return 0
  printf '  %s›%s %s%s: ' "$CYN" "$RST" "$1" "${2:+ [$2]}"
  IFS= read -r ANS || ANS=""
  ANS=${ANS#"${ANS%%[![:space:]]*}"}
  ANS=${ANS%"${ANS##*[![:space:]]}"}
  [ -n "$ANS" ] || ANS="${2:-}"
}

SPID=""
cleanup() { [ -n "$SPID" ] && kill "$SPID" 2>/dev/null; [ "$TTY" = 1 ] && printf '\033[?25h'; return 0; }
trap 'cleanup; printf "\n"; exit 130' INT TERM
trap 'cleanup' EXIT

# task "message" cmd args...   (runs with a spinner, output goes to the log)
task() {
  _msg=$1; shift
  _t0=$(date +%s); _out="$LOG.task.$$"; : >"$_out"
  if [ "$TTY" = 1 ]; then
    printf '\033[?25l'
    "$@" >"$_out" 2>&1 &
    SPID=$!; _k=0
    while kill -0 "$SPID" 2>/dev/null; do
      case $((_k % 8)) in
        0) _f='⠋' ;; 1) _f='⠙' ;; 2) _f='⠹' ;; 3) _f='⠸' ;;
        4) _f='⠼' ;; 5) _f='⠴' ;; 6) _f='⠦' ;; *) _f='⠧' ;;
      esac
      printf '\r  %s%s%s %s\033[K' "$CYN" "$_f" "$RST" "$_msg"
      _k=$((_k + 1)); sleep 0.1
    done
    wait "$SPID"; _rc=$?; SPID=""
    printf '\r\033[K\033[?25h'
  else
    "$@" >"$_out" 2>&1; _rc=$?
  fi
  _dt=$(( $(date +%s) - _t0 )); cat "$_out" >>"$LOG" 2>/dev/null
  if [ "$_rc" -eq 0 ]; then
    ok "$_msg  ${DIM}(${_dt}s)${RST}"; rm -f "$_out"
  else
    bad "$_msg"; tail -n 5 "$_out" 2>/dev/null | cut -c1-100 | sed 's/^/      /' >&2; rm -f "$_out"
    die "ขั้นตอนนี้ล้มเหลว"
  fi
}

banner() {
  printf '\n  %s╭%s╮%s\n' "$CYN" "$_BAR" "$RST"
  printf '  %s│%s  %s%-22s%s %13s  %s│%s\n' "$CYN" "$RST" "$BLD" "ZIVPN  UDP Installer" "$RST" "v$VERSION" "$CYN" "$RST"
  printf '  %s╰%s╯%s\n' "$CYN" "$_BAR" "$RST"
}

# ------------------------------------------------------------------ helpers
sc() { [ "$DRY" = 1 ] && return 0; systemctl "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }

udp_in_use() { # $1 port
  have ss || return 1
  ss -lnuH 2>/dev/null | grep -E "[:.]$1[[:space:]]" >/dev/null
}

valid_host()  { case $1 in ''|*[!A-Za-z0-9.:-]*) return 1 ;; esac; return 0; }
valid_range() {
  case $1 in ''|*[!0-9:]*|:*|*:|*:*:*) return 1 ;; *:*) ;; *) return 1 ;; esac
  _a=${1%:*}; _b=${1#*:}
  [ "$_a" -ge 1024 ] && [ "$_b" -le 65535 ] && [ "$_a" -lt "$_b" ]
}

public_ip() {
  _ip=$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null)
  if [ -z "$_ip" ] && have ip; then
    set -- $(ip -4 route get 1.1.1.1 2>/dev/null)
    while [ $# -gt 0 ]; do [ "$1" = src ] && { _ip=${2:-}; break; }; shift; done
  fi
  printf '%s' "$_ip"
}

pkg_install() { # uses $PKGS
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y && apt-get install -y --no-install-recommends $PKGS
}

fetch_bin() {
  mkdir -p "${BIN%/*}"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$BIN.part" "$URL" || return 1
  set -- $(sha256sum "$BIN.part")
  if [ "$1" != "$SHA" ]; then
    rm -f "$BIN.part"
    echo "SHA256 ไม่ตรง: ได้ $1 ต้องการ $SHA"
    return 1
  fi
  chmod 755 "$BIN.part" && mv -f "$BIN.part" "$BIN"
}

gen_cert() {
  openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 -subj "/CN=zivpn" \
    -keyout "$ETC/zivpn.key" -out "$ETC/zivpn.crt" && chmod 600 "$ETC/zivpn.key"
}

write_manager() { # ติดตั้ง menu.sh -> $SELF (คำสั่ง m)
  _src="${ZP_MENU:-}"
  if [ -z "$_src" ]; then
    _d=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
    [ -n "$_d" ] && [ -f "$_d/menu.sh" ] && _src="$_d/menu.sh"
  fi
  mkdir -p "${SELF%/*}"
  if [ -n "$_src" ]; then
    [ -r "$_src" ] || { echo "อ่านไฟล์ไม่ได้: $_src"; return 1; }
    cp "$_src" "$SELF.new" || return 1
  elif [ -n "${ZP_MENU_URL:-}" ]; then
    curl -fsSL --retry 3 --connect-timeout 15 -o "$SELF.new" "$ZP_MENU_URL" || return 1
  else
    echo "ไม่พบ menu.sh - วางไว้โฟลเดอร์เดียวกับ install.sh หรือตั้ง ZP_MENU=/path/menu.sh หรือ ZP_MENU_URL=https://..."
    return 1
  fi
  case $(head -n 1 "$SELF.new") in
    '#!'*) ;;
    *) rm -f "$SELF.new"; echo "menu.sh ไม่ถูกต้อง (บรรทัดแรกต้องเป็น #!/bin/sh)"; return 1 ;;
  esac
  chmod 755 "$SELF.new" && mv -f "$SELF.new" "$SELF"
}

write_units() {
  cat >"$UNITS/zivpn.service" <<EOF
[Unit]
Description=ZIVPN UDP Server
After=network.target

[Service]
ExecStart=$BIN server -c $ETC/config.json
WorkingDirectory=$ETC
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  cat >"$UNITS/zivpn-expire.service" <<EOF
[Unit]
Description=ZIVPN - disable expired accounts

[Service]
Type=oneshot
ExecStart=$SELF expire
EOF
  cat >"$UNITS/zivpn-expire.timer" <<EOF
[Unit]
Description=ZIVPN - check account expiry every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  if [ -n "$RANGE" ]; then
    cat >"$UNITS/zivpn-nat.service" <<EOF
[Unit]
Description=ZIVPN - UDP port hopping ($RANGE -> $PORT)
After=network-online.target
Before=zivpn.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SELF nat up
ExecStop=$SELF nat down

[Install]
WantedBy=multi-user.target
EOF
  else
    rm -f "$UNITS/zivpn-nat.service"
  fi
}

# ------------------------------------------------------------------ run
mkdir -p "${LOG%/*}" 2>/dev/null; : >>"$LOG" 2>/dev/null || LOG=/dev/null
[ "$TTY" = 1 ] && printf '\033[H\033[2J'
banner

# ---- 1. preflight
step 1 5 "ตรวจสอบระบบ"
[ "$(id -u)" -eq 0 ] || [ "$DRY" = 1 ] || die "ต้องรันด้วย root  (sudo sh install.sh)"
ok "สิทธิ์ root"
[ -d /run/systemd/system ] || [ "$DRY" = 1 ] || die "ระบบนี้ไม่มี systemd"
ok "systemd"

OSNAME="Linux"
[ -r /etc/os-release ] && OSNAME=$( . /etc/os-release; printf '%s' "${PRETTY_NAME:-Linux}" )
case $(uname -m) in
  x86_64|amd64)  A=amd64; SHA=df6658c195882ff2f6cefb44050e8cb2c238ceb2b6e3fbefb931698f4f0519cb ;;
  aarch64|arm64) A=arm64; SHA=1bc3f0a46db2b4a4771dd08e68e2134c55d7c48874334ed7bba512d983bfa83a ;;
  armv7l|armv6l|arm) A=arm; SHA=45671cdf1ee995a33273128f8c953747c003da7cdc228b9b34e68e080eb6a123 ;;
  *) die "ไม่รองรับสถาปัตยกรรม $(uname -m)" ;;
esac
URL="${ZP_URL:-$BASE/udp-zivpn-linux-$A}"
SHA="${ZP_SHA256:-$SHA}"
ok "$OSNAME · $A"

REINSTALL=0
[ -f "$ETC/manager.conf" ] && REINSTALL=1
if [ "$REINSTALL" = 1 ]; then
  info "พบการติดตั้งเดิม - จะอัปเดตโปรแกรม และเก็บผู้ใช้เดิมไว้"
  sc stop zivpn.service >/dev/null 2>&1
fi
LEGACY=0
{ [ -d /opt/unified-vpn ] || [ -f /etc/systemd/system/unified-panel.service ]; } && LEGACY=1

# ---- 2. questions
step 2 5 "ตั้งค่า"
if [ -f "$ETC/manager.conf" ]; then . "$ETC/manager.conf"; DEF_HOST=${HOST:-}; DEF_RANGE=${RANGE:-off}; else DEF_HOST=""; DEF_RANGE="6000:9999"; fi
DEF_HOST="${ZP_HOST:-$DEF_HOST}"
[ -n "${ZP_RANGE:-}" ] && DEF_RANGE=$ZP_RANGE

ask "ที่อยู่เซิร์ฟเวอร์ที่ลูกค้าใช้ (โดเมน/IP, เว้นว่าง = ตรวจ IP อัตโนมัติ)" "$DEF_HOST"; HOST=$ANS
ask "ช่วงพอร์ต UDP hopping (off = ปิด)" "$DEF_RANGE"; RANGE=$ANS
case $RANGE in off|OFF|Off|-|none) RANGE="" ;; esac
[ -z "$HOST" ] || valid_host "$HOST" || die "ที่อยู่เซิร์ฟเวอร์ไม่ถูกต้อง: $HOST"
[ -z "$RANGE" ] || valid_range "$RANGE" || die "ช่วงพอร์ตไม่ถูกต้อง (ตัวอย่าง 6000:9999): $RANGE"
ok "port ${PORT}/udp${RANGE:+  +  hopping $RANGE}"

# ---- 3. packages
step 3 5 "ติดตั้งแพ็กเกจที่จำเป็น"
PKGS=""
have curl    || PKGS="$PKGS curl"
have openssl || PKGS="$PKGS openssl"
{ have ss && have ip; } || PKGS="$PKGS iproute2"
[ -s /etc/ssl/certs/ca-certificates.crt ] || PKGS="$PKGS ca-certificates"
{ [ -z "$RANGE" ] || have iptables; } || PKGS="$PKGS iptables"
if [ -n "$PKGS" ] && [ "$DRY" != 1 ]; then
  have apt-get || die "ไม่พบ apt-get - ติดตั้งเอง:$PKGS"
  task "ติดตั้ง:$PKGS" pkg_install
else
  ok "ครบแล้ว (curl openssl${RANGE:+ iptables}) - ไม่ต้องติดตั้งเพิ่ม"
fi
have curl || die "ไม่พบ curl"
[ "$DRY" = 1 ] || curl -fsS --max-time 10 -o /dev/null https://github.com || die "เชื่อมต่อ github.com ไม่ได้"

if [ "$REINSTALL" = 0 ] && udp_in_use "$PORT"; then
  if [ "$LEGACY" = 1 ]; then
    die "udp/$PORT ถูกใช้โดยระบบ unified-vpn (ตัวเก่า) - ถอนก่อนด้วย: /opt/unified-vpn/uninstall.sh แล้วค่อยรันใหม่"
  fi
  die "udp/$PORT ถูกใช้งานอยู่โดยโปรแกรมอื่น - ปิดมันก่อน (ดู: ss -lunp | grep $PORT)"
fi
[ -n "$HOST" ] || { HOST=$(public_ip); [ -n "$HOST" ] || die "ตรวจ IP สาธารณะไม่ได้ - ตั้งเองด้วย ZP_HOST=..."; info "ตรวจพบ IP: $HOST"; }

# ---- 4. binary + certificate
step 4 5 "ติดตั้ง ZIVPN"
mkdir -p "$ETC"; chmod 700 "$ETC"
task "ดาวน์โหลด ZIVPN $REL ($A) + ตรวจ SHA256" fetch_bin
if [ -s "$ETC/zivpn.key" ] && [ -s "$ETC/zivpn.crt" ]; then
  ok "ใช้ใบรับรองเดิม"
else
  task "สร้างใบรับรอง TLS (self-signed)" gen_cert
fi
[ -f "$ETC/users.db" ] || { : >"$ETC/users.db"; chmod 600 "$ETC/users.db"; }
{
  printf "HOST='%s'\n" "$HOST"
  printf "PORT='%s'\n" "$PORT"
  printf "RANGE='%s'\n" "$RANGE"
  printf "OBFS='%s'\n" "$OBFS"
} >"$ETC/manager.conf"
chmod 600 "$ETC/manager.conf"
write_manager && ok "ติดตั้งตัวจัดการ: ${BLD}m${RST}" || die "เขียน $SELF ไม่สำเร็จ"
ZP_ETC="$ETC" ZP_DRY="$DRY" "$SELF" render >>"$LOG" 2>&1 || die "สร้าง config.json ไม่สำเร็จ"
ok "สร้าง config.json"

# ---- 5. services
step 5 5 "เปิดบริการ"
if [ -z "$RANGE" ] && [ -f "$UNITS/zivpn-nat.service" ]; then sc disable --now zivpn-nat.service >>"$LOG" 2>&1; fi
write_units
sc daemon-reload
if [ -n "$RANGE" ]; then sc enable zivpn-nat.service >>"$LOG" 2>&1; sc restart zivpn-nat.service >>"$LOG" 2>&1
fi
sc enable zivpn.service >>"$LOG" 2>&1; sc restart zivpn.service >>"$LOG" 2>&1 || die "เริ่ม zivpn.service ไม่ได้ - ดู: journalctl -u zivpn -n 30"
sc enable --now zivpn-expire.timer >>"$LOG" 2>&1
ok "zivpn · expire timer${RANGE:+ · port hopping}"
if [ "$DRY" != 1 ] && have ufw && ufw status 2>/dev/null | grep 'Status: active' >/dev/null; then
  ufw allow "$PORT/udp" >>"$LOG" 2>&1
  [ -n "$RANGE" ] && ufw allow "$RANGE/udp" >>"$LOG" 2>&1
  ok "เปิดพอร์ตใน UFW แล้ว"
fi
sleep 1

# ------------------------------------------------------------------ summary
echo
ZP_ETC="$ETC" ZP_DRY="$DRY" "$SELF" health
printf '\n  %s┌─ ติดตั้งเสร็จเรียบร้อย ────────────────%s\n' "$CYN" "$RST"
kv "Server"  "$HOST"
kv "Port"    "$PORT/udp${RANGE:+  (hopping ${RANGE%:*}-${RANGE#*:})}"
kv "Obfs"    "$OBFS"
kv "Menu"    "${BLD}m${RST}       ${DIM}เปิดเมนูจัดการผู้ใช้${RST}"
kv "Backup"  "m backup"
printf '  %s└────────────────────────────────────────%s\n\n' "$CYN" "$RST"

if [ "$YES" != 1 ] && [ -t 0 ] && [ "$DRY" != 1 ]; then
  ask "สร้างผู้ใช้คนแรกเลยไหม? (y/N)" "n"
  case $ANS in y|Y|yes) "$SELF" add ;; esac
fi
exit 0
