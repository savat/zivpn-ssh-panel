#!/bin/sh
# m - ZIVPN manager (pure POSIX sh, no python / no web panel)
VERSION="1.2.0"
set -u
LC_COLLATE=C; export LC_COLLATE
umask 077

# ------------------------------------------------------------------ paths
ETC="${ZP_ETC:-/etc/zivpn}"
BIN="${ZP_BIN:-/usr/local/bin/zivpn}"
UNITS="${ZP_UNITS:-/etc/systemd/system}"
BACKUPS="${ZP_BACKUPS:-/var/backups/zivpn}"
SELF="${ZP_SELF:-/usr/local/bin/m}"
SHARE="${ZP_SHARE:-/usr/local/share/zivpn-panel}"   # hysteria.sh + install_server.sh อยู่ที่นี่
RAW="${ZP_RAW:-https://github.com/savat/zivpn-ssh-panel/raw/main}"
HY_BIN="${ZP_HY_BIN:-/usr/local/bin/hysteria}"
DRY="${ZP_DRY:-0}"
DB="$ETC/users.db"
CONF="$ETC/manager.conf"
CFG="$ETC/config.json"
LOCK="$ETC/.lock"
CHAIN="ZIVPN_DNAT"

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
die()  { bad "$*"; exit 1; }
sect() { printf '\n  %s%s%s\n' "$BLD" "$1" "$RST"; }
kv()   { printf '  %s│%s %s%-11s%s %s\n' "$DIM" "$RST" "$DIM" "$1" "$RST" "$2"; }

banner() {
  printf '\n  %s╭%s╮%s\n' "$CYN" "$_BAR" "$RST"
  printf '  %s│%s  %s%-22s%s %13s  %s│%s\n' "$CYN" "$RST" "$BLD" "ZIVPN  UDP Manager" "$RST" "v$VERSION" "$CYN" "$RST"
  printf '  %s╰%s╯%s\n' "$CYN" "$_BAR" "$RST"
}

# ask "prompt" "default"  -> $ANS  (trims spaces: phone keyboards love trailing blanks)
ask() {
  printf '  %s›%s %s%s: ' "$CYN" "$RST" "$1" "${2:+ [$2]}"
  IFS= read -r ANS || ANS=""
  ANS=${ANS#"${ANS%%[![:space:]]*}"}
  ANS=${ANS%"${ANS##*[![:space:]]}"}
  [ -n "$ANS" ] || ANS="${2:-}"
}

yesno() { ask "$1 (y/N)" ""; case $ANS in y|Y|yes|YES|Yes) return 0 ;; esac; return 1; }
pause() { printf '\n  %sกด Enter เพื่อกลับเมนู…%s' "$DIM" "$RST"; IFS= read -r _x || exit 0; }

# ------------------------------------------------------------------ system helpers
now() { date +%s; }
fmt_date() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"; }
fmt_day()  { date -d "@$1" '+%Y-%m-%d' 2>/dev/null || printf '%s' "$1"; }

sc() { [ "$DRY" = 1 ] && return 0; systemctl "$@"; }
sysq() { [ "$DRY" = 1 ] || systemctl is-active --quiet "$1"; }
svc_active() { sysq zivpn.service; }

load_conf() {
  HOST=""; PORT=5667; RANGE=""; OBFS=""
  [ -r "$CONF" ] && . "$CONF"
  return 0
}

need_installed() {
  [ -r "$CONF" ] || die "ยังไม่ได้ติดตั้ง ZIVPN - รัน: sh install.sh"
}

lock() {
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"$LOCK" && flock -w 15 9
}
unlock() { exec 9>&- 2>/dev/null; return 0; }
locked() {
  lock || { bad "ระบบกำลังถูกใช้งานอยู่ ลองใหม่อีกครั้ง"; return 1; }
  "$@"; _lrc=$?
  unlock
  return "$_lrc"
}

# ------------------------------------------------------------------ validation
valid_user() {
  case $1 in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  [ "${#1}" -ge 3 ] && [ "${#1}" -le 32 ]
}
valid_pass() {
  case $1 in ''|*[!A-Za-z0-9@#%^*_+=.,:\;!?~/-]*) return 1 ;; esac
  [ "${#1}" -ge 4 ] && [ "${#1}" -le 64 ]
}
valid_days() {
  case $1 in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 4 ] && [ "$1" -ge 1 ] && [ "$1" -le 3650 ]
}
randpw() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10; }

# ------------------------------------------------------------------ user database
# users.db : one line per user   name|password|expiry_epoch|active|disabled
db_init() {
  [ -d "$ETC" ] || mkdir -p "$ETC"
  [ -f "$DB" ] || { : >"$DB"; chmod 600 "$DB"; }
}

