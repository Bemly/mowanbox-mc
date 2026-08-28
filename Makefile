ARCHS = arm64
TARGET = iphone:clang:latest:12.0
INSTALL_TARGET_PROCESSES = minecraftpe

# macOS 上用自带 codesign 做 ad-hoc 签名 (越狱设备不校验证书)
TARGET_CODESIGN = codesign
TARGET_CODESIGN_FLAGS = -s - --force

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = mowanbox
mowanbox_FILES = Tweak.xm EMI.mm
mowanbox_FRAMEWORKS = UIKit CoreGraphics Foundation QuartzCore ImageIO
mowanbox_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
