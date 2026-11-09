DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets with the PreferenceBundle.
include AxsBLELoggerBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsBLELogger
AxsBLELogger_FILES = $(wildcard Hooks/*.xm Sources/*.m)
AxsBLELogger_CFLAGS = -fobjc-arc -I./Sources
AxsBLELogger_FRAMEWORKS = UIKit Foundation CoreFoundation CoreBluetooth
AxsBLELogger_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += AxsBLELoggerPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
