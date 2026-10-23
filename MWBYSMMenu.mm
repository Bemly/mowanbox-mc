// MWBYSMMenu.mm — 插件菜单第 5 项：YSM 模型橱窗＋模型设置（对标 mod 的选模型界面与 Alt+Y 面板，原生实现，不搬 mod 代码）
// 橱窗：mwbmodels/ 下每个 <id>_anim.json＋<id>.glb 一张卡片，卡片播 gui 动画（离线烘焙的精灵条：
//   <id>_thumb_intro.png 开门段播一次 → <id>_thumb_loop.png 循环段，web/thumb.html 生成），名字在卡片下；
//   每页 5×2，底栏 前一页 / 页码 / 后一页 / 设置；点卡片＝选中该模型并开 4D 皮肤，“设置”进当前模型设置子页。
// 设置子页：
// 数据：fatfish_anim.json 的 settings（脸部选项/面部细调/服饰/额外）；控件三类：
//  checkbox → 像素开关（0/1）；range → [−] 数值 [+] 步进（min/max/step）；radio → 选项按钮换行排（labels 是赋值串）。
// 值走 MWBAnimSetRoaming 写 v.roaming.*（运行时即时生效＋NSUserDefaults 持久化，下次载入回放）。
// 同一变量可能出现在多组（如“禁用自动表情”），改一处全体刷新。
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "MWBCommon.h"
#import "MWBUI.h"
#import "MWBYSMAnim.h"
#import "MWBGLBModel.h" // 当前模型 id / 切换
#import <QuartzCore/QuartzCore.h>

