#!/bin/sh
#
# Proto ATC untuk Fibocom L850-GL dan L860-GL
# Berdasarkan karya asli mrhaav (2025-09-06)
# Diperbaiki untuk kompatibilitas BusyBox ash (OpenWrt)
#
# Perubahan dari versi asli:
#   - [[ ]] diganti ke case/[ ]
#   - ${var::n} dan ${var: -n} (bash substring) diganti ke POSIX cut/awk/expr
#   - Semua bashism lain dihapus
#

[ -n "$INCLUDE_ONLY" ] || {
    . /lib/functions.sh
    . ../netifd-proto.sh
    init_proto "$@"
}

# ---------------------------------------------------------------------------
# Helper: ambil N karakter pertama dari string (pengganti ${var::N})
# Penggunaan: str_head "$string" N
# ---------------------------------------------------------------------------
str_head() {
    echo "$1" | cut -c1-"$2"
}

# Helper: ambil karakter dari posisi N sampai akhir (pengganti ${var:N})
# Penggunaan: str_tail "$string" N   (N = 1-based, inklusif)
str_tail() {
    echo "$1" | cut -c"$2"-
}

# Helper: ambil N karakter dari belakang (pengganti ${var: -N})
# Penggunaan: str_right "$string" N
str_right() {
    echo "$1" | rev | cut -c1-"$2" | rev
}

# Helper: buang N karakter dari belakang (pengganti ${var:: -N})
# Penggunaan: str_chop "$string" N
str_chop() {
    local s="$1"
    local n="$2"
    local len
    len=$(expr ${#s} - $n)
    [ "$len" -le 0 ] && echo "" || echo "$s" | cut -c1-"$len"
}

# ---------------------------------------------------------------------------
update_IPv4() {
    proto_init_update "$ifname" 1
    proto_set_keep 1
    proto_add_ipv4_address "$v4address" "$v4netmask"
    proto_add_ipv4_route "$v4gateway" "128"
    [ "$defaultroute" = 0 ] || proto_add_ipv4_route "0.0.0.0" 0 "$v4gateway"
    [ "$peerdns" = 0 ] || {
        proto_add_dns_server "$v4dns1"
        proto_add_dns_server "$v4dns2"
    }
    [ -n "$zone" ] && {
        proto_add_data
        json_add_string zone "$zone"
        proto_close_data
    }
    proto_send_update "$interface"
}

update_DHCPv6() {
    json_init
    json_add_string name "${interface}6"
    json_add_string ifname "@$interface"
    json_add_string proto "dhcpv6"
    proto_add_dynamic_defaults
    json_add_string extendprefix 1
    [ "$peerdns" = 0 ] || {
        json_add_array dns
        json_add_string "" "$v6dns1"
        json_add_string "" "$v6dns2"
        json_close_array
    }
    [ -n "$zone" ] && json_add_string zone "$zone"
    json_close_object
    [ "$atc_debug" -ge 1 ] && echo "JSON: $(json_dump)"
    ubus call network add_dynamic "$(json_dump)"
}

subnet_calc() {
    local IPaddr="$1"
    local A B C D x y netaddr res subnet gateway

    A=$(echo "$IPaddr" | awk -F '.' '{print $1}')
    B=$(echo "$IPaddr" | awk -F '.' '{print $2}')
    C=$(echo "$IPaddr" | awk -F '.' '{print $3}')
    D=$(echo "$IPaddr" | awk -F '.' '{print $4}')

    x=1
    y=4
    netaddr=$((y - 1))
    res=$((D % y))

    while [ "$res" -eq 0 ] || [ "$res" -eq "$netaddr" ]; do
        x=$((x + 1))
        y=$((y * 2))
        netaddr=$((y - 1))
        res=$((D % y))
    done

    subnet=$((31 - x))
    gateway=$((D / y))
    if [ "$res" -eq 1 ]; then
        gateway=$(( (D / y) * y + 2 ))
    else
        gateway=$(( (D / y) * y + 1 ))
    fi
    echo "$subnet $A.$B.$C.$gateway"
}

nb_rat() {
    local rat_nb="$1"
    case "$rat_nb" in
        0|1|3)   echo "GSM" ;;
        2|4|5|6) echo "WCDMA" ;;
        7)       echo "LTE" ;;
        11)      echo "NR" ;;
        13)      echo "LTE-ENDC" ;;
        *)       echo "$rat_nb" ;;
    esac
}

