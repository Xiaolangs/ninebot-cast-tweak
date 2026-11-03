TARGET = iphone:clang:latest:13.0
ARCHS  = arm64
TWEAK_NAME = ThemePush
ThemePush_FILES      = Tweak.m
ThemePush_FRAMEWORKS = UIKit Foundation
ThemePush_CFLAGS     = -fobjc-arc
ThemePush_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/ThemePush.dylib
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