db_find() { # sets F_PASS F_EXP F_STAT
  while IFS='|' read -r _u _p _e _s; do
    if [ "$_u" = "$1" ]; then F_PASS=$_p; F_EXP=$_e; F_STAT=$_s; return 0; fi
  done <"$DB"
  return 1
}

db_pass_taken() { # $1 password  $2 user to ignore
  while IFS='|' read -r _u _p _e _s; do
    [ "$_u" = "${2:-}" ] && continue
    [ "$_p" = "$1" ] && return 0
  done <"$DB"
  return 1
}

db_nth() { # $1 = row number -> PICK
  _n=0
  while IFS='|' read -r _u _p _e _s; do
    [ -n "$_u" ] || continue
    _n=$((_n + 1))
    if [ "$_n" -eq "$1" ]; then PICK=$_u; return 0; fi
  done <"$DB"
  return 1
}

db_write() { # $1 user  $2 new line ("" = delete)
  _tmp="$DB.new.$$"; _hit=0
  : >"$_tmp" || return 1
  while IFS='|' read -r _u _p _e _s; do
    [ -n "$_u" ] || continue
    if [ "$_u" = "$1" ]; then
      _hit=1
      [ -n "$2" ] && printf '%s\n' "$2" >>"$_tmp"
    else
      printf '%s|%s|%s|%s\n' "$_u" "$_p" "$_e" "$_s" >>"$_tmp"
    fi
  done <"$DB"
  if [ "$_hit" = 0 ] && [ -n "$2" ]; then printf '%s\n' "$2" >>"$_tmp"; fi
  chmod 600 "$_tmp"
  mv -f "$_tmp" "$DB"
}

eff() { # $1 expiry  $2 stored status -> active|expired|off
  if [ "$2" != active ]; then printf 'off'
  elif [ "$1" -gt "$(now)" ] 2>/dev/null; then printf 'active'
  else printf 'expired'; fi
}

left_str() {
  _d=$(( $1 - $(now) ))
  if   [ "$_d" -le 0 ];     then printf '0'
  elif [ "$_d" -ge 86400 ]; then printf '%sd' $((_d / 86400))
  elif [ "$_d" -ge 3600 ];  then printf '%sh' $((_d / 3600))
  else printf '%sm' $((_d / 60)); fi
}

count_users() { # -> N_TOTAL N_ACTIVE
  N_TOTAL=0; N_ACTIVE=0
  while IFS='|' read -r _u _p _e _s; do
    [ -n "$_u" ] || continue
    N_TOTAL=$((N_TOTAL + 1))
    [ "$(eff "$_e" "$_s")" = active ] && N_ACTIVE=$((N_ACTIVE + 1))
  done <"$DB"
}

# ------------------------------------------------------------------ zivpn config
placeholder() {
  [ -s "$ETC/.placeholder" ] || {
    LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 40 >"$ETC/.placeholder"
    chmod 600 "$ETC/.placeholder"
  }
  cat "$ETC/.placeholder"
}

# render: 0 = config changed (written), 1 = unchanged, 2 = error
render() {
  _t=$(now); _list=""
  while IFS='|' read -r _u _p _e _s; do
    [ -n "$_u" ] || continue
    [ "$_s" = active ] || continue
    [ "$_e" -gt "$_t" ] 2>/dev/null || continue
    _list="$_list${_list:+, }\"$_p\""
  done <"$DB"
  [ -n "$_list" ] || _list="\"$(placeholder)\""
  _new=$(printf '{\n  "listen": ":%s",\n  "cert": "%s/zivpn.crt",\n  "key": "%s/zivpn.key",\n  "obfs": "%s",\n  "auth": {\n    "mode": "passwords",\n    "config": [%s]\n  }\n}' \
    "$PORT" "$ETC" "$ETC" "$OBFS" "$_list")
  if [ -f "$CFG" ] && [ "$(cat "$CFG")" = "$_new" ]; then return 1; fi
  [ -f "$CFG" ] && cp -f "$CFG" "$CFG.bak"
  printf '%s\n' "$_new" >"$CFG.new" || return 2
  chmod 600 "$CFG.new"
  mv -f "$CFG.new" "$CFG" || return 2
  return 0
}

# apply [force]: render and restart zivpn when needed; roll back if it fails to start
apply() {
  render; _rc=$?
  [ "$_rc" -eq 2 ] && { bad "เขียนไฟล์ตั้งค่าไม่สำเร็จ"; return 1; }
  if [ "$_rc" -eq 0 ] || [ "${1:-}" = force ]; then
    sc restart zivpn.service
    sleep 1
    if ! svc_active; then
      bad "ZIVPN เริ่มทำงานไม่ได้ - กำลังย้อนกลับไปใช้ค่าเดิม"
      [ -f "$CFG.bak" ] && cp -f "$CFG.bak" "$CFG"
      sc restart zivpn.service
      return 1
    fi
  fi
  return 0
}

