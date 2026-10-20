/* MWBDebug.mm — 触摸模拟/cycript 调试入口 + 菜单命中探针 */
#import "MWBCommon.h"
#import <UIKit/UIKit.h>
#import "MWBUI.h"
#import "MWBMenu.h"
#import "MWBFloat.h"

#pragma mark - 触摸模拟 (调试用, cycript 可调用)

// 通过 UITouch 模拟单次点击
// 用法 (cycript): [MWBTouchHelper tapAtX:512 y:480]
@interface MWBTouchHelper : NSObject
+ (void)tapAtX:(CGFloat)x y:(CGFloat)y;
+ (UIView *)findGameView;
// 直调式点击 (AGENTS 坑#6 合规路径: 直接调游戏 VC 的 touchesBegan/Ended,
// 不走 UIApplication sendEvent:, 不会 SIGSEGV)
// 用法 (cycript): [MWBTouchHelper tapGameAtX:512 y:485]
+ (void)tapGameAtX:(CGFloat)x y:(CGFloat)y;
+ (UIViewController *)findGameVC;
@end

@implementation MWBTouchHelper

// 找到 MCPE 的 OpenGL 渲染 view (GLKView/EAGLView)
+ (UIView *)findGameView {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        // 跳过我们自己的 overlay window
        if ([w isKindOfClass:NSClassFromString(@"MWBOverlayWindow")]) continue;
        // 递归查找 GLKView/EAGLView
        NSMutableArray *stack = [@[w] mutableCopy];
        while (stack.count > 0) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            NSString *cls = NSStringFromClass([v class]);
            if ([cls containsString:@"GLKView"] || [cls containsString:@"EAGL"] ||
                [cls containsString:@"Surface"] || [cls containsString:@"Render"] ||
                [cls containsString:@"MTKView"] || [cls containsString:@"Metal"]) {
                return v;
            }
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    }
    return nil;
}

+ (UITouch *)createTouchAt:(CGPoint)pt window:(UIWindow *)window view:(UIView *)view phase:(UITouchPhase)phase {
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:window forKey:@"_window"];
    [touch setValue:view forKey:@"_view"];
    [touch setValue:@(phase) forKey:@"_phase"];
    [touch setValue:@([[NSDate date] timeIntervalSinceReferenceDate]) forKey:@"_timestamp"];
    [touch setValue:@1 forKey:@"_tapCount"];
    NSValue *loc = [NSValue valueWithCGPoint:pt];
    [touch setValue:loc forKey:@"_locationInWindow"];
    [touch setValue:loc forKey:@"_previousLocationInWindow"];
    return touch;
}

+ (void)tapAtX:(CGFloat)x y:(CGFloat)y {
    NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    void (^log)(NSString *) = ^(NSString *m) {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], m];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *gameView = [self findGameView];
        UIWindow *window = gameView.window;
        log([NSString stringWithFormat:@"模拟点击 (%.0f,%.0f) gameView=%@ window=%@",
            x, y, gameView.class, window.class]);
        if (!gameView || !window) { log(@"未找到游戏 view, 放弃"); return; }

        CGPoint pt = (CGPoint){x, y};

        // 必须走 UIApplication sendEvent: 路由 (直接调 window touchesBegan: 是
        // UIResponder 空实现, 不会转发给子 view); 同时 UIEvent 内部 _touches
        // 也要塞进触摸, 否则游戏侧查 allTouches 拿不到
        UITouch *touch = [self createTouchAt:pt window:window view:gameView phase:UITouchPhaseBegan];
        UIEvent *beganEvent = [[UIEvent alloc] init];
        @try { [beganEvent setValue:[NSSet setWithObject:touch] forKey:@"_touches"]; }
        @catch (NSException *e) { log([NSString stringWithFormat:@"注入 _touches 失败: %@", e]); return; }
        [[UIApplication sharedApplication] sendEvent:beganEvent];
        log(@"触摸 began 已发送");

        // Touch Ended (延迟 80ms, 复用同一个 UITouch 对象)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [touch setValue:@(UITouchPhaseEnded) forKey:@"_phase"];
            UIEvent *endEvent = [[UIEvent alloc] init];
            @try { [endEvent setValue:[NSSet setWithObject:touch] forKey:@"_touches"]; }
            @catch (NSException *e) { log([NSString stringWithFormat:@"注入 _touches 失败: %@", e]); return; }
            [[UIApplication sharedApplication] sendEvent:endEvent];
            log(@"触摸 ended 已发送");
        });
    });
}

