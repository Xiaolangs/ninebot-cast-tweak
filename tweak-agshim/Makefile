TARGET = iphone:clang:latest:13.0
ARCHS  = arm64
TWEAK_NAME = AppGroupShim
AppGroupShim_FILES      = Tweak.m
AppGroupShim_FRAMEWORKS = Foundation Security SystemConfiguration
AppGroupShim_CFLAGS     = -fobjc-arc
AppGroupShim_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/AppGroupShim.dylib
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
