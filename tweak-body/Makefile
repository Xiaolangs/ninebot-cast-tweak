TARGET = iphone:clang:latest:13.0
ARCHS  = arm64
TWEAK_NAME = BodyProbe
BodyProbe_FILES      = Tweak.x substrate_shim.m
BodyProbe_FRAMEWORKS = Foundation
BodyProbe_LIBRARIES  = z
BodyProbe_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)/include
BodyProbe_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/BodyProbe.dylib
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
