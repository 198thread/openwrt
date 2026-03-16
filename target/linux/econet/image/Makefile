include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/image.mk

define Target/Description
	Build firmware images for EcoNet MIPS based boards.
endef

# tclinux-trx is the default format used in the SDK
define Build/tclinux-trx
  ./tclinux-trx.sh --kernel $@ --rootfs $(IMAGE_ROOTFS) \
    --version $(VERSION_DIST)-$(REVISION) --endian $(TRX_ENDIAN) \
    $(if $(TRX_MODEL),--model $(TRX_MODEL)) \
    $(if $(TRX_HDRLEN),--hdrlen $(TRX_HDRLEN)) > $@.new
	mv $@.new $@
endef

# tclinux-trx variant for initramfs kernels (rootfs embedded in kernel)
# Uses /dev/null as dummy rootfs so the kernel's built-in initramfs is used.
define Build/tclinux-trx-initramfs
	echo -n > $(KDIR)/empty_rootfs
	./tclinux-trx.sh --kernel $@ --rootfs $(KDIR)/empty_rootfs \
	  --version $(VERSION_DIST)-$(REVISION) --endian $(TRX_ENDIAN) \
	  $(if $(TRX_MODEL),--model $(TRX_MODEL)) \
	  $(if $(TRX_HDRLEN),--hdrlen $(TRX_HDRLEN)) > $@.new
	mv $@.new $@
endef

# tclinux bootloader requires LZMA, BUT only provides 7.5MB of space
# to decompress into. So we use vmlinuz and decompress twice.
define Device/Default
  DEVICE_DTS_DIR := ../dts
  KERNEL_SIZE := 7480k
  KERNEL_NAME := vmlinuz.bin
  KERNEL_LOADADDR := 0x80020000
  KERNEL := kernel-bin | append-dtb
endef

include $(SUBTARGET).mk

$(eval $(call BuildImage))
