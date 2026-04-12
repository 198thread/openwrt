#!/usr/bin/env python3
"""
Flash an OpenWrt TRX image to a ZHAL-based EcoNet device via TFTP.
Used by zhal-flash.sh after the bootloader ATUR command starts the TFTP
server on the device at 192.168.1.1.

Key behaviours:
- Short 1s per-block timeout with immediate retry (bootloader drops idle connections fast)
- Sends in SEGMENTS of ~256 blocks (~128KB) then pauses briefly to let NAND write catch up
- Prints progress every 500 blocks so terminal doesn't flood
- Reconnects cleanly on stall (sends fresh WRQ, resumes from last ACKed block)
"""

import socket
import struct
import sys
import os
import time

SERVER_IP   = "192.168.1.1"
SERVER_PORT = 69
BLOCK_SIZE  = 512
TIMEOUT     = 1       # seconds before retry
SEGMENT     = 256     # blocks per segment (128KB) — pause after each
PAUSE       = 0.05    # seconds between segments (let NAND write buffer drain)
PRINT_EVERY = 200     # print progress every N blocks

OP_WRQ = 2
OP_DATA = 3
OP_ACK  = 4
OP_ERR  = 5


def send_wrq(sock, filename):
    pkt = struct.pack("!H", OP_WRQ) + filename.encode() + b"\x00octet\x00"
    sock.sendto(pkt, (SERVER_IP, SERVER_PORT))


def send_data(sock, addr, block_num, data):
    pkt = struct.pack("!HH", OP_DATA, block_num) + data
    sock.sendto(pkt, addr)


def flash(local_path, remote_filename="openwrt.trx"):
    raw = open(local_path, "rb").read()
    # Trim to actual image size from TRX header (offset 8, big-endian) to avoid
    # sending NAND padding and crossing the 65535-block TFTP limit.
    if raw[:4] == b'2RDH' and len(raw) > 12:
        declared = struct.unpack_from(">I", raw, 8)[0]
        if 0 < declared < len(raw):
            print(f"Trimming : {len(raw)} → {declared} bytes (TRX total_len)")
            raw = raw[:declared]
    image = raw
    total_blocks = (len(image) + BLOCK_SIZE - 1) // BLOCK_SIZE
    print(f"Flashing : {local_path}")
    print(f"Size     : {len(image)} bytes ({total_blocks} blocks)")
    print(f"Target   : tftp://{SERVER_IP}/{remote_filename}")
    print(f"Segment  : {SEGMENT} blocks ({SEGMENT * BLOCK_SIZE // 1024}KB) with {PAUSE}s pause")
    print()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(TIMEOUT)

    tid_addr   = None
    block_num  = 1      # next block to send
    offset     = 0      # byte offset into image
    seg_count  = 0      # blocks sent in current segment
    retries    = 0

    # Send initial WRQ
    send_wrq(sock, remote_filename)

    while True:
        try:
            pkt, addr = sock.recvfrom(1024)
            retries = 0
        except socket.timeout:
            retries += 1
            if retries > 60:
                print(f"\n[!] No ACK for block {block_num-1} after 60s — giving up")
                sys.exit(1)
            if tid_addr is None:
                send_wrq(sock, remote_filename)
            else:
                # Resend last block (NAND write can take several seconds per block)
                prev_offset = max(0, offset - BLOCK_SIZE)
                chunk = image[prev_offset:prev_offset + BLOCK_SIZE]
                send_data(sock, tid_addr, (block_num - 1) % 65536, chunk)
            continue

        opcode = struct.unpack("!H", pkt[:2])[0]

        if opcode == OP_ERR:
            code = struct.unpack("!H", pkt[2:4])[0]
            msg  = pkt[4:].rstrip(b"\x00").decode(errors="replace")
            print(f"\n[!] Server error {code}: {msg}")
            sys.exit(1)

        if opcode != OP_ACK:
            continue

        ack = struct.unpack("!H", pkt[2:4])[0]

        if tid_addr is None:
            tid_addr = addr
            print(f"  Connected — server port {tid_addr[1]}")

        # Ignore stale/duplicate ACKs (block numbers wrap mod 65536)
        expected_ack = (block_num - 1) % 65536
        if ack != expected_ack and not (ack == 0 and block_num == 1):
            continue

        # All done?
        chunk = image[offset:offset + BLOCK_SIZE]
        if not chunk:
            pct = 100
            print(f"\r  [{pct:3d}%] Block {block_num-1}/{total_blocks} — Done!     ")
            break

        send_data(sock, tid_addr, block_num % 65536, chunk)
        offset    += len(chunk)
        seg_count += 1

        if block_num % PRINT_EVERY == 0 or block_num == total_blocks:
            pct = min(100, offset * 100 // len(image))
            print(f"\r  [{pct:3d}%] Block {block_num}/{total_blocks}", end="", flush=True)

        block_num += 1

        # Segment pause — let NAND write buffer drain
        if seg_count >= SEGMENT:
            seg_count = 0
            time.sleep(PAUSE)

        if len(chunk) < BLOCK_SIZE:
            continue  # last block — wait for final ACK

    sock.close()
    print(f"\nComplete. {total_blocks} blocks written.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <image.trx> [remote_filename]")
        sys.exit(1)
    remote = sys.argv[2] if len(sys.argv) > 2 else "openwrt.trx"
    flash(sys.argv[1], remote)
