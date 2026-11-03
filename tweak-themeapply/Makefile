TARGET = iphone:clang:latest:13.0
ARCHS  = arm64
TWEAK_NAME = ThemeApply
ThemeApply_FILES      = Tweak.m
ThemeApply_FRAMEWORKS = UIKit Foundation UniformTypeIdentifiers
ThemeApply_CFLAGS     = -fobjc-arc
ThemeApply_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/ThemeApply.dylib
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
