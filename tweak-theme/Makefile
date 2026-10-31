TARGET = iphone:clang:latest:13.0
ARCHS  = arm64

TWEAK_NAME = ThemeProbe

ThemeProbe_FILES      = Tweak.x substrate_shim.m
ThemeProbe_FRAMEWORKS = Foundation
ThemeProbe_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)/include
ThemeProbe_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/ThemeProbe.dylib

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
