#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN='\033[0m'

red() {
    echo -e "\033[31m\033[01m$1\033[0m"
}

green() {
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow() {
    echo -e "\033[33m\033[01m$1\033[0m"
}

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Alpine")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update" "apk update -f")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install" "apk add -f")
PACKAGE_UNINSTALL=("apt -y autoremove" "apt -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove" "apk del -f")

[[ $EUID -ne 0 ]] && red "คำเตือน: กรุณารันสคริปต์นี้ด้วยผู้ใช้ root (sudo)" && exit 1

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
    fi
done

[[ -z $SYSTEM ]] && red "ไม่รองรับระบบของ VPS นี้ กรุณาใช้ระบบปฏิบัติการที่เป็นที่นิยม (Debian/Ubuntu/CentOS/Fedora/Alpine)" && exit 1

realip(){
    ip=$(curl -s4m8 ip.gs -k) || ip=$(curl -s6m8 ip.gs -k)
}

# ---------------------------------------------------------------------------
# ส่วนที่เพิ่ม: อยู่ร่วมกับ ZIVPN ได้โดยไม่กระทบกัน
#  - Hysteria ใช้ iptables chain ของตัวเอง (HYSTERIA_DNAT) ไม่ล้าง PREROUTING ทั้งก้อนอีกต่อไป
#  - ไม่ให้เลือกพอร์ต/ช่วงพอร์ตที่ชนกับ ZIVPN (พอร์ตหลัก + ช่วง port hopping)
#  - ใช้ install_server.sh ที่อยู่โฟลเดอร์เดียวกับสคริปต์นี้ (ไม่ดาวน์โหลดจากที่อื่น)
# ---------------------------------------------------------------------------
HY_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
HY_CHAIN="HYSTERIA_DNAT"
ZIVPN_CONF="${ZP_ETC:-/etc/zivpn}/manager.conf"
zv_port=""
zv_range=""

load_zivpn(){
    zv_port=""; zv_range=""
    [[ -r $ZIVPN_CONF ]] || return 0
    zv_port=$(sed -n "s/^PORT='\([0-9]*\)'$/\1/p" "$ZIVPN_CONF" | head -n1)
    zv_range=$(sed -n "s/^RANGE='\([0-9]*:[0-9]*\)'$/\1/p" "$ZIVPN_CONF" | head -n1)
}

