TARGET = iphone:clang:latest:13.0
ARCHS  = arm64
TWEAK_NAME = SeedProbe
SeedProbe_FILES      = Tweak.x substrate_shim.m
SeedProbe_FRAMEWORKS = Foundation
SeedProbe_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)/include
SeedProbe_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/SeedProbe.dylib
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
