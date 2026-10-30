TARGET = iphone:clang:latest:13.0
ARCHS  = arm64

TWEAK_NAME = ProjectionOverride

ProjectionOverride_FILES      = Tweak.x substrate_shim.m
ProjectionOverride_FRAMEWORKS = Foundation CoreGraphics CoreVideo CoreText
ProjectionOverride_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)/include
ProjectionOverride_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/ProjectionOverride.dylib

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