# พอร์ตเดี่ยวชนกับ ZIVPN หรือไม่ (0 = ชน)
zv_conflict_port(){
    local p=$1 a b
    [[ -n $zv_port && $p == "$zv_port" ]] && return 0
    if [[ -n $zv_range ]]; then
        a=${zv_range%:*}; b=${zv_range#*:}
        (( p >= a && p <= b )) && return 0
    fi
    return 1
}

# ช่วงพอร์ตซ้อนกับ ZIVPN หรือไม่ (0 = ซ้อน)
zv_conflict_range(){
    local f=$1 e=$2 a b
    [[ -n $zv_port ]] && (( zv_port >= f && zv_port <= e )) && return 0
    if [[ -n $zv_range ]]; then
        a=${zv_range%:*}; b=${zv_range#*:}
        (( f <= b && e >= a )) && return 0
    fi
    return 1
}

# ลบเฉพาะกฎของ Hysteria (ไม่แตะกฎของ ZIVPN หรือโปรแกรมอื่น)
hy_nat_clear(){
    local t
    for t in iptables ip6tables; do
        command -v "$t" >/dev/null 2>&1 || continue
        while "$t" -w -t nat -D PREROUTING -p udp -j "$HY_CHAIN" 2>/dev/null; do :; done
        "$t" -w -t nat -F "$HY_CHAIN" 2>/dev/null
        "$t" -w -t nat -X "$HY_CHAIN" 2>/dev/null
    done
    return 0
}

# hy_nat_add FIRST END PORT
hy_nat_add(){
    local t
    for t in iptables ip6tables; do
        command -v "$t" >/dev/null 2>&1 || continue
        "$t" -w -t nat -N "$HY_CHAIN" 2>/dev/null
        "$t" -w -t nat -F "$HY_CHAIN" 2>/dev/null
        "$t" -w -t nat -A "$HY_CHAIN" -p udp --dport "$1:$2" -j DNAT --to-destination ":$3" 2>/dev/null || { [[ $t == iptables ]] && return 1; }
        "$t" -w -t nat -C PREROUTING -p udp -j "$HY_CHAIN" 2>/dev/null || "$t" -w -t nat -A PREROUTING -p udp -j "$HY_CHAIN" 2>/dev/null
    done
    return 0
}

inst_cert(){
    green "วิธีขอใบรับรอง (certificate) ของ Hysteria:"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} ใบรับรองที่เซ็นเองตามแบบ Bing ${YELLOW}（ค่าเริ่มต้น）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} ขออัตโนมัติด้วยสคริปต์ Acme"
    echo -e " ${GREEN}3.${PLAIN} กำหนดพาธใบรับรองเอง"
    echo ""
    read -rp "กรุณาเลือกตัวเลือก [1-3]: " certInput
    if [[ $certInput == 2 ]]; then
        cert_path="/root/cert.crt"
        key_path="/root/private.key"
        if [[ -f /root/cert.crt && -f /root/private.key ]] && [[ -s /root/cert.crt && -s /root/private.key ]] && [[ -f /root/ca.log ]]; then
            domain=$(cat /root/ca.log)
            green "ตรวจพบใบรับรองของโดเมนเดิม: $domain กำลังนำไปใช้"
            hy_ym=$domain
        else
            WARPv4Status=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
            WARPv6Status=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
            if [[ $WARPv4Status =~ on|plus ]] || [[ $WARPv6Status =~ on|plus ]]; then
                wg-quick down wgcf >/dev/null 2>&1
                systemctl stop warp-go >/dev/null 2>&1
                realip
                wg-quick up wgcf >/dev/null 2>&1
                systemctl start warp-go >/dev/null 2>&1
            else
                realip
            fi
            
            read -p "กรุณากรอกโดเมนที่จะขอใบรับรอง: " domain
            [[ -z $domain ]] && red "ไม่ได้กรอกโดเมน ไม่สามารถดำเนินการได้!" && exit 1
            green "โดเมนที่กรอก: $domain" && sleep 1
            domainIP=$(dig @8.8.8.8 +time=2 +short "$domain" 2>/dev/null)
            if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]]; then
                domainIP=$(dig @2001:4860:4860::8888 +time=2 aaaa +short "$domain" 2>/dev/null)
            fi
            if echo $domainIP | grep -q "network unreachable\|timed out" || [[ -z $domainIP ]] ; then
                red "ไม่สามารถแยก IP ของโดเมนได้ กรุณาตรวจสอบว่าโดเมนที่กรอกถูกต้องหรือไม่"
                yellow "ต้องการลองจับคู่แบบบังคับไหม?"
                green "1. ใช่ จะใช้การจับคู่แบบบังคับ"
                green "2. ไม่ ออกจากสคริปต์"
                read -p "กรุณาเลือกตัวเลือก [1-2]: " ipChoice
                if [[ $ipChoice == 1 ]]; then
                    yellow "จะลองจับคู่แบบบังคับเพื่อขอใบรับรองโดเมน"
                else
                    red "จะออกจากสคริปต์"
                    exit 1
                fi
            fi
            if [[ $domainIP == $ip ]]; then
                ${PACKAGE_INSTALL[int]} curl wget sudo socat openssl
                if [[ $SYSTEM == "CentOS" ]]; then
                    ${PACKAGE_INSTALL[int]} cronie
                    systemctl start crond
                    systemctl enable crond
                else
                    ${PACKAGE_INSTALL[int]} cron
                    systemctl start cron
                    systemctl enable cron
                fi
                curl https://get.acme.sh | sh -s email=$(date +%s%N | md5sum | cut -c 1-16)@gmail.com
                source ~/.bashrc
                bash ~/.acme.sh/acme.sh --upgrade --auto-upgrade
                bash ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
                if [[ -n $(echo $ip | grep ":") ]]; then
                    bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --listen-v6 --insecure
                else
                    bash ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256 --insecure
                fi
                bash ~/.acme.sh/acme.sh --install-cert -d ${domain} --key-file /root/private.key --fullchain-file /root/cert.crt --ecc
                if [[ -f /root/cert.crt && -f /root/private.key ]] && [[ -s /root/cert.crt && -s /root/private.key ]]; then
                    echo $domain > /root/ca.log
                    sed -i '/--cron/d' /etc/crontab >/dev/null 2>&1
                    echo "0 0 * * * root bash /root/.acme.sh/acme.sh --cron -f >/dev/null 2>&1" >> /etc/crontab
                    green "ขอใบรับรองสำเร็จ! ไฟล์ใบรับรอง (cert.crt) และคีย์ส่วนตัว (private.key) ถูกบันทึกไว้ในโฟลเดอร์ /root"
                    yellow "พาธไฟล์ใบรับรอง .crt คือ: /root/cert.crt"
                    yellow "พาธไฟล์คีย์ส่วนตัว .key คือ: /root/private.key"
                    hy_ym=$domain
                fi
            else
                red "IP ที่โดเมนชี้ไปไม่ตรงกับ IP จริงของ VPS นี้"
                green "คำแนะนำ:"
                yellow "1. ตรวจว่า Cloudflare ลูกโม่ (cloud) ปิดอยู่ (ใช้เป็น DNS เท่านั้น) สำหรับ DNS อื่นหรือ CDN ก็ตั้งแบบเดียวกัน"
                yellow "2. ตรวจว่า IP ที่ตั้งในการแยก DNS ชี้ไป ตรงกับ IP จริงของ VPS หรือไม่"
                yellow "3. สคริปต์อาจไม่ทันยุค แนะนำแคปหน้าจอไปถามใน GitHub Issues, GitLab Issues, เว็บบอร์ด หรือกลุ่ม TG"
                exit 1
            fi
        fi
    elif [[ $certInput == 3 ]]; then
        read -p "กรุณากรอกพาธของไฟล์ใบรับรอง (.crt): " certpath
        yellow "พาธไฟล์ใบรับรอง .crt: $certpath "
        read -p "กรุณากรอกพาธของไฟล์คีย์ส่วนตัว (.key): " keypath
        yellow "พาธไฟล์คีย์ส่วนตัว .key: $keypath "
        read -p "กรุณากรอกโดเมนของใบรับรอง: " domain
        yellow "โดเมนของใบรับรอง: $domain"
        hy_ym=$domain
    else
        green "จะใช้ใบรับรองที่เซ็นเองตามแบบ Bing เป็นใบรับรองของโหนด Hysteria"

        cert_path="/etc/hysteria/cert.crt"
        key_path="/etc/hysteria/private.key"
        openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/private.key
        openssl req -new -x509 -days 36500 -key /etc/hysteria/private.key -out /etc/hysteria/cert.crt -subj "/CN=www.bing.com"
        chmod 777 /etc/hysteria/cert.crt
        chmod 777 /etc/hysteria/private.key
        hy_ym="www.bing.com"
        domain="www.bing.com"
    fi
}

