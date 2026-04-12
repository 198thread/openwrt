#!/bin/bash
# flash.sh — Install OpenWrt on ZyXEL EX3301-T0 via UART + TFTP
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
# Requirements (install before running):
#   Debian/Ubuntu:  sudo apt install screen expect python3
#   Arch:           sudo pacman -S screen expect python
#
# The image file must be in the same directory as this script.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="$(ls "$SCRIPT_DIR"/openwrt-econet-en751627-zyxel_ex3301-t0-squashfs-tclinux.trx 2>/dev/null | head -1)"
FLASH_PY="$SCRIPT_DIR/flash_image.py"
TTY="${1:-/dev/ttyUSB0}"
BAUD="${2:-115200}"
SCREEN_NAME="openwrt_flash"
BOOT_LOG="/tmp/openwrt_flash_$(date +%Y%m%d_%H%M%S).txt"

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
if [ -z "$IMAGE" ] || [ ! -f "$IMAGE" ]; then
    echo "ERROR: No image file found in $SCRIPT_DIR"
    echo "  Expected: openwrt-econet-en751627-zyxel_ex3301-t0-squashfs-tclinux.trx"
    exit 1
fi

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
    echo "  Check your USB serial adapter is plugged in."
    echo "  Available ports: $(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | tr '\n' ' ')"
    exit 1
fi

echo "============================================"
echo "  OpenWrt installer — ZyXEL EX3301-T0"
echo "============================================"
echo "  Image : $(basename "$IMAGE")"
echo "  SHA256: $(sha256sum "$IMAGE" | cut -d' ' -f1)"
echo "  TTY   : $TTY @ $BAUD baud"
echo "============================================"
echo ""
echo "Verifying sha256..."
if [ -f "$SCRIPT_DIR/sha256sums.txt" ]; then
    cd "$SCRIPT_DIR" && sha256sum -c sha256sums.txt || { echo "CHECKSUM MISMATCH — aborting."; exit 1; }
    echo "  Checksum OK."
else
    echo "  (No sha256sums.txt found — skipping verification)"
fi
echo ""

# ---------------------------------------------------------------------------
# Clear any existing screen sessions on this TTY
# ---------------------------------------------------------------------------
for s in $(sudo screen -list 2>/dev/null | grep -oP '\d+\.\S+'); do
    sudo screen -S "$s" -X quit 2>/dev/null || true
done
sudo screen -wipe 2>/dev/null || true

# ---------------------------------------------------------------------------
# Expect script: catch ZHAL, issue AT commands
# ---------------------------------------------------------------------------
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
                send_error "  1. Serial cable is connected to the UART pins (see INSTALL.md)\n"
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

# Disable model-ID check
send "ATDC\r"
set timeout 5
expect { "disabled" {} "ZHAL>" {} timeout {} }
after 800
expect -timeout 3 "ZHAL>" {}

# Enable verbose output
send "ATEN 1\r"
set timeout 5
expect { "ZHAL>" {} timeout {} }
after 500

# Start TFTP server on slot 1
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

echo "============================================"
echo "ACTION: Power cycle the device NOW."
echo "  (unplug power, wait 2 seconds, plug back in)"
echo "  The script will catch the bootloader"
echo "  automatically — do not press any keys."
echo "============================================"
echo ""

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
echo "  Ctrl+A then D to detach from screen without stopping it."
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
echo "  To attach to UART console:"
echo "    sudo screen -r $SCREEN_NAME"
echo "    (Ctrl+A then D to detach)"
echo ""
echo "  If the device did not boot, see INSTALL.md — Troubleshooting."
echo "============================================"
