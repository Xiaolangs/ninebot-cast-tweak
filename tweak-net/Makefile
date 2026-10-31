TARGET = iphone:clang:latest:13.0
ARCHS  = arm64

TWEAK_NAME = NetPlainLog

NetPlainLog_FILES      = Tweak.x substrate_shim.m
NetPlainLog_FRAMEWORKS = Foundation
NetPlainLog_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)/include
NetPlainLog_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/NetPlainLog.dylib

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
