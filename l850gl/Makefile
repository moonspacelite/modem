include $(TOPDIR)/rules.mk

PKG_NAME:=l850gl
PKG_VERSION:=1.0.2
PKG_RELEASE:=2
PKG_MAINTAINER:=0x <0xhyperbug@gmail.com>
PKG_LICENSE:=MIT

PKG_BUILD_DIR := $(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/l850gl
  SECTION:=net
  CATEGORY:=Network
  TITLE:=L850GL Auto-Connect (Proto ATC + hotplug)
  DEPENDS:=+comgt +kmod-usb-net-cdc-ncm +kmod-usb-acm
  PKGARCH:=all
endef

define Package/l850gl/description
  Complete plug-and-play solution for Fibocom L850GL modem.
  Includes proto atc backend (atc.sh, gcom scripts, LuCI UI),
  hotplug-based auto-detection, vendor script, and scanner.
  Just install and plug your modem.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./files/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/l850gl/install
	# gcom scripts (data)
	$(INSTALL_DIR) $(1)/etc/gcom
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/etc/gcom/at.gcom        $(1)/etc/gcom/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/etc/gcom/getrun_at.gcom $(1)/etc/gcom/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/etc/gcom/run_at.gcom    $(1)/etc/gcom/

	# proto atc handler (executable)
	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/lib/netifd/proto/atc.sh  $(1)/lib/netifd/proto/

	# LuCI UI (data)
	$(INSTALL_DIR) $(1)/www/luci-static/resources/protocol
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/www/luci-static/resources/protocol/atc.js \
	                $(1)/www/luci-static/resources/protocol/

	# hotplug handler (executable)
	$(INSTALL_DIR) $(1)/etc/hotplug.d/usb
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/hotplug.d/usb/99-l850gl \
	               $(1)/etc/hotplug.d/usb/

	# uci-defaults (executable)
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/uci-defaults/99-l850gl-defaults \
	               $(1)/etc/uci-defaults/

	# init.d script (executable)
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/init.d/l850gl-init $(1)/etc/init.d/

	# management binaries (executable)
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/bin/l850gl-init $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/bin/l850gl-scan $(1)/usr/bin/

	# vendor script (executable)
	$(INSTALL_DIR) $(1)/usr/share/l850gl/vendor
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/share/l850gl/vendor/fibocom.sh $(1)/usr/share/l850gl/vendor/

	# udev rule (data) - prioritas tinggi untuk blokir ModemManager
	$(INSTALL_DIR) $(1)/etc/udev/rules.d
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/etc/udev/rules.d/10-l850gl-mm.rules $(1)/etc/udev/rules.d/
endef

define Package/l850gl/postinst
#!/bin/sh
# Bersihkan cache LuCI
rm -f /tmp/luci-indexcache.* 2>/dev/null
rm -rf /tmp/luci-modulecache/ 2>/dev/null
killall -HUP rpcd 2>/dev/null

# Aktifkan init script untuk auto-start saat boot
/etc/init.d/l850gl-init enable 2>/dev/null

# Muat ulang aturan udev agar ModemManager diblokir segera
udevadm control --reload-rules 2>/dev/null
udevadm trigger 2>/dev/null

echo "============================================="
echo " L850GL (Proto ATC) berhasil terinstal."
echo " Modem akan otomatis terkoneksi saat dicolok."
echo " Interface 'wwan' akan muncul di LuCI."
echo " Pastikan APN sudah benar di konfigurasi."
echo "============================================="
exit 0
endef

$(eval $(call BuildPackage,l850gl))
