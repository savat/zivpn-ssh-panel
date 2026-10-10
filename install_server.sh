#!/usr/bin/env bash
# ดัดแปลงจาก https://github.com/v2fly/fhs-install-v2ray/blob/master/install-release.sh
# คุณสามารถตั้งค่าตัวแปรนี้เป็นอะไรก็ได้ในเซสชันเชลล์ก่อนรันสคริปต์นี้ โดยใช้คำสั่ง:
# export JSON_PATH='/usr/local/etc/hysteria'
JSON_PATH=${JSON_PATH:-/etc/hysteria}

curl() {
    $(type -P curl) -L -q --retry 5 --retry-delay 10 --retry-max-time 60 "$@"
}


## ฟังก์ชันตัวอย่างสำหรับประมวลผลพารามิเตอร์
judgment_parameters() {
    while [[ "$#" -gt '0' ]]; do
        case "$1" in
            '--remove')
                if [[ "$#" -gt '1' ]]; then
                    echo 'ข้อผิดพลาด: กรุณาใส่ค่าพารามิเตอร์ให้ถูกต้อง'
                    exit 1
                fi
                REMOVE='1'
            ;;
            '--version')
                VERSION="${2:?ข้อผิดพลาด: กรุณาระบุรุ่น (version) ให้ถูกต้อง}"
                break
            ;;
            '-c' | '--check')
                CHECK='1'
                break
            ;;
            '-f' | '--force')
                FORCE='1'
                break
            ;;
            '-h' | '--help')
                HELP='1'
                break
            ;;
            '-l' | '--local')
                LOCAL_INSTALL='1'
                LOCAL_FILE="${2:?ข้อผิดพลาด: กรุณาระบุไฟล์ท้องถิ่นให้ถูกต้อง}"
                break
            ;;
            '-p' | '--proxy')
                if [[ -z "${2:?ข้อผิดพลาด: กรุณาระบุที่อยู่พร็อกซีเซิร์ฟเวอร์}" ]]; then
                    exit 1
                fi
                PROXY="$2"
                shift
            ;;
            *)
                echo "$0: ตัวเลือกไม่รู้จัก -- -"
                exit 1
            ;;
        esac
        shift
    done
}

install_software() {
    package_name="$1"
    file_to_detect="$2"
    type -P "$file_to_detect" > /dev/null 2>&1 && return
    if ${PACKAGE_MANAGEMENT_INSTALL} "$package_name"; then
        echo "ข้อมูล: ติดตั้ง $package_name แล้ว"
    else
        echo "ข้อผิดพลาด: ติดตั้ง $package_name ล้มเหลว กรุณาตรวจสอบเครือข่ายของคุณ"
        exit 1
    fi
}
check_if_running_as_root() {
    # หากต้องการรันด้วยผู้ใช้อื่น กรุณาแก้ไข $UID ให้เป็นของผู้ใช้นั้น
    if [[ "$UID" -ne '0' ]]; then
        echo "คำเตือน: ผู้ใช้ที่รันสคริปต์นี้ไม่ใช่ root คุณอาจพบข้อผิดพลาดเรื่องสิทธิ์ไม่เพียงพอ"
        read -r -p "คุณแน่ใจหรือไม่ว่าต้องการดำเนินการต่อ? [y/n] " cont_without_been_root
        if [[ x"${cont_without_been_root:0:1}" = x'y' ]]; then
            echo "กำลังดำเนินการติดตั้งต่อด้วยผู้ใช้ปัจจุบัน..."
        else
            echo "ไม่ได้รันด้วย root กำลังออก..."
            exit 1
        fi
    fi
}

