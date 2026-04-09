TRX_ENDIAN := be

define Device/en751627_generic
  DEVICE_VENDOR := EN751627
  DEVICE_MODEL := Generic
  DEVICE_DTS := en751627_generic
endef
TARGET_DEVICES += en751627_generic

define Device/zyxel_ex3301-t0
  DEVICE_VENDOR := ZyXEL
  DEVICE_MODEL := EX3301-T0
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7916-firmware mt7915-firmware \
		     kmod-usb3 kmod-usb-xhci-mtk kmod-usb-storage kmod-usb-ledtrig-usbport kmod-gpio-button-hotplug
  TRX_MODEL := EX3301-T0
  TRX_CHIP := en7516
  TRX_HDRLEN := 372
  IMAGES := tclinux.trx sysupgrade.bin
  IMAGE/tclinux.trx := append-kernel | lzma | tclinux-trx
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  KERNEL_INITRAMFS := kernel-bin | append-dtb | lzma | tclinux-trx-initramfs
  DEVICE_DTS := en751627_zyxel_ex3301-t0
endef
TARGET_DEVICES += zyxel_ex3301-t0
