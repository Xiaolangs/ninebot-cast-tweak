TARGET = iphone:clang:latest:13.0
ARCHS  = arm64
TWEAK_NAME = DebugLauncher
DebugLauncher_FILES      = Tweak.m
DebugLauncher_FRAMEWORKS = UIKit Foundation
DebugLauncher_CFLAGS     = -fobjc-arc
DebugLauncher_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/DebugLauncher.dylib
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
