#!/bin/ash
# EX3301-T0 Initramfs Diagnostic Script
# Runs inside initramfs BusyBox shell to test all NAND/MTD hypotheses
# Output is printed to serial console (captured by screen)
#
# Tests covered:
# T1: MTD partition map - what partitions exist, sizes, offsets
# T2: NAND raw read at firmware1 offset - verify TRX magic present
# T3: Squashfs magic search - find 0x73717368 in firmware1
# T4: Memory map - /proc/iomem for SoC register layout
# T5: BMT status - verify BMT remapping is active
# T6: Kernel image load address - verify bootloader load addr
# T7: UBI/UBIFS probe on firmware1
# T8: Direct squashfs mount attempts from different offsets
# T9: ECC error rate on firmware1 reads
# T10: OOB data check on first few pages

set -o pipefail

DIAG_LOG="/tmp/diag_$(date +%s).log"
PASS=0
FAIL=0
WARN=0

diag_header() {
    echo ""
    echo "============================================================"
    echo "  EX3301-T0 NAND Diagnostic Suite"
    echo "  $(date)"
    echo "============================================================"
    echo ""
}

test_start() {
    echo ""
    echo "--- TEST $1: $2 ---"
}

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN+1)); }
info() { echo "[INFO] $1"; }

# ===================================================================
# T1: MTD Partition Map
# ===================================================================
t1_mtd_map() {
    test_start "T1" "MTD Partition Map"

    if [ ! -r /proc/mtd ]; then
        fail "/proc/mtd not readable"
        return
    fi

    echo "Raw /proc/mtd:"
    cat /proc/mtd

    # Check for expected partitions
    local fw1_mtd=""
    while IFS=': "' read -r dev size erasesize name; do
        [ "$name" = "firmware1" ] && fw1_mtd="$dev"
    done < /proc/mtd

    if [ -n "$fw1_mtd" ]; then
        pass "firmware1 partition found: /dev/$fw1_mtd"
        echo "FW1_MTD=/dev/$fw1_mtd" > /tmp/diag_vars
    else
        fail "firmware1 partition NOT found in /proc/mtd"
        # Try to find any partition that looks like our slot
        warn "Looking for alternative partition names..."
        cat /proc/mtd | grep -E "firmware|tclinux|kernel_slave|rootfs_slave" || true
        echo "FW1_MTD=" > /tmp/diag_vars
    fi

    # Check total partition coverage
    local total_parts=$(grep -c "mtd" /proc/mtd || echo 0)
    info "Total MTD devices: $total_parts"
}

