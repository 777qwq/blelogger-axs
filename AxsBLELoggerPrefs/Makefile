include ../AxsBLELoggerBuild.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AxsBLELoggerPrefs
AxsBLELoggerPrefs_FILES = $(wildcard *.m)
AxsBLELoggerPrefs_CFLAGS = -fobjc-arc -I../Sources
AxsBLELoggerPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsBLELoggerPrefs_PRIVATE_FRAMEWORKS = Preferences
AxsBLELoggerPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
