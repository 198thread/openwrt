#!/bin/sh
# SPDX-License-Identifier: GPL-2.0

set -e

# This is not necessary, but it makes finding the rootfs easier.
PAD_ROOTFS_OFFSET_TO=4194304

# Default header length. ZyXEL ZHAL bootloaders require 372 (0x174);
# other devices (e.g. EN7528/Dasan) use 256 (0x100). Pass --hdrlen to override.
HDRLEN=256

die() {
    echo "$1" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
SYNTAX: $0 --kernel <file> --rootfs <file> --version <string> [options]

Options:
  --kernel   Path to kernel lzma file (required)
  --rootfs   Path to rootfs squashfs file (required)
  --version  Version string, max 31 chars (required)
  --endian   Endianness: 'be' for big endian, 'le' for little endian (default: be)
  --model    Model/platform name, max 31 chars (default: empty)
  --hdrlen   Header length in bytes: 256 (default) or 372 (ZyXEL ZHAL)
EOF
    exit 1
}

# Defaults
kernel=""
rootfs=""
version=""
endian="be"
model=""

# Parse named arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --kernel)
            kernel="$2"
            shift 2
            ;;
        --rootfs)
            rootfs="$2"
            shift 2
            ;;
        --version)
            version="$2"
            shift 2
            ;;
        --endian)
            endian="$2"
            shift 2
            ;;
        --model)
            model="$2"
            shift 2
            ;;
        --hdrlen)
            HDRLEN="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# Validate required arguments
[ -n "$kernel" ] || die "Missing required argument: --kernel"
[ -n "$rootfs" ] || die "Missing required argument: --rootfs"
[ -n "$version" ] || die "Missing required argument: --version"

# Validate endianness
case "$endian" in
    be|BE) endian="be" ;;
    le|LE) endian="le" ;;
    *) die "Invalid endianness: $endian (must be 'be' or 'le')" ;;
esac

which zytrx >/dev/null || die "zytrx not found in PATH $PATH"
[ -f "$kernel" ] || die "Kernel file not found: $kernel"
[ -f "$rootfs" ] || die "Rootfs file not found: $rootfs"
[ "$(echo "$version" | wc -c)" -lt 32 ] || die "Version string too long: $version"
[ -z "$model" ] || [ "$(printf '%s' "$model" | wc -c)" -lt 32 ] || die "Model string too long: $model"

kernel_len=$(stat -c '%s' "$kernel")
header_plus_kernel_len=$(($HDRLEN + $kernel_len))
rootfs_len=$(stat -c '%s' "$rootfs")

if [ "$PAD_ROOTFS_OFFSET_TO" -gt "$header_plus_kernel_len" ]; then
    padding_len=$(($PAD_ROOTFS_OFFSET_TO - $header_plus_kernel_len))
else
    padding_len=0
fi

echo "endian: $endian" >&2
echo "padding_len: $padding_len" >&2

padded_rootfs_len=$(($padding_len + $rootfs_len))

echo "padded_rootfs_len: $padded_rootfs_len" >&2

total_len=$(($header_plus_kernel_len + $padded_rootfs_len))

echo "total_len: $total_len" >&2

padding() {
    head -c $padding_len /dev/zero | tr '\0' '\377'
}

to_hex() {
    hexdump -v -e '1/1 "%02x"'
}

from_hex() {
    perl -pe 's/\s+//g; s/(..)/chr(hex($1))/ge'
}

# Output a 32-bit value in hex with correct endianness
# Usage: hex32 <value>
hex32() {
    val=$(printf '%08x' "$1")
    if [ "$endian" = "le" ]; then
        # Swap bytes for little endian: AABBCCDD -> DDCCBBAA
        echo "$val" | sed 's/\(..\)\(..\)\(..\)\(..\)/\4\3\2\1/'
    else
        echo "$val"
    fi
}

