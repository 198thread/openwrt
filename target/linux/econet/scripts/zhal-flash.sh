#!/bin/bash
# zhal-flash.sh — Flash an OpenWrt TRX image to a ZHAL-based EcoNet device
#                 via UART + TFTP.
#
# Works with any device that uses the ZyXEL ZHAL bootloader (EN7528 / EN751627
# family: EX3301-T0, VMG3312-T20A, etc.).
#
# Requirements:
#   sudo apt install screen expect python3   (Debian/Ubuntu)
#   sudo pacman -S screen expect python      (Arch)
#
# Usage:
#   ./zhal-flash.sh <image.trx> [tty] [baud]
#
#   image.trx  — OpenWrt TRX image (e.g. openwrt-...-tclinux.trx)
#   tty        — serial device   (default: /dev/ttyUSB0)
#   baud       — baud rate       (default: 115200)
#
# Steps performed:
#   1. Open serial port via screen (inside expect)
#   2. Hammer 'b' to intercept ZHAL bootloader
#   3. ATDC — disable model-ID check (always enabled on fresh power-on)
#   4. ATEN 1 — enable verbose boot output
#   5. ATUR openwrt.trx,1 — start TFTP server (slot 1)
#   6. Transfer image via TFTP using flash_image.py
#   7. Wait for NAND write to complete
#   8. Capture boot log via screen for 120 s
#
# Network:
#   The device becomes a TFTP server at 192.168.1.1 during flashing.
#   Your host must have an IP in 192.168.1.0/24 on the interface
#   connected to the device (LAN port or dedicated Ethernet adapter).
#
#   Example (Linux, interface eth0):
#     sudo ip addr add 192.168.1.2/24 dev eth0
#
# Power cycle:
#   When prompted, physically power-cycle the device.  The script will
#   catch the ZHAL prompt automatically.

set -e

IMAGE="${1:-}"
TTY="${2:-/dev/ttyUSB0}"
BAUD="${3:-115200}"
SCREEN_NAME="zhal_flash"
BOOT_LOG="/tmp/zhal_boot_$(date +%Y%m%d_%H%M%S).txt"
WAIT_BOOT=120
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FLASH_PY="$SCRIPT_DIR/flash_image.py"

# ---------------------------------------------------------------------------
# Argument check
# ---------------------------------------------------------------------------
if [ -z "$IMAGE" ] || [ ! -f "$IMAGE" ]; then
    echo "Usage: $0 <image.trx> [tty] [baud]"
    echo ""
    echo "  image.trx  — OpenWrt TRX image"
    echo "  tty        — serial port  (default: /dev/ttyUSB0)"
    echo "  baud       — baud rate    (default: 115200)"
    echo ""
    echo "Example:"
    echo "  $0 openwrt-econet-en751627-zyxel_ex3301-t0-squashfs-tclinux.trx"
    echo "  $0 myimage.trx /dev/ttyUSB1 115200"
    exit 1
fi

if [ ! -f "$FLASH_PY" ]; then
    echo "ERROR: flash_image.py not found at $FLASH_PY"
    echo "  Place flash_image.py in the same directory as this script."
    exit 1
fi

IMAGE=$(realpath "$IMAGE")

echo "========================================"
echo "ZHAL Flash Script"
echo "Image : $IMAGE ($(du -sh "$IMAGE" | cut -f1))"
echo "TTY   : $TTY"
echo "Baud  : $BAUD"
echo "========================================"
echo ""

# ---------------------------------------------------------------------------
# Clear any existing screen sessions holding the TTY
# ---------------------------------------------------------------------------
echo "--- Checking for existing screen sessions ---"
for s in $(sudo screen -list 2>/dev/null | grep -oP '\d+\.\S+'); do
    sudo screen -S "$s" -X quit 2>/dev/null || true
done
sudo screen -wipe 2>/dev/null || true
sleep 0.5

REMAINING=$(sudo screen -list 2>/dev/null | grep -cP 'Detached|Attached' || true)
if [ "$REMAINING" -gt 0 ]; then
    echo "ERROR: Could not clear all screen sessions:"
    sudo screen -list
    exit 1
fi
echo "  TTY clear."
echo ""

# ---------------------------------------------------------------------------
# Build expect script (written to a temp file)
# ---------------------------------------------------------------------------
EXPECT_SCRIPT=$(mktemp /tmp/zhal_XXXXXX.exp)
trap "rm -f $EXPECT_SCRIPT" EXIT

cat > "$EXPECT_SCRIPT" << EXPECT_EOF
#!/usr/bin/expect -f
#
# ZHAL bootloader interaction.
# Exits:
#   0 = TFTP server started — ready for flash_image.py
#   1 = could not reach ZHAL prompt
#   4 = ATUR did not start TFTP server

set tty   "$TTY"
set baud  $BAUD
set image "$IMAGE"

log_user 1

spawn screen "\$tty" "\$baud"
after 500
send "\r"

