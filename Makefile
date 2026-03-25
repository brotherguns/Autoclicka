THEOS_DEVICE_IP = 0
ARCHS = arm64
TARGET = iphone:clang:latest:16.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = UnlockrCredits
UnlockrCredits_FILES = Tweak.x
UnlockrCredits_CFLAGS = -fobjc-arc
UnlockrCredits_LDFLAGS = -F$(THEOS_DEVICE_IP)

include $(THEOS_MAKE_PATH)/tweak.mk
