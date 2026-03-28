#!/bin/sh
# zzz-diag-run.sh v111 — run by zzz-diag init script (oneshot via procd respawn 0 0 1)
# v111: added section 10 — cm_probe.ko insmod for kernel-mode CM/GIC/CP0 diagnostic
# All output goes to /dev/kmsg (visible in serial log).

exec > /dev/kmsg 2>&1

log() { printf '%s\n' "$*"; }
sec() { printf '\n=== %s ===\n' "$*"; }

# Read a debugfs value by grepping a key from a regs file.
dbg_read() {
	local f=$1 key=$2
	grep -m1 "$key" "$f" 2>/dev/null | grep -oE '[0-9a-f]{8}' | head -1
}

# Read integer counter after = sign
dbg_int() {
	local f=$1 key=$2
	grep -m1 "$key" "$f" 2>/dev/null | grep -oE '[0-9]+' | tail -1
}

DBG=/sys/kernel/debug/econet_eth
QDMA0_REGS="$DBG/qdma0/regs"
QDMA1_REGS="$DBG/qdma1/regs"
INT_ENABLE_FULL=0007ffbb

log "========================================"
log "=== DIAG START v110 ===================="
log "========================================"

mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true

# ============================================================
# 1. BASELINE STATE
# ============================================================
sec "1a. CPUs online"
grep "^processor" /proc/cpuinfo | while IFS= read -r l; do log "  $l"; done

sec "1b. IRQ 22+23 baseline counts and affinity"
cat /proc/interrupts | grep -E "^ *2[23]:" | while IFS= read -r l; do log "  $l"; done
for irq in 22 23; do
	log "  IRQ $irq smp_affinity:       $(cat /proc/irq/$irq/smp_affinity 2>/dev/null)"
	log "  IRQ $irq effective_affinity: $(cat /proc/irq/$irq/effective_affinity 2>/dev/null)"
done

sec "1c. QDMA0 baseline regs (debugfs)"
if [ -f "$QDMA0_REGS" ]; then
	grep -E "int_status|int_enable|rx_cpui|rx_hwi|tx_cpui|tx_hwi|qdma_cfg|rxbase|txbase" \
		"$QDMA0_REGS" | while IFS= read -r l; do log "  $l"; done
else
	log "  $QDMA0_REGS not found — debugfs not mounted or driver not probed"
	ls "$DBG/" 2>/dev/null | while IFS= read -r l; do log "    $l"; done
fi

sec "1d. eth0 device parent chain"
if [ -d /sys/class/net/eth0 ]; then
	log "  /sys/class/net/eth0 -> $(readlink /sys/class/net/eth0 2>/dev/null)"
	log "  of_node              -> $(readlink /sys/class/net/eth0/device/of_node 2>/dev/null || echo NONE)"
	log "  parent of_node       -> $(readlink /sys/class/net/eth0/device/../of_node 2>/dev/null || echo NONE)"
else
	log "  eth0 not in /sys/class/net yet"
fi

# ============================================================
# 2. WAIT FOR eth0 UP + NAPI ENABLED
# ============================================================
sec "2. Wait for eth0 UP (max 30s)"
ETH_UP=0
for i in $(seq 1 30); do
	state=$(cat /sys/class/net/eth0/operstate 2>/dev/null)
	if [ "$state" = "up" ] || [ "$state" = "unknown" ]; then
		log "  eth0 operstate=$state at T=${i}s — proceeding"
		ETH_UP=1
		break
	fi
	sleep 1
done
[ "$ETH_UP" = "0" ] && log "  eth0 not up after 30s — proceeding anyway"
sleep 2

