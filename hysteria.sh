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


# ---------- NAT ของ Hysteria แยก chain เป็นของตัวเอง (ไม่แตะ rule ของ zivpn) ----------
HY_CHAIN="HYSTERIA_DNAT"
HY_RANGE_MIN=10000
HY_RANGE_MAX=65000

hy_nat_clear(){
    for ipt in iptables ip6tables; do
        command -v $ipt >/dev/null 2>&1 || continue
        while $ipt -w -t nat -D PREROUTING -p udp -j $HY_CHAIN 2>/dev/null; do :; done
        $ipt -w -t nat -F $HY_CHAIN 2>/dev/null
        $ipt -w -t nat -X $HY_CHAIN 2>/dev/null
    done
}

hy_nat_add(){ # $1=firstport $2=endport $3=port
    for ipt in iptables ip6tables; do
        command -v $ipt >/dev/null 2>&1 || continue
        $ipt -w -t nat -N $HY_CHAIN 2>/dev/null
        $ipt -w -t nat -F $HY_CHAIN
        $ipt -w -t nat -A $HY_CHAIN -p udp --dport $1:$2 -j DNAT --to-destination :$3
        $ipt -w -t nat -C PREROUTING -p udp -j $HY_CHAIN 2>/dev/null || $ipt -w -t nat -A PREROUTING -p udp -j $HY_CHAIN
    done
}

