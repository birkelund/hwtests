LIBNVME_VERSION = master 
LIBNVME_SITE = $(call github,linux-nvme,libnvme,$(LIBNVME_VERSION))
LIBNVME_LICENSE = LGPL-2.1
LIBNVME_LICENSE_FILES = COPYING
LIBNVME_DEPENDENCIES = host-pkgconf

LIBNVME_CONF_OPTS += -Ddocs-build=false
LIBNVME_CONF_OPTS += -Dpython=disabled

$(eval $(meson-package))

define LIBNVME_INSTALL_MI_MCTP_EXAMPLE
	$(INSTALL) -D -m 0755 $(@D)/build/examples/mi-mctp $(TARGET_DIR)/usr/bin
endef

LIBNVME_POST_INSTALL_TARGET_HOOKS += LIBNVME_INSTALL_MI_MCTP_EXAMPLE
