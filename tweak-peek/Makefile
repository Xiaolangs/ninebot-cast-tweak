TARGET = iphone:clang:latest:13.0
ARCHS  = arm64
TWEAK_NAME = CachePeek
CachePeek_FILES      = Tweak.x substrate_shim.m
CachePeek_FRAMEWORKS = Foundation
CachePeek_CFLAGS     = -fobjc-arc -I$(THEOS_PROJECT_DIR)/include
CachePeek_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/CachePeek.dylib
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
