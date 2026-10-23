ARCHS = arm64
TARGET = iphone:clang:latest:12.0
INSTALL_TARGET_PROCESSES = minecraftpe

# macOS 上用自带 codesign 做 ad-hoc 签名 (越狱设备不校验证书)
TARGET_CODESIGN = codesign
TARGET_CODESIGN_FLAGS = -s - --force

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = mowanbox
mowanbox_FILES = Tweak.xm MWBVersion.mm MWBUI.mm MWBMenu.mm MWBFloat.mm MWBHooks010.mm MWBHooks1133.mm MWBHooks117.mm MWBHooks143.mm MWBHooks1215.mm MWBHooks120.mm MWBActions.mm MWBMinimap.mm MWBZhLang.mm MWBZhBlocks.mm MWBZhGui.mm MWBDebug.mm MWBCamera010.mm EMI.mm EMIItems.mm EMIViews.mm EMIWindow.mm MWBSkin4D.mm MWBGLBMolang.mm MWBYSMAnim.mm MWBYSMMenu.mm MWBGLBModel.mm
mowanbox_FRAMEWORKS = UIKit CoreGraphics Foundation QuartzCore ImageIO AVFoundation
mowanbox_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# 显式 gnu++17（要 typeof 等 GNU 扩展）：新版 Theos 不再默认 C++11+，CI 上 auto/range-for 会被 -Werror 拦（本机旧 Theos 默认够用）
mowanbox_CCFLAGS = -std=gnu++17
# 构建号打进二进制（git 计数+短哈希+脏标记，启动时写日志，验证先对构建号再看效果）
MWB_GIT_COUNT := $(shell git rev-list --count HEAD)
MWB_GIT_HASH := $(shell git rev-parse --short HEAD)
MWB_GIT_DIRTY := $(shell git status --porcelain | grep -q . && echo -dirty)
mowanbox_CFLAGS += -DMWB_BUILD_TAG='"$(MWB_GIT_COUNT)-$(MWB_GIT_HASH)$(MWB_GIT_DIRTY)"'

# 发布版：make package FINALPACKAGE=1 → 关日志（MWB_RELEASE），Theos 同时去 +debug 后缀、开优化
ifeq ($(FINALPACKAGE),1)
mowanbox_CFLAGS += -DMWB_RELEASE
endif

include $(THEOS_MAKE_PATH)/tweak.mk