# ------------------------------------------------------------------ nat (port hopping)
iface() {
  set -- $(ip -4 route get 1.1.1.1 2>/dev/null)
  while [ $# -gt 0 ]; do
    [ "$1" = dev ] && { printf '%s' "${2:-}"; return 0; }
    shift
  done
  return 0
}
ipt() { iptables -w "$@"; }
ifarg() { _if=$(iface); [ -n "$_if" ] && IFARG="-i $_if" || IFARG=""; }

nat_up() {
  [ -n "$RANGE" ] || return 0
  [ "$DRY" = 1 ] && return 0
  ifarg
  ipt -t nat -N "$CHAIN" 2>/dev/null
  ipt -t nat -F "$CHAIN"
  ipt -t nat -A "$CHAIN" -p udp --dport "$RANGE" -j DNAT --to-destination ":$PORT" || return 1
  # shellcheck disable=SC2086
  ipt -t nat -C PREROUTING $IFARG -p udp -j "$CHAIN" 2>/dev/null \
    || ipt -t nat -A PREROUTING $IFARG -p udp -j "$CHAIN"
}
nat_down() {
  [ "$DRY" = 1 ] && return 0
  command -v iptables >/dev/null 2>&1 || return 0
  ifarg
  # shellcheck disable=SC2086
  while ipt -t nat -D PREROUTING $IFARG -p udp -j "$CHAIN" 2>/dev/null; do :; done
  ipt -t nat -F "$CHAIN" 2>/dev/null
  ipt -t nat -X "$CHAIN" 2>/dev/null
  return 0
}
nat_present() { [ "$DRY" = 1 ] || ipt -t nat -S "$CHAIN" >/dev/null 2>&1; }

udp_listening() {
  [ "$DRY" = 1 ] && return 0
  ss -lnuH 2>/dev/null | grep -E "[:.]$PORT[[:space:]]" >/dev/null
}

# ------------------------------------------------------------------ user operations (non-interactive core)
show_info() {
  db_find "$1" || { bad "ไม่พบผู้ใช้ '$1'"; return 1; }
  printf '\n  %s┌─ ข้อมูลเชื่อมต่อ (ส่งให้ลูกค้า) ─%s\n' "$CYN" "$RST"
  kv "User"     "$1"
  kv "Server"   "$HOST"
  kv "Password" "$F_PASS"
  kv "Obfs"     "$OBFS"
  kv "Port"     "$PORT"
  [ -n "$RANGE" ] && kv "Port range" "${RANGE%:*}-${RANGE#*:}"
  kv "Expires"  "$(fmt_date "$F_EXP")  ($(left_str "$F_EXP"))"
  printf '  %s└────────────────────────────────%s\n' "$CYN" "$RST"
}

u_add() { # user pass days
  valid_user "$1" || { bad "ชื่อผู้ใช้ไม่ถูกต้อง (3-32 ตัว: a-z A-Z 0-9 _ -)"; return 1; }
  db_find "$1" && { bad "มีผู้ใช้ชื่อ '$1' อยู่แล้ว"; return 1; }
  _pw=$2; [ -n "$_pw" ] || _pw=$(randpw)
  valid_pass "$_pw" || { bad "รหัสผ่านไม่ถูกต้อง (4-64 ตัว: a-z A-Z 0-9 และ @#%^*_+=.,:;!?~/-)"; return 1; }
  db_pass_taken "$_pw" && { bad "รหัสผ่านนี้ถูกใช้โดยผู้ใช้อื่นแล้ว (ZIVPN แยกผู้ใช้ด้วยรหัสผ่าน)"; return 1; }
  valid_days "$3" || { bad "จำนวนวันต้องเป็นตัวเลข 1-3650"; return 1; }
  db_write "$1" "$1|$_pw|$(( $(now) + $3 * 86400 ))|active"
  if ! apply; then
    db_write "$1" ""; apply >/dev/null 2>&1
    bad "สร้างผู้ใช้ไม่สำเร็จ (ย้อนกลับแล้ว)"; return 1
  fi
  ok "สร้างผู้ใช้ '$1' สำเร็จ"
  show_info "$1"
}

u_del() {
  db_find "$1" || { bad "ไม่พบผู้ใช้ '$1'"; return 1; }
  db_write "$1" ""
  apply || return 1
  ok "ลบผู้ใช้ '$1' แล้ว"
}

u_passwd() { # user newpass
  db_find "$1" || { bad "ไม่พบผู้ใช้ '$1'"; return 1; }
  _pw=$2; [ -n "$_pw" ] || _pw=$(randpw)
  valid_pass "$_pw" || { bad "รหัสผ่านไม่ถูกต้อง (4-64 ตัว: a-z A-Z 0-9 และ @#%^*_+=.,:;!?~/-)"; return 1; }
  db_pass_taken "$_pw" "$1" && { bad "รหัสผ่านนี้ถูกใช้โดยผู้ใช้อื่นแล้ว"; return 1; }
  db_write "$1" "$1|$_pw|$F_EXP|$F_STAT"
  apply || return 1
  ok "เปลี่ยนรหัสผ่านของ '$1' แล้ว"
  show_info "$1"
}

u_renew() { # user days
  db_find "$1" || { bad "ไม่พบผู้ใช้ '$1'"; return 1; }
  valid_days "$2" || { bad "จำนวนวันต้องเป็นตัวเลข 1-3650"; return 1; }
  _base=$F_EXP; _t=$(now); [ "$_base" -gt "$_t" ] 2>/dev/null || _base=$_t
  db_write "$1" "$1|$F_PASS|$(( _base + $2 * 86400 ))|active"
  apply || return 1
  ok "ต่ออายุ '$1' อีก $2 วันแล้ว"
  show_info "$1"
}

u_set() { # user on|off
  db_find "$1" || { bad "ไม่พบผู้ใช้ '$1'"; return 1; }
  if [ "$2" = on ]; then
    [ "$F_EXP" -gt "$(now)" ] 2>/dev/null || { bad "บัญชีหมดอายุแล้ว - ให้ต่ออายุแทน"; return 1; }
    db_write "$1" "$1|$F_PASS|$F_EXP|active"
    apply || return 1
    ok "เปิดใช้งาน '$1' แล้ว"
  else
    db_write "$1" "$1|$F_PASS|$F_EXP|disabled"
    apply || return 1
    ok "ปิดใช้งาน '$1' แล้ว"
  fi
}

u_list() {
  count_users
  if [ "$N_TOTAL" -eq 0 ]; then
    printf '\n  %s(ยังไม่มีผู้ใช้ - เลือกเมนู "เพิ่มผู้ใช้")%s\n' "$DIM" "$RST"; return 0
  fi
  printf '\n  %s%-2s %-14s  %-8s %-10s  %s%s\n' "$DIM" "#" "USER" "STATUS" "EXPIRES" "LEFT" "$RST"
  _i=0; _nexp=0; _noff=0
  while IFS='|' read -r _u _p _e _s; do
    [ -n "$_u" ] || continue
    _i=$((_i + 1))
    case $(eff "$_e" "$_s") in
      active)  _c=$GRN; _l=ACTIVE;  _lf=$(left_str "$_e") ;;
      expired) _c=$RED; _l=EXPIRED; _lf=-; _nexp=$((_nexp + 1)) ;;
      *)       _c=$YEL; _l=OFF;     _lf=-; _noff=$((_noff + 1)) ;;
    esac
    printf '  %-2s %-14s %s●%s %-8s %-10s  %s\n' "$_i" "$_u" "$_c" "$RST" "$_l" "$(fmt_day "$_e")" "$_lf"
  done <"$DB"
  printf '\n  %sรวม %s บัญชี · ใช้งาน %s · หมดอายุ %s · ปิด %s%s\n' "$DIM" "$N_TOTAL" "$N_ACTIVE" "$_nexp" "$_noff" "$RST"
}

