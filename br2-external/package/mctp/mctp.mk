MCTP_VERSION = 1.1
MCTP_SITE = $(call github,CodeConstruct,mctp,v$(MCTP_VERSION))
MCTP_LICENSE = GPL-2.0
MCTP_LICENSE_FILES = LICENSE
MCTP_DEPENDENCIES = host-pkgconf

$(eval $(meson-package))
