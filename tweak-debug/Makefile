TARGET = iphone:clang:latest:13.0
ARCHS  = arm64
TWEAK_NAME = DebugPanel
DebugPanel_FILES      = Tweak.m
DebugPanel_FRAMEWORKS = UIKit Foundation
DebugPanel_CFLAGS     = -fobjc-arc
DebugPanel_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/DebugPanel.dylib
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
