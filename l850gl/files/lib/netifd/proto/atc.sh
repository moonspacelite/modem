#!/bin/sh
#
# AT commands for Fibocom L850-GL and L860-GL modems
# Revisi: validasi ketat substring, cegah "out of range"
#

[ -n "$INCLUDE_ONLY" ] || {
    . /lib/functions.sh
    . ../netifd-proto.sh
    init_proto "$@"
}

VENDOR_SCRIPT="/usr/share/l850gl/vendor/fibocom.sh"
[ -f "$VENDOR_SCRIPT" ] && . "$VENDOR_SCRIPT"

update_IPv4 () {
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

update_DHCPv6 () {
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

subnet_calc () {
    local IPaddr="$1"
    [ -z "$IPaddr" ] && { echo "0 0.0.0.0"; return; }
    local A B C D 
    local x y netaddr res subnet gateway

    A=$(echo $IPaddr | awk -F '.' '{print $1}')
    B=$(echo $IPaddr | awk -F '.' '{print $2}')
    C=$(echo $IPaddr | awk -F '.' '{print $3}')
    D=$(echo $IPaddr | awk -F '.' '{print $4}')

    x=1
    y=4
    netaddr=$((y-1))
    res=$((D%y))

    while [ $res -eq 0 ] || [ $res -eq $netaddr ]; do
        x=$((x+1))
        y=$((y*2))
        netaddr=$((y-1))
        res=$((D%y))
    done

    subnet=$((31-x))
    gateway=$((D/y))
    [ $res -eq 1 ] && gateway=$((gateway*y+2)) || gateway=$((gateway*y+1))
    echo "$subnet $A.$B.$C.$gateway"
}

nb_rat () {
    local rat_nb="${1:-}"
    case $rat_nb in
        0|1|3) echo "GSM" ;;
        2|4|5|6) echo "WCDMA" ;;
        7) echo "LTE" ;;
        11) echo "NR" ;;
        13) echo "LTE-ENDC" ;;
        *) echo "Unknown" ;;
    esac
}