CxREG() {
    local reg_string="$1"
    local lac_tac g_cell_id rat reject_cause cell_prefix cell_suffix

    if [ "${#reg_string}" -gt 4 ]; then
        lac_tac=$(echo "$reg_string"     | awk -F ',' '{print $2}')
        g_cell_id=$(echo "$reg_string"   | awk -F ',' '{print $3}')
        rat=$(echo "$reg_string"         | awk -F ',' '{print $4}')
        reject_cause=$(echo "$reg_string"| awk -F ',' '{print $6}')

        [ -n "$rat" ] && rat=$(nb_rat "$rat") || { echo ""; return; }
        [ -z "$reject_cause" ] && reject_cause=0

        case "$rat" in
            WCDMA)
                # WCDMA: cell_id = RNCid (terkecuali 4 hex terakhir) + CellId (4 hex terakhir)
                cell_prefix=$(str_chop "$g_cell_id" 4)
                cell_suffix=$(str_right "$g_cell_id" 4)
                reg_string=", RNCid:$(printf '%d' 0x${cell_prefix}) LAC:$(printf '%d' 0x${lac_tac}) CellId:$(printf '%d' 0x${cell_suffix})"
                ;;
            LTE|LTE-ENDC)
                # LTE/ENDC: eNodeB = semua kecuali 2 hex terakhir, CID = 2 hex terakhir
                cell_prefix=$(str_chop "$g_cell_id" 2)
                cell_suffix=$(str_right "$g_cell_id" 2)
                reg_string=", TAC:$(printf '%d' 0x${lac_tac}) eNodeB:$(printf '%d' 0x${cell_prefix})-$(printf '%d' 0x${cell_suffix})"
                ;;
            *)
                reg_string=""
                ;;
        esac

        [ "$reject_cause" -gt 0 ] && reg_string="${reg_string} - Reject cause: ${reject_cause}"
        # Jika tidak ada reject dan string dimulai '0' (notRegistered), kosongkan
        first_char=$(str_head "$reg_string" 1)
        [ "$reject_cause" -eq 0 ] && [ "$first_char" = "0" ] && reg_string=""
    else
        reg_string=""
    fi
    echo "$reg_string"
}