// radio 选项：按主变量的赋值数值排序（JSON 对象无序，靠值还原 mod 里的顺序）
static float YSMAssignValue(NSString *assign, NSString *var) {
    for (NSString *part in [assign componentsSeparatedByString:@";"]) {
        NSArray *kv = [part componentsSeparatedByString:@"="];
        if (kv.count != 2) continue;
        NSString *k = [kv[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([k isEqualToString:[@"v." stringByAppendingString:var]]) return [kv[1] floatValue];
    }
    return NAN;
}
static NSString *YSMFmt(float v, float step) {
    if (step >= 1) return [NSString stringWithFormat:@"%d", (int)lroundf(v)];
    if (step >= 0.1f) return [NSString stringWithFormat:@"%.1f", v];
    return [NSString stringWithFormat:@"%.2f", v];
}

@interface MWBYSMMenuTarget : NSObject
@property (nonatomic, strong) NSMutableArray *refreshers; // 每个控件一个刷新块（同变量多处同步）
@end
@implementation MWBYSMMenuTarget
- (void)refreshAll { for (void (^r)(void) in self.refreshers) r(); }
@end
static MWBYSMMenuTarget *sYSMTarget = nil;

// 动作块挂在控件上（UIControl 不带块回调，自带一个小转发器）
@interface MWBYSMBlockProxy : NSObject
@property (nonatomic, copy) void (^block)(id sender);
- (void)fire:(id)sender;
@end
@implementation MWBYSMBlockProxy
- (void)fire:(id)sender { if (self.block) self.block(sender); }
@end
static void YSMOn(UIControl *c, UIControlEvents ev, void (^blk)(id)) {
    MWBYSMBlockProxy *p = [MWBYSMBlockProxy new];
    p.block = blk;
    [c addTarget:p action:@selector(fire:) forControlEvents:ev];
    objc_setAssociatedObject(c, (__bridge const void *)p, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UILabel *YSMLabel(NSString *t, CGFloat size, UIColor *c) {
    UILabel *l = [[UILabel alloc] init];
    l.attributedText = MWBPixelText(t, MWBPixelFont(size), c, 3, 3, MWB_COLOR(0x30,0x30,0x31));
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.6;
    return l;
}
static MWBPixelButton *YSMButton(NSString *t, CGFloat size) {
    MWBPixelButton *b = [[MWBPixelButton alloc] init];
    [b setAttributedTitle:MWBPixelText(t, MWBPixelFont(size), MWB_COLOR(0xef,0xed,0xeb), 3, 3, MWB_COLOR(0x39,0x36,0x38))
                 forState:UIControlStateNormal];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.minimumScaleFactor = 0.5;
    return b;
}

static UIView *YSMBuildSettings(double pw, NSString *title) {
    sYSMTarget = [MWBYSMMenuTarget new];
    sYSMTarget.refreshers = [NSMutableArray new];
    MWBYSMMenuTarget *tg = sYSMTarget;
    UIView *page = [[UIView alloc] init];
    page.backgroundColor = [UIColor clearColor];
    UILabel *h = [[UILabel alloc] init];
    h.attributedText = MWBPixelText(title, MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea), 4, 4, MWB_COLOR(0x30,0x30,0x31));
    [h sizeToFit];
    h.frame = (CGRect){{58 + 170,4},h.bounds.size}; // 左边留给“返回”
    [page addSubview:h];
    CGFloat y = CGRectGetMaxY(h.frame) + 16, L = 33, W = pw - 66 - 33;
    NSArray *groups = MWBAnimSettings();
    if (!groups.count) {
        UILabel *e = YSMLabel(MWBTr("ysm_none"), 26, MWB_COLOR(0xcf,0xcc,0xc6));
        e.frame = (CGRect){{L,y},{W,60}};
        [page addSubview:e];
        page.frame = (CGRect){{0,0},{pw,y + 80}};
        return page;
    }
    for (NSDictionary *g in groups) {
        UILabel *gl = YSMLabel(g[@"name"] ?: @"", 34, MWB_COLOR(0xf0,0xd8,0x6a));
        gl.frame = (CGRect){{L,y},{W,56}};
        [page addSubview:gl];
        y += 62;
        for (NSDictionary *f in (NSArray *)g[@"forms"]) {
            NSString *type = f[@"type"], *var = f[@"var"];
            if (![var hasPrefix:@"roaming."]) continue;
            NSString *rv = [var substringFromIndex:8];
            const char *rvc = rv.UTF8String;
            NSString *title = [f[@"title"] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@": ：　"]];
            if ([type isEqualToString:@"checkbox"]) {
                UIView *row = [[UIView alloc] initWithFrame:(CGRect){{L,y},{W,77}}];
                UILabel *l = YSMLabel(title, 30, MWB_COLOR(0xcf,0xcc,0xc6));
                l.frame = (CGRect){{0,0},{W - 180,77}};
                MWBPixelToggle *t = [[MWBPixelToggle alloc] init];
                t.frame = (CGRect){{W - 152,0},{152,77}};
                t.on = MWBAnimRoaming(rvc) != 0;
                t.userInteractionEnabled = NO; // 整行可点（同作弊页）
                [row addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:t action:@selector(toggle)]];
                __weak MWBPixelToggle *wt = t;
                YSMOn(t, UIControlEventValueChanged, ^(id s) { MWBAnimSetRoaming(rvc, wt.on ? 1 : 0); [tg refreshAll]; });
                [tg.refreshers addObject:^{ wt.on = MWBAnimRoaming(rvc) != 0; }];
                [row addSubview:l]; [row addSubview:t];
                [page addSubview:row];
                y += 85;
            } else if ([type isEqualToString:@"range"]) {
                float mn = [f[@"min"] floatValue], mx = [f[@"max"] floatValue], st = [f[@"step"] floatValue];
                if (st <= 0) st = (mx - mn) / 10;
                UIView *row = [[UIView alloc] initWithFrame:(CGRect){{L,y},{W,77}}];
                UILabel *l = YSMLabel(title, 30, MWB_COLOR(0xcf,0xcc,0xc6));
                l.frame = (CGRect){{0,0},{W - 330,77}};
                MWBPixelButton *minus = YSMButton(@"－", 30), *plus = YSMButton(@"＋", 30);
                minus.frame = (CGRect){{W - 320,8},{90,60}};
                plus.frame = (CGRect){{W - 90,8},{90,60}};
                UILabel *v = YSMLabel(YSMFmt(MWBAnimRoaming(rvc), st), 30, MWB_COLOR(0x79,0xc0,0xff));
                v.textAlignment = NSTextAlignmentCenter;
                v.frame = (CGRect){{W - 225,0},{130,77}};
                __weak UILabel *wv = v;
                void (^bump)(float) = ^(float d) {
                    float nv = MWBAnimRoaming(rvc) + d;
                    nv = roundf(nv / st) * st;                 // 吸附步长，免浮点累加漂移
                    nv = fminf(mx, fmaxf(mn, nv));
                    MWBAnimSetRoaming(rvc, nv); [tg refreshAll];
                };
                YSMOn(minus, UIControlEventTouchUpInside, ^(id s) { bump(-st); });
                YSMOn(plus, UIControlEventTouchUpInside, ^(id s) { bump(st); });
                [tg.refreshers addObject:^{
                    wv.attributedText = MWBPixelText(YSMFmt(MWBAnimRoaming(rvc), st), MWBPixelFont(30), MWB_COLOR(0x79,0xc0,0xff),
                                                     3, 3, MWB_COLOR(0x30,0x30,0x31));
                    wv.textAlignment = NSTextAlignmentCenter;
                }];
                [row addSubview:l]; [row addSubview:minus]; [row addSubview:v]; [row addSubview:plus];
                [page addSubview:row];
                y += 85;
            } else if ([type isEqualToString:@"radio"]) {
                UILabel *l = YSMLabel(title, 30, MWB_COLOR(0xcf,0xcc,0xc6));
                l.frame = (CGRect){{L,y},{W,60}};
                [page addSubview:l];
                y += 64;
                NSDictionary *labels = f[@"labels"];
                NSArray *keys = [labels.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                    float va = YSMAssignValue(a, var), vb = YSMAssignValue(b, var);
                    return va < vb ? NSOrderedAscending : (va > vb ? NSOrderedDescending : NSOrderedSame);
                }];
                int cols = 4; CGFloat gap = 10, bw = (W - gap * (cols - 1)) / cols;
                for (NSUInteger i = 0; i < keys.count; i++) {
                    NSString *assign = keys[i];
                    float myv = YSMAssignValue(assign, var);
                    MWBPixelButton *b = YSMButton(labels[assign], 26);
                    b.frame = (CGRect){{L + (i % cols) * (bw + gap), y + (i / cols) * 70},{bw,60}};
                    __weak MWBPixelButton *wb = b;
                    YSMOn(b, UIControlEventTouchUpInside, ^(id s) { MWBAnimApplyAssign(assign); [tg refreshAll]; });
                    void (^ref)(void) = ^{ wb.alpha = (MWBAnimRoaming(rvc) == myv) ? 1.0 : 0.45; }; // 选中亮，其余半透明
                    ref();
                    [tg.refreshers addObject:ref];
                    [page addSubview:b];
                }
                y += ((keys.count + cols - 1) / cols) * 70 + 14;
            }
        }
        y += 18;
    }
    page.frame = (CGRect){{0,0},{pw,y}};
    return page;
}