inst_pro(){
    green "โปรโตคอลของโหนด Hysteria:"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} UDP ${YELLOW}（ค่าเริ่มต้น）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} wechat-video"
    echo -e " ${GREEN}3.${PLAIN} faketcp"
    echo ""
    read -rp "กรุณาเลือกตัวเลือก [1-3]: " proInput
    if [[ $proInput == 2 ]]; then
        protocol="wehcat-video"
    elif [[ $proInput == 3 ]]; then
        protocol="faketcp"
    else
        protocol="udp"
    fi
    yellow "จะใช้ $protocol เป็นโปรโตคอลของโหนด Hysteria"
}

inst_port(){
    # ล้างเฉพาะกฎ port hopping ของ Hysteria เอง (เดิมใช้ iptables -t nat -F PREROUTING ซึ่งจะลบกฎของ ZIVPN ด้วย)
    hy_nat_clear
    load_zivpn
    [[ -n $zv_port ]] && yellow "ตรวจพบ ZIVPN: พอร์ต $zv_port${zv_range:+ และช่วง hopping $zv_range} - จะไม่ใช้ซ้ำกับ Hysteria"

    local p
    while :; do
        read -p "ตั้งพอร์ต Hysteria [1-65535]（กด Enter เพื่อสุ่มพอร์ต）: " p || exit 1
        [[ -z $p ]] && p=$(shuf -i 2000-65535 -n 1)
        if [[ ! $p =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
            red "พอร์ตไม่ถูกต้อง กรุณากรอกตัวเลข 1-65535"
            continue
        fi
        if zv_conflict_port "$p"; then
            echo -e "${RED} $p ${PLAIN} ชนกับพอร์ตหรือช่วงพอร์ตของ ZIVPN กรุณาเลือกพอร์ตอื่น!"
            continue
        fi
        if [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$p") ]]; then
            echo -e "${RED} $p ${PLAIN} พอร์ตนี้ถูกโปรแกรมอื่นใช้งานอยู่แล้ว กรุณาเปลี่ยนพอร์ตแล้วลองใหม่!"
            continue
        fi
        break
    done
    port=$p

    yellow "พอร์ตที่จะใช้บนโหนด Hysteria คือ: $port"

    if [[ $protocol == "udp" ]]; then
        inst_jump
    fi
}

inst_jump(){
    firstport=""; endport=""
    yellow "โปรโตคอลที่เลือกคือ udp รองรับฟังก์ชันข้ามพอร์ต (port hopping)"
    green "รูปแบบการใช้พอร์ตของ Hysteria:"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} พอร์ตเดียว ${YELLOW}（ค่าเริ่มต้น）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} ข้ามพอร์ต (port hopping)"
    echo ""
    read -rp "กรุณาเลือกตัวเลือก [1-2]: " jumpInput
    if [[ $jumpInput == 2 ]]; then
        while :; do
            read -p "ตั้งพอร์ตเริ่มต้นของช่วง (แนะนำระหว่าง 10000-65535): " firstport || exit 1
            read -p "ตั้งพอร์ตปลายของช่วง (แนะนำ 10000-65535 ต้องมากกว่าพอร์ตเริ่มต้น): " endport || exit 1
            if [[ ! $firstport =~ ^[0-9]+$ || ! $endport =~ ^[0-9]+$ ]] || (( firstport < 1 || endport > 65535 || firstport >= endport )); then
                red "ต้องกรอกพอร์ตเริ่มต้นให้น้อยกว่าพอร์ตปลาย (ตัวเลข 1-65535) กรุณากรอกใหม่"
                continue
            fi
            if zv_conflict_range "$firstport" "$endport"; then
                red "ช่วง $firstport-$endport ซ้อนกับพอร์ต/ช่วงของ ZIVPN (${zv_port}${zv_range:+, $zv_range}) กรุณากรอกใหม่"
                continue
            fi
            break
        done
        hy_nat_add "$firstport" "$endport" "$port" || red "เพิ่มกฎ iptables ไม่สำเร็จ"
        netfilter-persistent save >/dev/null 2>&1
    else
        red "จะใช้โหมดพอร์ตเดียวต่อไป"
    fi
}

# ---------------------------------------------------------------------------
# โหมดอัตโนมัติ: ตอนติดตั้งถามแค่ auth_str กับ obfs ส่วนที่เหลือตั้งให้เอง
#   ใบรับรอง = เซ็นเอง · โปรโตคอล = udp · พอร์ต = สุ่ม · port hopping = 20000-50000
# ปรับเองได้ด้วยตัวแปร (ไม่ต้องกดถาม): HY_AUTH HY_OBFS HY_PORT HY_RANGE (a:b หรือ off) HY_YES=1
# ---------------------------------------------------------------------------
auto_cert(){
    mkdir -p /etc/hysteria
    cert_path="/etc/hysteria/cert.crt"
    key_path="/etc/hysteria/private.key"
    openssl ecparam -genkey -name prime256v1 -out "$key_path" >/dev/null 2>&1
    openssl req -new -x509 -days 36500 -key "$key_path" -out "$cert_path" -subj "/CN=www.bing.com" >/dev/null 2>&1
    chmod 644 "$cert_path"
    chmod 600 "$key_path"
    hy_ym="www.bing.com"
    domain="www.bing.com"
    if [[ -s $cert_path && -s $key_path ]]; then
        green "สร้างใบรับรอง (เซ็นเอง) อัตโนมัติแล้ว"
    else
        red "สร้างใบรับรองไม่สำเร็จ (ต้องมี openssl)"; return 1
    fi
}

# ตั้งช่วง hopping อัตโนมัติ -> firstport/endport (ว่าง = ไม่ใช้ hopping)
auto_jump(){
    firstport=""; endport=""
    local r=${HY_RANGE:-auto} f e b
    if [[ $r == off ]]; then
        yellow "ปิด port hopping (HY_RANGE=off)"; return 0
    fi
    if [[ $r != auto ]]; then
        IFS=':-' read -r f e <<< "$r"
        if [[ $f =~ ^[0-9]+$ && $e =~ ^[0-9]+$ ]] && (( f >= 1 && e <= 65535 && f < e )) && ! zv_conflict_range "$f" "$e"; then
            firstport=$f; endport=$e; return 0
        fi
        red "HY_RANGE=$r ใช้ไม่ได้ (ไม่ถูกต้อง หรือซ้อนกับ ZIVPN) - ใช้ค่าอัตโนมัติแทน"
    fi
    f=20000; e=50000
    if zv_conflict_range "$f" "$e"; then
        # ช่วงมาตรฐานซ้อนกับ ZIVPN -> เลื่อนไปต่อท้ายช่วงของ ZIVPN
        b=${zv_range#*:}
        f=$(( b + 1 > 20000 ? b + 1 : 20000 ))
        e=$(( f + 30000 )); (( e > 65000 )) && e=65000
        if (( e - f < 1000 )) || zv_conflict_range "$f" "$e"; then
            yellow "หาช่วง hopping ที่ไม่ซ้อนกับ ZIVPN ไม่ได้ - ใช้พอร์ตเดียว"
            return 0
        fi
    fi
    firstport=$f; endport=$e
}

# สุ่มพอร์ตหลัก -> port (ไม่ชน ZIVPN / ช่วง hopping / พอร์ตที่ถูกใช้อยู่)
auto_port(){
    local p i
    if [[ -n ${HY_PORT:-} ]]; then
        p=$HY_PORT
        if [[ ! $p =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )) || zv_conflict_port "$p" \
           || [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$p") ]]; then
            red "HY_PORT=$p ใช้ไม่ได้ (ไม่ถูกต้อง ชนกับ ZIVPN หรือถูกใช้อยู่)"; return 1
        fi
        port=$p; return 0
    fi
    for ((i = 0; i < 200; i++)); do
        p=$(shuf -i 10000-65535 -n 1)
        zv_conflict_port "$p" && continue
        [[ -n $firstport ]] && (( p >= firstport && p <= endport )) && continue
        [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$p") ]] && continue
        port=$p; return 0
    done
    red "สุ่มพอร์ตที่ว่างไม่สำเร็จ"; return 1
}

inst_pwd(){
    if [[ -n ${HY_AUTH:-} ]]; then
        if [[ $HY_AUTH =~ ^[A-Za-z0-9_.:@+=-]+$ ]]; then
            auth_pwd=$HY_AUTH; yellow "รหัสผ่านที่ใช้บนโหนด Hysteria คือ: $auth_pwd"; return 0
        fi
        red "HY_AUTH มีอักขระที่ใช้ไม่ได้ - ถามใหม่"
    fi
    while :; do
        read -p "ตั้งรหัสผ่าน Hysteria (auth_str) เช่น user:pass（กด Enter เพื่อสุ่ม）: " auth_pwd || exit 1
        [[ -z $auth_pwd ]] && auth_pwd=$(date +%s%N | md5sum | cut -c 1-8)
        if [[ $auth_pwd =~ ^[A-Za-z0-9_.:@+=-]+$ ]]; then
            break
        fi
        red "ใช้ได้เฉพาะ a-z A-Z 0-9 และ _ . : @ + = - (ห้ามเว้นวรรคหรืออักขระพิเศษอื่น)"
    done
    yellow "รหัสผ่านที่ใช้บนโหนด Hysteria คือ: $auth_pwd"
}

inst_obfs(){
    if [[ -n ${HY_OBFS+x} && $HY_OBFS =~ ^[A-Za-z0-9_.@+=-]*$ ]]; then
        obfs=$HY_OBFS
        if [[ -n $obfs ]]; then yellow "obfs ที่ใช้คือ: $obfs"; else yellow "ไม่ใช้ obfs"; fi
        return 0
    fi
    while :; do
        read -p "ตั้งค่า obfs เช่น jaideevpn（กด Enter = ไม่ใช้ obfs）: " obfs || exit 1
        if [[ -z $obfs || $obfs =~ ^[A-Za-z0-9_.@+=-]+$ ]]; then
            break
        fi
        red "ใช้ได้เฉพาะ a-z A-Z 0-9 และ _ . @ + = - (ห้ามเว้นวรรคหรืออักขระพิเศษอื่น)"
    done
    if [[ -n $obfs ]]; then yellow "obfs ที่ใช้คือ: $obfs"; else yellow "ไม่ใช้ obfs"; fi
}

inst_resolv(){
    green "โหมดการแยกชื่อโดเมนของ Hysteria:"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} IPv4 ก่อน ${YELLOW}（ค่าเริ่มต้น）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} IPv6 ก่อน"
    echo ""
    read -rp "กรุณาเลือกตัวเลือก [1-2]: " resolvInput
    if [[ $resolvInput == 2 ]]; then
        yellow "ตั้งค่าให้แยกโดเมนแบบ IPv6 ก่อน"
        resolv=64
    else
        yellow "ตั้งค่าให้แยกโดเมนแบบ IPv4 ก่อน"
        resolv=46
    fi
}

inst_hy(){
    if [[ -f /etc/hysteria/config.json && ${HY_YES:-0} != 1 ]]; then
        yellow "พบ Hysteria ติดตั้งอยู่แล้ว - การติดตั้งซ้ำจะสร้าง config และไฟล์ไคลเอนต์ใหม่ทั้งหมด"
        read -rp "ติดตั้งซ้ำหรือไม่? (y/N): " yn
        [[ $yn =~ ^[yY] ]] || return 0
    fi

    # ไม่ให้ apt ถามระหว่างติดตั้ง (iptables-persistent ชอบเด้งหน้าต่างถามเรื่องบันทึกกฎ)
    export DEBIAN_FRONTEND=noninteractive
    if command -v debconf-set-selections >/dev/null 2>&1; then
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    fi

    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl wget sudo qrencode procps iptables-persistent netfilter-persistent

    # ใช้ install_server.sh ที่ติดมากับแพ็กเกจนี้ (โฟลเดอร์เดียวกับ hysteria.sh)
    if [[ ! -f "$HY_DIR/install_server.sh" ]]; then
        red "ไม่พบ $HY_DIR/install_server.sh - กรุณารัน install.sh ใหม่ หรือเปิดผ่านเมนู m"
        return 1
    fi
    bash "$HY_DIR/install_server.sh"

    if [[ -f "/usr/local/bin/hysteria" ]]; then
        green "ติดตั้ง Hysteria สำเร็จ!"
    else
        red "ติดตั้ง Hysteria ล้มเหลว!"
    fi

    # ตั้งค่าอัตโนมัติ (ถามแค่ auth_str กับ obfs)
    auto_cert || return 1
    protocol="udp"
    resolv=46
    hy_nat_clear
    load_zivpn
    [[ -n $zv_port ]] && yellow "ตรวจพบ ZIVPN: พอร์ต $zv_port${zv_range:+ และช่วง hopping $zv_range} - จะไม่ใช้ซ้ำ"
    auto_jump
    auto_port || return 1
    if [[ -n $firstport ]]; then
        hy_nat_add "$firstport" "$endport" "$port" || red "เพิ่มกฎ iptables ไม่สำเร็จ"
        netfilter-persistent save >/dev/null 2>&1
    fi
    yellow "พอร์ต Hysteria: $port${firstport:+  ·  port hopping: $firstport-$endport}"
    echo ""
    inst_pwd
    inst_obfs

    # สร้างไฟล์ config ของ Hysteria
    obfs_line=""
    [[ -n $obfs ]] && obfs_line=$'\n'"    \"obfs\": \"$obfs\","
    cat <<EOF > /etc/hysteria/config.json
{
    "protocol": "$protocol",
    "listen": ":$port",$obfs_line
    "resolve_preference": "$resolv",
    "cert": "$cert_path",
    "key": "$key_path",
    "alpn": "h3",
    "auth": {
        "mode": "password",
        "config": {
            "password": "$auth_pwd"
        }
    }
}
EOF

    # หาขอบเขตพอร์ตสุดท้ายที่ลูกค้าใช้
    if [[ -n $firstport ]]; then
        last_port="$firstport-$endport"
    else
        last_port=$port
    fi

    # ดึง IP สาธารณะถ้ายังไม่มี (เดิมตั้งค่าเฉพาะตอนเลือกขอใบรับรองด้วย Acme ทำให้ลิงก์/ไฟล์ config ไม่มีที่อยู่เซิร์ฟเวอร์)
    [[ -z $ip ]] && realip
    [[ -z $ip ]] && ip=$(curl -s4m8 https://api.ipify.org)

    # ครอบ IP ของ IPv6 ด้วยวงเล็บเหลี่ยม
    if [[ -n $(echo $ip | grep ":") ]]; then
        last_ip="[$ip]"
    else
        last_ip=$ip
    fi

    # ถ้าใบรับรองเป็นแบบเซ็นเองตามแบบ Bing ให้ใช้ IP เป็นที่อยู่ของโหนด
    if [[ $hy_ym == "www.bing.com" ]]; then
        WARPv4Status=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
        WARPv6Status=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
        if [[ $WARPv4Status =~ on|plus ]] || [[ $WARPv6Status =~ on|plus ]]; then
            wg-quick down wgcf >/dev/null 2>&1
            systemctl stop warp-go >/dev/null 2>&1
            hy_ym=$last_ip
            wg-quick up wgcf >/dev/null 2>&1
            systemctl start warp-go >/dev/null 2>&1
        else
            hy_ym=$last_ip
        fi
    fi

    # สร้างไฟล์ config ของ V2rayN และ Clash Meta
    mkdir /root/hy >/dev/null 2>&1
    # hy-client.json ใช้รูปแบบเดียวกับตัวอย่าง (auth_str / obfs / up_mbps / down_mbps / socks5 / http ...)
    # alpn ต้องตรงกับฝั่งเซิร์ฟเวอร์ (ตั้งเป็น h3) ถ้าแอปของคุณไม่มีช่อง alpn ให้ลบบรรทัดนี้ได้ถ้าแอปตั้งค่าเอง
    proto_line=""
    [[ $protocol != "udp" ]] && proto_line=$'\n'"  \"protocol\": \"$protocol\","
    cat <<EOF > /root/hy/hy-client.json
{
  "server": "$hy_ym:$last_port",$proto_line
  "auth_str": "$auth_pwd",
  "obfs": "$obfs",
  "alpn": "h3",
  "up_mbps": 10,
  "down_mbps": 20,
  "retry": 3,
  "retry_interval": 1,
  "socks5": { "listen": "127.0.0.1:1080" },
  "http": { "listen": "127.0.0.1:8989" },
  "insecure": true,
  "ca": "",
  "recv_window_conn": 196608,
  "recv_window": 491520
}
EOF

    cat <<EOF > /root/hy/clash-meta.yaml
mixed-port: 7890
external-controller: 127.0.0.1:9090
allow-lan: false
mode: rule
log-level: debug
ipv6: true
dns:
  enable: true
  listen: 0.0.0.0:53
  enhanced-mode: fake-ip
  nameserver:
    - 8.8.8.8
    - 1.1.1.1
    - 114.114.114.114
proxies:
  - name: Misaka-Hysteria
    type: hysteria
    server: $hy_ym
    port: $port
    auth_str: $auth_pwd
    alpn:
      - h3
    protocol: $protocol
$([[ -n $obfs ]] && echo "    obfs: $obfs")
    up: 20
    down: 100
    sni: $domain
    skip-cert-verify: true
proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Misaka-Hysteria
      
rules:
  - GEOIP,CN,DIRECT
  - MATCH,Proxy
EOF
    url="hysteria://$hy_ym:$port?protocol=$protocol&auth=$auth_pwd&peer=$domain&insecure=true&upmbps=20&downmbps=100&alpn=h3${obfs:+&obfsParam=$obfs&obfs=xplus}#Misaka-Hysteria"
    echo $url > /root/hy/url.txt

    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl start hysteria-server

    if [[ -n $(systemctl status hysteria-server 2>/dev/null | grep -w active) && -f '/etc/hysteria/config.json' ]]; then
        green "บริการ Hysteria เริ่มต้นสำเร็จ"
    else
        red "เริ่มบริการ hysteria-server ไม่สำเร็จ กรุณารัน systemctl status hysteria-server เพื่อดูสถานะ แล้วแจ้งกลับ สคริปต์จะออก" && exit 1
    fi

    green "ติดตั้งบริการพร็อกซี Hysteria เสร็จสิ้น"
    yellow "ไฟล์ config ไคลเอนต์ Clash Meta บันทึกไว้ที่ /root/hy/clash-meta.yaml"
    yellow "ลิงก์แชร์โหนด Hysteria บันทึกไว้ที่ /root/hy/url.txt"
    echo ""
    # แสดง JSON เป็นอย่างสุดท้าย จะได้เห็นเต็ม ๆ บนหน้าจอ (ดูซ้ำได้ด้วย: cat /root/hy/hy-client.json)
    green "===== hy-client.json (คัดลอกส่วนนี้ไปใช้ในแอป) ====="
    cat /root/hy/hy-client.json
    green "===== บันทึกไว้ที่ /root/hy/hy-client.json ====="
}

uninst_hy(){
    systemctl stop hysteria-server.service >/dev/null 2>&1
    systemctl disable hysteria-server.service >/dev/null 2>&1
    rm -f /lib/systemd/system/hysteria-server.service /lib/systemd/system/hysteria-server@.service
    rm -rf /usr/local/bin/hysteria /etc/hysteria /root/hy
    systemctl daemon-reload >/dev/null 2>&1
    hy_nat_clear
    netfilter-persistent save >/dev/null 2>&1
    green "ถอนการติดตั้ง Hysteria เรียบร้อยแล้ว!"
}

starthy(){
    systemctl start hysteria-server
    systemctl enable hysteria-server >/dev/null 2>&1
}

stophy(){
    systemctl stop hysteria-server
    systemctl disable hysteria-server >/dev/null 2>&1
}

hyswitch(){
    yellow "กรุณาเลือกสิ่งที่ต้องการทำ:"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} เริ่ม Hysteria"
    echo -e " ${GREEN}2.${PLAIN} ปิด Hysteria"
    echo -e " ${GREEN}3.${PLAIN} รีสตาร์ท Hysteria"
    echo ""
    read -rp "กรุณาเลือกตัวเลือก [0-3]: " switchInput
    case $switchInput in
        1 ) starthy ;;
        2 ) stophy ;;
        3 ) stophy && starthy ;;
        * ) exit 1 ;;
    esac
}

