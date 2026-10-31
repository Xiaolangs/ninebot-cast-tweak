TARGET = iphone:clang:latest:13.0
ARCHS  = arm64
TWEAK_NAME = KeyBodyProbe
KeyBodyProbe_FILES      = Tweak.x substrate_shim.m
KeyBodyProbe_FRAMEWORKS = Foundation
KeyBodyProbe_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)/include
KeyBodyProbe_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/KeyBodyProbe.dylib
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