full_apn() {
    local apn="$1"
    local rest len_rest len_apn

    apn=$(echo "$apn" | awk '{print tolower($0)}')
    # Buang suffix ".mncXXX.mccYYY.gprs" (mulai dari ".mnc")
    rest=$(echo "$apn" | sed 's/.*\.mnc/\.mnc/')
    len_rest=${#rest}
    len_apn=${#apn}
    # Jika rest ditemukan dan bukan apn itu sendiri, potong
    if [ "$len_rest" -lt "$len_apn" ]; then
        apn=$(str_chop "$apn" "$((len_rest + 4))")
    fi
    echo "$apn"
}

# ---------------------------------------------------------------------------
proto_atc_init_config() {
    no_device=1
    available=1
    proto_config_add_string "device:device"
    proto_config_add_string "apn"
    proto_config_add_string "pincode"
    proto_config_add_string "pdp"
    proto_config_add_string "auth"
    proto_config_add_string "username"
    proto_config_add_string "password"
    proto_config_add_string "atc_debug"
    proto_config_add_string "delay"
    proto_config_add_string "v6dns_ra"
    proto_config_add_defaults
}

proto_atc_setup() {
    local interface="$1"
    local OK_received=0
    local nw_disconnect=0
    local devname devpath atOut conStatus manufactor model fw rssi
    local firstASCII URCline URCcommand URCvalue x status rat new_rat
    local cops_format operator plmn used_apn
    local v6address hwaddr h
    local device ifname apn pdp pincode auth username password delay atc_debug v6dns_ra
    local sms_index sms_pdu at_line at_command lines

    json_get_vars device ifname apn pdp pincode auth username password \
                  delay atc_debug v6dns_ra $PROTO_DEFAULT_OPTIONS

    local custom_at
    custom_at=$(uci -q get network.${interface}.custom_at 2>/dev/null)

    mkdir -p /var/sms/rx

    /usr/bin/modem_led boot 2>/dev/null

    [ -z "$delay" ] && delay=15
    [ ! -f /var/modem.status ] && {
        echo "Modem boot delay ${delay}s"
        sleep "$delay"
    }

    devname=$(basename "$device")
    case "$devname" in
        *ttyACM*)
            devpath="$(readlink -f /sys/class/tty/$devname/device)"
            hwaddr="$(ls -1 $devpath/../*/net/*/*address* 2>/dev/null)"
            for h in $hwaddr; do
                if [ "$(cat "${h}" 2>/dev/null)" = "00:00:11:12:13:14" ]; then
                    ifname=$(echo "${h}" | awk -F '/' '{print $(NF-1)}')
                fi
            done
            ;;
    esac

    [ -n "$ifname" ] || {
        echo "No interface could be found"
        proto_notify_error "$interface" NO_IFACE
        proto_block_restart "$interface"
        return 1
    }

    zone="$(fw3 -q network "$interface" 2>/dev/null)"
    echo 0 > /var/modem.status
    echo "Initiate modem with interface $ifname"

    atOut=$(COMMAND='AT+CMEE=2' gcom -d "$device" -s /etc/gcom/run_at.gcom 2>&1)
    while [ "$atOut" != "OK" ]; do
        echo "Modem not ready yet"
        [ "$atc_debug" -gt 1 ] && {
            echo "$device"
            case "$atOut" in
                *"Error @"*) echo "$atOut" | grep 'Error @' ;;
            esac
        }
        sleep 1
        atOut=$(COMMAND='AT+CMEE=2' gcom -d "$device" -s /etc/gcom/run_at.gcom 2>&1)
    done

    atOut=$(COMMAND='AT+CPIN?' gcom -d "$device" -s /etc/gcom/getrun_at.gcom)
    if echo "$atOut" | grep -q 'CPIN:'; then
        atOut=$(echo "$atOut" | grep 'CPIN:' | awk -F ':' '{print $2}' | sed 's/[\r\n]//g' | sed 's/^ //')
    elif echo "$atOut" | grep -q 'CME ERROR:'; then
        atOut=$(echo "$atOut" | grep 'CME ERROR:' | awk -F ':' '{print $2}' | sed 's/[\r\n]//g' | sed 's/^ //')
        echo "$atOut"
        proto_notify_error "$interface" "$atOut"
        proto_block_restart "$interface"
        return 1
    else
        echo "Can not read SIMcard"
        proto_notify_error "$interface" SIMreadfailure
        proto_block_restart "$interface"
        return 1
    fi

    case "$atOut" in
        READY)
            echo "SIMcard ready"
            ;;
        'SIM PIN')
            if [ -z "$pincode" ]; then
                echo "PINcode required but missing"
                proto_notify_error "$interface" PINmissing
                proto_block_restart "$interface"
                return 1
            fi
            atOut=$(COMMAND='AT+CPIN="'"$pincode"'"' gcom -d "$device" -s /etc/gcom/getrun_at.gcom | grep 'CME ERROR:')
            if [ -n "$atOut" ]; then
                echo "PINcode error: ${atOut#*CME ERROR:}"
                proto_notify_error "$interface" PINerror
                proto_block_restart "$interface"
                return 1
            fi
            echo "PINcode verified"
            ;;
        *)
            echo "SIMcard error: $atOut"
            proto_notify_error "$interface" PINerror
            proto_block_restart "$interface"
            return 1
            ;;
    esac

    /usr/bin/modem_led config 2>/dev/null

    atOut=$(COMMAND='AT+CFUN=4' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != "OK" ] && echo "$atOut"
    conStatus=offline
    echo "Configure modem"

    # Baca manufaktur — strip prefix "+CGMI:" jika ada (POSIX-safe)
    manufactor=$(COMMAND='AT+CGMI' gcom -d "$device" -s /etc/gcom/getrun_at.gcom \
        | grep -Ev "^(AT\+CGMI\r?$|\r?$|OK\r?$)" \
        | sed 's/"//g; s/\r//g')
    case "$manufactor" in
        '+CGMI:'*) manufactor="${manufactor#'+CGMI:'}" ;;
    esac
    manufactor=$(echo "$manufactor" | sed 's/^ //')

    model=$(COMMAND='AT+CGMM' gcom -d "$device" -s /etc/gcom/getrun_at.gcom \
        | grep -Ev "^(AT\+CGMM\r?$|\r?$|OK\r?$)" \
        | sed 's/"//g; s/\r//g')
    case "$model" in
        '+CGMM:'*) model="${model#'+CGMM:'}" ;;
    esac
    model=$(echo "$model" | sed 's/^ //')

    [ "$atc_debug" -gt 1 ] && {
        fw=$(COMMAND='AT+CGMR' gcom -d "$device" -s /etc/gcom/getrun_at.gcom \
            | grep -Ev "^(AT\+CGMR\r?$|\r?$|OK\r?$)" \
            | sed 's/"//g; s/\r//g')
        case "$fw" in '+CGMR:'*) fw="${fw#'+CGMR:'}" ;; esac
        fw=$(echo "$fw" | sed 's/^ //')
        echo "$manufactor"
        echo "$model"
        echo "$fw"
    }

    # Validasi manufaktur dan model (POSIX: pakai case + grep)
    if echo "$manufactor" | grep -q 'Fibocom' && echo "$model" | grep -qE 'L8[56]0'; then
        :
    else
        echo "Wrong script. This is optimized for: Fibocom, L850 or L860 LTE Module"
        echo "$manufactor"
        echo "$model"
        proto_notify_error "$interface" MODEM
        proto_block_restart "$interface"
        return 1
    fi

    atOut=$(COMMAND='AT+CREG=0'    gcom -d "$device" -s /etc/gcom/run_at.gcom); [ "$atOut" != "OK" ] && echo "$atOut"
    atOut=$(COMMAND='AT+CGREG=3'   gcom -d "$device" -s /etc/gcom/run_at.gcom); [ "$atOut" != "OK" ] && echo "$atOut"
    atOut=$(COMMAND='AT+CEREG=3'   gcom -d "$device" -s /etc/gcom/run_at.gcom); [ "$atOut" != "OK" ] && echo "$atOut"
    atOut=$(COMMAND='AT+CGEREP=2,1' gcom -d "$device" -s /etc/gcom/run_at.gcom); [ "$atOut" != "OK" ] && echo "$atOut"

    atOut=$(COMMAND='AT+CGDCONT=0,"'"$pdp"'","'"$apn"'"' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != "OK" ] && echo "$atOut"
    atOut=$(COMMAND='AT+XGAUTH=0,'"$auth"',"'"$username"'","'"$password"'"' gcom -d "$device" -s /etc/gcom/run_at.gcom)
    [ "$atOut" != "OK" ] && echo "$atOut"

    atOut=$(COMMAND='AT+XDNS=0,1;+XDNS=0,2' gcom -d "$device" -s /etc/gcom/run_at.gcom);    [ "$atOut" != "OK" ] && echo "$atOut"
    atOut=$(COMMAND='AT+CGPIAF=1,1,0,1'      gcom -d "$device" -s /etc/gcom/run_at.gcom);    [ "$atOut" != "OK" ] && echo "$atOut"
    atOut=$(COMMAND='AT+CMGF=0'              gcom -d "$device" -s /etc/gcom/run_at.gcom);    [ "$atOut" != "OK" ] && echo "$atOut"
    atOut=$(COMMAND='AT+CSCS="GSM"'          gcom -d "$device" -s /etc/gcom/run_at.gcom);    [ "$atOut" != "OK" ] && echo "$atOut"
    atOut=$(COMMAND='AT+CNMI=2,1'            gcom -d "$device" -s /etc/gcom/run_at.gcom);    [ "$atOut" != "OK" ] && echo "$atOut"
    atOut=$(COMMAND='AT+XCESQ=1'             gcom -d "$device" -s /etc/gcom/run_at.gcom);    [ "$atOut" != "OK" ] && echo "$atOut"
    atOut=$(COMMAND='AT+XCESQRC=1'           gcom -d "$device" -s /etc/gcom/run_at.gcom);    [ "$atOut" != "OK" ] && echo "$atOut"
    atOut=$(COMMAND='AT+XCCINFO=0'           gcom -d "$device" -s /etc/gcom/run_at.gcom);    [ "$atOut" != "OK" ] && echo "$atOut"

    # Custom AT commands dari UCI
    x=$(echo "$custom_at" | wc -w)
    [ "$x" -gt 0 ] && {
        echo "Running custom AT-commands"
        for at_command in $custom_at; do
            at_prefix=$(echo "$at_command" | cut -c1-2 | awk '{print toupper($0)}')
            if [ "$at_prefix" = "AT" ]; then
                echo "  $at_command"
                atOut=$(COMMAND="$at_command" gcom -d "$device" -s /etc/gcom/getrun_at.gcom)
                lines=$(echo "$atOut" | wc -l)
                x=1
                while [ "$x" -le "$lines" ]; do
                    at_line=$(echo "$atOut" | sed -n "${x}p" | sed 's/[\r\n]//g')
                    [ -n "$at_line" ] && [ "$at_line" != "$at_command" ] && echo "  $at_line"
                    x=$((x + 1))
                done
            else
                echo "Custom AT-command harus diawali 'AT': $at_command"
            fi
        done
    }

    echo "Activate modem"
    COMMAND='AT+CFUN=1' gcom -d "$device" -s /etc/gcom/at.gcom

    /usr/bin/modem_led searching 2>/dev/null

    # -----------------------------------------------------------------------
    # Loop URC — baca langsung dari device TTY
    # Perhatian: loop ini berjalan sampai proto_teardown atau device hilang.
    # -----------------------------------------------------------------------
    while IFS= read -r URCline; do
        # Lewati baris kosong (CR saja, ASCII 13) dan spasi
        firstASCII=$(printf "%d" "'$(str_head "$URCline" 1)" 2>/dev/null || echo 0)
        [ "$firstASCII" -eq 13 ] && continue
        [ "$firstASCII" -eq 32 ] && continue

        URCcommand=$(echo "$URCline" | awk -F ':' '{print $1}' | sed 's/[\r\n]//g')
        x=$((${#URCcommand} + 1))
        URCvalue=$(str_tail "$URCline" $((x + 1)))
        URCvalue=$(echo "$URCvalue" | sed 's/"//g; s/[\r\n]//g; s/^ //')

        case "$URCcommand" in
            +CGREG|+CEREG)
                [ "$atc_debug" -gt 1 ] && echo "$URCline"
                status=$(echo "$URCvalue" | awk -F ',' '{print $1}')
                new_rat=""
                if [ "${#URCvalue}" -gt 6 ]; then
                    new_rat=$(echo "$URCvalue" | awk -F ',' '{print $4}')
                    new_rat=$(nb_rat "$new_rat")
                fi
                case "$status" in
                    0)
                        echo "  $conStatus -> notRegistered$(CxREG "$URCvalue")"
                        conStatus=notRegistered
                        ;;
                    1)
                        if [ "$conStatus" = "registered" ]; then
                            [ -n "$rat" ] && [ -n "$new_rat" ] && [ "$new_rat" != "$rat" ] && {
                                echo "RATchange: $rat -> $new_rat"
                                rat=$new_rat
                                /usr/bin/modem_led connected_${new_rat} 2>/dev/null
                            }
                            [ "$atc_debug" -ge 1 ] && echo "Cell change$(CxREG "$URCvalue")"
                        else
                            echo "  $conStatus -> registered - home network$(CxREG "$URCvalue")"
                            rat=$new_rat
                            conStatus=registered
                        fi
                        ;;
                    2)
                        echo "  $conStatus -> searching $(CxREG "$URCvalue")"
                        conStatus=searching
                        ;;
                    3)
                        echo "Registration denied"
                        [ "$nw_disconnect" -eq 0 ] && {
                            proto_notify_error "$interface" REG_DENIED
                            proto_block_restart "$interface"
                            return 1
                        }
                        ;;
                    4)
                        echo "  $conStatus -> unknown"
                        conStatus=unknown
                        ;;
                    5)
                        if [ "$conStatus" = "registered" ]; then
                            [ -n "$rat" ] && [ -n "$new_rat" ] && [ "$new_rat" != "$rat" ] && {
                                echo "RATchange: $rat -> $new_rat"
                                rat=$new_rat
                                /usr/bin/modem_led connected_${new_rat} 2>/dev/null
                            }
                            [ "$atc_debug" -ge 1 ] && echo "Cell change$(CxREG "$URCvalue")"
                        else
                            echo "  $conStatus -> registered - roaming$(CxREG "$URCvalue")"
                            rat=$new_rat
                            conStatus=registered
                        fi
                        ;;
                esac
                ;;

            +COPS)
                [ "$atc_debug" -ge 1 ] && echo "$URCline"
                cops_format=$(echo "$URCvalue" | awk -F ',' '{print $2}')
                [ "$cops_format" -eq 0 ] && {
                    operator=$(echo "$URCvalue" | awk -F ',' '{print $3}')
                }
                [ "$cops_format" -eq 2 ] && {
                    plmn=$(echo "$URCvalue" | awk -F ',' '{print $3}')
                    rat=$(echo "$URCvalue" | awk -F ',' '{print $4}')
                    rat=$(nb_rat "$rat")
                    echo "Registered to $operator PLMN:$plmn on $rat"
                    echo "Activate session"
                    OK_received=1
                }
                ;;

            +CGEV)
                [ "$atc_debug" -ge 1 ] && echo "$URCline"
                case "$URCvalue" in
                    'NW DETACH')
                        nw_disconnect=1
                        ;;
                    'ME PDN DEACT 0'|'NW PDN DEACT 0')
                        echo "Session disconnected by the network"
                        /usr/bin/modem_led searching 2>/dev/null
                        proto_init_update "$ifname" 0
                        proto_send_update "$interface"
                        ;;
                    'ME PDN ACT 0')
                        if [ "$nw_disconnect" -eq 0 ]; then
                            nw_disconnect=2
                            COMMAND='AT+COPS=3,0;+COPS?;+COPS=3,2;+COPS?' gcom -d "$device" -s /etc/gcom/at.gcom
                        else
                            nw_disconnect=2
                            echo "Re-activate session"
                            COMMAND='AT+CGCONTRDP=0' gcom -d "$device" -s /etc/gcom/at.gcom
                            OK_received=2
                        fi
                        ;;
                esac
                ;;

            +CGCONTRDP)
                [ "$atc_debug" -ge 1 ] && echo "$URCline"
                [ -z "$used_apn" ] && {
                    used_apn=$(echo "$URCvalue" | awk -F ',' '{print $3}')
                    used_apn=$(full_apn "$used_apn")
                    [ "$apn" != "$used_apn" ] && echo "Using network default APN: $used_apn"
                }
                case "$URCvalue" in
                    *:*)
                        # IPv6
                        v6address=$(echo "$URCvalue" | awk -F ',' '{print $4}')
                        v6dns1=$(echo "$URCvalue"    | awk -F ',' '{print $6}')
                        v6dns2=$(echo "$URCvalue"    | awk -F ',' '{print $7}')
                        ;;
                    *)
                        # IPv4
                        v4address=$(echo "$URCvalue" | awk -F ',' '{print $4}' | awk -F '.' '{print $1"."$2"."$3"."$4}')
                        v4netmask=$(subnet_calc "$v4address")
                        v4gateway=$(echo "$v4netmask" | awk '{print $2}')
                        v4netmask=$(echo "$v4netmask" | awk '{print $1}')
                        v4dns1=$(echo "$URCvalue"    | awk -F ',' '{print $6}')
                        v4dns2=$(echo "$URCvalue"    | awk -F ',' '{print $7}')
                        ;;
                esac
                ;;

            CONNECT)
                [ "$atc_debug" -ge 1 ] && echo "$URCline"
                /usr/bin/modem_led connected_${new_rat} 2>/dev/null
                proto_init_update "$ifname" 1
                proto_set_keep 1
                proto_add_data
                json_add_string "modem" "${model}"
                proto_close_data
                proto_send_update "$interface"
                ip link set dev "$ifname" arp off
                [ -n "$v4address" ] && update_IPv4
                [ -n "$v6address" ] && update_DHCPv6
                ;;

            +XCESQI)
                [ "$atc_debug" -gt 1 ] && echo "$URCline"
                rssi=$(echo "$URCvalue" | awk -F ',' '{print $6}')
                if [ "$rssi" -ne 255 ] 2>/dev/null; then
                    rssi=$((rssi * 100 / 97))
                else
                    rssi=$(echo "$URCvalue" | awk -F ',' '{print $3}')
                    if [ "$rssi" -ne 255 ] 2>/dev/null; then
                        rssi=$((rssi * 100 / 96))
                    else
                        rssi=256
                    fi
                fi
                /usr/bin/modem_led rssi "$rssi" 2>/dev/null
                ;;

            +CMTI)
                [ "$atc_debug" -ge 1 ] && echo "$URCline"
                sms_index=$(echo "$URCvalue" | awk -F ',' '{print $2}')
                COMMAND="AT+CMGR=$sms_index" gcom -d "$device" -s /etc/gcom/at.gcom
                ;;

            +CMGR)
                [ "$atc_debug" -ge 1 ] && echo "$URCline"
                OK_received=11
                ;;

            +CMGS)
                [ "$atc_debug" -ge 1 ] && echo "$URCline"
                echo "SMS successfully sent"
                ;;

            OK)
                [ "$atc_debug" -ge 1 ] && echo "$URCline"
                [ "$OK_received" -eq 12 ] && {
                    /usr/bin/atc_rx_pdu_sms "$sms_pdu" 2>/dev/null
                    [ "$sms_index" -gt 1 ] && {
                        sms_index=$((sms_index - 1))
                        COMMAND="AT+CMGR=$sms_index" gcom -d "$device" -s /etc/gcom/at.gcom
                    } || {
                        OK_received=0
                    }
                }
                [ "$OK_received" -eq 11 ] && {
                    COMMAND="AT+CMGD=$sms_index" gcom -d "$device" -s /etc/gcom/at.gcom
                    OK_received=12
                }
                [ "$OK_received" -eq 3 ] && {
                    COMMAND='AT+CGDATA="M-RAW_IP",0' gcom -d "$device" -s /etc/gcom/at.gcom
                    OK_received=10
                }
                [ "$OK_received" -eq 2 ] && {
                    COMMAND='AT+XDATACHANNEL=1,1,"/USBCDC/0","/USBHS/NCM/0",2,0' gcom -d "$device" -s /etc/gcom/at.gcom
                    OK_received=3
                }
                [ "$OK_received" -eq 1 ] && {
                    COMMAND='AT+CGCONTRDP=0' gcom -d "$device" -s /etc/gcom/at.gcom
                    OK_received=2
                }
                ;;

            *)
                [ "$atc_debug" -ge 1 ] && echo "$URCline"
                [ "$OK_received" -eq 11 ] && {
                    sms_pdu="$URCline"
                    echo "SMS received"
                    [ "$atc_debug" -gt 1 ] && echo "$sms_pdu" >> /var/sms/pdus 2>/dev/null
                }
                ;;
        esac

    done < "$device"
    # Jika sampai di sini berarti device tutup (modem dicabut atau error)
    echo "Device $device closed, proto will restart"
}

proto_atc_teardown() {
    local interface="$1"
    local device
    device=$(uci -q get network.${interface}.device)
    echo "$interface is disconnected"
    /usr/bin/modem_led off 2>/dev/null
    COMMAND='AT+XDATACHANNEL=0' gcom -d "$device" -s /etc/gcom/run_at.gcom 2>/dev/null
    COMMAND='AT+CGDATA=0'       gcom -d "$device" -s /etc/gcom/run_at.gcom 2>/dev/null
    proto_init_update "*" 0
    proto_send_update "$interface"
}

[ -n "$INCLUDE_ONLY" ] || {
    add_protocol atc
}