identify_the_operating_system_and_architecture() {
    if [[ "$(uname)" == 'Linux' ]]; then
        case "$(uname -m)" in
            'i386' | 'i686')
                MACHINE='386'
            ;;
            'amd64' | 'x86_64')
                MACHINE='amd64'
            ;;
            'armv5tel' | 'armv6l' | 'armv7' | 'armv7l')
                MACHINE='arm'
            ;;
            'armv8' | 'aarch64')
                MACHINE='arm64'
            ;;
            's390x')
                MACHINE='s390x'
            ;;
            'mips' | 'mipsle' | 'mips64' | 'mips64le')
                MACHINE='mipsle'
            ;;
            *)
                echo "ข้อผิดพลาด: ไม่รองรับสถาปัตยกรรมนี้"
                exit 1
            ;;
        esac
        if [[ ! -f '/etc/os-release' ]]; then
            echo "ข้อผิดพลาด: อย่าใช้ Linux ที่ล้าสมัย"
            exit 1
        fi
        # อย่ารวมเงื่อนไขนี้กับเงื่อนไขถัดไป
        ## ระวัง Linux อย่าง Gentoo ที่เคอร์เนลรองรับการสลับระหว่าง Systemd และ OpenRC
        ### อ้างอิง: https://github.com/v2fly/fhs-install-v2ray/issues/84#issuecomment-688574989
        if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup && [[ "$(type -P systemctl)" ]]; then
            true
            elif [[ -d /run/systemd/system ]] || grep -q systemd <(ls -l /sbin/init); then
            true
        else
            echo "ข้อผิดพลาด: รองรับเฉพาะ Linux ที่ใช้ systemd เท่านั้น"
            exit 1
        fi
        if [[ "$(type -P apt)" ]]; then
            PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install'
            PACKAGE_MANAGEMENT_REMOVE='apt purge'
            package_provide_tput='ncurses-bin'
            elif [[ "$(type -P dnf)" ]]; then
            PACKAGE_MANAGEMENT_INSTALL='dnf -y install'
            PACKAGE_MANAGEMENT_REMOVE='dnf remove'
            package_provide_tput='ncurses'
            elif [[ "$(type -P yum)" ]]; then
            PACKAGE_MANAGEMENT_INSTALL='yum -y install'
            PACKAGE_MANAGEMENT_REMOVE='yum remove'
            package_provide_tput='ncurses'
            elif [[ "$(type -P zypper)" ]]; then
            PACKAGE_MANAGEMENT_INSTALL='zypper install -y --no-recommends'
            PACKAGE_MANAGEMENT_REMOVE='zypper remove'
            package_provide_tput='ncurses-utils'
            elif [[ "$(type -P pacman)" ]]; then
            PACKAGE_MANAGEMENT_INSTALL='pacman -Syu --noconfirm'
            PACKAGE_MANAGEMENT_REMOVE='pacman -Rsn'
            package_provide_tput='ncurses'
        else
            echo "ข้อผิดพลาด: สคริปต์ไม่รองรับตัวจัดการแพ็กเกจของระบบปฏิบัติการนี้"
            exit 1
        fi
    else
        echo "ข้อผิดพลาด: ไม่รองรับระบบปฏิบัติการนี้"
        exit 1
    fi
}

