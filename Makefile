ARCHS         = arm64
TARGET        = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = UniversalAutoClicker

UniversalAutoClicker_FILES       = Tweak.x
UniversalAutoClicker_FRAMEWORKS  = UIKit Foundation CoreGraphics IOKit
UniversalAutoClicker_PRIVATE_FRAMEWORKS =
UniversalAutoClicker_CFLAGS      = -fobjc-arc -Wno-deprecated-declarations
UniversalAutoClicker_LDFLAGS     = -lz

include $(THEOS)/makefiles/tweak.mk