# ------------------------------------------------------------------ interactive helpers
pick_user() { # -> PICK
  ask "ผู้ใช้ (ลำดับ หรือ ชื่อ)" ""
  [ -n "$ANS" ] || return 1
  if db_find "$ANS"; then PICK=$ANS; return 0; fi
  case $ANS in *[!0-9]*) bad "ไม่พบผู้ใช้ '$ANS'"; return 1 ;; esac
  db_nth "$ANS" && return 0
  bad "ไม่พบผู้ใช้ลำดับที่ $ANS"; return 1
}

ui_add() {
  sect "เพิ่มผู้ใช้ใหม่"
  ask "ชื่อผู้ใช้" ""; _nu=$ANS
  valid_user "$_nu" || { bad "ชื่อผู้ใช้ไม่ถูกต้อง (3-32 ตัว: a-z A-Z 0-9 _ -)"; return 1; }
  ask "รหัสผ่าน (เว้นว่าง = สุ่มให้)" ""; _np=$ANS
  ask "จำนวนวัน" "30"; _nd=$ANS
  locked u_add "$_nu" "$_np" "$_nd"
}
ui_pick_then() { # $1 = label, rest = callback taking user
  _cb=$1; shift
  u_list; count_users; [ "$N_TOTAL" -gt 0 ] || return 0
  echo
  pick_user || return 1
  "$_cb" "$PICK"
}
ui_info()   { ui_pick_then _cb_info; }
_cb_info()  { show_info "$1"; }
ui_renew()  { ui_pick_then _cb_renew; }
_cb_renew() { ask "ต่ออายุกี่วัน" "30"; locked u_renew "$1" "$ANS"; }
ui_passwd() { ui_pick_then _cb_passwd; }
_cb_passwd() { ask "รหัสผ่านใหม่ (เว้นว่าง = สุ่มให้)" ""; locked u_passwd "$1" "$ANS"; }
ui_toggle() { ui_pick_then _cb_toggle; }
_cb_toggle() {
  db_find "$1"
  if [ "$F_STAT" = active ]; then yesno "ปิดใช้งาน '$1' ?" && locked u_set "$1" off
  else yesno "เปิดใช้งาน '$1' ?" && locked u_set "$1" on; fi
  return 0
}
ui_del()    { ui_pick_then _cb_del; }
_cb_del()   { yesno "ยืนยันลบผู้ใช้ '$1' ?" && locked u_del "$1"; return 0; }

