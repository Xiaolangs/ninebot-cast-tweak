TARGET = iphone:clang:latest:13.0
ARCHS  = arm64

TWEAK_NAME = KeyProbe

KeyProbe_FILES      = Tweak.x substrate_shim.m
KeyProbe_FRAMEWORKS = Foundation
KeyProbe_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)/include
KeyProbe_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/KeyProbe.dylib

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
