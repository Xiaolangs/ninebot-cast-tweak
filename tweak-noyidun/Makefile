TARGET = iphone:clang:latest:13.0
ARCHS  = arm64
TWEAK_NAME = NoYidun
NoYidun_FILES      = Tweak.m
NoYidun_FRAMEWORKS = Foundation UIKit
NoYidun_CFLAGS     = -fobjc-arc
NoYidun_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/NoYidun.dylib
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