# ------------------------------------------------------------------ system operations
chk() { _lbl=$1; shift; if "$@" >/dev/null 2>&1; then ok "$_lbl"; else bad "$_lbl"; HBAD=$((HBAD + 1)); fi; }
f_bin()  { [ -x "$BIN" ]; }
f_cfg()  { [ -s "$CFG" ]; }
f_cert() { [ -s "$ETC/zivpn.crt" ] && [ -s "$ETC/zivpn.key" ]; }
t_timer() { sysq zivpn-expire.timer; }

do_health() {
  HBAD=0
  sect "ตรวจสุขภาพระบบ"
  chk "ไฟล์โปรแกรม ZIVPN ($BIN)" f_bin
  chk "ไฟล์ตั้งค่า config.json" f_cfg
  chk "ใบรับรอง TLS" f_cert
  chk "บริการ zivpn ทำงานอยู่" svc_active
  chk "พอร์ต udp/$PORT กำลังรอรับ" udp_listening
  [ -n "$RANGE" ] && chk "Port hopping $RANGE → $PORT" nat_present
  chk "ตัวตัดบัญชีหมดอายุ (timer)" t_timer
  echo
  if [ "$HBAD" -eq 0 ]; then ok "ระบบปกติทุกอย่าง"; else bad "พบปัญหา $HBAD รายการ"; fi
  return "$HBAD"
}

_st() { # label unit
  if sysq "$2"; then printf '  %s●%s %-22s %sRUNNING%s\n' "$GRN" "$RST" "$1" "$GRN" "$RST"
  else printf '  %s●%s %-22s %sSTOPPED%s\n' "$RED" "$RST" "$1" "$RED" "$RST"; fi
}
do_status() {
  sect "สถานะบริการ"
  _st "zivpn (UDP $PORT)" zivpn.service
  [ -n "$RANGE" ] && _st "port hopping" zivpn-nat.service
  _st "expire timer" zivpn-expire.timer
  count_users
  printf '\n  %sผู้ใช้ %s บัญชี (ใช้งานได้ %s)%s\n' "$DIM" "$N_TOTAL" "$N_ACTIVE" "$RST"
}

do_restart() {
  sc restart zivpn.service; sleep 1
  if svc_active; then ok "รีสตาร์ท ZIVPN แล้ว"; else bad "รีสตาร์ทไม่สำเร็จ - ดู: journalctl -u zivpn -n 30"; return 1; fi
}

do_backup() {
  mkdir -p "$BACKUPS"; chmod 700 "$BACKUPS"
  _f="$BACKUPS/zivpn-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$_f" -C "${ETC%/*}" "${ETC##*/}" 2>/dev/null || { bad "สำรองข้อมูลไม่สำเร็จ"; return 1; }
  chmod 600 "$_f"
  ls -1t "$BACKUPS"/zivpn-*.tar.gz 2>/dev/null | tail -n +11 | while IFS= read -r _old; do rm -f "$_old"; done
  ok "สำรองข้อมูลแล้ว"
  info "$_f"
}

