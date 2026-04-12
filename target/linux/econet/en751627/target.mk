# SPDX-License-Identifier: GPL-2.0-only

ARCH:=mips
SUBTARGET:=en751627
BOARDNAME:=EN751627 based boards
CPU_TYPE:=1004kc
KERNELNAME:=vmlinuz.bin

DEFAULT_PACKAGES += kmod-leds-gpio kmod-gpio-button-hotplug wpad-basic-mbedtls

define Target/Description
	Build firmware images for EcoNet EN751627 based boards.
	The EN751627 family includes EN7516, EN7527, EN7561 - big-endian
	quad-VPE MIPS 1004Kc SoCs with MIPS GIC, used in DSL/WiFi gateways.
endef
