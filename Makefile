ARCHS = arm64
TARGET = iphone:clang:latest:12.0
INSTALL_TARGET_PROCESSES = minecraftpe

# macOS 上用自带 codesign 做 ad-hoc 签名 (越狱设备不校验证书)
TARGET_CODESIGN = codesign
TARGET_CODESIGN_FLAGS = -s - --force

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = mowanbox
mowanbox_FILES = Tweak.xm MWBVersion.mm MWBUI.mm MWBMenu.mm MWBFloat.mm MWBHooks010.mm MWBHooks1133.mm MWBHooks117.mm MWBHooks143.mm MWBHooks1215.mm MWBHooks120.mm MWBActions.mm MWBMinimap.mm MWBZhLang.mm MWBZhBlocks.mm MWBZhGui.mm MWBDebug.mm EMI.mm EMIItems.mm EMIViews.mm EMIWindow.mm MWBYSMCodec.mm MWBYSMModel.mm MWBYSMRender.mm zstddeclib.c
mowanbox_FRAMEWORKS = UIKit CoreGraphics Foundation QuartzCore ImageIO AVFoundation
mowanbox_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