do_restore() { # [file]
  _rf=${1:-}
  if [ -z "$_rf" ]; then
    sect "กู้คืนข้อมูล"
    _i=0
    for _f in $(ls -1t "$BACKUPS"/zivpn-*.tar.gz 2>/dev/null); do
      _i=$((_i + 1)); printf '  %s %s\n' "$_i" "${_f##*/}"
    done
    [ "$_i" -gt 0 ] || { warn "ยังไม่มีไฟล์สำรองใน $BACKUPS"; return 0; }
    ask "เลือกลำดับไฟล์" "1"
    case $ANS in *[!0-9]*|"") bad "ลำดับไม่ถูกต้อง"; return 1 ;; esac
    _rf=$(ls -1t "$BACKUPS"/zivpn-*.tar.gz 2>/dev/null | sed -n "${ANS}p")
  fi
  [ -f "$_rf" ] || { bad "ไม่พบไฟล์: $_rf"; return 1; }
  tar -tzf "$_rf" 2>/dev/null | grep -E "^${ETC##*/}/users.db$" >/dev/null || { bad "ไฟล์สำรองนี้ใช้ไม่ได้"; return 1; }
  [ -n "${1:-}" ] || yesno "กู้คืนจาก ${_rf##*/} ? (ข้อมูลปัจจุบันจะถูกสำรองไว้ก่อน)" || return 0
  do_backup >/dev/null
  tar -xzf "$_rf" -C "${ETC%/*}" || { bad "แตกไฟล์ไม่สำเร็จ"; return 1; }
  load_conf
  apply force || return 1
  ok "กู้คืนข้อมูลเรียบร้อย"
}

do_expire() { # run by systemd timer every minute
  if command -v flock >/dev/null 2>&1; then exec 9>"$LOCK"; flock -n 9 || exit 0; fi
  apply
}

do_uninstall() {
  sect "ถอนการติดตั้ง ZIVPN"
  echo "   1  ถอนโปรแกรม (เก็บข้อมูลผู้ใช้ไว้ ติดตั้งใหม่แล้วใช้ต่อได้)"
  echo "   2  ลบทุกอย่าง (รวมผู้ใช้ ใบรับรอง และไฟล์สำรอง)"
  echo "   0  ยกเลิก"
  ask "เลือก" "0"; _um=$ANS
  case $_um in 1|2) ;; *) info "ยกเลิก"; return 0 ;; esac
  yesno "ยืนยันถอนการติดตั้ง ?" || { info "ยกเลิก"; return 0; }
  nat_down
  sc disable --now zivpn.service zivpn-nat.service zivpn-expire.timer >/dev/null 2>&1
  sc stop zivpn-expire.service >/dev/null 2>&1
  rm -f "$UNITS/zivpn.service" "$UNITS/zivpn-nat.service" "$UNITS/zivpn-expire.service" "$UNITS/zivpn-expire.timer"
  sc daemon-reload
  rm -f "$BIN"
  if [ "$DRY" != 1 ] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep 'Status: active' >/dev/null; then
    ufw delete allow "$PORT/udp" >/dev/null 2>&1
    [ -n "$RANGE" ] && ufw delete allow "$RANGE/udp" >/dev/null 2>&1
  fi
  if [ "$_um" = 2 ]; then
    case $ETC in ''|/|/etc|/etc/) die "ETC path ไม่ปลอดภัย: $ETC" ;; esac
    rm -rf "$ETC" "$BACKUPS"
    ok "ลบข้อมูลทั้งหมดแล้ว"
  else
    info "เก็บข้อมูลผู้ใช้ไว้ที่ $ETC"
  fi
  rm -f "$SELF"
  ok "ถอนการติดตั้งเรียบร้อย"
  if hy_installed; then
    info "Hysteria ยังอยู่ (ไม่ได้ลบ) - จัดการต่อด้วย: bash $SHARE/hysteria.sh"
  fi
  exit 0
}

# ------------------------------------------------------------------ hysteria (ตัวเสริม - แยกจาก ZIVPN)
# Hysteria ใช้ service (hysteria-server) / โฟลเดอร์ (/etc/hysteria) / iptables chain (HYSTERIA_DNAT) ของตัวเอง
# และ hysteria.sh ตรวจพอร์ตไม่ให้ชนกับ ZIVPN จึงไม่กระทบ ZIVPN ที่ติดตั้งไว้
hy_installed() { [ -x "$HY_BIN" ] && [ -f /etc/hysteria/config.json ]; }

hy_label() {
  if hy_installed; then
    if sysq hysteria-server.service; then printf '%s● RUNNING%s' "$GRN" "$RST"
    else printf '%s● STOPPED%s' "$RED" "$RST"; fi
  else
    printf '%sยังไม่ติดตั้ง%s' "$DIM" "$RST"
  fi
}