// ---- 橱窗 ----
static NSString *const kYSMDir = @"/var/mobile/Documents/mwbmodels";
// 模型目录：<id>_anim.json 且 <id>.glb 都在才算；名字取 sidecar meta.name（缺省用 id）
static NSArray<NSDictionary *> *YSMModelList(void) {
    static NSArray *sList = nil;
    if (sList) return sList;
    NSMutableArray *out = [NSMutableArray new];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *f in [[fm contentsOfDirectoryAtPath:kYSMDir error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![f hasSuffix:@"_anim.json"]) continue;
        NSString *mid = [f substringToIndex:f.length - 10];
        if (![fm fileExistsAtPath:[kYSMDir stringByAppendingFormat:@"/%@.glb", mid]]) continue;
        NSData *d = [NSData dataWithContentsOfFile:[kYSMDir stringByAppendingPathComponent:f]];
        NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSString *name = [j isKindOfClass:[NSDictionary class]] ? j[@"meta"][@"name"] : nil;
        [out addObject:@{@"id": mid, @"name": name.length ? name : mid}];
    }
    sList = out;
    return sList;
}
// 精灵条切帧（横排，帧宽 = 高 × 128/160）
static NSArray<UIImage *> *YSMSlice(NSString *path) {
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (!img.CGImage) return nil;
    size_t h = CGImageGetHeight(img.CGImage), w = h * 128 / 160, n = w ? CGImageGetWidth(img.CGImage) / w : 0;
    NSMutableArray *fr = [NSMutableArray new];
    for (size_t i = 0; i < n; i++) {
        CGImageRef c = CGImageCreateWithImageInRect(img.CGImage, (CGRect){{(CGFloat)(i * w), 0}, {(CGFloat)w, (CGFloat)h}});
        if (c) { [fr addObject:[UIImage imageWithCGImage:c]]; CGImageRelease(c); }
    }
    return fr;
}
// 卡片动画：开门段播一次（12fps）→ 循环段（8fps）
static void YSMPlayCard(UIImageView *iv, NSString *mid) {
    NSArray *intro = YSMSlice([kYSMDir stringByAppendingFormat:@"/%@_thumb_intro.png", mid]);
    NSArray *loop = YSMSlice([kYSMDir stringByAppendingFormat:@"/%@_thumb_loop.png", mid]);
    [iv stopAnimating];
    if (!intro.count && !loop.count) return;
    __weak UIImageView *w = iv;
    void (^startLoop)(void) = ^{
        if (!w || !loop.count) return;
        w.image = loop.firstObject;
        w.animationImages = loop; w.animationDuration = loop.count / 8.0; w.animationRepeatCount = 0;
        [w startAnimating];
    };
    if (!intro.count) { startLoop(); return; }
    iv.image = loop.count ? loop.firstObject : intro.lastObject; // 播完停在循环段首帧，不闪回关门
    iv.animationImages = intro; iv.animationDuration = intro.count / 12.0; iv.animationRepeatCount = 1;
    [iv startAnimating];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(intro.count / 12.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), startLoop);
}
// 子视图切换后同步外层页高与滚动区
static void YSMFit(UIView *page, UIView *shown) {
    CGRect f = page.frame; f.size.height = shown.frame.size.height; page.frame = f;
    UIScrollView *sc = [page.superview isKindOfClass:[UIScrollView class]] ? (UIScrollView *)page.superview : nil;
    if (sc) { sc.contentSize = f.size; sc.contentOffset = CGPointZero; }
}