# ===================================================================
# T2: TRX Magic at firmware1 offset
# ===================================================================
t2_trx_magic() {
    test_start "T2" "TRX Magic Verification in firmware1"
    . /tmp/diag_vars 2>/dev/null

    if [ -z "$FW1_MTD" ]; then
        warn "No firmware1 MTD — trying to detect from /proc/mtd"
        # Find the largest non-bootloader partition
        FW1_MTD=$(awk '!/^dev/ && !/bootloader/ && !/romfile/ && !/reserve/ {
            size=strtonum("0x"$2); if(size > max) {max=size; dev=$1}
        } END {print "/dev/"dev}' /proc/mtd)
        info "Guessing $FW1_MTD as firmware partition"
    fi

    if [ ! -r "$FW1_MTD" ]; then
        fail "$FW1_MTD not readable"
        return
    fi

    # Read first 16 bytes - should be TRX header
    echo "First 16 bytes of $FW1_MTD:"
    hexdump -C -n 16 "$FW1_MTD" 2>/dev/null || dd if="$FW1_MTD" bs=16 count=1 2>/dev/null | od -A x -t x1z

    # Check magic: 0x32524448 ("2RDH" BE)
    local magic=$(dd if="$FW1_MTD" bs=4 count=1 2>/dev/null | od -A n -t x4 | tr -d ' \n')
    info "Magic bytes: $magic"

    if [ "$magic" = "32524448" ]; then
        pass "TRX magic 0x32524448 (2RDH) found at firmware1+0"

        # Read header length (offset 4)
        local hdrlen=$(dd if="$FW1_MTD" bs=1 skip=4 count=4 2>/dev/null | od -A n -t x4 | tr -d ' \n')
        # Read kernel_len (offset 72 = 0x48)
        local klen_hex=$(dd if="$FW1_MTD" bs=1 skip=72 count=4 2>/dev/null | od -A n -t x4 | tr -d ' \n')
        info "Header length: 0x$hdrlen"
        info "Kernel length: 0x$klen_hex"

        # Calculate rootfs offset
        local klen_dec=$((16#$klen_hex))
        local hdrlen_dec=$((16#$hdrlen))
        local raw_offset=$((hdrlen_dec + klen_dec))
        local rootfs_off=$(( (raw_offset + 4194303) / 4194304 * 4194304 ))

        info "hdrlen=$hdrlen_dec (0x$(printf '%x' $hdrlen_dec))"
        info "kernel_len=$klen_dec (0x$(printf '%x' $klen_dec))"
        info "hdrlen+kernel_len=$(printf '0x%x' $raw_offset)"
        info "rootfs_offset (4MB aligned)=$(printf '0x%x' $rootfs_off)"

        echo "ROOTFS_OFFSET=$rootfs_off" >> /tmp/diag_vars
        echo "FW1_MTD_CONFIRMED=$FW1_MTD" >> /tmp/diag_vars
    else
        fail "TRX magic mismatch: got 0x$magic, expected 32524448"
        echo "ROOTFS_OFFSET=" >> /tmp/diag_vars

        # Maybe the NAND is reading wrong due to BMT
        warn "Possible BMT remapping issue — raw NAND data not matching"
        warn "Checking if any 2RDH magic exists in first 64KB..."
        dd if="$FW1_MTD" bs=512 count=128 2>/dev/null | od -A x -t x4 | grep "32524448" | head -5 || true
    fi
}

# ===================================================================
# T3: Squashfs Magic Search
# ===================================================================
t3_squashfs_search() {
    test_start "T3" "Squashfs Magic Search in firmware1"
    . /tmp/diag_vars 2>/dev/null

    local mtd="${FW1_MTD_CONFIRMED:-$FW1_MTD}"
    if [ -z "$mtd" ] || [ ! -r "$mtd" ]; then
        fail "No firmware MTD to search"
        return
    fi

    # Expected squashfs offset from TRX calculation
    local expected_off="${ROOTFS_OFFSET:-4194304}"
    info "Checking squashfs magic at expected offset 0x$(printf '%x' $expected_off)"

    # Read 4 bytes at rootfs offset
    local sq_magic=$(dd if="$mtd" bs=1 skip="$expected_off" count=4 2>/dev/null | od -A n -t x4 | tr -d ' \n')
    info "Bytes at offset 0x$(printf '%x' $expected_off): $sq_magic"

    # Squashfs magic: 0x73717368 (LE: "sqsh", BE: "hsqs")
    if [ "$sq_magic" = "73717368" ] || [ "$sq_magic" = "68737173" ]; then
        pass "Squashfs magic found at offset 0x$(printf '%x' $expected_off): $sq_magic"
    else
        fail "No squashfs magic at offset 0x$(printf '%x' $expected_off) — got $sq_magic"

        # Broad scan: search for squashfs magic in 8MB range
        info "Scanning firmware1 for squashfs magic (this may take a while)..."
        local scan_size=$((8 * 1024 * 1024))
        local found=0

        # Check common offsets
        for off in 4194304 2097152 1048576 8388608 3145728; do
            local magic=$(dd if="$mtd" bs=1 skip="$off" count=4 2>/dev/null | od -A n -t x4 | tr -d ' \n')
            if [ "$magic" = "73717368" ] || [ "$magic" = "68737173" ]; then
                pass "Squashfs found at ALTERNATE offset 0x$(printf '%x' $off): $magic"
                echo "ACTUAL_ROOTFS_OFFSET=$off" >> /tmp/diag_vars
                found=1
            fi
        done

        [ $found -eq 0 ] && warn "Squashfs not found at any common offset in firmware1"
    fi

    # Also check at offset 0 (sanity check)
    local sq_at_zero=$(dd if="$mtd" bs=4 count=1 2>/dev/null | od -A n -t x4 | tr -d ' \n')
    info "Bytes at offset 0: $sq_at_zero (should be TRX magic 32524448)"
}

# ===================================================================
# T4: Memory Map
# ===================================================================
t4_memory_map() {
    test_start "T4" "SoC Memory Map (/proc/iomem)"

    if [ -r /proc/iomem ]; then
        pass "/proc/iomem readable"
        cat /proc/iomem
    else
        fail "/proc/iomem not readable"
    fi

    info "CPU info:"
    cat /proc/cpuinfo | grep -E "system type|BogoMIPS|cpu model|processor" | head -10

    info "Memory info:"
    cat /proc/meminfo | grep -E "MemTotal|MemFree" | head -5
}

# ===================================================================
# T5: BMT Status
# ===================================================================
t5_bmt_status() {
    test_start "T5" "BMT (Bad Block Management) Status"

    # Check dmesg for BMT messages
    if dmesg | grep -qi "bmt"; then
        pass "BMT driver loaded (found in dmesg)"
        dmesg | grep -i "bmt\|bad.block\|BBT" | head -20
    else
        fail "No BMT messages in dmesg"
        warn "BMT may not be active — NAND reads may go to wrong physical blocks"
    fi

    # Check for BBT
    dmesg | grep -i "BBT\|bad block table" | head -10

    # Check SPI NAND
    dmesg | grep -i "spi.nand\|W25N\|nand.*detect" | head -10
}

# ===================================================================
# T6: Kernel Load Address Verification
# ===================================================================
t6_load_address() {
    test_start "T6" "Kernel Load Address and Physical Memory"

    # Check where we are in memory
    if [ -r /proc/iomem ]; then
        info "RAM regions:"
        grep -i "System RAM\|memory\|kernel" /proc/iomem | head -10
    fi

    # Check kernel text start
    if [ -r /proc/kallsyms ]; then
        info "Kernel _text address:"
        grep "^[0-9a-f]* . _text$" /proc/kallsyms | head -3
        grep "^[0-9a-f]* . _end$" /proc/kallsyms | head -3
    fi

    info "Kernel dmesg memory lines:"
    dmesg | grep -E "memory|RAM|DRAM|zone|kernel image" | head -20
}

# ===================================================================
# T7: Direct Mount Tests
# ===================================================================
t7_mount_tests() {
    test_start "T7" "Direct Squashfs Mount Attempts"
    . /tmp/diag_vars 2>/dev/null

    local mtd="${FW1_MTD_CONFIRMED:-$FW1_MTD}"

    # Find mtdblock device number
    local mtd_num=""
    if [ -n "$mtd" ]; then
        mtd_num=$(echo "$mtd" | grep -o '[0-9]*$')
    fi

    mkdir -p /tmp/mnt_test

    # Test 1: Mount firmware1 as squashfs (offset 4MB via loopback not supported in BusyBox)
    # Instead, try mounting each mtdblock device
    for i in $(seq 0 9); do
        local blk="/dev/mtdblock$i"
        if [ ! -b "$blk" ] && [ -r "/dev/mtd$i" ]; then
            mknod "$blk" b 31 $i 2>/dev/null || true
        fi

        if [ -b "$blk" ]; then
            local res=$(mount -t squashfs "$blk" /tmp/mnt_test 2>&1)
            if mount | grep -q /tmp/mnt_test; then
                pass "Mounted $blk as squashfs"
                ls /tmp/mnt_test/ | head -5
                umount /tmp/mnt_test 2>/dev/null
            else
                info "$blk: $res"
            fi
        fi
    done

    # Check if any squashfs partitions visible
    if mount | grep squashfs | head -5; then
        pass "squashfs mount(s) successful"
    else
        info "No squashfs mounts found (expected if no sub-partitions created)"
    fi
}

# ===================================================================
# T8: DTS/OF Partition Check
# ===================================================================
t8_of_partitions() {
    test_start "T8" "Device Tree Partition Configuration"

    if [ -d /sys/firmware/devicetree/base ]; then
        pass "Device tree accessible"

        # Find NAND partition nodes
        info "NAND partition labels from DT:"
        find /sys/firmware/devicetree/base -name "label" 2>/dev/null | while read f; do
            echo "  $(cat $f): $(dirname $f | sed 's|.*/||')"
        done

        # Check for linux,rootfs property
        info "Partitions with linux,rootfs:"
        find /sys/firmware/devicetree/base -name "linux,rootfs" 2>/dev/null | while read f; do
            echo "  $(dirname $f)"
        done

        # Check chosen bootargs
        info "Bootargs:"
        cat /sys/firmware/devicetree/base/chosen/bootargs 2>/dev/null && echo ""

        # Check memory node
        info "Memory reg:"
        od -A x -t x4 /sys/firmware/devicetree/base/memory@0/reg 2>/dev/null | head -3

    else
        warn "Device tree not accessible at /sys/firmware/devicetree/base"
    fi
}

# ===================================================================
# T9: mtdsplit parser output check
# ===================================================================
t9_mtdsplit_check() {
    test_start "T9" "MTD Split Parser Results"

    info "dmesg mtdsplit output:"
    dmesg | grep -i "mtdsplit\|tclinux\|squashfs.*split\|split.*squashfs\|rootfs.*mtd\|firmware.*split" | head -30

    info "All MTD related dmesg:"
    dmesg | grep -iE "mtd|nand|spi.nand|flash" | grep -v "^$" | head -40

    # Check if sub-partitions were created
    local subparts=$(cat /proc/mtd | grep -cE "kernel|rootfs" || echo 0)
    if [ "$subparts" -gt 0 ]; then
        pass "MTD sub-partitions exist: $subparts"
    else
        fail "No kernel/rootfs sub-partitions found — parser may not have run"
    fi
}

# ===================================================================
# T10: NAND Page/ECC Analysis
# ===================================================================
t10_nand_ecc() {
    test_start "T10" "NAND ECC and Read Error Check"

    . /tmp/diag_vars 2>/dev/null
    local mtd="${FW1_MTD_CONFIRMED:-$FW1_MTD}"

    # Check dmesg for ECC errors
    local ecc_errors=$(dmesg | grep -c -iE "ECC error|bit.*flip|uncorrect" || echo 0)
    if [ "$ecc_errors" -gt 0 ]; then
        fail "ECC errors detected: $ecc_errors occurrences"
        dmesg | grep -iE "ECC error|bit.*flip|uncorrect" | head -10
    else
        pass "No ECC errors in dmesg"
    fi

    # Try reading firmware1 end to check for truncation
    if [ -n "$mtd" ] && [ -r "$mtd" ]; then
        local mtd_size=$(cat /proc/mtd | awk -F'[ :]' "/$mtd/ {print strtonum(\"0x\"\$3)}" || echo 0)
        info "Attempting read at end of $mtd to check for read errors..."
        dd if="$mtd" bs=512 count=1 skip=$((mtd_size/512 - 1)) 2>&1 | tail -3 || true
    fi
}

# ===================================================================
# T11: Comprehensive dmesg dump
# ===================================================================
t11_dmesg_full() {
    test_start "T11" "Full dmesg (filtered for key events)"

    echo "--- Boot sequence summary ---"
    dmesg | grep -E "Linux version|early|MIPS|GIC|timer|nand|bmt|mtd|squashfs|VFS|rootfs|panic|error|fail" | head -80
}

# ===================================================================
# T12: Physical NAND offset vs partition offset
# ===================================================================
t12_physical_offset_verify() {
    test_start "T12" "Physical NAND Offset Sanity Check"
    . /tmp/diag_vars 2>/dev/null

    # firmware1 should start at NAND physical 0x4380000
    # Check that /proc/mtd shows the right size
    local fw1_line=$(grep "firmware1" /proc/mtd 2>/dev/null)
    if [ -n "$fw1_line" ]; then
        local fw1_size=$(echo "$fw1_line" | awk '{print strtonum("0x"$2)}')
        local expected_size=$((0x3c80000))  # 60.5MB
        info "firmware1 size: 0x$(printf '%x' $fw1_size) (expected ~0x3c80000)"

        if [ "$fw1_size" -eq "$expected_size" ]; then
            pass "firmware1 size matches expected 0x3c80000"
        elif [ "$fw1_size" -gt $((expected_size - 0x100000)) ] && [ "$fw1_size" -lt $((expected_size + 0x100000)) ]; then
            warn "firmware1 size close to expected (within 1MB): 0x$(printf '%x' $fw1_size)"
        else
            fail "firmware1 size mismatch: got 0x$(printf '%x' $fw1_size), expected ~0x3c80000"
            info "This may indicate DTS reg= is wrong"
        fi
    fi

    # Check sysfs mtd info if available
    if [ -d /sys/class/mtd ]; then
        info "MTD sysfs info:"
        for mtd_dir in /sys/class/mtd/mtd*/; do
            local name=$(cat "${mtd_dir}name" 2>/dev/null)
            local size=$(cat "${mtd_dir}size" 2>/dev/null)
            local offset=$(cat "${mtd_dir}offset" 2>/dev/null)
            echo "  $name: size=$size offset=$offset"
        done
    fi
}

# ===================================================================
# MAIN
# ===================================================================
main() {
    diag_header

    t1_mtd_map
    t2_trx_magic
    t3_squashfs_search
    t4_memory_map
    t5_bmt_status
    t6_load_address
    t7_mount_tests
    t8_of_partitions
    t9_mtdsplit_check
    t10_nand_ecc
    t11_dmesg_full
    t12_physical_offset_verify

    echo ""
    echo "============================================================"
    echo "  DIAGNOSTIC SUMMARY"
    echo "  PASS: $PASS  FAIL: $FAIL  WARN: $WARN"
    echo "============================================================"
    echo ""
    echo "Saving full dmesg to /tmp/dmesg_full.txt"
    dmesg > /tmp/dmesg_full.txt
    echo "Done. Check /tmp/dmesg_full.txt for complete boot log."
}

main "$@"
