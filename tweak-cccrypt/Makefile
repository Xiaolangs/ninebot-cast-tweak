TARGET = iphone:clang:latest:13.0
ARCHS  = arm64
TWEAK_NAME = CCCryptProbe
CCCryptProbe_FILES      = Tweak.m
CCCryptProbe_FRAMEWORKS = Foundation Security
CCCryptProbe_CFLAGS     = -fobjc-arc
CCCryptProbe_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/CCCryptProbe.dylib
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