sec "2b. NAPI thread states after eth0 UP"
for pid in $(ls /proc/ | grep '^[0-9]'); do
	comm=$(cat /proc/$pid/comm 2>/dev/null)
	case "$comm" in
		napi/*) state=$(grep "^State:" /proc/$pid/status 2>/dev/null)
		        log "  PID $pid ($comm): $state" ;;
	esac
done

sec "2c. int_enable / int_status AFTER ndo_open"
INT_EN_AFTER=$(dbg_read "$QDMA0_REGS" "int_enable")
INT_ST_AFTER=$(dbg_read "$QDMA0_REGS" "int_status")
log "  int_status (debugfs) = ${INT_ST_AFTER:-UNREADABLE}"
log "  int_enable (debugfs) = ${INT_EN_AFTER:-UNREADABLE}"
log "  int_enable expected  = $INT_ENABLE_FULL"
if [ "${INT_EN_AFTER:-x}" = "$INT_ENABLE_FULL" ]; then
	log "  int_enable MATCHES full mask — re-arm OK"
elif [ -z "$INT_EN_AFTER" ]; then
	log "  int_enable UNREADABLE — driver not probed or debugfs path wrong"
else
	INT_EN_HEX="0x${INT_EN_AFTER}"
	TX_DONE=$(printf '%d' "$(( $(printf '%d' $INT_EN_HEX) & 1 ))" 2>/dev/null)
	RX_DONE=$(printf '%d' "$(( ($(printf '%d' $INT_EN_HEX) >> 1) & 1 ))" 2>/dev/null)
	log "  int_enable DIFFERS: TX_DONE(bit0)=$TX_DONE  RX_DONE(bit1)=$RX_DONE"
fi

# ============================================================
# 3. PING — confirm RX working
# ============================================================
sec "3. Ping 192.168.1.2 x10 — watch IRQ 22 and rx_cpui"
IRQ22_B=$(grep "^ *22:" /proc/interrupts | awk '{print $2+$3}')
RX_B=$(dbg_int "$QDMA0_REGS" "rx_cpui")
RX_HWI_B=$(dbg_int "$QDMA0_REGS" "rx_hwi")
ping -c 10 -W 1 192.168.1.2 >/dev/null 2>&1
sleep 1
IRQ22_B2=$(grep "^ *22:" /proc/interrupts | awk '{print $2+$3}')
RX_B2=$(dbg_int "$QDMA0_REGS" "rx_cpui")
RX_HWI_B2=$(dbg_int "$QDMA0_REGS" "rx_hwi")
log "  IRQ22:   $IRQ22_B -> $IRQ22_B2"
log "  rx_cpui: $RX_B -> $RX_B2"
log "  rx_hwi:  $RX_HWI_B -> $RX_HWI_B2"
if [ "$IRQ22_B2" != "$IRQ22_B" ]; then
	log "  RESULT: IRQ 22 FIRING — RX working"
elif [ "$RX_B2" != "$RX_B" ]; then
	log "  RESULT: rx_cpui advancing but IRQ 22 not counted (polling mode?)"
else
	log "  RESULT: RX dead — rx_cpui flat, IRQ22 flat"
fi

# ============================================================
# 4. SUSTAINED PING — 3 rounds
# ============================================================
sec "4. Sustained ping rounds (3x10)"
for round in 1 2 3; do
	IRQ22_R=$(grep "^ *22:" /proc/interrupts | awk '{print $2+$3}')
	RX_R=$(dbg_int "$QDMA0_REGS" "rx_cpui")
	ping -c 10 -W 1 192.168.1.2 >/dev/null 2>&1
	sleep 1
	IRQ22_R2=$(grep "^ *22:" /proc/interrupts | awk '{print $2+$3}')
	RX_R2=$(dbg_int "$QDMA0_REGS" "rx_cpui")
	log "  Round $round: IRQ22 $IRQ22_R->$IRQ22_R2  rx_cpui $RX_R->$RX_R2"
	sleep 3
done

# ============================================================
# 5. FULL STATE SNAPSHOT
# ============================================================
sec "5a. Final /proc/interrupts"
cat /proc/interrupts | while IFS= read -r l; do log "  $l"; done

sec "5b. Final QDMA0 regs (debugfs)"
[ -f "$QDMA0_REGS" ] && cat "$QDMA0_REGS" | while IFS= read -r l; do log "  $l"; done

sec "5c. Final QDMA1 regs (debugfs — int_status/int_enable only)"
[ -f "$QDMA1_REGS" ] && grep -E "int_status|int_enable|rx_cpui|rx_hwi" \
	"$QDMA1_REGS" | while IFS= read -r l; do log "  $l"; done

sec "5d. softirqs"
cat /proc/softirqs | while IFS= read -r l; do log "  $l"; done

sec "5e. NAPI thread state final"
for pid in $(ls /proc/ | grep '^[0-9]'); do
	comm=$(cat /proc/$pid/comm 2>/dev/null)
	case "$comm" in
		napi/*) state=$(grep "^State:" /proc/$pid/status 2>/dev/null)
		        log "  PID $pid ($comm): $state" ;;
	esac
done

sec "5f. iomem — QDMA/econet region visibility"
grep -i "1fb5\|qdma\|econet" /proc/iomem 2>/dev/null | \
	while IFS= read -r l; do log "  $l"; done || log "  (no QDMA entries in /proc/iomem)"

sec "5g. SSH reachability"
if ping -c 3 -W 2 192.168.1.2 >/dev/null 2>&1; then
	log "  ping 192.168.1.2: REACHABLE"
else
	log "  ping 192.168.1.2: UNREACHABLE — RX still broken"
fi

# ============================================================
# 6. QDMA PER-BIT INTERRUPT COUNTERS (debugfs)
# ============================================================
sec "6a. QDMA0 debug registers (probe_lo/hi, mem_ctl)"
if [ -f "$QDMA0_REGS" ]; then
	grep -E "probe_lo|probe_hi|mem_ctl|hwf_desc_free|hwd_buf_used" \
		"$QDMA0_REGS" | while IFS= read -r l; do log "  $l"; done
else
	log "  $QDMA0_REGS not available"
fi

sec "6b. QDMA0 per-bit interrupt counters"
QDMA0_INT=$DBG/qdma0/interrupts
if [ -f "$QDMA0_INT" ]; then
	cat "$QDMA0_INT" | while IFS= read -r l; do log "  $l"; done
else
	log "  $QDMA0_INT not found"
fi

sec "6c. QDMA1 per-bit interrupt counters"
QDMA1_INT=$DBG/qdma1/interrupts
if [ -f "$QDMA1_INT" ]; then
	cat "$QDMA1_INT" | while IFS= read -r l; do log "  $l"; done
else
	log "  $QDMA1_INT not found"
fi

# ============================================================
# 7. GIC_SH_PEND — THE KEY DIAGNOSTIC
# GIC base: 0x1f8c0000
# GIC_SH_PEND[31:0] at base+0x0480 = 0x1f8c0480
# Bit 20 = QDMA_LAN0 (GIC_SHARED 20)
# Bit 21 = QDMA_WAN0 (GIC_SHARED 21)
#
# If bit 20 SET while int_status DONE bits SET:
#   QDMA drives signal, GIC sees it — problem is CPU delivery or Linux dispatch.
# If bit 20 CLEAR while int_status DONE bits SET:
#   Signal never reaches GIC — gate register between QDMA and GIC is missing.
#   → Investigate INTC at 0x1fb40000 (Section 8).
# ============================================================
sec "7. GIC_SH_PEND — does QDMA signal reach the GIC?"
GIC_PEND=$(devmem 0x1f8c0480 2>/dev/null || echo "FAIL")
GIC_MASK=$(devmem 0x1f8c0380 2>/dev/null || echo "FAIL")
log "  GIC_SH_PEND[31:0] (0x1f8c0480) = $GIC_PEND"
log "  GIC_SH_MASK[31:0] (0x1f8c0380) = $GIC_MASK"
if [ "$GIC_PEND" != "FAIL" ]; then
	VAL=$(printf '%d' "$GIC_PEND" 2>/dev/null || echo 0)
	BIT20=$(( (VAL >> 20) & 1 ))
	BIT21=$(( (VAL >> 21) & 1 ))
	log "  bit 20 (QDMA_LAN0) pending? $BIT20"
	log "  bit 21 (QDMA_WAN0) pending? $BIT21"
	if [ "$BIT20" = "1" ]; then
		log "  INTERPRETATION: QDMA_LAN0 signal IS reaching GIC."
		log "    Problem is in GIC->CPU routing or Linux IRQ dispatch."
	else
		INT_ST=$(dbg_read "$QDMA0_REGS" "int_status")
		if [ -n "$INT_ST" ] && [ "$INT_ST" != "00000000" ]; then
			log "  INTERPRETATION: int_status=$INT_ST but GIC bit 20 CLEAR."
			log "    GATE REGISTER MISSING between QDMA and GIC."
			log "    → Check INTC at 0x1fb40000 (Section 8)."
		else
			log "  INTERPRETATION: GIC bit 20 clear AND int_status=$INT_ST"
			log "    QDMA hardware not generating interrupt signal at all."
		fi
	fi
else
	log "  devmem 0x1f8c0480 FAILED — STRICT_DEVMEM=y or GIC not mapped?"
fi

# ============================================================
# 8. INTC PROBE (0x1fb40000)
# en751221-intc may be the actual routing path for QDMA interrupts.
# If Caleb's driver routes via INTC → GIC_SHARED 0 rather than direct GIC_SHARED 20/21,
# then our current DTS interrupts assignment is wrong.
# ============================================================
sec "8. INTC probe (econet,en751221-intc at 0x1fb40000)"
for addr in 0x1fb40000 0x1fb40004 0x1fb40008 0x1fb4000c 0x1fb40010; do
	val=$(devmem $addr 2>/dev/null || echo "FAIL")
	log "  [$addr] = $val"
done
# Check if GIC_SHARED 0 (the INTC output) is pending
GIC_PEND_INTC=$(devmem 0x1f8c0480 2>/dev/null || echo "FAIL")
if [ "$GIC_PEND_INTC" != "FAIL" ]; then
	INTC_VAL=$(printf '%d' "$GIC_PEND_INTC" 2>/dev/null || echo 0)
	BIT0=$(( INTC_VAL & 1 ))
	log "  GIC_SH_PEND bit 0 (potential INTC output) = $BIT0"
	[ "$BIT0" = "1" ] && log "  NOTE: GIC_SHARED 0 pending — INTC output line active."
fi

# ============================================================
# 9. FTRACE — trace en75_irq_handler call path
# Only runs if CONFIG_FUNCTION_TRACER=y was built.
# ============================================================
sec "9. ftrace setup (function_graph tracer)"
FTRACE=/sys/kernel/debug/tracing
if [ -d "$FTRACE" ]; then
	log "  ftrace available"
	echo 0 > $FTRACE/tracing_on 2>/dev/null
	echo function_graph > $FTRACE/current_tracer 2>/dev/null && {
		# Trace the IRQ handler and RX path
		echo en75_irq_handler > $FTRACE/set_graph_function 2>/dev/null
		echo en75_qdma_rx_process >> $FTRACE/set_graph_function 2>/dev/null
		echo 1 > $FTRACE/tracing_on 2>/dev/null
		log "  ftrace active — tracing en75_irq_handler + en75_qdma_rx_process for 10s"
		sleep 10
		echo 0 > $FTRACE/tracing_on 2>/dev/null
		log "  --- ftrace output (last 50 lines) ---"
		tail -50 $FTRACE/trace 2>/dev/null | while IFS= read -r l; do log "  $l"; done
		TRACE_LINES=$(wc -l < $FTRACE/trace 2>/dev/null || echo 0)
		log "  Total ftrace lines: $TRACE_LINES"
		if [ "$TRACE_LINES" = "0" ] || [ "$TRACE_LINES" = "1" ]; then
			log "  INTERPRETATION: en75_irq_handler NEVER called — IRQ not delivered to CPU."
		else
			log "  INTERPRETATION: en75_irq_handler called $TRACE_LINES times — IRQ IS delivered."
		fi
		# Try irqsoff tracer for 5s to catch long irq-off windows
		echo irqsoff > $FTRACE/current_tracer 2>/dev/null && {
			echo 1 > $FTRACE/tracing_on 2>/dev/null
			log "  irqsoff tracer active for 5s"
			sleep 5
			echo 0 > $FTRACE/tracing_on 2>/dev/null
			log "  --- irqsoff trace (first 30 lines) ---"
			head -30 $FTRACE/trace 2>/dev/null | while IFS= read -r l; do log "  $l"; done
		}
	} || log "  function_graph tracer not available — CONFIG_FUNCTION_TRACER not set"
else
	log "  /sys/kernel/debug/tracing not found — debugfs not mounted or no ftrace"
fi

# ============================================================
# 10. cm_probe.ko — CM/GIC/CP0 diagnostic (v111 new)
# Reads CMGCRBase, Config0, Config3 (VEIC!), Status, IntCtl,
# GCR_GIC_BASE (GICEN bit), GIC_SH_PEND0 from kernel context.
# ============================================================
sec "10. cm_probe.ko — kernel-mode CM/GIC/CP0 diagnostic"
CM_KO=$(find /lib/modules -name "cm_probe.ko" 2>/dev/null | head -1)
if [ -n "$CM_KO" ]; then
	log "  Loading $CM_KO"
	insmod "$CM_KO" 2>/dev/null && {
		sleep 2
		log "  cm_probe loaded — results in dmesg above"
		rmmod cm_probe 2>/dev/null
	} || log "  insmod cm_probe FAILED"
else
	log "  cm_probe.ko not found in /lib/modules — not included in this image"
fi

log "========================================"
log "=== DIAG END v111 ======================"
log "========================================"
