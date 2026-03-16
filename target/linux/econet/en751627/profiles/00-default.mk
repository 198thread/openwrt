# SPDX-License-Identifier: GPL-2.0-only

define Profile/Default
	NAME:=Default Profile
	PACKAGES:=
endef

define Profile/Default/Description
	Default profile for EN751627 devices.
endef

$(eval $(call Profile,Default))
