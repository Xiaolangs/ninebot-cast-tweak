TARGET = iphone:clang:latest:13.0
ARCHS  = arm64
TWEAK_NAME = NbKeyGrab
NbKeyGrab_FILES      = Tweak.m
NbKeyGrab_FRAMEWORKS = Foundation Security UIKit
NbKeyGrab_CFLAGS     = -fobjc-arc
NbKeyGrab_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/NbKeyGrab.dylib
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