trx_crc32() {
    tmpfile=$(mktemp)
    outtmpfile=$(mktemp)
    cat "$kernel" > "$tmpfile"
    padding >> "$tmpfile"
    cat "$rootfs" >> "$tmpfile"
    # We just need a CRC-32/JAMCRC of the concatnated files
    # There's no readily available tool for this, but zytrx does create one when
    # creating their TRX header, so we just use that.
    zytrx \
        -B NR7101 \
        -v x \
        -i "$tmpfile" \
        -o "$outtmpfile" >/dev/null
    crc_hex=$(dd if="$outtmpfile" bs=4 count=1 skip=3 2>/dev/null | to_hex)
    rm "$tmpfile" "$outtmpfile" >/dev/null
    hex32 "0x$crc_hex"
}

tclinux_trx_hdr() {
    # TRX header magic: "2RDH" for big endian, "HDR2" for little endian
    if [ "$endian" = "le" ]; then
        printf 'HDR2' | to_hex
    else
        printf '2RDH' | to_hex
    fi

    # Length of the header
    hex32 "$HDRLEN"

    # Length of header + content
    hex32 "$total_len"

    # crc32 of the content
    trx_crc32

    # version
    echo "$version" | to_hex
    head -c "$((32 - $(echo "$version" | wc -c)))" /dev/zero | to_hex

    # customer version
    head -c 32 /dev/zero | to_hex

    # kernel length
    hex32 "$kernel_len"

    # rootfs length
    hex32 "$padded_rootfs_len"

    # romfile length (0)
    hex32 0

    # model (32 bytes, zero-padded)
    if [ -n "$model" ]; then
        printf '%s' "$model" | to_hex
        head -c "$((32 - $(printf '%s' "$model" | wc -c)))" /dev/zero | to_hex
    else
        head -c 32 /dev/zero | to_hex
    fi

    # Load address (CONFIG_ZBOOT_LOAD_ADDRESS)
    hex32 0x80020000

    # "reserved" 128 bytes of zeros  (bytes 0x80-0xFF)
    head -c 128 /dev/zero | to_hex

    # Extended header (bytes 0x100-0x173) required by ZyXEL ZHAL bootloader.
    # Only written when --hdrlen 372 is specified; other devices use hdrlen=256.
    [ "$HDRLEN" -lt 372 ] && return

    # Platform/chip string (16 bytes, zero-padded) at 0x100
    if [ -n "$model" ]; then
        printf '%s' "$model" | to_hex
        head -c "$((16 - $(printf '%s' "$model" | wc -c)))" /dev/zero | to_hex
    else
        head -c 16 /dev/zero | to_hex
    fi

    # 8 zero bytes at 0x110
    head -c 8 /dev/zero | to_hex

    # Flag word 0x00000001 at 0x118
    hex32 1

    # SW version string (32 bytes, zero-padded) at 0x11C
    echo "$version" | to_hex
    head -c "$((32 - $(echo "$version" | wc -c)))" /dev/zero | to_hex

    # 4 zero bytes at 0x13C
    head -c 4 /dev/zero | to_hex

    # SW version repeated (32 bytes, zero-padded) at 0x140
    echo "$version" | to_hex
    head -c "$((32 - $(echo "$version" | wc -c)))" /dev/zero | to_hex

    # 20 zero bytes at 0x160 (includes kernel checksum placeholder + padding)
    head -c 20 /dev/zero | to_hex
}

# Build the image: header + kernel + padding + rootfs
# Then patch offset 0x170 with JAMCRC of header bytes 0x000-0x173
# (ZHAL bootloader validates this field before flashing)
{
    tclinux_trx_hdr | from_hex
    cat "$kernel"
    padding
    cat "$rootfs"
} | python3 -c "
import sys, binascii, struct
data = sys.stdin.buffer.read()
hdrlen = struct.unpack('>I', data[4:8])[0]
# Compute JAMCRC of header with checksum field zeroed (it already is)
hdr_crc = binascii.crc32(data[:hdrlen]) & 0xFFFFFFFF
jamcrc = hdr_crc ^ 0xFFFFFFFF
# Write JAMCRC at offset 0x170 big-endian
out = bytearray(data)
struct.pack_into('>I', out, 0x170, jamcrc)
sys.stdout.buffer.write(bytes(out))
"
