include $(TOPDIR)/rules.mk

PKG_NAME:=l850gl
PKG_VERSION:=1.0.1
PKG_RELEASE:=1
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
  Includes proto atc backend (atc.sh, gcom scripts, LuCI UI)
  and hotplug-based auto-detection/interface management.
  Just install and plug your modem.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./files/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/l850gl/install
	# gcom scripts
	$(INSTALL_DIR) $(1)/etc/gcom
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/etc/gcom/at.gcom        $(1)/etc/gcom/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/etc/gcom/getrun_at.gcom $(1)/etc/gcom/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/etc/gcom/run_at.gcom    $(1)/etc/gcom/

	# proto atc
	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/lib/netifd/proto/atc.sh  $(1)/lib/netifd/proto/

	# LuCI UI
	$(INSTALL_DIR) $(1)/www/luci-static/resources/protocol
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/www/luci-static/resources/protocol/atc.js \
	                $(1)/www/luci-static/resources/protocol/

	# hotplug
	$(INSTALL_DIR) $(1)/etc/hotplug.d/usb
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/hotplug.d/usb/99-l850gl \
	               $(1)/etc/hotplug.d/usb/

	# uci-defaults (run once on first boot)
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/uci-defaults/99-l850gl-defaults \
	               $(1)/etc/uci-defaults/

	# init.d script (untuk memastikan modem diinisialisasi setelah boot)
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/init.d/l850gl-init $(1)/etc/init.d/

	# management binary
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/bin/l850gl-init $(1)/usr/bin/
endef

define Package/l850gl/postinst
#!/bin/sh
# Bersihkan LuCI cache agar protocol baru terdeteksi
rm -f /tmp/luci-indexcache.* 2>/dev/null
rm -rf /tmp/luci-modulecache/ 2>/dev/null
killall -HUP rpcd 2>/dev/null

# Aktifkan init script agar berjalan saat boot
/etc/init.d/l850gl-init enable 2>/dev/null

echo "============================================="
echo " L850GL (Proto ATC) berhasil terinstal."
echo " Modem akan otomatis terkoneksi saat dicolok."
echo " Interface akan dihapus saat modem dicabut."
echo " LuCI: Network -> Interfaces -> Add -> AT commands"
echo " Pastikan APN sudah benar di interface 'wwan'."
echo "============================================="
exit 0
endef

$(eval $(call BuildPackage,l850gl))