change_cert(){
    old_cert=$(cat /etc/hysteria/config.json | grep cert | awk -F " " '{print $2}' | sed "s/\"//g" | sed "s/,//g")
    old_key=$(cat /etc/hysteria/config.json | grep key | awk -F " " '{print $2}' | sed "s/\"//g" | sed "s/,//g")
    old_hyym=$(cat /root/hy/hy-client.json | grep server | awk -F " " '{print $2}' | sed "s/\"//g" | sed "s/,//g" | awk -F ":" '{print $1}')
    old_domain=$(cat /root/hy/hy-client.json | grep server_name | awk -F " " '{print $2}' | sed "s/\"//g" | sed "s/,//g")
    inst_cert
    if [[ $hy_ym == "www.bing.com" ]]; then
        WARPv4Status=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
        WARPv6Status=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
        if [[ $WARPv4Status =~ on|plus ]] || [[ $WARPv6Status =~ on|plus ]]; then
            wg-quick down wgcf >/dev/null 2>&1
            systemctl stop warp-go >/dev/null 2>&1
            hy_ym=$(curl -s4m8 ip.gs -k) || hy_ym="[$(curl -s6m8 ip.gs -k)]"
            wg-quick up wgcf >/dev/null 2>&1
            systemctl start warp-go >/dev/null 2>&1
        else
            hy_ym=$(curl -s4m8 ip.gs -k) || hy_ym="[$(curl -s6m8 ip.gs -k)]"
        fi
    fi
    sed -i "s!$old_cert!$cert_path!g" /etc/hysteria/config.json
    sed -i "s!$old_key!$key_path!g" /etc/hysteria/config.json
    sed -i "s/$old_hyym/$hy_ym/g" /root/hy/hy-client.json
    sed -i "s/$old_hyym/$hy_ym/g" /root/hy/clash-meta.yaml
    sed -i "s/$old_hyym/$hy_ym/g" /root/hy/url.txt
    stophy && starthy
    green "แก้ไข config สำเร็จ กรุณานำเข้าไฟล์ config โหนดใหม่อีกครั้ง"
}

