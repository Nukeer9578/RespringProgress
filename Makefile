SDKVERSION = 11.2
SYSROOT = $(THEOS)/sdks/iPhoneOS11.2.sdk
include $(THEOS)/makefiles/common.mk

ARCHS = arm64 arm64e

#GO_EASY_ON_ME=1

TWEAK_NAME = RespringProgress
RespringProgress_FILES = Tweak.xm
RespringProgress_PRIVATE_FRAMEWORKS = ProgressUI

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 backboardd"
