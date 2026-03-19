ARCHS = arm64
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CodUnlock
CodUnlock_FILES = Tweak.x
CodUnlock_FRAMEWORKS = Foundation
CodUnlock_LIBRARIES = dobby
CodUnlock_CFLAGS = -fobjc-arc

include $(THEOS)/makefiles/tweak.mk