change_pro(){
    old_pro=$(cat /etc/hysteria/config.json | grep protocol | awk -F " " '{print $2}' | sed "s/\"//g" | sed "s/,//g")
    inst_pro
    sed -i "s/$old_pro/$protocol" /etc/hysteria/config.json
    sed -i "s/$old_pro/$protocol" /root/hy/hy-client.json
    sed -i "s/$old_pro/$protocol" /root/hy/clash-meta.yaml
    sed -i "s/$old_pro/$protocol" /root/hy/url.txt
    stophy && starthy
    green "แก้ไข config สำเร็จ กรุณานำเข้าไฟล์ config โหนดใหม่อีกครั้ง"
}

change_port(){
    old_port=$(cat /etc/hysteria/config.json | grep listen | awk -F " " '{print $2}' | sed "s/\"//g" | sed "s/,//g" | sed "s/://g")
    inst_port
    netfilter-persistent save >/dev/null 2>&1

    if [[ -n $firstport ]]; then
        last_port="$firstport-$endport"
    else
        last_port=$port
    fi

    # ที่อยู่เซิร์ฟเวอร์เดิมในไฟล์ client (ตัดส่วนพอร์ตท้ายสุดออก)
    old_host=$(sed -n 's/^  "server": "\(.*\):[^:]*",\?$/\1/p' /root/hy/hy-client.json | head -n1)

    sed -i "s/$old_port/$port/" /etc/hysteria/config.json
    [[ -n $old_host ]] && sed -i "s#^  \"server\": .*#  \"server\": \"$old_host:$last_port\",#" /root/hy/hy-client.json
    sed -i "s/$old_port/$port/" /root/hy/clash-meta.yaml
    sed -i "s/$old_port/$port/" /root/hy/url.txt

    stophy && starthy
    green "แก้ไข config สำเร็จ กรุณานำเข้าไฟล์ config โหนดใหม่อีกครั้ง"
}

