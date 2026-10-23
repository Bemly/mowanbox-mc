ARCHS = arm64
TARGET = iphone:clang:latest:12.0
INSTALL_TARGET_PROCESSES = minecraftpe

# macOS 上用自带 codesign 做 ad-hoc 签名 (越狱设备不校验证书)
TARGET_CODESIGN = codesign
TARGET_CODESIGN_FLAGS = -s - --force

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = mowanbox
mowanbox_FILES = Tweak.xm MWBVersion.mm MWBUI.mm MWBMenu.mm MWBFloat.mm MWBHooks010.mm MWBHooks1133.mm MWBHooks117.mm MWBHooks143.mm MWBHooks1215.mm MWBHooks120.mm MWBActions.mm MWBMinimap.mm MWBZhLang.mm MWBZhBlocks.mm MWBZhGui.mm MWBDebug.mm MWBCamera010.mm EMI.mm EMIItems.mm EMIViews.mm EMIWindow.mm MWBSkin4D.mm MWBGLBMolang.mm MWBGLBModel.mm MWBFishData.c
mowanbox_FRAMEWORKS = UIKit CoreGraphics Foundation QuartzCore ImageIO AVFoundation
mowanbox_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# 构建号打进二进制（git 计数+短哈希+脏标记，启动时写日志，验证先对构建号再看效果）
MWB_GIT_COUNT := $(shell git rev-list --count HEAD)
MWB_GIT_HASH := $(shell git rev-parse --short HEAD)
MWB_GIT_DIRTY := $(shell git status --porcelain | grep -q . && echo -dirty)
mowanbox_CFLAGS += -DMWB_BUILD_TAG='"$(MWB_GIT_COUNT)-$(MWB_GIT_HASH)$(MWB_GIT_DIRTY)"'

include $(THEOS_MAKE_PATH)/tweak.mk