hy_fetch_one() { # $1 = ชื่อไฟล์ -> $SHARE/$1
  command -v curl >/dev/null 2>&1 || return 1
  _hd="$SHARE/$1"; _ht="$_hd.part.$$"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$_ht" "$RAW/$1" || { rm -f "$_ht"; return 1; }
  case $(head -n 1 "$_ht") in '#!'*) ;; *) rm -f "$_ht"; return 1 ;; esac
  chmod 755 "$_ht" && mv -f "$_ht" "$_hd"
}

hy_ensure() { # ไฟล์ติดตั้งครบไหม - ถ้าขาดจะโหลดให้
  mkdir -p "$SHARE" && chmod 755 "$SHARE" || return 1
  for _hf in hysteria.sh install_server.sh; do
    [ -s "$SHARE/$_hf" ] && continue
    info "กำลังดาวน์โหลด $_hf …"
    hy_fetch_one "$_hf" || { bad "ดาวน์โหลด $_hf ไม่สำเร็จ ($RAW/$_hf)"; return 1; }
  done
  return 0
}

do_hysteria() {
  sect "Hysteria"
  command -v bash >/dev/null 2>&1 || { bad "ต้องมี bash (apt-get install -y bash)"; return 1; }
  hy_ensure || return 1
  info "ZIVPN (udp/$PORT${RANGE:+ + $RANGE}) จะไม่ถูกแตะต้อง - Hysteria แยกบริการ/ไฟล์/กฎ iptables และไม่ใช้พอร์ตซ้ำกับ ZIVPN"
  # umask 077 ของ m ไม่ควรส่งต่อไปให้ hysteria (ไฟล์ config/ใบรับรองต้องอ่านได้ตามปกติ)
  ( umask 022; ZP_ETC="$ETC" bash "$SHARE/hysteria.sh" )
  _hrc=$?
  # เช็กหลังกลับมา: ZIVPN ต้องยังปกติ - ถ้ากฎ port hopping หายให้ใส่คืน
  if [ -n "$RANGE" ] && ! nat_present; then
    warn "กฎ port hopping ของ ZIVPN หายไป - กำลังใส่คืน"
    nat_up && ok "คืนกฎ port hopping ($RANGE → $PORT) แล้ว"
  fi
  if svc_active; then ok "ZIVPN ยังทำงานปกติ"; else warn "ZIVPN ไม่ทำงาน - ลอง: m restart"; fi
  return "$_hrc"
}

# ------------------------------------------------------------------ menu
clr() { [ "$TTY" = 1 ] && printf '\033[H\033[2J'; return 0; }

draw_menu() {
  clr
  banner
  count_users
  if svc_active; then _sv="${GRN}● RUNNING${RST}"; else _sv="${RED}● STOPPED${RST}"; fi
  printf '\n  %sServer%s   %s  %sudp/%s%s%s\n' "$DIM" "$RST" "${HOST:-?}" "$DIM" "$PORT" "${RANGE:+ +$RANGE}" "$RST"
  printf '  %sService%s  %s   %sUsers %s/%s%s\n' "$DIM" "$RST" "$_sv" "$DIM" "$N_ACTIVE" "$N_TOTAL" "$RST"
  printf '\n  %s── ผู้ใช้ ──────────────────────────────%s\n' "$DIM" "$RST"
  printf '   %s1%s  รายการผู้ใช้\n'          "$CYN" "$RST"
  printf '   %s2%s  เพิ่มผู้ใช้\n'           "$CYN" "$RST"
  printf '   %s3%s  ข้อมูลเชื่อมต่อ\n'      "$CYN" "$RST"
  printf '   %s4%s  ต่ออายุ\n'              "$CYN" "$RST"
  printf '   %s5%s  เปลี่ยนรหัสผ่าน\n'      "$CYN" "$RST"
  printf '   %s6%s  เปิด / ปิดบัญชี\n'      "$CYN" "$RST"
  printf '   %s7%s  ลบผู้ใช้\n'             "$CYN" "$RST"
  printf '\n  %s── ระบบ ───────────────────────────────%s\n' "$DIM" "$RST"
  printf '   %s8%s  สถานะบริการ\n'          "$CYN" "$RST"
  printf '   %s9%s  รีสตาร์ท ZIVPN\n'       "$CYN" "$RST"
  printf '  %s10%s  ตรวจสุขภาพระบบ\n'       "$CYN" "$RST"
  printf '  %s11%s  สำรองข้อมูล\n'          "$CYN" "$RST"
  printf '  %s12%s  กู้คืนข้อมูล\n'         "$CYN" "$RST"
  printf '  %s13%s  ถอนการติดตั้ง\n'        "$CYN" "$RST"
  printf '\n  %s── เสริม ──────────────────────────────%s\n' "$DIM" "$RST"
  printf '  %s14%s  ติดตั้ง / จัดการ Hysteria   %s\n' "$CYN" "$RST" "$(hy_label)"
  printf '   %s0%s  ออก\n\n'                "$CYN" "$RST"
}