get_version() {
    # 0: ติดตั้งหรืออัปเดต Hysteria
    # 1: ติดตั้งแล้วหรือไม่มี Hysteria รุ่นใหม่
    # 2: ติดตั้ง Hysteria รุ่นที่ระบุ
    if [[ -n "$VERSION" ]]; then
        RELEASE_VERSION="v${VERSION#v}"
        return 2
    fi
    # หาเลขรุ่นของ Hysteria ที่ติดตั้งจากไฟล์ท้องถิ่น
    if [[ -f '/usr/local/bin/hysteria' ]]; then
        VERSION="$(/usr/local/bin/hysteria -v | awk 'NR==1 {print $3}')"
        CURRENT_VERSION="v${VERSION#v}"
        if [[ "$LOCAL_INSTALL" -eq '1' ]]; then
            RELEASE_VERSION="$CURRENT_VERSION"
            return
        fi
    fi
    # ดึงเลขรุ่น Hysteria release
    TMP_FILE="$(mktemp)"
    # if ! curl -x "${PROXY}" -sS -H "Accept: application/vnd.github.v3+json" -o "$TMP_FILE" 'https://api.github.com/repos/apernet/hysteria/releases/latest'; then
    #     "rm" "$TMP_FILE"
    #     echo 'ข้อผิดพลาด: ดึงรายการ release ไม่สำเร็จ กรุณาตรวจสอบเครือข่ายของคุณ'
    #     exit 1
    # fi
    # RELEASE_LATEST="$(curl -Ls "https://data.jsdelivr.com/v1/package/resolve/gh/apernet/Hysteria" | grep '"version":' | sed -E 's/.*"([^"]+)".*/\1/')"
    "rm" "$TMP_FILE"
    RELEASE_VERSION="v1.3.5"
    # เปรียบเทียบเลขรุ่นของ Hysteria
    if [[ "$RELEASE_VERSION" != "$CURRENT_VERSION" ]]; then
        RELEASE_VERSIONSION_NUMBER="${RELEASE_VERSION#v}"
        RELEASE_MAJOR_VERSION_NUMBER="${RELEASE_VERSIONSION_NUMBER%%.*}"
        RELEASE_MINOR_VERSION_NUMBER="$(echo "$RELEASE_VERSIONSION_NUMBER" | awk -F '.' '{print $2}')"
        RELEASE_MINIMUM_VERSION_NUMBER="${RELEASE_VERSIONSION_NUMBER##*.}"
        # shellcheck disable=SC2001
        CURRENT_VERSIONSION_NUMBER="$(echo "${CURRENT_VERSION#v}" | sed 's/-.*//')"
        CURRENT_MAJOR_VERSION_NUMBER="${CURRENT_VERSIONSION_NUMBER%%.*}"
        CURRENT_MINOR_VERSION_NUMBER="$(echo "$CURRENT_VERSIONSION_NUMBER" | awk -F '.' '{print $2}')"
        CURRENT_MINIMUM_VERSION_NUMBER="${CURRENT_VERSIONSION_NUMBER##*.}"
        if [[ "$RELEASE_MAJOR_VERSION_NUMBER" -gt "$CURRENT_MAJOR_VERSION_NUMBER" ]]; then
            return 0
            elif [[ "$RELEASE_MAJOR_VERSION_NUMBER" -eq "$CURRENT_MAJOR_VERSION_NUMBER" ]]; then
            if [[ "$RELEASE_MINOR_VERSION_NUMBER" -gt "$CURRENT_MINOR_VERSION_NUMBER" ]]; then
                return 0
                elif [[ "$RELEASE_MINOR_VERSION_NUMBER" -eq "$CURRENT_MINOR_VERSION_NUMBER" ]]; then
                if [[ "$RELEASE_MINIMUM_VERSION_NUMBER" -gt "$CURRENT_MINIMUM_VERSION_NUMBER" ]]; then
                    return 0
                else
                    return 1
                fi
            else
                return 1
            fi
        else
            return 1
        fi
        elif [[ "$RELEASE_VERSION" == "$CURRENT_VERSION" ]]; then
        return 1
    fi
}

download_hysteria() {
    DOWNLOAD_LINK="https://github.com/apernet/hysteria/releases/download/$RELEASE_VERSION/hysteria-linux-$MACHINE"
    echo "กำลังดาวน์โหลดไฟล์ Hysteria: $DOWNLOAD_LINK"
    if ! curl -x "${PROXY}" -R -H 'Cache-Control: no-cache' -o "$BIN_FILE" "$DOWNLOAD_LINK"; then
        echo 'ข้อผิดพลาด: ดาวน์โหลดล้มเหลว! กรุณาตรวจสอบเครือข่ายหรือลองใหม่อีกครั้ง'
        return 1
    fi
}

install_file() {
    NAME="$1"
    if [[ "$NAME" == "hysteria-linux-$MACHINE" ]] ; then
        install -m 755 "${TMP_DIRECTORY}/$NAME" "/usr/local/bin/hysteria"
    fi
}

install_hysteria() {
    # ติดตั้งไบนารี hysteria ไปที่ /usr/local/bin/
    install_file hysteria-linux-$MACHINE
    
    # ติดตั้งไฟล์ config ของ hysteria ไปที่ $JSON_PATH
    # shellcheck disable=SC2153
    if [[ -z "$JSONS_PATH" ]] && [[ ! -d "$JSON_PATH" ]]; then
        install -d "$JSON_PATH"
    cat << EOF >> "${JSON_PATH}/config.json"
{
    "listen": ":36712",
    "acme": {
        "domains": [
            "your.domain.com"
        ],
        "email": "hacker@gmail.com"
    },
    "obfs": "fuck me till the daylight",
    "up_mbps": 100,
    "down_mbps": 100
}
EOF
        CONFIG_NEW='1'
    fi
}

install_startup_service_file() {
    useradd -s /sbin/nologin --create-home hysteria
    [ $? -eq 0 ] && echo "เพิ่มผู้ใช้ hysteria แล้ว"
    echo "[Unit]
Description=Hysteria ยูทิลิตี้เครือข่ายที่มาพร้อมฟีเจอร์ครบครัน ปรับให้เหมาะกับเครือข่ายคุณภาพต่ำ
Documentation=https://github.com/apernet/hysteria/wiki
After=network.target

[Service]
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
WorkingDirectory=/etc/hysteria
Environment=HYSTERIA_LOG_LEVEL=info
ExecStart=/usr/local/bin/hysteria -c /etc/hysteria/config.json server
Restart=on-failure
RestartPreventExitStatus=1
RestartSec=5

[Install]
    WantedBy=multi-user.target" > /lib/systemd/system/hysteria-server.service
    echo "[Unit]
Description=Hysteria ยูทิลิตี้เครือข่ายที่มาพร้อมฟีเจอร์ครบครัน ปรับให้เหมาะกับเครือข่ายคุณภาพต่ำ
Documentation=https://github.com/apernet/hysteria/wiki
After=network.target

[Service]
User=hysteria
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
WorkingDirectory=/etc/hysteria
Environment=HYSTERIA_LOG_LEVEL=info
ExecStart=/usr/local/bin/hysteria -c /etc/hysteria/%i.json server
Restart=on-failure
RestartPreventExitStatus=1
RestartSec=5

[Install]
    WantedBy=multi-user.target" > /lib/systemd/system/hysteria-server@.service
    echo "ข้อมูล: ติดตั้งไฟล์บริการ systemd สำเร็จแล้ว!"
    systemctl daemon-reload
    SYSTEMD='1'
}

start_hysteria() {
    if [[ -f '/lib/systemd/system/hysteria-server.service' ]]; then
        if systemctl start "${HYSTERIA_CUSTOMIZE:-hysteria}"; then
            echo 'ข้อมูล: เริ่มบริการ Hysteria แล้ว'
        else
            echo "${red}ข้อผิดพลาด: เริ่มบริการ Hysteria ไม่สำเร็จ${reset}"
            exit 1
        fi
    fi
}

stop_hysteria() {
    HYSTERIA_CUSTOMIZE="$(systemctl list-units | grep 'hysteria@' | awk -F ' ' '{print $1}')"
    if [[ -z "$HYSTERIA_CUSTOMIZE" ]]; then
        local hysteria_daemon_to_stop='hysteria-server.service'
    else
        local hysteria_daemon_to_stop="$HYSTERIA_CUSTOMIZE"
    fi
    if ! systemctl stop "$hysteria_daemon_to_stop"; then
        echo 'ข้อผิดพลาด: หยุดบริการ Hysteria ไม่สำเร็จ'
        exit 1
    fi
    echo 'ข้อมูล: หยุดบริการ Hysteria แล้ว'
}

check_update() {
    if [[ -f '/lib/systemd/system/hysteria-server.service' ]]; then
        get_version
        local get_ver_exit_code=$?
        if [[ "$get_ver_exit_code" -eq '0' ]]; then
            echo "ข้อมูล: พบ Hysteria รุ่นใหม่ล่าสุด $RELEASE_VERSION (รุ่นปัจจุบัน: $CURRENT_VERSION)"
            elif [[ "$get_ver_exit_code" -eq '1' ]]; then
            echo "ข้อมูล: ไม่มีรุ่นใหม่ รุ่นปัจจุบันของ Hysteria คือ $CURRENT_VERSION"
        fi
        exit 0
    else
        echo 'ข้อผิดพลาด: ยังไม่ได้ติดตั้ง Hysteria'
        exit 1
    fi
}

remove_hysteria() {
    if systemctl list-unit-files | grep -qw 'hysteria'; then
        if [[ -n "$(pidof hysteria)" ]]; then
            stop_hysteria
        fi
        if ! ("rm" -r '/usr/local/bin/hysteria' \
            '/lib/systemd/system/hysteria-server.service' \
            '/lib/systemd/system/hysteria-server@.service'); then
            echo 'ข้อผิดพลาด: ลบ Hysteria ไม่สำเร็จ'
            exit 1
        else
            echo 'ลบแล้ว: /usr/local/bin/hysteria'
            echo 'ลบแล้ว: /lib/systemd/system/hysteria-server.service'
            echo 'ลบแล้ว: /lib/systemd/system/hysteria-server@.service'
            echo 'กรุณารันคำสั่ง: systemctl disable hysteria'
            echo 'ข้อมูล: ลบ Hysteria แล้ว'
            echo 'ข้อมูล: หากจำเป็น กรุณาลบไฟล์ config และ log ด้วยตนเอง'
            exit 0
        fi
    else
        echo 'ข้อผิดพลาด: ยังไม่ได้ติดตั้ง Hysteria'
        exit 1
    fi
}

# คำอธิบายพารามิเตอร์ในสคริปต์
show_help() {
    echo "วิธีใช้: $0 [--remove | --version number | -c | -f | -h | -l | -p]"
    echo '  [-p address] [--version number | -c | -f]'
    echo '  --remove        ถอนการติดตั้ง Hysteria'
    echo '  --version       ติดตั้ง Hysteria รุ่นที่ระบุ เช่น --version v0.9.6'
    echo '  -c, --check     ตรวจว่าสามารถอัปเดต Hysteria ได้หรือไม่'
    echo '  -f, --force     บังคับติดตั้ง Hysteria รุ่นล่าสุด'
    echo '  -h, --help      แสดงวิธีใช้'
    echo '  -l, --local     ติดตั้ง Hysteria จากไฟล์ท้องถิ่น'
    echo '  -p, --proxy     ดาวน์โหลดผ่านพร็อกซี เช่น -p http://127.0.0.1:8118 หรือ -p socks5://127.0.0.1:1080'
    exit 0
}


main() {
    check_if_running_as_root
    identify_the_operating_system_and_architecture
    judgment_parameters "$@"
    
    install_software "$package_provide_tput" 'tput'
    red=$(tput setaf 1)
    green=$(tput setaf 2)
    aoi=$(tput setaf 6)
    reset=$(tput sgr0)
    
    # ข้อมูลพารามิเตอร์
    [[ "$HELP" -eq '1' ]] && show_help
    [[ "$CHECK" -eq '1' ]] && check_update
    [[ "$REMOVE" -eq '1' ]] && remove_hysteria
    
    # ตัวแปรสำคัญสองตัว
    TMP_DIRECTORY="$(mktemp -d)"
    BIN_FILE="${TMP_DIRECTORY}/hysteria-linux-$MACHINE"
    
    # ติดตั้ง Hysteria จากไฟล์ท้องถิ่น แต่ยังต้องแน่ใจว่าเครือข่ายพร้อมใช้งาน
    if [[ "$LOCAL_INSTALL" -eq '1' ]]; then
        echo 'คำเตือน: ติดตั้ง Hysteria จากไฟล์ท้องถิ่น แต่ยังต้องแน่ใจว่าเครือข่ายพร้อมใช้งาน'
        echo -n 'คำเตือน: กรุณาตรวจสอบว่าไฟล์ใช้ได้ เพราะเราไม่สามารถยืนยันได้ (กดปุ่มใดก็ได้) ...'
        read -r
    else
        # วิธีปกติ
        install_software 'curl' 'curl'
        get_version
        NUMBER="$?"
        if [[ "$NUMBER" -eq '0' ]] || [[ "$FORCE" -eq '1' ]] || [[ "$NUMBER" -eq 2 ]]; then
            echo "ข้อมูล: กำลังติดตั้ง Hysteria $RELEASE_VERSION สำหรับ $(uname -m)"
            download_hysteria
            if [[ "$?" -eq '1' ]]; then
                "rm" -r "$TMP_DIRECTORY"
                echo "ลบแล้ว: $TMP_DIRECTORY"
                exit 1
            fi
            elif [[ "$NUMBER" -eq '1' ]]; then
            echo "ข้อมูล: ไม่มีรุ่นใหม่ รุ่นปัจจุบันของ Hysteria คือ $CURRENT_VERSION"
            exit 0
        fi
    fi
    
    # ตรวจว่า Hysteria กำลังทำงานอยู่หรือไม่
    if systemctl list-unit-files | grep -qw 'hysteria'; then
        if [[ -n "$(pidof hysteria)" ]]; then
            stop_hysteria
            HYSTERIA_RUNNING='1'
        fi
    fi
    install_hysteria
    install_startup_service_file
    echo 'ติดตั้งแล้ว: /usr/local/bin/hysteria'
    # ถ้าไฟล์มีอยู่ จะไม่แสดงเนื้อหาของการติดตั้งหรืออัปเดต geoip.dat และ geosite.dat
    if [[ "$CONFIG_NEW" -eq '1' ]]; then
        echo "ติดตั้งแล้ว: ${JSON_PATH}/config.json"
    fi
    if [[ "$SYSTEMD" -eq '1' ]]; then
        echo 'ติดตั้งแล้ว: /lib/systemd/system/hysteria-server.service'
        echo 'ติดตั้งแล้ว: /lib/systemd/system/hysteria-server@.service'
    fi
    "rm" -r "$TMP_DIRECTORY"
    echo "ลบแล้ว: $TMP_DIRECTORY"
    if [[ "$LOCAL_INSTALL" -eq '1' ]]; then
        get_version
    fi
    echo "ข้อมูล: ติดตั้ง Hysteria $RELEASE_VERSION แล้ว"
    if [[ "$HYSTERIA_RUNNING" -eq '1' ]]; then
        start_hysteria
    else
        echo 'กรุณารันคำสั่ง: systemctl enable hysteria-server; systemctl start hysteria-server'
    fi
}

main "$@"