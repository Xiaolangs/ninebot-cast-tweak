TARGET = iphone:clang:latest:13.0
ARCHS  = arm64

TWEAK_NAME = FirmwareProbe

FirmwareProbe_FILES      = Tweak.x substrate_shim.m
FirmwareProbe_FRAMEWORKS = Foundation
FirmwareProbe_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)/include
FirmwareProbe_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/FirmwareProbe.dylib

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
