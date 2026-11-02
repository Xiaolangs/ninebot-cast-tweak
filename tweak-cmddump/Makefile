TARGET = iphone:clang:latest:13.0
ARCHS  = arm64
TWEAK_NAME = CmdDump
CmdDump_FILES      = Tweak.m
CmdDump_FRAMEWORKS = UIKit Foundation
CmdDump_CFLAGS     = -fobjc-arc
CmdDump_LDFLAGS    = -Wl,-undefined,dynamic_lookup -install_name @executable_path/CmdDump.dylib
include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