UIView *MWBBuildYSMPage(double pw) {
    UIView *page = [[UIView alloc] initWithFrame:(CGRect){{0,0},{pw,100}}];
    page.backgroundColor = [UIColor clearColor];
    UIView *picker = [[UIView alloc] initWithFrame:page.bounds];
    [page addSubview:picker];
    UILabel *h = [[UILabel alloc] init];
    h.attributedText = MWBPixelText(MWBTr("ysm_models"), MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea), 4, 4, MWB_COLOR(0x30,0x30,0x31));
    [h sizeToFit];
    h.frame = (CGRect){{58,4},h.bounds.size};
    [picker addSubview:h];
    NSArray *models = YSMModelList();
    const int cols = 5, rows = 2, per = cols * rows;
    CGFloat L = 33, W = pw - 66, gap = 22, cw = (W - gap * (cols - 1)) / cols, ch = cw * 160 / 128, nameH = 44;
    CGFloat top = CGRectGetMaxY(h.frame) + 18;
    CGFloat gridH = rows * (ch + nameH + gap);
    UIView *grid = [[UIView alloc] initWithFrame:(CGRect){{L, top}, {W, gridH}}];
    [picker addSubview:grid];
    UILabel *pageLbl = YSMLabel(@"", 30, MWB_COLOR(0xcf,0xcc,0xc6));
    pageLbl.textAlignment = NSTextAlignmentCenter;
    __block int pg = 0;
    int pages = MAX(1, ((int)models.count + per - 1) / per);
    void (^fill)(void);
    __block __weak void (^wfill)(void) = nil; // 卡片里回调自身用弱引用（防循环引用）
    __weak UIView *wgrid = grid;
    __weak UILabel *wpl = pageLbl;
    fill = ^{
        UIView *gv = wgrid; if (!gv) return;
        for (UIView *v in [gv.subviews copy]) [v removeFromSuperview];
        NSString *cur = MWBGLBModelId();
        for (int k = 0; k < per; k++) {
            int idx = pg * per + k; if (idx >= (int)models.count) break;
            NSDictionary *m = models[idx];
            CGFloat x = (k % cols) * (cw + gap), y = (k / cols) * (ch + nameH + gap);
            UIControl *card = [[UIControl alloc] initWithFrame:(CGRect){{x, y}, {cw, ch}}];
            BOOL sel = [m[@"id"] isEqualToString:cur] && (gSkin4D || gGLBModel);
            card.backgroundColor = MWB_COLOR(0x3a,0x3a,0x3c);
            card.layer.borderWidth = sel ? 6 : 3;
            card.layer.borderColor = (sel ? MWB_COLOR(0x8c,0xc4,0xf2) : MWB_COLOR(0x5a,0x5a,0x5e)).CGColor;
            UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectInset(card.bounds, 6, 6)];
            iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.layer.magnificationFilter = kCAFilterNearest;
            iv.userInteractionEnabled = NO;
            [card addSubview:iv];
            YSMPlayCard(iv, m[@"id"]);
            NSString *mid = m[@"id"];
            YSMOn(card, UIControlEventTouchUpInside, ^(id s) {
                if (!MWB010Only()) return;
                MWBGLBSetModel(mid);
                gSkin4D = YES; gGLBModel = YES;
                MWBGLBEnsureParsed();
                MWBPlayClick();
                if (wfill) wfill(); // 重画选中框＋重播开门
            });
            [gv addSubview:card];
            UILabel *nm = YSMLabel(m[@"name"], 26, MWB_COLOR(0xe6,0xe3,0xde));
            nm.textAlignment = NSTextAlignmentCenter;
            nm.frame = (CGRect){{x, y + ch + 4}, {cw, nameH - 6}};
            [gv addSubview:nm];
        }
        UILabel *pl = wpl;
        pl.attributedText = MWBPixelText([NSString stringWithFormat:@"%d/%d", pg + 1, pages], MWBPixelFont(30),
                                         MWB_COLOR(0xcf,0xcc,0xc6), 3, 3, MWB_COLOR(0x30,0x30,0x31));
        pl.textAlignment = NSTextAlignmentCenter;
    };
    wfill = fill;
    objc_setAssociatedObject(page, &kYSMDir, fill, OBJC_ASSOCIATION_COPY_NONATOMIC); // 页面持有 fill
    if (!models.count) {
        UILabel *e = YSMLabel(MWBTr("ysm_none"), 26, MWB_COLOR(0xcf,0xcc,0xc6));
        e.frame = (CGRect){{0,0},{W,60}};
        [grid addSubview:e];
    }
    // 底栏：前一页 / 页码 / 后一页 / 设置
    CGFloat by = top + gridH + 6, bw = 200, bh = 64;
    MWBPixelButton *prev = YSMButton(MWBTr("ysm_prev"), 28), *next = YSMButton(MWBTr("ysm_next"), 28), *set = YSMButton(MWBTr("ysm_set"), 28);
    CGFloat bx = L + (W - (bw * 3 + 160 + 40)) / 2;
    prev.frame = (CGRect){{bx, by}, {bw, bh}};
    pageLbl.frame = (CGRect){{bx + bw, by}, {160, bh}};
    next.frame = (CGRect){{bx + bw + 160, by}, {bw, bh}};
    set.frame = (CGRect){{bx + bw * 2 + 160 + 40, by}, {bw, bh}};
    for (UIView *v in @[prev, pageLbl, next, set]) [picker addSubview:v];
    YSMOn(prev, UIControlEventTouchUpInside, ^(id s) { if (pg > 0) { pg--; fill(); } });
    YSMOn(next, UIControlEventTouchUpInside, ^(id s) { if (pg + 1 < pages) { pg++; fill(); } });
    if (models.count) fill(); else wpl.text = @"1/1";
    picker.frame = (CGRect){{0,0},{pw, by + bh + 20}};
    page.frame = picker.frame;
    // 设置子页：点“设置”现建（取当前模型的 settings），“返回”回橱窗
    __weak UIView *wpage = page, *wpicker = picker;
    YSMOn(set, UIControlEventTouchUpInside, ^(id s) {
        UIView *pv = wpage; if (!pv) return;
        NSString *mid = MWBGLBModelId(), *name = mid;
        for (NSDictionary *m in models) if ([m[@"id"] isEqualToString:mid]) name = m[@"name"];
        UIView *sv = YSMBuildSettings(pw, [NSString stringWithFormat:@"%@ · %@", MWBTr("ysm"), name]);
        MWBPixelButton *back = YSMButton(MWBTr("ysm_back"), 28);
        back.frame = (CGRect){{33, 6}, {170, 60}};
        [sv addSubview:back];
        __weak UIView *wsv = sv;
        YSMOn(back, UIControlEventTouchUpInside, ^(id s2) {
            [wsv removeFromSuperview];
            wpicker.hidden = NO;
            YSMFit(wpage, wpicker);
            fill();
        });
        wpicker.hidden = YES;
        [pv addSubview:sv];
        YSMFit(pv, sv);
    });
    return page;
}
