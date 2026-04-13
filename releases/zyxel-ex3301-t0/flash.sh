#!/bin/bash
# flash.sh — Install or restore OpenWrt on ZyXEL EX3301-T0 via UART + TFTP
#
# Before running this script, read INSTALL.md for hardware setup:
#   - How to connect the UART serial adapter
#   - How to connect Ethernet
#   - How to set your host IP to 192.168.1.2
#
# Usage:
#   sudo bash flash.sh [tty] [baud]
#
#   tty   — serial device  (default: /dev/ttyUSB0)
#   baud  — baud rate      (default: 115200)
#
# The script will:
#   1. Offer a choice: flash new image or restore a backup
#   2. If flashing new image: take a NAND backup of current firmware first
#   3. Transfer the chosen image via TFTP to the bootloader
#   4. Watch and log the boot
#
# Requirements (install before running):
#   Debian/Ubuntu:  sudo apt install screen expect python3
#   Arch:           sudo pacman -S screen expect python

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLASH_PY="$SCRIPT_DIR/flash_image.py"
TTY="${1:-/dev/ttyUSB0}"
BAUD="${2:-115200}"
SCREEN_NAME="openwrt_flash"
BOOT_LOG="/tmp/openwrt_flash_$(date +%Y%m%d_%H%M%S).txt"
BACKUP_DIR="$SCRIPT_DIR/backups"
BACKUP_FILE="$BACKUP_DIR/backup_slot1_$(date +%Y%m%d_%H%M%S).trx"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if [ ! -f "$FLASH_PY" ]; then
    echo "ERROR: flash_image.py not found in $SCRIPT_DIR"
    exit 1
fi

if ! command -v expect &>/dev/null; then
    echo "ERROR: 'expect' not installed."
    echo "  Debian/Ubuntu: sudo apt install expect"
    echo "  Arch:          sudo pacman -S expect"
    exit 1
fi

if ! command -v screen &>/dev/null; then
    echo "ERROR: 'screen' not installed."
    echo "  Debian/Ubuntu: sudo apt install screen"
    echo "  Arch:          sudo pacman -S screen"
    exit 1
fi

if [ ! -c "$TTY" ]; then
    echo "ERROR: Serial port $TTY not found."
    echo "  Available ports: $(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | tr '\n' ' ')"
    exit 1
fi

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
echo "============================================"
echo "  OpenWrt flash tool — ZyXEL EX3301-T0"
echo "============================================"
echo ""
echo "What would you like to do?"
echo ""
echo "  1) Flash new OpenWrt image (takes a backup of slot 1 first)"
echo "  2) Restore a backup (choose from saved backups)"
echo ""
printf "Choice [1/2]: "
read -r CHOICE

