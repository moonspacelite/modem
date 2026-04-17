#!/bin/sh
#
# Vendor script untuk modem Fibocom (L850-GL, L860-GL)
# Digunakan oleh proto_atc.sh dan skrip lainnya
#

# === Fungsi Bantuan ===

# Kirim AT command via gcom
# Parameter: $1 = port device, $2 = AT command
# Mengembalikan output dari gcom
at_command() {
    local port="$1"
    local cmd="$2"
    COMMAND="$cmd" gcom -d "$port" -s /etc/gcom/getrun_at.gcom 2>/dev/null
}

# Kirim AT command dan hanya mengembalikan true/false berdasarkan OK
at_ok() {
    local port="$1"
    local cmd="$2"
    COMMAND="$cmd" gcom -d "$port" -s /etc/gcom/run_at.gcom 2>/dev/null | grep -q "^OK"
}

# === Fungsi Informasi Dasar ===

# Cek apakah modem dalam mode NCM
# Return: 0 jika mode NCM, 1 jika tidak
get_usb_mode() {
    local port="$1"
    local mode
    mode=$(at_command "$port" "AT+GTUSBMODE?" | grep "+GTUSBMODE:" | awk -F ':' '{print $2}' | tr -d '\r\n ')
    echo "$mode"
}

# Set mode USB ke NCM (0)
set_ncm_mode() {
    local port="$1"
    logger -t "l850gl-vendor" "Mengubah mode USB ke NCM pada $port"
    at_ok "$port" "AT+GTUSBMODE=0"
    sleep 1
    at_ok "$port" "AT+CFUN=15"
    logger -t "l850gl-vendor" "Modem akan reboot. Tunggu 20 detik..."
    sleep 20
}

# Pastikan modem dalam mode NCM (akan reboot jika perlu)
ensure_ncm_mode() {
    local port="$1"
    local mode
    mode=$(get_usb_mode "$port")
    logger -t "l850gl-vendor" "Mode USB saat ini: $mode"
    case "$mode" in
        0|10)
            return 0
            ;;
        *)
            set_ncm_mode "$port"
            return 1  # reboot terjadi
            ;;
    esac
}

# Cek apakah SIM siap (READY)
sim_ready() {
    local port="$1"
    local status
    status=$(at_command "$port" "AT+CPIN?" | grep "CPIN:" | awk -F ':' '{print $2}' | tr -d '\r\n ' | sed 's/^ //')
    [ "$status" = "READY" ]
}

# Masukkan PIN jika diperlukan
handle_pin() {
    local port="$1"
    local pincode="$2"
    local status
    status=$(at_command "$port" "AT+CPIN?" | grep "CPIN:" | awk -F ':' '{print $2}' | tr -d '\r\n ' | sed 's/^ //')
    case "$status" in
        "SIM PIN")
            if [ -n "$pincode" ]; then
                if at_ok "$port" "AT+CPIN=\"$pincode\""; then
                    logger -t "l850gl-vendor" "PIN diterima"
                    return 0
                else
                    logger -t "l850gl-vendor" "PIN salah"
                    return 1
                fi
            else
                logger -t "l850gl-vendor" "PIN diperlukan tapi tidak disediakan"
                return 1
            fi
            ;;
        "READY")
            return 0
            ;;
        *)
            logger -t "l850gl-vendor" "Status SIM: $status"
            return 1
            ;;
    esac
}

# === Fungsi Koneksi Data ===

# Dapatkan info PDP context (IP, DNS, dll)
get_pdp_info() {
    local port="$1"
    at_command "$port" "AT+CGCONTRDP=0"
}

# Buka kanal data NCM
open_data_channel() {
    local port="$1"
    at_ok "$port" "AT+XDATACHANNEL=1,1,\"/USBCDC/0\",\"/USBHS/NCM/0\",2,0"
}

# Mulai sesi data
start_data_session() {
    local port="$1"
    at_ok "$port" "AT+CGDATA=\"M-RAW_IP\",0"
}

# Tutup kanal data
close_data_channel() {
    local port="$1"
    at_ok "$port" "AT+XDATACHANNEL=0"
    at_ok "$port" "AT+CGDATA=0"
}

# === Fungsi Tambahan (untuk pengembangan) ===

get_manufacturer() {
    local port="$1"
    at_command "$port" "AT+CGMI" | grep -v "^AT" | grep -v "^OK" | grep -v "^$" | head -1 | tr -d '\r\n'
}

get_model() {
    local port="$1"
    at_command "$port" "AT+CGMM" | grep -v "^AT" | grep -v "^OK" | grep -v "^$" | head -1 | tr -d '\r\n'
}

get_firmware() {
    local port="$1"
    at_command "$port" "AT+CGMR" | grep -v "^AT" | grep -v "^OK" | grep -v "^$" | head -1 | tr -d '\r\n'
}

get_imei() {
    local port="$1"
    at_command "$port" "AT+CGSN" | grep -v "^AT" | grep -v "^OK" | grep -v "^$" | head -1 | tr -d '\r\n'
}

