ifeq ($(SIDELOADED),1)
MODULES = jailed
endif

PACKAGE_VERSION = 0.1.27
ifdef APP_VERSION
  PACKAGE_VERSION := $(APP_VERSION)-$(PACKAGE_VERSION)
endif

TARGET := iphone:clang:latest:13.0
INSTALL_TARGET_PROCESSES = Twitch

ARCHS = arm64

ADDITIONAL_CFLAGS = -Wno-module-import-in-extern-c

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TwitchAdBlock

$(TWEAK_NAME)_FILES = $(filter-out Sideloaded.x, $(wildcard *.x)) $(wildcard *.*m) fishhook/fishhook.c
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Iinclude -DPACKAGE_VERSION=@\"$(PACKAGE_VERSION)\"
$(TWEAK_NAME)_LDFLAGS = -Wl,-undefined,dynamic_lookup
$(TWEAK_NAME)_LOGOS_DEFAULT_GENERATOR = internal
ifeq ($(SIDELOADED),1)
  $(TWEAK_NAME)_FILES += Sideloaded.x
  CODESIGN_IPA = 0
endif

include $(THEOS_MAKE_PATH)/tweak.mk