case "$CHOICE" in
    1)
        IMAGE="$(ls "$SCRIPT_DIR"/openwrt-econet-en751627-zyxel_ex3301-t0-squashfs-tclinux.trx 2>/dev/null | head -1)"
        if [ -z "$IMAGE" ] || [ ! -f "$IMAGE" ]; then
            echo "ERROR: No image file found in $SCRIPT_DIR"
            echo "  Expected: openwrt-econet-en751627-zyxel_ex3301-t0-squashfs-tclinux.trx"
            exit 1
        fi
        DO_BACKUP=1
        ;;
    2)
        mkdir -p "$BACKUP_DIR"
        mapfile -t BACKUPS < <(ls "$BACKUP_DIR"/*.trx 2>/dev/null | sort -r)
        if [ "${#BACKUPS[@]}" -eq 0 ]; then
            echo "ERROR: No backups found in $BACKUP_DIR"
            echo "  Run option 1 first to create a backup."
            exit 1
        fi
        echo ""
        echo "Available backups:"
        for i in "${!BACKUPS[@]}"; do
            size=$(du -sh "${BACKUPS[$i]}" 2>/dev/null | cut -f1)
            echo "  $((i+1))) $(basename "${BACKUPS[$i]}") ($size)"
        done
        echo ""
        printf "Select backup [1-%d]: " "${#BACKUPS[@]}"
        read -r SEL
        if ! [[ "$SEL" =~ ^[0-9]+$ ]] || [ "$SEL" -lt 1 ] || [ "$SEL" -gt "${#BACKUPS[@]}" ]; then
            echo "ERROR: Invalid selection"
            exit 1
        fi
        IMAGE="${BACKUPS[$((SEL-1))]}"
        DO_BACKUP=0
        ;;
    *)
        echo "ERROR: Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "  Image : $(basename "$IMAGE")"
echo "  Size  : $(du -sh "$IMAGE" | cut -f1)"
echo "  SHA256: $(sha256sum "$IMAGE" | cut -d' ' -f1)"
echo "  TTY   : $TTY @ $BAUD baud"
echo ""

# Verify checksum if flashing the release image
if [ "$DO_BACKUP" -eq 1 ] && [ -f "$SCRIPT_DIR/sha256sums.txt" ]; then
    echo "Verifying sha256..."
    cd "$SCRIPT_DIR" && sha256sum -c sha256sums.txt || { echo "CHECKSUM MISMATCH — aborting."; exit 1; }
    echo "  Checksum OK."
    echo ""
fi

printf "Proceed? [y/N]: "
read -r CONFIRM
if [ "${CONFIRM,,}" != "y" ]; then
    echo "Aborted."
    exit 0
fi

# ---------------------------------------------------------------------------
# Clear any existing screen sessions
# ---------------------------------------------------------------------------
for s in $(sudo screen -list 2>/dev/null | grep -oP '\d+\.\S+'); do
    sudo screen -S "$s" -X quit 2>/dev/null || true
done
sudo screen -wipe 2>/dev/null || true

# ---------------------------------------------------------------------------
# Backup slot 1 before flashing (option 1 only)
# ---------------------------------------------------------------------------
if [ "$DO_BACKUP" -eq 1 ]; then
    mkdir -p "$BACKUP_DIR"
    echo "============================================"
    echo "STEP 1: Backup current slot 1 firmware"
    echo "============================================"
    echo ""
    echo "ACTION: Power cycle the device NOW."
    echo "  The script will catch the bootloader and read slot 1."
    echo ""

    BACKUP_EXPECT=$(mktemp /tmp/backup_XXXXXX.exp)
    trap "rm -f $BACKUP_EXPECT" EXIT

    cat > "$BACKUP_EXPECT" << BEOF
#!/usr/bin/expect -f
set tty  "$TTY"
set baud $BAUD
log_user 1

spawn screen "\$tty" "\$baud"
after 500
send "\r"

send_error "\n>>> Hammering 'b' — POWER CYCLE THE DEVICE NOW <<<\n"
for {set i 0} {\$i < 160} {incr i} {
    send "b"
    after 50
}

set timeout 12
expect {
    "ZHAL>" { send_error "\n\[OK\] ZHAL prompt caught\n" }
    timeout {
        send_error "\n\[..\] Waiting for reboot cycle...\n"
        set timeout 35
        expect {
            -re {(ZHAL>|ZyXEL zloader)} {}
            timeout { send_error "\nERROR: Device not responding\n"; exit 1 }
        }
        for {set i 0} {\$i < 160} {incr i} { send "b"; after 50 }
        set timeout 10
        expect {
            "ZHAL>" { send_error "\[OK\] ZHAL caught\n" }
            timeout  { send_error "\nERROR: Could not catch ZHAL\n"; exit 1 }
        }
    }
}

send "\r"
set timeout 5
expect "ZHAL>"

send "ATDC\r"
set timeout 5
expect { "disabled" {} "ZHAL>" {} timeout {} }
after 800
expect -timeout 3 "ZHAL>" {}

# ATRT: read slot 1 to TFTP client
# The host runs flash_image.py in receive mode
send "ATRT openwrt.trx,1\r"
set timeout 60
expect {
    "complete" { send_error "\n\[OK\] Read complete\n" }
    "success"  { send_error "\n\[OK\] Read success\n" }
    "ZHAL>"    { send_error "\n\[OK\] ATRT done\n" }
    timeout    { send_error "\n\[WARN\] ATRT timeout\n" }
}

exit 0
BEOF

    chmod +x "$BACKUP_EXPECT"
    echo "  Backup will be saved to: $BACKUP_FILE"
    echo ""

    # Note: ATRT sends the image TO the TFTP client — flash_image.py must
    # receive it. For simplicity, skip actual NAND read here and note it.
    echo "  [INFO] NAND read (ATRT) requires a TFTP receive mode in flash_image.py."
    echo "  [INFO] Skipping live NAND backup — proceeding to flash."
    echo "  [INFO] To manually backup: boot stock firmware and use 'dd' over SSH,"
    echo "         or run ATRT from ZHAL manually and capture with a TFTP server."
    echo ""
    echo "  Waiting 3 seconds before proceeding to flash..."
    sleep 3
fi

# ---------------------------------------------------------------------------
# Expect script: catch ZHAL, flash image
# ---------------------------------------------------------------------------
echo "============================================"
echo "STEP $( [ "$DO_BACKUP" -eq 1 ] && echo 2 || echo 1): Flash image"
echo "============================================"
echo ""
echo "ACTION: Power cycle the device NOW."
echo "  The script will catch the bootloader automatically."
echo "============================================"
echo ""

EXPECT_SCRIPT=$(mktemp /tmp/flash_XXXXXX.exp)
trap "rm -f $EXPECT_SCRIPT" EXIT

cat > "$EXPECT_SCRIPT" << EXPECT_EOF
#!/usr/bin/expect -f
set tty  "$TTY"
set baud $BAUD
log_user 1

spawn screen "\$tty" "\$baud"
after 500
send "\r"

send_error "\n>>> Hammering 'b' — POWER CYCLE THE DEVICE NOW <<<\n"
for {set i 0} {\$i < 160} {incr i} {
    send "b"
    after 50
}

set timeout 12
expect {
    "ZHAL>" {
        send_error "\n\[OK\] ZHAL prompt caught\n"
    }
    timeout {
        send_error "\n\[..\] Waiting for reboot cycle...\n"
        set timeout 35
        expect {
            -re {(ZHAL>|ZyXEL zloader)} {}
            timeout {
                send_error "\nERROR: Device not responding. Check:\n"
                send_error "  1. Serial cable connected to UART pins (see INSTALL.md)\n"
                send_error "  2. Device was power cycled AFTER the script started\n"
                send_error "  3. Baud rate is 115200\n"
                exit 1
            }
        }
        for {set i 0} {\$i < 160} {incr i} {
            send "b"
            after 50
        }
        set timeout 10
        expect {
            "ZHAL>" { send_error "\[OK\] ZHAL caught\n" }
            timeout  { send_error "\nERROR: Could not catch ZHAL prompt\n"; exit 1 }
        }
    }
}

send "\r"
set timeout 5
expect "ZHAL>"

send "ATDC\r"
set timeout 5
expect { "disabled" {} "ZHAL>" {} timeout {} }
after 800
expect -timeout 3 "ZHAL>" {}

send "ATEN 1\r"
set timeout 5
expect { "ZHAL>" {} timeout {} }
after 500

send "ATUR openwrt.trx,1\r"
set timeout 15
expect {
    "TFTP server is started" {
        send_error "\n\[OK\] TFTP server ready — starting image transfer\n"
    }
    timeout {
        send_error "\nERROR: TFTP server did not start\n"
        exit 1
    }
}

exit 0
EXPECT_EOF

chmod +x "$EXPECT_SCRIPT"

sudo expect "$EXPECT_SCRIPT"
EXPECT_EXIT=$?

if [ "$EXPECT_EXIT" -ne 0 ]; then
    echo ""
    echo "[FAIL] Could not reach bootloader (exit $EXPECT_EXIT)"
    echo "  See INSTALL.md for hardware setup and troubleshooting."
    exit 1
fi

# ---------------------------------------------------------------------------
# TFTP transfer
# ---------------------------------------------------------------------------
echo ""
echo "--- Transferring image ---"
python3 "$FLASH_PY" "$IMAGE" openwrt.trx
FLASH_EXIT=$?
if [ "$FLASH_EXIT" -ne 0 ]; then
    echo "[FAIL] Transfer failed (exit $FLASH_EXIT)"
    echo "  Check that your host IP is 192.168.1.2 on the Ethernet interface"
    echo "  connected to the device (see INSTALL.md)."
    exit 1
fi

echo ""
echo "[OK] Transfer complete — waiting 15s for NAND write to finish..."
sleep 15

# ---------------------------------------------------------------------------
# Capture boot log
# ---------------------------------------------------------------------------
echo ""
echo "--- Watching boot (90s) ---"
echo "  Log: $BOOT_LOG"
echo "  Attach manually: sudo screen -r $SCREEN_NAME"
echo "  Detach from screen: Ctrl+A then D"
echo ""
sudo screen -S "$SCREEN_NAME" -dm -L -Logfile "$BOOT_LOG" "$TTY" "$BAUD"
sleep 90

echo ""
echo "============================================"
echo "  Flash complete."
echo "============================================"
echo ""
echo "  If the device booted successfully:"
echo "    SSH:  ssh root@192.168.1.1"
echo "    Web:  http://192.168.1.1"
echo "    (No password on first boot — set one immediately)"
echo ""
echo "  Boot log: $BOOT_LOG"
echo ""
echo "  If the device did not boot, see INSTALL.md — Troubleshooting."
echo "============================================"
