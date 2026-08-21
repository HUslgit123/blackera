/*
 * BlackEra_Mod_v3.dylib — 《黑色纪元》修改器 (面板布局与动态Hook终极修复版)
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <time.h>

#pragma mark - ============ 全局状态与日志 ============

static BOOL g_intercept_announce = YES;
static BOOL g_feature6_enabled   = NO;

static NSMutableArray *g_logs     = nil;
static UITextView     *g_logView  = nil;
static BOOL           g_hudVisible = NO;
static UIView         *g_panelView = nil;

static NSString *Timestamp(void) {
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    char buf[32];
    strftime(buf, sizeof buf, "%H:%M:%S", &tmv);
    return [NSString stringWithUTF8String:buf];
}

static void AddLog(NSString *msg) {
    if (!g_logs) g_logs = [NSMutableArray arrayWithCapacity:100];
    
    NSString *full = [NSString stringWithFormat:@"%@ %@", Timestamp(), msg];
    [g_logs addObject:full];
    while (g_logs.count > 100) [g_logs removeObjectAtIndex:0];
    
    NSLog(@"[BlackEra] %@", full);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_logView || !g_hudVisible) return;
        
        NSMutableString *all = [NSMutableString string];
        for (NSString *line in g_logs) {
            [all appendString:line];
            [all appendString:@"\n"];
        }
        g_logView.text = all;
        
        if (all.length > 0) {
            NSRange end = NSMakeRange(all.length - 1, 1);
            [g_logView scrollRangeToVisible:end];
        }
    });
}

#pragma mark - ============ 混淆穿透与方法查找引擎 ============

static Method FindMethodContains(Class cls, NSString *keyword) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *selName = NSStringFromSelector(sel);
        if ([selName rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            Method m = methods[i];
            free(methods);
            return m;
        }
    }
    if (methods) free(methods);
    
    // Check superclass
    Class superCls = class_getSuperclass(cls);
    if (superCls && superCls != [NSObject class]) {
        return FindMethodContains(superCls, keyword);
    }
    return NULL;
}

static id GetVCByKeyword(NSString *keyword) {
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *w in windows) {
        NSMutableArray *toCheck = [NSMutableArray arrayWithObject:w.rootViewController];
        while (toCheck.count > 0) {
            UIViewController *vc = [toCheck lastObject];
            [toCheck removeLastObject];
            if (!vc) continue;
            
            NSString *clsName = NSStringFromClass([vc class]);
            if ([clsName rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                AddLog([NSString stringWithFormat:@"[✓] 捕获界面实例: %@", clsName]);
                return vc;
            }
            
            if ([vc isKindOfClass:[UINavigationController class]]) {
                [toCheck addObjectsFromArray:((UINavigationController *)vc).viewControllers];
            } else if ([vc isKindOfClass:[UITabBarController class]]) {
                UITabBarController *tab = (UITabBarController *)vc;
                if (tab.viewControllers) [toCheck addObjectsFromArray:tab.viewControllers];
            }
            if (vc.childViewControllers.count > 0) [toCheck addObjectsFromArray:vc.childViewControllers];
            if (vc.presentedViewController) [toCheck addObject:vc.presentedViewController];
        }
    }
    return nil;
}

#pragma mark - ============ 广播拦截 Hook (动态模糊匹配) ============

static IMP orig_bcloud_callFunc_IMP = NULL;
static void BE_Bcloud_CallFunc(id self, SEL _cmd, NSString *functionName, NSDictionary *params, void (^block)(id result, NSError *error)) {
    if (g_intercept_announce && functionName) {
        if ([functionName rangeOfString:@"Send" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [functionName rangeOfString:@"system" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [functionName rangeOfString:@"message" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            AddLog([NSString stringWithFormat:@"[🛡️] 已阻断云端广播: %@", functionName]);
            if (block) block(@[@"success"], nil);
            return;
        }
    }
    if (orig_bcloud_callFunc_IMP) {
        ((void (*)(id, SEL, NSString *, NSDictionary *, void (^)(id, NSError *)))orig_bcloud_callFunc_IMP)(self, _cmd, functionName, params, block);
    }
}

static IMP orig_sendEvent_IMP = NULL;
static void BE_SocketIO_SendEvent(id self, SEL _cmd, NSString *event, id data) {
    if (g_intercept_announce && event) {
        if ([event rangeOfString:@"announce" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [event rangeOfString:@"broadcast" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [event rangeOfString:@"system" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            AddLog([NSString stringWithFormat:@"[🛡️] 已阻断Socket广播: %@", event]);
            return;
        }
    }
    if (orig_sendEvent_IMP) {
        ((void (*)(id, SEL, NSString *, id))orig_sendEvent_IMP)(self, _cmd, event, data);
    }
}

#pragma mark - ============ 业务控制器 ============

@interface ModManager : NSObject
+ (instancetype)shared;
- (void)claimSpiritStonesLoop;
- (void)triggerMakeActions;
- (void)triggerPetRebirth;
- (void)triggerFeature6;
@end

@implementation ModManager

+ (instancetype)shared {
    static ModManager *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [[ModManager alloc] init]; });
    return inst;
}

- (void)claimSpiritStonesLoop {
    AddLog(@"[💎] 正在扫描领灵石目标...");
    id targetVC = GetVCByKeyword(@"Option") ?: GetVCByKeyword(@"Shop");
    
    if (!targetVC) {
        AddLog(@"[❌] 提示: 请先在游戏中切换到【设置】或【商城】界面！");
        return;
    }
    
    Method m = FindMethodContains([targetVC class], @"rewardVideoAdDidRewardEffective");
    if (!m) m = FindMethodContains([targetVC class], @"reward");
    
    if (!m) {
        AddLog(@"[❌] 未找到广告发奖方法");
        return;
    }
    
    SEL sel = method_getName(m);
    AddLog([NSString stringWithFormat:@"[💎] 准备开始刷灵石: 0.3s/次 x 20次 (方法: %@)", NSStringFromSelector(sel)]);
    
    __weak id weakVC = targetVC;
    for (int i = 0; i < 20; i++) {
        int idx = i;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(idx * 0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id strongVC = weakVC;
            if (!strongVC) return;
            @try {
                ((void (*)(id, SEL, id, id))objc_msgSend)(strongVC, sel, nil, nil);
            } @catch (...) {
                @try { ((void (*)(id, SEL, id))objc_msgSend)(strongVC, sel, nil); } @catch (...) {}
            }
            AddLog([NSString stringWithFormat:@"[✓] 灵石发放第 %d/20 次", idx + 1]);
        });
    }
}

- (void)triggerMakeActions {
    AddLog(@"[⚒️] 正在扫描制造/炼器界面...");
    id targetVC = GetVCByKeyword(@"Make") ?: GetVCByKeyword(@"Forge") ?: GetVCByKeyword(@"Equipment");
    if (!targetVC) {
        AddLog(@"[❌] 提示: 请先进入【制造/炼器/装备】界面！");
        return;
    }
    
    Method m = FindMethodContains([targetVC class], @"clickMakeButton") ?: FindMethodContains([targetVC class], @"clickButton");
    if (!m) {
        AddLog(@"[❌] 未找到制造交互方法");
        return;
    }
    
    SEL sel = method_getName(m);
    UIButton *fakeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    ((void (*)(id, SEL, id))objc_msgSend)(targetVC, sel, fakeBtn);
    AddLog([NSString stringWithFormat:@"[⚒️] 已触发制造接口: %@", NSStringFromSelector(sel)]);
}

- (void)triggerPetRebirth {
    AddLog(@"[🐾] 正在扫描灵宠界面...");
    id targetVC = GetVCByKeyword(@"Pet") ?: GetVCByKeyword(@"Lingchong") ?: GetVCByKeyword(@"SpiritBeast");
    if (!targetVC) {
        AddLog(@"[❌] 提示: 请先进入【灵宠】界面！");
        return;
    }
    
    Method m = FindMethodContains([targetVC class], @"clickWashButton") ?: FindMethodContains([targetVC class], @"clickButton");
    if (!m) {
        AddLog(@"[❌] 未找到灵宠洗练方法");
        return;
    }
    
    SEL sel = method_getName(m);
    UIButton *fakeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    ((void (*)(id, SEL, id))objc_msgSend)(targetVC, sel, fakeBtn);
    AddLog([NSString stringWithFormat:@"[🐾] 已触发灵宠洗练: %@", NSStringFromSelector(sel)]);
}

- (void)triggerFeature6 {
    if (!g_feature6_enabled) {
        AddLog(@"[⚠️] 请先在控制台中将【GM全装注入开关】点成已开启！");
        return;
    }
    AddLog(@"[🎁] 正在扫描背包界面...");
    id bagVC = GetVCByKeyword(@"Bag") ?: GetVCByKeyword(@"Inventory");
    if (!bagVC) {
        AddLog(@"[❌] 提示: 请先进入【背包】界面！");
        return;
    }
    
    Method m = FindMethodContains([bagVC class], @"clickCZButton") ?: FindMethodContains([bagVC class], @"clickGMButton");
    if (!m) {
        AddLog(@"[❌] 背包中未找到GM/CZ按钮接口");
        return;
    }
    
    SEL sel = method_getName(m);
    UIButton *fakeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    ((void (*)(id, SEL, id))objc_msgSend)(bagVC, sel, fakeBtn);
    AddLog([NSString stringWithFormat:@"[🎁] 已触发背包注入接口: %@", NSStringFromSelector(sel)]);
}

@end

#pragma mark - ============ 穿透 Overlay 窗口 ============

@interface BEOverlayWindow : UIWindow
@end

@implementation BEOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) return nil;
    return hitView;
}
@end

#pragma mark - ============ 悬浮 UI 控制台 ============

@interface FloatingMenuUI : NSObject
+ (void)showFloatingBall;
@end

@implementation FloatingMenuUI

static BEOverlayWindow *s_win = nil;
static UIButton *s_ball = nil;

+ (void)showFloatingBall {
    if (s_win) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect bounds = [UIScreen mainScreen].bounds;
        UIWindowScene *activeScene = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                    activeScene = (UIWindowScene *)scene;
                    break;
                }
            }
        }
        
        s_win = activeScene ? [[BEOverlayWindow alloc] initWithWindowScene:activeScene] : [[BEOverlayWindow alloc] initWithFrame:bounds];
        s_win.windowLevel = UIWindowLevelAlert + 100;
        s_win.backgroundColor = [UIColor clearColor];
        
        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        s_win.rootViewController = rootVC;
        
        // 悬浮球
        s_ball = [UIButton buttonWithType:UIButtonTypeCustom];
        s_ball.frame = CGRectMake(15, bounds.size.height - 140, 56, 56);
        s_ball.backgroundColor = [UIColor colorWithRed:0.0 green:0.75 blue:0.1 alpha:0.9];
        s_ball.layer.cornerRadius = 28;
        s_ball.layer.borderWidth = 2.0;
        s_ball.layer.borderColor = [UIColor whiteColor].CGColor;
        [s_ball setTitle:@"作弊" forState:UIControlStateNormal];
        s_ball.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [s_ball addGestureRecognizer:pan];
        
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)];
        [tap requireGestureRecognizerToFail:pan];
        [s_ball addGestureRecognizer:tap];
        
        [rootVC.view addSubview:s_ball];
        
        // 控制面板
        [self buildPanel:rootVC.view bounds:bounds];
        
        // 日志视图
        g_logView = [[UITextView alloc] initWithFrame:CGRectMake(bounds.size.width - 250, 40, 240, 160)];
        g_logView.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
        g_logView.textColor = [UIColor colorWithRed:0.1 green:1.0 blue:0.3 alpha:1.0];
        g_logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
        g_logView.layer.cornerRadius = 6;
        g_logView.editable = NO;
        g_logView.hidden = YES;
        [rootVC.view addSubview:g_logView];
        
        s_win.hidden = NO;
        [s_win makeKeyAndVisible];
        AddLog(@"[✓] 控制台挂载成功");
    });
}

+ (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *superview = s_ball.superview;
    CGPoint trans = [pan translationInView:superview];
    CGFloat newX = fmaxf(28, fminf(s_ball.center.x + trans.x, superview.bounds.size.width - 28));
    CGFloat newY = fmaxf(28, fminf(s_ball.center.y + trans.y, superview.bounds.size.height - 28));
    s_ball.center = CGPointMake(newX, newY);
    [pan setTranslation:CGPointMake(0, 0) inView:superview];
}

+ (void)buildPanel:(UIView *)parent bounds:(CGRect)bounds {
    CGFloat w = MIN(320, bounds.size.width - 40);
    CGFloat h = 400;
    
    g_panelView = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width - w) / 2, (bounds.size.height - h) / 2, w, h)];
    g_panelView.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.16 alpha:0.97];
    g_panelView.layer.cornerRadius = 14;
    g_panelView.layer.borderWidth = 1.5;
    g_panelView.layer.borderColor = [UIColor colorWithRed:0.0 green:0.85 blue:0.25 alpha:0.8].CGColor;
    g_panelView.hidden = YES; // 默认隐藏
    
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, w - 24, 24)];
    lbl.text = @"⚡ 修仙修改器控制台 ⚡";
    lbl.textColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.3 alpha:1.0];
    lbl.font = [UIFont boldSystemFontOfSize:15];
    lbl.textAlignment = NSTextAlignmentCenter;
    [g_panelView addSubview:lbl];
    
    // 增加高度，确保 ScrollView 内部所有 7 个按钮都能完整显示且不被截断
    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(8, 40, w - 16, h - 90)];
    sv.showsVerticalScrollIndicator = YES;
    
    CGFloat y = 4, bh = 40, spacing = 8, bw = w - 24;
    
    NSArray *titles = @[
        @"💎 领灵石 x20 (设置/商城点)",
        @"⚒️ 炼丹/炼器 (制造界面点)",
        @"🐾 灵宠洗练 (灵宠界面点)",
        @"⚙️ GM全装注入:【已关闭】",
        @"🎁 一键注入全装备 (背包点)",
        @"🔇 全服公告拦截:【已开启】",
        @"📊 切换 HUD 实时日志"
    ];
    
    NSArray *colors = @[
        [UIColor colorWithRed:0.15 green:0.35 blue:0.75 alpha:1.0],
        [UIColor colorWithRed:0.18 green:0.55 blue:0.35 alpha:1.0],
        [UIColor colorWithRed:0.45 green:0.25 blue:0.65 alpha:1.0],
        [UIColor colorWithRed:0.28 green:0.28 blue:0.35 alpha:1.0],
        [UIColor colorWithRed:0.75 green:0.20 blue:0.18 alpha:1.0],
        [UIColor colorWithRed:0.20 green:0.45 blue:0.30 alpha:1.0],
        [UIColor colorWithRed:0.30 g_color_placeholder:0.30 alpha:1.0] // fallback
    ];
    
    NSArray *actions = @[
        NSStringFromSelector(@selector(clickClaim)),
        NSStringFromSelector(@selector(clickMake)),
        NSStringFromSelector(@selector(clickPet)),
        NSStringFromSelector(@selector(clickToggleF6:)),
        NSStringFromSelector(@selector(clickInject)),
        NSStringFromSelector(@selector(clickToggleAnnounce:)),
        NSStringFromSelector(@selector(clickToggleHUD))
    ];
    
    for (int i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, y, bw, bh);
        b.backgroundColor = (i == 6) ? [UIColor colorWithRed:0.35 green:0.35 blue:0.4 alpha:1.0] : colors[i];
        b.layer.cornerRadius = 7;
        b.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        
        SEL act = NSSelectorFromString(actions[i]);
        [b addTarget:self action:act forControlEvents:UIControlEventTouchUpInside];
        [sv addSubview:b];
        y += bh + spacing;
    }
    
    sv.contentSize = CGSizeMake(bw, y + 10);
    [g_panelView addSubview:sv];
    
    UIButton *close = [UIButton buttonWithType:UIButtonTypeCustom];
    close.frame = CGRectMake(12, h - 42, w - 24, 32);
    close.backgroundColor = [UIColor colorWithRed:0.18 green:0.18 blue:0.22 alpha:1.0];
    close.layer.cornerRadius = 6;
    [close setTitle:@"✕ 收起控制台" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    [close addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [g_panelView addSubview:close];
    
    [parent addSubview:g_panelView];
}

+ (void)togglePanel {
    if (!g_panelView) return;
    g_panelView.hidden = !g_panelView.hidden;
    s_ball.alpha = g_panelView.hidden ? 1.0 : 0.6;
}

+ (void)clickClaim { [[ModManager shared] claimSpiritStonesLoop]; }
+ (void)clickMake { [[ModManager shared] triggerMakeActions]; }
+ (void)clickPet { [[ModManager shared] triggerPetRebirth]; }
+ (void)clickInject { [[ModManager shared] triggerFeature6]; }
+ (void)clickToggleHUD {
    g_hudVisible = !g_hudVisible;
    if (g_logView) g_logView.hidden = !g_hudVisible;
}

+ (void)clickToggleF6:(UIButton *)btn {
    g_feature6_enabled = !g_feature6_enabled;
    [btn setTitle:g_feature6_enabled ? @"⚙️ GM全装注入:【已开启】" : @"⚙️ GM全装注入:【已关闭】" forState:UIControlStateNormal];
    btn.backgroundColor = g_feature6_enabled ? [UIColor colorWithRed:0.1 green:0.55 blue:0.2 alpha:1.0] : [UIColor colorWithRed:0.28 green:0.28 blue:0.35 alpha:1.0];
    AddLog(g_feature6_enabled ? @"[⚙️] 功能六已开启" : @"[⚙️] 功能六已关闭");
}

+ (void)clickToggleAnnounce:(UIButton *)btn {
    g_intercept_announce = !g_intercept_announce;
    [btn setTitle:g_intercept_announce ? @"🔇 全服公告拦截:【已开启】" : @"🔊 全服公告拦截:【已关闭】" forState:UIControlStateNormal];
    AddLog(g_intercept_announce ? @"[🛡️] 公告拦截已开启" : @"[🛡️] 公告拦截已关闭");
}

@end

#pragma mark - ============ 构造器入口 ============

__attribute__((constructor))
static void BlackEraModMain(void) {
    @autoreleasepool {
        AddLog(@"[INIT] BlackEra Mod 正在挂载Hook...");
        
        Class bcloudClass = objc_getClass("BmobCloud");
        if (bcloudClass) {
            Method m = FindMethodContains(bcloudClass, @"callFunction");
            if (m) {
                orig_bcloud_callFunc_IMP = method_setImplementation(m, (IMP)BE_Bcloud_CallFunc);
                AddLog(@"[✓] BmobCloud 拦截挂载成功");
            }
        }
        
        Class socketClass = objc_getClass("BmobSocketIO");
        if (!socketClass) socketClass = objc_getClass("SocketManager");
        if (socketClass) {
            Method m2 = FindMethodContains(socketClass, @"sendEvent");
            if (m2) {
                orig_sendEvent_IMP = method_setImplementation(m2, (IMP)BE_SocketIO_SendEvent);
                AddLog(@"[✓] SocketIO 拦截挂载成功");
            }
        }
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [FloatingMenuUI showFloatingBall];
        });
    }
}
