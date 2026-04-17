#!/bin/sh
#
# Vendor script untuk Fibocom L850-GL / L860-GL
#

# Kirim AT command dengan flock untuk mencegah konflik
at_command() {
    local port="$1"
    local cmd="$2"
    (
        flock -x 200
        COMMAND="$cmd" gcom -d "$port" -s /etc/gcom/getrun_at.gcom 2>/dev/null
    ) 200>"$port"
}

at_ok() {
    local port="$1"
    local cmd="$2"
    (
        flock -x 200
        COMMAND="$cmd" gcom -d "$port" -s /etc/gcom/run_at.gcom 2>/dev/null | grep -q "^OK"
    ) 200>"$port"
}

get_usb_mode() {
    at_command "$1" "AT+GTUSBMODE?" | grep "+GTUSBMODE:" | awk -F ':' '{print $2}' | tr -d '\r\n '
}

set_ncm_mode() {
    local port="$1"
    logger -t "l850gl-vendor" "Mengubah mode USB ke NCM pada $port"
    at_ok "$port" "AT+GTUSBMODE=0"
    sleep 1
    at_ok "$port" "AT+CFUN=15"
    logger -t "l850gl-vendor" "Modem akan reboot. Tunggu 20 detik..."
    sleep 20
}

ensure_ncm_mode() {
    local port="$1"
    local mode=$(get_usb_mode "$port")
    logger -t "l850gl-vendor" "Mode USB saat ini: $mode"
    case "$mode" in
        0|10) return 0 ;;
        *) set_ncm_mode "$port"; return 1 ;;
    esac
}

handle_pin() {
    local port="$1"
    local pincode="$2"
    local status=$(at_command "$port" "AT+CPIN?" | grep "CPIN:" | awk -F ':' '{print $2}' | tr -d '\r\n ' | sed 's/^ //')
    case "$status" in
        READY) return 0 ;;
        "SIM PIN")
            [ -n "$pincode" ] || { logger -t "l850gl-vendor" "PIN diperlukan tapi tidak disediakan"; return 1; }
            at_ok "$port" "AT+CPIN=\"$pincode\"" || { logger -t "l850gl-vendor" "PIN salah"; return 1; }
            logger -t "l850gl-vendor" "PIN diterima"
            return 0
            ;;
        *) logger -t "l850gl-vendor" "Status SIM: $status"; return 1 ;;
    esac
}

open_data_channel() {
    at_ok "$1" "AT+XDATACHANNEL=1,1,\"/USBCDC/0\",\"/USBHS/NCM/0\",2,0"
}

start_data_session() {
    at_ok "$1" "AT+CGDATA=\"M-RAW_IP\",0"
}

close_data_channel() {
    at_ok "$1" "AT+XDATACHANNEL=0"
    at_ok "$1" "AT+CGDATA=0"
}

get_manufacturer() { at_command "$1" "AT+CGMI" | tail -n +2 | head -1 | tr -d '\r'; }
get_model()        { at_command "$1" "AT+CGMM" | tail -n +2 | head -1 | tr -d '\r'; }
get_firmware()     { at_command "$1" "AT+CGMR" | tail -n +2 | head -1 | tr -d '\r'; }
get_imei()         { at_command "$1" "AT+CGSN" | tail -n +2 | head -1 | tr -d '\r'; }