# Hammer 'b' for ~8 seconds to catch the bootloader
send_error "\n>>> Hammering 'b' — POWER CYCLE THE DEVICE NOW <<<\n"
for {set i 0} {\$i < 160} {incr i} {
    send "b"
    after 50
}

set timeout 12
expect {
    "ZHAL>" {
        send_error "\n\[OK\] ZHAL prompt caught (first attempt)\n"
    }
    timeout {
        send_error "\n\[..\] Missed first window — waiting for reboot cycle...\n"
        set timeout 30
        expect {
            "ZyXEL zloader" {
                send_error "\[..\] Reboot detected, hammering again...\n"
            }
            timeout {
                send_error "\nERROR: Device not responding after 30s\n"
                exit 1
            }
        }
        for {set i 0} {\$i < 160} {incr i} {
            send "b"
            after 50
        }
        set timeout 10
        expect {
            "ZHAL>" { send_error "\[OK\] ZHAL caught on second attempt\n" }
            timeout {
                send_error "\nERROR: Could not catch ZHAL\n"
                exit 1
            }
        }
    }
}

# Flush trailing 'b' chars
send "\r"
set timeout 5
expect "ZHAL>"

# ATDC: disable model-ID check (required — always enabled on fresh power-on)
send_error "\n>>> ATDC: disabling model ID check <<<\n"
send "ATDC\r"
set timeout 5
expect {
    "disabled" { send_error "\[OK\] Model ID check disabled\n" }
    "ZHAL>"    { send_error "\[OK\] ATDC acknowledged\n" }
    timeout    { send_error "\[WARN\] ATDC timeout — continuing\n" }
}
after 800
expect -timeout 3 "ZHAL>" {}

# ATEN 1: verbose boot output
send_error "\n>>> ATEN 1: enabling verbose boot output <<<\n"
send "ATEN 1\r"
set timeout 5
expect {
    "ZHAL>" { send_error "\[OK\] ATEN accepted\n" }
    timeout  { send_error "\[WARN\] ATEN timeout — continuing\n" }
}
after 500

# ATUR: start TFTP server on slot 1
send_error "\n>>> ATUR: starting TFTP server <<<\n"
send "ATUR openwrt.trx,1\r"
set timeout 15
expect {
    "TFTP server is started" {
        send_error "\[OK\] TFTP server ready at 192.168.1.1\n"
    }
    "ZHAL>" {
        send_error "\nERROR: ATUR did not start TFTP server\n"
        exit 4
    }
    timeout {
        send_error "\nERROR: Timeout waiting for TFTP server\n"
        exit 4
    }
}

send_error "\n>>> Handing off to flash_image.py <<<\n"
exit 0
EXPECT_EOF

chmod +x "$EXPECT_SCRIPT"

# ---------------------------------------------------------------------------
# Run the bootloader interaction
# ---------------------------------------------------------------------------
echo "========================================"
echo "ACTION REQUIRED: Power cycle the device."
echo "The script will catch ZHAL automatically."
echo "========================================"
echo ""

sudo expect "$EXPECT_SCRIPT"
EXPECT_EXIT=$?

echo ""
case $EXPECT_EXIT in
    0) ;;
    1) echo "[FAIL] Could not reach ZHAL prompt."; exit 1 ;;
    4) echo "[FAIL] ATUR did not start TFTP server."; exit 1 ;;
    *) echo "[FAIL] Unexpected exit code $EXPECT_EXIT from expect."; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# TFTP transfer
# ---------------------------------------------------------------------------
echo "--- TFTP transfer ---"
python3 "$FLASH_PY" "$IMAGE" openwrt.trx
FLASH_EXIT=$?
if [ "$FLASH_EXIT" -ne 0 ]; then
    echo "[FAIL] flash_image.py exited with code $FLASH_EXIT"
    exit 1
fi

echo ""
echo "[OK] Transfer complete — waiting ~12s for NAND write to finish"
sleep 12

# ---------------------------------------------------------------------------
# Capture boot log
# ---------------------------------------------------------------------------
echo ""
echo "--- Starting boot log capture (${WAIT_BOOT}s) ---"
sudo screen -S "$SCREEN_NAME" -dm -L -Logfile "$BOOT_LOG" "$TTY" "$BAUD"
sudo screen -S "$SCREEN_NAME" -X scrollback 50000
echo "  Logging to: $BOOT_LOG"
echo "  Live view:  sudo screen -r $SCREEN_NAME"
echo "  Live tail:  tail -f $BOOT_LOG | strings"
echo ""
echo "  Waiting ${WAIT_BOOT}s for boot..."
sleep "$WAIT_BOOT"

echo ""
echo "========================================"
echo "Done."
echo "Boot log: $BOOT_LOG"
echo ""
echo "To attach to the serial console:"
echo "  sudo screen -r $SCREEN_NAME"
echo ""
echo "Default OpenWrt credentials:"
echo "  SSH:  ssh root@192.168.1.1  (no password on first boot)"
echo "  Web:  http://192.168.1.1"
echo "========================================"