change_pwd(){
    old_pwd=$(cat /etc/hysteria/config.json | grep password | sed -n 2p | awk -F " " '{print $2}' | sed "s/\"//g" | sed "s/,//g")
    inst_pwd
    sed -i "s/$old_pwd/$auth_pwd/" /etc/hysteria/config.json
    sed -i "s/$old_pwd/$auth_pwd/" /root/hy/hy-client.json
    sed -i "s/$old_pwd/$auth_pwd/" /root/hy/clash-meta.yaml
    sed -i "s/$old_pwd/$auth_pwd/" /root/hy/url.txt
    stophy && starthy
    green "แก้ไข config สำเร็จ กรุณานำเข้าไฟล์ config โหนดใหม่อีกครั้ง"
}

change_resolv(){
    old_resolv=$(cat /etc/hysteria/config.json | grep resolv | awk -F " " '{print $2}' | sed "s/\"//g" | sed "s/,//g")
    inst_resolv
    sed -i "s/$old_resolv/$resolv" /etc/hysteria/config.json
    stophy && starthy
    green "แก้ไข config สำเร็จ กรุณานำเข้าไฟล์ config โหนดใหม่อีกครั้ง"
}

change_obfs(){
    inst_obfs
    sed -i '/"obfs":/d' /etc/hysteria/config.json
    [[ -n $obfs ]] && sed -i "/\"listen\":/a\\    \"obfs\": \"$obfs\"," /etc/hysteria/config.json
    sed -i "s/^  \"obfs\":.*/  \"obfs\": \"$obfs\",/" /root/hy/hy-client.json
    sed -i '/^    obfs: /d' /root/hy/clash-meta.yaml
    [[ -n $obfs ]] && sed -i "/^    protocol:/a\\    obfs: $obfs" /root/hy/clash-meta.yaml
    sed -i -E 's/&obfsParam=[^&#]*&obfs=xplus//' /root/hy/url.txt
    [[ -n $obfs ]] && sed -i "s/#Misaka-Hysteria/\&obfsParam=$obfs\&obfs=xplus#Misaka-Hysteria/" /root/hy/url.txt
    stophy && starthy
    green "แก้ไข config สำเร็จ กรุณานำเข้าไฟล์ config โหนดใหม่อีกครั้ง"
}