# Fungsi aman untuk mengambil substring: safe_substr <string> <start> <length>
safe_substr() {
    local str="$1"
    local start="$2"
    local len="$3"
    if [ -z "$str" ] || [ $start -ge ${#str} ]; then
        echo ""
        return
    fi
    echo "${str:$start:$len}"
}

CxREG () {
    local reg_string="$1"
    local lac_tac g_cell_id rat reject_cause

    if [ ${#reg_string} -le 4 ] || ! echo "$reg_string" | grep -q ','; then
        echo ""
        return
    fi

    lac_tac=$(echo "$reg_string" | awk -F ',' '{print $2}')
    g_cell_id=$(echo "$reg_string" | awk -F ',' '{print $3}')
    rat=$(echo "$reg_string" | awk -F ',' '{print $4}')
    reject_cause=$(echo "$reg_string" | awk -F ',' '{print $6}')

    [ -n "$rat" ] && rat=$(nb_rat "$rat")
    [ -z "$reject_cause" ] && reject_cause=0

    if [ "$rat" = 'WCDMA' ] && [ -n "$g_cell_id" ] && [ ${#g_cell_id} -ge 4 ] && [ -n "$lac_tac" ]; then
        local rncid=$(safe_substr "$g_cell_id" 0 $((${#g_cell_id}-4)))
        local cellid=$(safe_substr "$g_cell_id" $((${#g_cell_id}-4)) 4)
        reg_string=", RNCid:$(printf '%d' 0x${rncid} 2>/dev/null || echo 0) LAC:$(printf '%d' 0x$lac_tac 2>/dev/null || echo 0) CellId:$(printf '%d' 0x${cellid} 2>/dev/null || echo 0)"
    elif [ "${rat::3}" = 'LTE' ] && [ -n "$g_cell_id" ] && [ ${#g_cell_id} -ge 2 ] && [ -n "$lac_tac" ]; then
        local enb=$(safe_substr "$g_cell_id" 0 $((${#g_cell_id}-2)))
        local cell=$(safe_substr "$g_cell_id" $((${#g_cell_id}-2)) 2)
        reg_string=", TAC:$(printf '%d' 0x$lac_tac 2>/dev/null || echo 0) eNodeB:$(printf '%d' 0x${enb} 2>/dev/null || echo 0)-$(printf '%d' 0x${cell} 2>/dev/null || echo 0)"
    fi

    [ "$reject_cause" -gt 0 ] && reg_string="$reg_string - Reject cause: $reject_cause"
    [ "$reject_cause" -eq 0 ] && [ "${reg_string::1}" = '0' ] && reg_string=''

    echo "$reg_string"
}

full_apn () {
    local apn=$1
    local rest

    apn=$(echo "$apn" | awk '{print tolower($0)}')
    rest=$(echo "${apn#*'.mnc'}")
    rest=${#rest}
    rest=$((rest+4))
    [ $rest -lt ${#apn} ] && apn=${apn:: -$rest}
    echo "$apn"
}

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

proto_atc_setup () {
    local interface="$1"
    local OK_received=0
    local nw_disconnect=0
    local devname devpath atOut conStatus manufactor model fw rssi
    local firstASCII URCline URCcommand URCvalue x status rat new_rat cops_format operator plmn used_apn
    local v6address hwaddr h
    local device ifname apn pdp pincode auth username password delay atc_debug v6dns_ra $PROTO_DEFAULT_OPTIONS

    json_get_vars device ifname apn pdp pincode auth username password delay atc_debug v6dns_ra $PROTO_DEFAULT_OPTIONS

    if [ ! -c "$device" ]; then
        echo "Error: '$device' is not a valid character device."
        proto_notify_error "$interface" INVALID_DEVICE
        proto_block_restart "$interface"
        return 1
    fi

    local custom_at=$(uci -q get network.${interface}.custom_at)

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
            hwaddr="$(ls -1 $devpath/../*/net/*/*address*)"
            for h in $hwaddr; do
                if [ "$(cat ${h})" = "00:00:11:12:13:14" ]; then
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

    if command -v ensure_ncm_mode >/dev/null 2>&1; then
        if ! ensure_ncm_mode "$device"; then
            echo "Modem sedang reboot untuk mengubah mode. Coba lagi nanti."
            proto_notify_error "$interface" MODEM_REBOOT
            proto_block_restart "$interface"
            return 1
        fi
    fi

    if ! at_ok "$device" "AT+CMEE=2"; then
        echo "Gagal mengirim AT+CMEE=2"
        proto_notify_error "$interface" AT_FAILED
        proto_block_restart "$interface"
        return 1
    fi

    while ! at_ok "$device" "AT"; do
        echo "Modem not ready yet"
        [ "$atc_debug" -gt 1 ] && echo "Device: $device"
        sleep 1
    done

    if command -v handle_pin >/dev/null 2>&1; then
        if ! handle_pin "$device" "$pincode"; then
            proto_notify_error "$interface" SIM_FAILURE
            proto_block_restart "$interface"
            return 1
        fi
    else
        atOut=$(at_command "$device" "AT+CPIN?" | grep "CPIN:")
        if [ -n "$atOut" ]; then
            atOut=$(echo "$atOut" | awk -F ':' '{print $2}' | tr -d '\r\n ' | sed 's/^ //')
            case "$atOut" in
                READY)
                    echo "SIMcard ready"
                    ;;
                "SIM PIN")
                    if [ -z "$pincode" ]; then
                        echo "PIN required but missing"
                        proto_notify_error "$interface" PINmissing
                        proto_block_restart "$interface"
                        return 1
                    fi
                    if ! at_ok "$device" "AT+CPIN=\"$pincode\""; then
                        echo "PIN error"
                        proto_notify_error "$interface" PINerror
                        proto_block_restart "$interface"
                        return 1
                    fi
                    echo "PIN verified"
                    ;;
                *)
                    echo "SIM error: $atOut"
                    proto_notify_error "$interface" SIMerror
                    proto_block_restart "$interface"
                    return 1
                    ;;
            esac
        else
            echo "Cannot read SIM"
            proto_notify_error "$interface" SIMreadfailure
            proto_block_restart "$interface"
            return 1
        fi
    fi

    /usr/bin/modem_led config 2>/dev/null

    at_ok "$device" "AT+CFUN=4"
    conStatus="offline"
    echo "Configure modem"

    if command -v get_manufacturer >/dev/null 2>&1; then
        manufactor=$(get_manufacturer "$device")
        model=$(get_model "$device")
    else
        manufactor=$(at_command "$device" "AT+CGMI" | tail -n +2 | head -1 | tr -d '\r')
        model=$(at_command "$device" "AT+CGMM" | tail -n +2 | head -1 | tr -d '\r')
    fi

    [ "$atc_debug" -gt 1 ] && {
        if command -v get_firmware >/dev/null 2>&1; then
            fw=$(get_firmware "$device")
        else
            fw=$(at_command "$device" "AT+CGMR" | tail -n +2 | head -1 | tr -d '\r')
        fi
        echo "$manufactor"
        echo "$model"
        echo "$fw"
    }

    at_ok "$device" "AT+CREG=0"
    at_ok "$device" "AT+CGREG=3"
    at_ok "$device" "AT+CEREG=3"
    at_ok "$device" "AT+CGEREP=2,1"

    at_ok "$device" "AT+CGDCONT=0,\"$pdp\",\"$apn\""
    at_ok "$device" "AT+XGAUTH=0,$auth,\"$username\",\"$password\""

    at_ok "$device" "AT+XDNS=0,1;+XDNS=0,2"
    at_ok "$device" "AT+CGPIAF=1,1,0,1"

    at_ok "$device" "AT+CMGF=0"
    at_ok "$device" "AT+CSCS=\"GSM\""
    at_ok "$device" "AT+CNMI=2,1"

    at_ok "$device" "AT+XCESQ=1"
    at_ok "$device" "AT+XCESQRC=1"
    at_ok "$device" "AT+XCCINFO=0"

    [ -n "$custom_at" ] && {
        echo "Running custom AT-commands"
        for at_cmd in $custom_at; do
            echo " $at_cmd"
            at_command "$device" "$at_cmd"
        done
    }

    echo "Activate modem"
    at_ok "$device" "AT+CFUN=1"

    /usr/bin/modem_led searching 2>/dev/null

    while read -r URCline; do
        [ -z "$URCline" ] && continue
        # Hindari error "out of range" dengan safe_substr
        first_char=$(safe_substr "$URCline" 0 1)
        [ -z "$first_char" ] && continue
        firstASCII=$(printf "%d" "'$first_char" 2>/dev/null || echo 0)
        if [ "$firstASCII" != 13 ] && [ "$firstASCII" != 32 ]; then
            URCcommand=$(echo "$URCline" | awk -F ':' '{print $1}' | tr -d '\r\n')
            [ -z "$URCcommand" ] && continue
            x=${#URCcommand}
            x=$((x+1))
            URCvalue=$(safe_substr "$URCline" $x)
            URCvalue=$(echo "$URCvalue" | sed -e 's/"//g' | tr -d '\r\n')
            [ "${URCvalue::1}" = ' ' ] && URCvalue="${URCvalue:1}"

            case $URCcommand in
                +CGREG|+CEREG )
                    [ "$atc_debug" -gt 1 ] && echo "$URCline"
                    status=$(echo "$URCvalue" | awk -F ',' '{print $1}')
                    if [ ${#URCvalue} -gt 6 ]; then
                        new_rat=$(echo "$URCvalue" | awk -F ',' '{print $4}')
                        new_rat=$(nb_rat "$new_rat")
                    fi
                    case $status in
                        0) echo " $conStatus -> notRegistered$(CxREG "$URCvalue")"; conStatus='notRegistered' ;;
                        1)
                            if [ "$conStatus" = 'registered' ]; then
                                [ "$new_rat" != "$rat" ] && [ -n "$rat" ] && {
                                    echo "RATchange: $rat -> $new_rat"
                                    rat="$new_rat"
                                    /usr/bin/modem_led "connected_$new_rat" 2>/dev/null
                                }
                                [ "$atc_debug" -ge 1 ] && echo "Cell change$(CxREG "$URCvalue")"
                            else
                                echo " $conStatus -> registered - home network$(CxREG "$URCvalue")"
                                rat="$new_rat"
                                conStatus='registered'
                            fi
                            ;;
                        2) echo " $conStatus -> searching$(CxREG "$URCvalue")"; conStatus='searching' ;;
                        3) echo "Registration denied"
                            [ $nw_disconnect -eq 0 ] && {
                                proto_notify_error "$interface" REG_DENIED
                                proto_block_restart "$interface"
                                return 1
                            } ;;
                        4) echo " $conStatus -> unknown"; conStatus='unknown' ;;
                        5)
                            if [ "$conStatus" = 'registered' ]; then
                                [ "$new_rat" != "$rat" ] && [ -n "$rat" ] && {
                                    echo "RATchange: $rat -> $new_rat"
                                    rat="$new_rat"
                                    /usr/bin/modem_led "connected_$new_rat" 2>/dev/null
                                }
                                [ "$atc_debug" -ge 1 ] && echo "Cell change$(CxREG "$URCvalue")"
                            else
                                echo " $conStatus -> registered - roaming$(CxREG "$URCvalue")"
                                rat="$new_rat"
                                conStatus='registered'
                            fi
                            ;;
                    esac
                    ;;

                +COPS )
                    [ "$atc_debug" -ge 1 ] && echo "$URCline"
                    cops_format=$(echo "$URCvalue" | awk -F ',' '{print $2}')
                    [ "$cops_format" = "0" ] && operator=$(echo "$URCvalue" | awk -F ',' '{print $3}' | tr -d '"')
                    if [ "$cops_format" = "2" ]; then
                        plmn=$(echo "$URCvalue" | awk -F ',' '{print $3}' | tr -d '"')
                        rat=$(echo "$URCvalue" | awk -F ',' '{print $4}')
                        rat=$(nb_rat "$rat")
                        echo "Registered to $operator PLMN:$plmn on $rat"
                        echo "Activate session"
                        OK_received=1
                    fi
                    ;;

                +CGEV )
                    [ "$atc_debug" -ge 1 ] && echo "$URCline"
                    case $URCvalue in
                        'NW DETACH') nw_disconnect=1 ;;
                        'ME PDN DEACT 0'|'NW PDN DEACT 0')
                            echo "Session disconnected by the network"
                            /usr/bin/modem_led searching 2>/dev/null
                            proto_init_update "$ifname" 0
                            proto_send_update "$interface"
                            ;;
                        'ME PDN ACT 0')
                            [ $nw_disconnect -eq 0 ] && {
                                nw_disconnect=2
                                COMMAND='AT+COPS=3,0;+COPS?;+COPS=3,2;+COPS?' gcom -d "$device" -s /etc/gcom/at.gcom
                            } || {
                                nw_disconnect=2
                                echo "Re-activate session"
                                COMMAND='AT+CGCONTRDP=0' gcom -d "$device" -s /etc/gcom/at.gcom
                                OK_received=2
                            }
                            ;;
                    esac
                    ;;

                +CGCONTRDP )
                    [ "$atc_debug" -ge 1 ] && echo "$URCline"
                    [ -z "$used_apn" ] && {
                        used_apn=$(echo "$URCvalue" | awk -F ',' '{print $3}')
                        used_apn=$(full_apn "$used_apn")
                        [ "$apn" != "$used_apn" ] && echo "Using network default APN: $used_apn"
                    }
                    IPv6=$(echo "$URCvalue" | grep -a ':')
                    if [ -z "$IPv6" ]; then
                        v4address=$(echo "$URCvalue" | awk -F ',' '{print $4}' | awk -F '.' '{print $1"."$2"."$3"."$4}')
                        v4netmask=$(subnet_calc "$v4address")
                        v4gateway=$(echo "$v4netmask" | awk '{print $2}')
                        v4netmask=$(echo "$v4netmask" | awk '{print $1}')
                        v4dns1=$(echo "$URCvalue" | awk -F ',' '{print $6}')
                        v4dns2=$(echo "$URCvalue" | awk -F ',' '{print $7}')
                    else
                        v6address=$(echo "$URCvalue" | awk -F ',' '{print $4}')
                        v6dns1=$(echo "$URCvalue" | awk -F ',' '{print $6}')
                        v6dns2=$(echo "$URCvalue" | awk -F ',' '{print $7}')
                    fi
                    ;;

                CONNECT )
                    [ "$atc_debug" -ge 1 ] && echo "$URCline"
                    /usr/bin/modem_led "connected_$new_rat" 2>/dev/null
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

                +XCESQI )
                    [ "$atc_debug" -gt 1 ] && echo "$URCline"
                    rssi=$(echo "$URCvalue" | awk -F ',' '{print $6}')
                    if [ -n "$rssi" ] && [ "$rssi" -eq "$rssi" ] 2>/dev/null; then
                        if [ "$rssi" -ne 255 ]; then
                            rssi=$((rssi*100/97))
                        else
                            rssi=$(echo "$URCvalue" | awk -F ',' '{print $3}')
                            [ -n "$rssi" ] && [ "$rssi" -eq "$rssi" ] 2>/dev/null && {
                                [ "$rssi" -ne 255 ] && rssi=$((rssi*100/96)) || rssi=256
                            } || rssi=256
                        fi
                    else
                        rssi=256
                    fi
                    /usr/bin/modem_led rssi "$rssi" 2>/dev/null
                    ;;

                +CMTI )
                    [ "$atc_debug" -ge 1 ] && echo "$URCline"
                    sms_index=$(echo "$URCvalue" | awk -F ',' '{print $2}')
                    COMMAND="AT+CMGR=$sms_index" gcom -d "$device" -s /etc/gcom/at.gcom
                    ;;

                +CMGR )
                    [ "$atc_debug" -ge 1 ] && echo "$URCline"
                    OK_received=11
                    ;;

                +CMGS )
                    [ "$atc_debug" -ge 1 ] && echo "$URCline"
                    echo "SMS successfully sent"
                    ;;

                OK )
                    [ "$atc_debug" -ge 1 ] && echo "$URCline"
                    if [ $OK_received -eq 12 ]; then
                        /usr/bin/atc_rx_pdu_sms "$sms_pdu" 2>/dev/null
                        if [ "$sms_index" -gt 1 ]; then
                            sms_index=$((sms_index-1))
                            COMMAND="AT+CMGR=$sms_index" gcom -d "$device" -s /etc/gcom/at.gcom
                        else
                            OK_received=0
                        fi
                    elif [ $OK_received -eq 11 ]; then
                        COMMAND="AT+CMGD=$sms_index" gcom -d "$device" -s /etc/gcom/at.gcom
                        OK_received=12
                    elif [ $OK_received -eq 3 ]; then
                        if command -v start_data_session >/dev/null 2>&1; then
                            start_data_session "$device"
                        else
                            COMMAND='AT+CGDATA="M-RAW_IP",0' gcom -d "$device" -s /etc/gcom/at.gcom
                        fi
                        OK_received=10
                    elif [ $OK_received -eq 2 ]; then
                        if command -v open_data_channel >/dev/null 2>&1; then
                            open_data_channel "$device"
                        else
                            COMMAND='AT+XDATACHANNEL=1,1,"/USBCDC/0","/USBHS/NCM/0",2,0' gcom -d "$device" -s /etc/gcom/at.gcom
                        fi
                        OK_received=3
                    elif [ $OK_received -eq 1 ]; then
                        COMMAND='AT+CGCONTRDP=0' gcom -d "$device" -s /etc/gcom/at.gcom
                        OK_received=2
                    fi
                    ;;

                * )
                    [ "$atc_debug" -ge 1 ] && echo "$URCline"
                    if [ $OK_received -eq 11 ]; then
                        sms_pdu="$URCline"
                        echo "SMS received"
                        [ "$atc_debug" -gt 1 ] && echo "$sms_pdu" >> /var/sms/pdus 2>/dev/null
                    fi
                    ;;
            esac
        fi
    done < "${device}"
}

proto_atc_teardown() {
    local interface="$1"
    local device=$(uci -q get network.$interface.device)
    echo "$interface is disconnected"
    /usr/bin/modem_led off 2>/dev/null

    if command -v close_data_channel >/dev/null 2>&1; then
        close_data_channel "$device"
    else
        at_ok "$device" "AT+XDATACHANNEL=0"
        at_ok "$device" "AT+CGDATA=0"
    fi

    proto_init_update "*" 0
    proto_send_update "$interface"
}

[ -n "$INCLUDE_ONLY" ] || {
    add_protocol atc
}