// 找到游戏的主 ViewController (minecraftpe 开头、非自家 overlay)
+ (UIViewController *)findGameVC {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        UIViewController *rvc = w.rootViewController;
        if (!rvc) continue;
        NSString *cls = NSStringFromClass([rvc class]);
        if ([cls containsString:@"MWB"] || [cls containsString:@"EMI"]) continue;
        if ([cls rangeOfString:@"minecraftpe" options:NSCaseInsensitiveSearch].length > 0) {
            return rvc;
        }
    }
    return nil;
}

// 直调式点击: began+ended 直接打到游戏 VC (主线程同步执行)
// 1.20 教训: 设置类弹窗是独立 VC, 只打主 VC 够不着, 改为全窗口全 VC 广播
+ (void)tapGameAtX:(CGFloat)x y:(CGFloat)y {
    NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    void (^log)(NSString *) = ^(NSString *m) {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], m];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *vcs = [NSMutableArray new];
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if ([w isKindOfClass:NSClassFromString(@"MWBOverlayWindow")]) continue;
            UIViewController *rvc = w.rootViewController;
            while (rvc) {
                NSString *cls = NSStringFromClass([rvc class]);
                if (![cls containsString:@"MWB"] && ![cls containsString:@"EMI"]) [vcs addObject:rvc];
                if (rvc.presentedViewController && rvc.presentedViewController != rvc)
                    rvc = rvc.presentedViewController;
                else break;
            }
            if (vcs.count == 0) {
                UIViewController *fvc = [self findGameVC];
                if (fvc) [vcs addObject:fvc];
            }
        }
        UIView *gameView = [self findGameView];
        UIWindow *window = gameView.window ?: [UIApplication sharedApplication].keyWindow;
        log([NSString stringWithFormat:@"直调点击 (%.0f,%.0f) vc数=%lu view=%@",
             x, y, (unsigned long)vcs.count, NSStringFromClass([gameView class])]);
        if (vcs.count == 0 || !gameView) { log(@"未找到游戏 VC/view, 放弃"); return; }
        CGPoint pt = (CGPoint){x, y};
        UITouch *touch = [self createTouchAt:pt window:window view:gameView phase:UITouchPhaseBegan];
        NSSet *s = [NSSet setWithObject:touch];
        for (UIViewController *vc in vcs) [vc touchesBegan:s withEvent:nil];
        log(@"直调 began 已调用");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [touch setValue:@(UITouchPhaseEnded) forKey:@"_phase"];
            for (UIViewController *vc in vcs) [vc touchesEnded:s withEvent:nil];
            log(@"直调 ended 已调用");
        });
    });
}

// cycript 直调开关 (确定性测试通道, 不依赖坐标点悬浮窗)
// 用法: cycript -p PID -e "[MWBTouchHelper dbgInv:1]"
+ (void)dbgInv:(BOOL)v { gInvincible = v; }
+ (void)dbgFly:(BOOL)v { gFly = v; }
+ (void)dbgBreak:(BOOL)v { gFastBreak = v; }
+ (void)dbgSpeed:(BOOL)v { gSpeed = v; }
+ (void)dbgJump:(BOOL)v { gSuperJump = v; }
+ (void)dbgNoclip:(BOOL)v { gNoclip = v; }
+ (void)dbgNight:(BOOL)v { gNightVision = v; }
+ (void)dbgAura:(BOOL)v { gKillAura = v; }
+ (void)dbgMap:(BOOL)v { gMinimap = v; MWBMinimapShow(v); }
+ (void)dbgDebug:(BOOL)v { gMWBDebug = v; }
+ (void)dbgTime:(int)v { gTimeMode = v; }
+ (void)dbgWeather:(int)v { gWeatherMode = v; }
+ (void)dbgHeal { MWBHealNow(); }
+ (void)dbgEnchant { MWBEnchantHeld255(); }
+ (void)dbgGive117:(int)itemId {
    if (gGV != (int)MWBGameV1_1_7) return;
    for (int i = 0; i < 100 && !gPlayer117; i++) [NSThread sleepForTimeInterval:0.5];
    if (gPlayer117) MWB117_Give(gPlayer117, itemId, 1);
}
+ (void)dbgGive143:(int)itemId { if (gGV == (int)MWBGameV1_4_3 && gPlayer143) MWB143_Give(gPlayer143, itemId, 5); }
+ (void)dbgTeleport { MWBTeleportUp10(); }
+ (void)dbgFill { MWBFillStone5(); }
+ (void)dbgReactor { MWB010SpawnReactor(); }
+ (void)dbgDiff:(int)difficulty { MWBSetDifficulty010(difficulty); }
+ (void)dbgMob:(int)typeId { MWB010SpawnMob(typeId); }
+ (void)dbgExplode { MWB010Explode(); }
+ (void)dbgProbe120 { MWB120ProbeMobEffect(); }

@end