editconf(){
    green "เลือกการแก้ไข config ของ Hysteria:"
    echo -e " ${GREEN}1.${PLAIN} เปลี่ยนประเภทใบรับรอง"
    echo -e " ${GREEN}2.${PLAIN} เปลี่ยนโปรโตคอล"
    echo -e " ${GREEN}3.${PLAIN} เปลี่ยนพอร์ต"
    echo -e " ${GREEN}4.${PLAIN} เปลี่ยนรหัสผ่านยืนยันตัวตน"
    echo -e " ${GREEN}5.${PLAIN} เปลี่ยนลำดับความสำคัญการแยกโดเมน"
    echo -e " ${GREEN}6.${PLAIN} เปลี่ยน obfs"
    echo ""
    read -p " กรุณาเลือกการทำงาน [1-6]: " confAnswer
    case $confAnswer in
        1 ) change_cert ;;
        2 ) change_pro ;;
        3 ) change_port ;;
        4 ) change_pwd ;;
        5 ) change_resolv ;;
        6 ) change_obfs ;;
        * ) exit 1 ;;
    esac
}

showconf(){
    yellow "เนื้อหาไฟล์ config ฝั่งไคลเอนต์ (hy-client.json) มีดังนี้ และบันทึกไว้ที่ /root/hy/hy-client.json"
    cat /root/hy/hy-client.json
    yellow "ไฟล์ config ไคลเอนต์ Clash Meta บันทึกไว้ที่ /root/hy/clash-meta.yaml"
    yellow "ลิงก์แชร์โหนด Hysteria มีดังนี้ และบันทึกไว้ที่ /root/hy/url.txt"
    red $(cat /root/hy/url.txt)
}