# ตรวจว่าช่วง/พอร์ตชนกับ zivpn หรือไม่ (อ่านจาก /etc/zivpn/manager.conf)
zivpn_conflict(){ # $1=start $2=end (ถ้ามีแค่ $1 = เช็คพอร์ตเดียว)
    [[ -f /etc/zivpn/manager.conf ]] || return 1
    local PORT RANGE zs ze a=$1 b=${2:-$1}
    PORT=$(. /etc/zivpn/manager.conf; echo "$PORT")
    RANGE=$(. /etc/zivpn/manager.conf; echo "$RANGE")
    [[ -n $PORT && $a -le $PORT && $PORT -le $b ]] && { ZC="พอร์ตหลัก zivpn ($PORT)"; return 0; }
    if [[ -n $RANGE ]]; then
        zs=${RANGE%:*}; ze=${RANGE#*:}
        [[ $a -le $ze && $zs -le $b ]] && { ZC="ช่วง hopping ของ zivpn ($RANGE)"; return 0; }
    fi
    return 1
}

inst_port(){
    hy_nat_clear

    read -p "ตั้งพอร์ต Hysteria [1-65535]（กด Enter เพื่อสุ่มพอร์ต）: " port
    [[ -z $port ]] && port=$(shuf -i $HY_RANGE_MIN-$HY_RANGE_MAX -n 1)
    until [[ -z $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; do
        if [[ -n $(ss -tunlp | grep -w udp | awk '{print $5}' | sed 's/.*://g' | grep -w "$port") ]]; then
            echo -e "${RED} $port ${PLAIN} พอร์ตนี้ถูกโปรแกรมอื่นใช้งานอยู่แล้ว กรุณาเปลี่ยนพอร์ตแล้วลองใหม่!"
            read -p "ตั้งพอร์ต Hysteria [1-65535]（กด Enter เพื่อสุ่มพอร์ต）: " port
            [[ -z $port ]] && port=$(shuf -i $HY_RANGE_MIN-$HY_RANGE_MAX -n 1)
        fi
    done

    if ! [[ $port =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        red "พอร์ตหลักต้องเป็นตัวเลขตัวเดียว 1-65535 (เช่น 36712) - ช่วง 10000-65000 ให้ใส่ในขั้นตอนข้ามพอร์ตถัดไป"
        inst_port
        return
    fi
    if zivpn_conflict $port; then
        red "พอร์ต $port ชนกับ $ZC - กรุณาเลือกพอร์ตอื่น"
        inst_port
        return
    fi
    yellow "พอร์ตที่จะใช้บนโหนด Hysteria คือ: $port"

    if [[ $protocol == "udp" ]]; then
        inst_jump
    fi
}

inst_jump(){
    yellow "โปรโตคอลที่เลือกคือ udp รองรับฟังก์ชันข้ามพอร์ต (port hopping)"
    green "รูปแบบการใช้พอร์ตของ Hysteria:"
    echo ""
    echo -e " ${GREEN}1.${PLAIN} พอร์ตเดียว ${YELLOW}（ค่าเริ่มต้น）${PLAIN}"
    echo -e " ${GREEN}2.${PLAIN} ข้ามพอร์ต (port hopping)"
    echo ""
    read -rp "กรุณาเลือกตัวเลือก [1-2]: " jumpInput
    if [[ $jumpInput == 2 ]]; then
        while true; do
            read -p "พอร์ตเริ่มต้นของช่วง [Enter = $HY_RANGE_MIN]: " firstport
            read -p "พอร์ตปลายของช่วง [Enter = $HY_RANGE_MAX]: " endport
            [[ -z $firstport ]] && firstport=$HY_RANGE_MIN
            [[ -z $endport ]] && endport=$HY_RANGE_MAX
            if ! [[ $firstport =~ ^[0-9]+$ && $endport =~ ^[0-9]+$ ]] || (( firstport >= endport || firstport < 1024 || endport > 65535 )); then
                red "ช่วงพอร์ตไม่ถูกต้อง (พอร์ตเริ่มต้องน้อยกว่าพอร์ตปลาย และอยู่ในช่วง 1024-65535)"; continue
            fi
            if zivpn_conflict $firstport $endport; then
                red "ช่วง $firstport-$endport ชนกับ $ZC - ปรับช่วงให้ไม่ทับกัน"; continue
            fi
            break
        done
        hy_nat_add $firstport $endport $port
        netfilter-persistent save >/dev/null 2>&1
    else
        red "จะใช้โหมดพอร์ตเดียวต่อไป"
    fi
}

inst_obfs(){
    read -p "ตั้งรหัส obfs [Enter = jaideevpn]: " obfs
    [[ -z $obfs ]] && obfs="jaideevpn"
    yellow "รหัส obfs ที่ใช้บนโหนด Hysteria คือ: $obfs"
}

inst_pwd(){
    read -p "ตั้งรหัสผ่าน Hysteria（กด Enter เพื่อสุ่ม）: " auth_pwd
    [[ -z $auth_pwd ]] && auth_pwd=$(date +%s%N | md5sum | cut -c 1-8)
    yellow "รหัสผ่านที่ใช้บนโหนด Hysteria คือ: $auth_pwd"
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
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl wget sudo qrencode procps iptables-persistent netfilter-persistent

    wget -N https://raw.githubusercontent.com/Misaka-blog/hysteria-install/main/hy1/install_server.sh
    bash install_server.sh
    rm -f install_server.sh

    if [[ -f "/usr/local/bin/hysteria" ]]; then
        green "ติดตั้ง Hysteria สำเร็จ!"
    else
        red "ติดตั้ง Hysteria ล้มเหลว!"
    fi

    # ถามค่าต่าง ๆ สำหรับการตั้งค่า Hysteria
    inst_cert
    inst_pro
    inst_port
    inst_pwd
    inst_obfs
    inst_resolv

    # สร้างไฟล์ config ของ Hysteria
    cat <<EOF > /etc/hysteria/config.json
{
    "protocol": "$protocol",
    "listen": ":$port",
    "resolve_preference": "$resolv",
    "cert": "$cert_path",
    "key": "$key_path",
    "obfs": "$obfs",
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

    # ถ้ายังไม่มี IP (กรณีใช้ใบรับรอง Bing จะไม่ได้เรียก realip มาก่อน) ให้หาตอนนี้
    [[ -z $ip ]] && realip

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

    client_proto=""
    [[ $protocol != "udp" ]] && client_proto="  \"protocol\": \"$protocol\",
"
    clash_ports=""
    url_mport=""
    if [[ -n $firstport ]]; then
        clash_ports="    ports: $firstport-$endport
"
        url_mport="&mport=$firstport-$endport"
    fi

    # สร้างไฟล์ config ของ V2rayN และ Clash Meta
    mkdir /root/hy >/dev/null 2>&1
    cat <<EOF > /root/hy/hy-client.json
{
  "server": "$hy_ym:$last_port",
${client_proto}  "auth_str": "$auth_pwd",
  "obfs": "$obfs",
  "up_mbps": 10,
  "down_mbps": 20,
  "retry": 3,
  "retry_interval": 1,
  "socks5": {
    "listen": "127.0.0.1:1080"
  },
  "http": {
    "listen": "127.0.0.1:8989"
  },
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
${clash_ports}    auth_str: $auth_pwd
    obfs: $obfs
    protocol: $protocol
    up: 10
    down: 20
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
    url="hysteria://$hy_ym:$port?protocol=$protocol&auth=$auth_pwd&peer=$domain$url_mport&obfs=xplus&obfsParam=$obfs&insecure=true&upmbps=10&downmbps=20#Misaka-Hysteria"
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
    yellow "เนื้อหาไฟล์ config ฝั่งไคลเอนต์ (hy-client.json) มีดังนี้ และบันทึกไว้ที่ /root/hy/hy-client.json"
    cat /root/hy/hy-client.json
    yellow "ไฟล์ config ไคลเอนต์ Clash Meta บันทึกไว้ที่ /root/hy/clash-meta.yaml"
    yellow "ลิงก์แชร์โหนด Hysteria มีดังนี้ และบันทึกไว้ที่ /root/hy/url.txt"
    red $(cat /root/hy/url.txt)
}

uninst_hy(){
    systemctl stop hysteria-server.service >/dev/null 2>&1
    systemctl disable hysteria-server.service >/dev/null 2>&1
    rm -f /lib/systemd/system/hysteria-server.service /lib/systemd/system/hysteria-server@.service
    rm -rf /usr/local/bin/hysteria /etc/hysteria /root/hy /root/hysteria.sh
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
    sed -i "s/$old_pro/$protocol/" /etc/hysteria/config.json
    sed -i "s/$old_pro/$protocol/" /root/hy/hy-client.json
    sed -i "s/$old_pro/$protocol/" /root/hy/clash-meta.yaml
    sed -i "s/$old_pro/$protocol/" /root/hy/url.txt
    stophy && starthy
    green "แก้ไข config สำเร็จ กรุณานำเข้าไฟล์ config โหนดใหม่อีกครั้ง"
}

change_port(){
    old_port=$(cat /etc/hysteria/config.json | grep listen | awk -F " " '{print $2}' | sed "s/\"//g" | sed "s/,//g" | sed "s/://g")
    inst_port

    hy_nat_clear
    netfilter-persistent save >/dev/null 2>&1

    if [[ -n $firstport ]]; then
        last_port="$firstport-$endport"
    else
        last_port=$port
    fi

    sed -i "s/$old_port/$port/" /etc/hysteria/config.json
    sed -i "s/\"server\": \"\(.*\):[^\"]*\"/\"server\": \"\1:$last_port\"/" /root/hy/hy-client.json
    sed -i "s/port: $old_port/port: $port/" /root/hy/clash-meta.yaml
    sed -i "/^    ports: /d" /root/hy/clash-meta.yaml
    sed -i "s/&mport=[0-9-]*//" /root/hy/url.txt
    sed -i "s/:$old_port?/:$port?/" /root/hy/url.txt
    if [[ -n $firstport ]]; then
        sed -i "s/^    port: $port\$/    port: $port\n    ports: $firstport-$endport/" /root/hy/clash-meta.yaml
        sed -i "s/:$port?protocol=\([^&]*\)&auth=\([^&]*\)&peer=\([^&]*\)/:$port?protocol=\1\&auth=\2\&peer=\3\&mport=$firstport-$endport/" /root/hy/url.txt
    fi

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
    sed -i "s/$old_resolv/$resolv/" /etc/hysteria/config.json
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
    echo ""
    read -p " กรุณาเลือกการทำงาน [1-5]: " confAnswer
    case $confAnswer in
        1 ) change_cert ;;
        2 ) change_pro ;;
        3 ) change_port ;;
        4 ) change_pwd ;;
        5 ) change_resolv ;;
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