menu() {
  while :; do
    load_conf
    draw_menu
    printf '  %s❯%s ' "$CYN" "$RST"
    IFS= read -r CH || { echo; exit 0; }
    CH=${CH#"${CH%%[![:space:]]*}"}; CH=${CH%"${CH##*[![:space:]]}"}
    case $CH in
      1|"") u_list ;;
      2) ui_add ;;
      3) ui_info ;;
      4) ui_renew ;;
      5) ui_passwd ;;
      6) ui_toggle ;;
      7) ui_del ;;
      8) do_status ;;
      9) do_restart ;;
      10) do_health ;;
      11) do_backup ;;
      12) do_restore ;;
      13) do_uninstall ;;
      14) do_hysteria ;;
      0|q|Q) exit 0 ;;
      *) bad "ไม่รู้จักเมนู: $CH" ;;
    esac
    pause
  done
}

usage() {
  banner
  cat <<EOF

  ใช้งาน:  m [คำสั่ง]        (ไม่ใส่คำสั่ง = เปิดเมนู)

    list                         รายการผู้ใช้
    add USER [PASS] [DAYS]       เพิ่มผู้ใช้ (PASS ว่าง = สุ่ม, DAYS เริ่มต้น 30)
    info USER                    ข้อมูลเชื่อมต่อ
    renew USER DAYS              ต่ออายุ
    passwd USER [PASS]           เปลี่ยนรหัสผ่าน (ว่าง = สุ่ม)
    on USER | off USER           เปิด/ปิดบัญชี
    del USER                     ลบผู้ใช้
    status | health | restart    ระบบ
    backup | restore FILE        สำรอง/กู้คืน
    uninstall                    ถอนการติดตั้ง
    hysteria                     ติดตั้ง/จัดการ Hysteria (ไม่กระทบ ZIVPN)
EOF
}

# ------------------------------------------------------------------ machine-readable (used by the web panel)
#   m api status  -> key=value lines
#   m api list    -> user|password|expiry_epoch|active|expired|off
do_api() {
  case ${1:-} in
    status)
      count_users
      if svc_active; then _sv=1; else _sv=0; fi
      printf 'version=%s\nhost=%s\nport=%s\nrange=%s\nobfs=%s\nservice=%s\ntotal=%s\nactive=%s\nnow=%s\n' \
        "$VERSION" "$HOST" "$PORT" "$RANGE" "$OBFS" "$_sv" "$N_TOTAL" "$N_ACTIVE" "$(now)"
      ;;
    list)
      while IFS='|' read -r _u _p _e _s; do
        [ -n "$_u" ] || continue
        printf '%s|%s|%s|%s\n' "$_u" "$_p" "$_e" "$(eff "$_e" "$_s")"
      done <"$DB"
      ;;
    *) die "m api status|list" ;;
  esac
}

# ------------------------------------------------------------------ main
main() {
  case "${1:-menu}" in -h|--help|help) usage; exit 0 ;; -v|--version|version) echo "$VERSION"; exit 0 ;; esac
  [ "$(id -u)" -eq 0 ] || [ "$DRY" = 1 ] || die "ต้องรันด้วย root (sudo m)"
  need_installed
  load_conf
  db_init
  _cmd=${1:-menu}; [ $# -gt 0 ] && shift
  case $_cmd in
    menu)        menu ;;
    list|ls)     u_list ;;
    add)         if [ $# -eq 0 ]; then ui_add; else locked u_add "${1:-}" "${2:-}" "${3:-30}"; fi ;;
    info)        show_info "${1:-}" ;;
    renew)       locked u_renew "${1:-}" "${2:-30}" ;;
    passwd)      locked u_passwd "${1:-}" "${2:-}" ;;
    on)          locked u_set "${1:-}" on ;;
    off)         locked u_set "${1:-}" off ;;
    del|rm)      locked u_del "${1:-}" ;;
    status)      do_status ;;
    health)      do_health ;;
    restart)     do_restart ;;
    backup)      do_backup ;;
    restore)     do_restore "${1:-}" ;;
    uninstall)   do_uninstall ;;
    hysteria|hy) do_hysteria ;;
    api)         do_api "${1:-}" ;;
    # internal (used by installer / systemd)
    render)      locked render; [ $? -le 1 ] ;;
    sync)        locked apply force ;;
    expire)      do_expire ;;
    nat)         case ${1:-} in up) nat_up ;; down) nat_down ;; *) die "m nat up|down" ;; esac ;;
    *)           bad "ไม่รู้จักคำสั่ง: $_cmd"; usage; exit 1 ;;
  esac
}

main "$@"