menu() {
    clear
    echo "#############################################################"
    echo -e "#               ${RED}สคริปต์ติดตั้ง Hysteria แบบคลิกเดียว${PLAIN}               #"
    echo -e "# ${GREEN}ผู้เขียน${PLAIN}: MisakaNo の 小破站                                  #"
    echo -e "# ${GREEN}บล็อก${PLAIN}: https://blog.misaka.cyou                            #"
    echo -e "# ${GREEN}โปรเจกต์ GitHub${PLAIN}: https://github.com/Misaka-blog               #"
    echo -e "# ${GREEN}โปรเจกต์ GitLab${PLAIN}: https://gitlab.com/Misaka-blog               #"
    echo -e "# ${GREEN}ช่อง Telegram${PLAIN}: https://t.me/misakanocchannel              #"
    echo -e "# ${GREEN}กลุ่ม Telegram${PLAIN}: https://t.me/misakanoc                     #"
    echo -e "# ${GREEN}ช่อง YouTube${PLAIN}: https://www.youtube.com/@misaka-blog        #"
    echo "#############################################################"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} ติดตั้ง Hysteria"
    echo -e " ${GREEN}2.${PLAIN} ${RED}ถอนการติดตั้ง Hysteria${PLAIN}"
    echo " -------------"
    echo -e " ${GREEN}3.${PLAIN} ปิด / เปิด / รีสตาร์ท Hysteria"
    echo -e " ${GREEN}4.${PLAIN} แก้ไข config Hysteria"
    echo -e " ${GREEN}5.${PLAIN} แสดงไฟล์ config Hysteria"
    echo " -------------"
    echo -e " ${GREEN}0.${PLAIN} ออกจากสคริปต์"
    echo ""
    read -rp "กรุณาเลือกตัวเลือก [0-5]: " menuInput
    case $menuInput in
        1 ) inst_hy ;;
        2 ) uninst_hy ;;
        3 ) hyswitch ;;
        4 ) editconf ;;
        5 ) showconf ;;
        * ) exit 1 ;;
    esac
}

menu