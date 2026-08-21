#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <time.h>

#pragma mark - ============ 全局状态与开关 ============

static BOOL g_intercept_announce  = YES; // 默认开启公告拦截
static BOOL g_feature6_enabled    = NO;  // 功能六独立开关

static NSMutableArray *g_logs     = nil;
static UITextView     *g_logView  = nil;
static BOOL           g_hudVisible= NO;
static UIView         *g_panelView= nil;

#pragma mark - ============ 日志系统 ============

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
    if (g_logs.count > 100) [g_logs removeObjectsInRange:NSMakeRange(0, g_logs.count - 100)];
    
    NSLog(@"[BlackEra] %@", full);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_logView || !g_hudVisible) return;
        NSMutableString *all = [NSMutableString string];
        for (NSString *line in g_logs) {
            [all appendString:line];
            [all appendString:@"\n"];
        }
        g_logView.text = all;
        NSRange end = NSMakeRange(MAX(0, (NSInteger)all.length - 1), 1);
        [g_logView scrollRangeToVisible:end];
    });
}

#pragma mark - ============ 辅助：遍历查找当前活跃的 ViewController ============

static id FindVC(Class targetClass, UIViewController *root) {
    if (!root || !targetClass) return nil;
    if ([root isKindOfClass:targetClass]) return root;
    
    if ([root isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)root;
        for (UIViewController *vc in nav.viewControllers) {
            id found = FindVC(targetClass, vc);
            if (found) return found;
        }
    }
    
    if ([root isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tab = (UITabBarController *)root;
        for (UIViewController *vc in tab.viewControllers) {
            id found = FindVC(targetClass, vc);
            if (found) return found;
        }
    }
    
    for (UIViewController *child in root.childViewControllers) {
        id found = FindVC(targetClass, child);
        if (found) return found;
    }
    
    if (root.presentedViewController) {
        id found = FindVC(targetClass, root.presentedViewController);
        if (found) return found;
    }
    
    return nil;
}

static id GetActiveVC(const char *className) {
    Class cls = objc_getClass(className);
    if (!cls) return nil;
    
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        id found = FindVC(cls, w.rootViewController);
        if (found) return found;
    }
    return nil;
}

#pragma mark - ============ 功能一：绝对拦截所有上报公告 ============

static IMP orig_bcloud_callFunc_IMP = NULL;
static void BE_Bcloud_CallFunc(id self, SEL _cmd, NSString *functionName, NSDictionary *params, void (^block)(id result, NSError *error)) {
    if (g_intercept_announce && functionName && 
       ([functionName rangeOfString:@"SendSystemMessage" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [functionName rangeOfString:@"system" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        AddLog(@"[🛡️公告已拦截] 已阻断向全服发送系统广播");
        if (block) block(@[@"success"], nil); // 伪造成功回调防止挂起
        return;
    }
    if (orig_bcloud_callFunc_IMP) {
        ((void (*)(id, SEL, NSString *, NSDictionary *, id))orig_bcloud_callFunc_IMP)(self, _cmd, functionName, params, block);
    }
}

static IMP orig_sendEvent_IMP = NULL;
static void BE_SocketIO_SendEvent(id self, SEL _cmd, NSString *event, id data) {
    if (g_intercept_announce && event && 
       ([event rangeOfString:@"announce" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [event rangeOfString:@"broadcast" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        AddLog([NSString stringWithFormat:@"[🛡️公告已拦截] Socket 广播: %@", event]);
        return;
    }
    if (orig_sendEvent_IMP) {
        ((void (*)(id, SEL, NSString *, id))orig_sendEvent_IMP)(self, _cmd, event, data);
    }
}

#pragma mark - ============ 核心业务安全调度类 ============

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

// 功能二：0.5 秒间隔领取灵石 x 20 次
- (void)claimSpiritStonesLoop {
    @try {
        id optVC = GetActiveVC("OptionViewController") ?: GetActiveVC("ShopViewController");
        if (!optVC) {
            AddLog(@"[⚠️] 请先在游戏中打开【设置】或【商城】界面后再点击！");
            return;
        }
        
        SEL sel1 = @selector(gdt_rewardVideoAdDidRewardEffective:info:);
        SEL sel2 = @selector(gdt_rewardVideoAdDidRewardEffective:);
        SEL targetSel = [optVC respondsToSelector:sel1] ? sel1 : ([optVC respondsToSelector:sel2] ? sel2 : nil);
        
        if (!targetSel) {
            AddLog(@"[❌] 当前界面未找到发奖回调接口！");
            return;
        }
        
        AddLog(@"[💎] 启动免看广告领灵石: 0.5s/次 x 20次");
        for (int i = 0; i < 20; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try {
                    if (targetSel == sel1) {
                        ((void (*)(id, SEL, id, id))objc_msgSend)(optVC, targetSel, nil, nil);
                    } else {
                        ((void (*)(id, SEL, id))objc_msgSend)(optVC, targetSel, nil);
                    }
                    AddLog([NSString stringWithFormat:@"[✓] 灵石到账第 %d/20 次 (+20 灵石)", i + 1]);
                } @catch (NSException *e) {
                    AddLog([NSString stringWithFormat:@"[❌] 发奖异常: %@", e.reason]);
                }
            });
        }
    } @catch (NSException *e) {
        AddLog([NSString stringWithFormat:@"[❌] 异常: %@", e.reason]);
    }
}

// 功能三与四：制造与强化
- (void)triggerMakeActions {
    @try {
        id makeVC = GetActiveVC("MakeViewController");
        if (!makeVC) {
            AddLog(@"[⚠️] 请先在游戏中打开【制造/炼器/炼丹】界面！");
            return;
        }
        
        // 触发制造点击
        SEL sel = @selector(clickButtonWithButton:);
        if ([makeVC respondsToSelector:sel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(makeVC, sel, nil);
            AddLog(@"[⚒️] 已触发制造/强化核心处理！");
        } else {
            AddLog(@"[❌] 未找到制造交互接口！");
        }
    } @catch (NSException *e) {
        AddLog([NSString stringWithFormat:@"[❌] 制造异常: %@", e.reason]);
    }
}

// 功能五：灵宠洗练与资质重置
- (void)triggerPetRebirth {
    @try {
        id petVC = GetActiveVC("PetViewController") ?: GetActiveVC("LingchongViewController");
        if (!petVC) {
            AddLog(@"[⚠️] 请先在游戏中打开【灵宠】界面！");
            return;
        }
        
        SEL sel = @selector(clickButtonWith_button:);
        if (![petVC respondsToSelector:sel]) {
            sel = @selector(clickButtonWithButton:);
        }
        
        if ([petVC respondsToSelector:sel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(petVC, sel, nil);
            AddLog(@"[🐾] 已向灵宠控制器发送免费洗练/突破指令！");
        } else {
            AddLog(@"[❌] 未找到灵宠交互接口！");
        }
    } @catch (NSException *e) {
        AddLog([NSString stringWithFormat:@"[❌] 灵宠异常: %@", e.reason]);
    }
}

// 功能六：GM全装备材料注入
- (void)triggerFeature6 {
    @try {
        if (!g_feature6_enabled) {
            AddLog(@"[⚠️] 功能六当前处于关闭状态，请先点击上方按钮开启！");
            return;
        }
        
        id bagVC = GetActiveVC("BagViewController");
        if (!bagVC) {
            AddLog(@"[⚠️] 请先在游戏中打开【背包】界面后再点击！");
            return;
        }
        
        // 优先触发 CZ 充值调试 / GM 按钮
        SEL czSel = @selector(clickCZButtonWithButton:);
        SEL gmSel = @selector(clickGMButtonWithButton:);
        
        if ([bagVC respondsToSelector:czSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(bagVC, czSel, nil);
            AddLog(@"[🎁] 已触发背包 CZ 充值与全装备注入！");
        } else if ([bagVC respondsToSelector:gmSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(bagVC, gmSel, nil);
            AddLog(@"[🎁] 已触发背包 GM 调试菜单！");
        } else {
            AddLog(@"[❌] 背包控制器中未找到调试方法！");
        }
    } @catch (NSException *e) {
        AddLog([NSString stringWithFormat:@"[❌] GM注入异常: %@", e.reason]);
    }
}

@end

#pragma mark - ============ 自定义点击穿透 UIWindow ============

@interface BEOverlayWindow : UIWindow
@end

@implementation BEOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil; // 点击空白区域穿透到游戏
    }
    return hitView;
}
@end

#pragma mark - ============ 原生暗黑风格悬浮控制台 ============

@interface FloatingMenuUI : NSObject
@end

@implementation FloatingMenuUI

static BEOverlayWindow *s_overlayWin = nil;
static UIButton *s_floatBall = nil;

+ (void)showFloatingBall {
    if (s_overlayWin) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *activeScene = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                    activeScene = (UIWindowScene *)scene;
                    break;
                }
            }
        }

        CGRect screenBounds = [UIScreen mainScreen].bounds;
        if (activeScene) {
            s_overlayWin = [[BEOverlayWindow alloc] initWithWindowScene:activeScene];
            s_overlayWin.frame = screenBounds;
        } else {
            s_overlayWin = [[BEOverlayWindow alloc] initWithFrame:screenBounds];
        }

        s_overlayWin.windowLevel = UIWindowLevelAlert + 100;
        s_overlayWin.backgroundColor = [UIColor clearColor];
        
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        s_overlayWin.rootViewController = vc;
        
        // 悬浮球 (左下角，支持拖拽)
        s_floatBall = [UIButton buttonWithType:UIButtonTypeCustom];
        s_floatBall.frame = CGRectMake(15, screenBounds.size.height - 140, 56, 56);
        s_floatBall.backgroundColor = [UIColor colorWithRed:0.0 green:0.75 blue:0.1 alpha:0.9];
        s_floatBall.layer.cornerRadius = 28;
        s_floatBall.layer.borderWidth = 2.0;
        s_floatBall.layer.borderColor = [UIColor whiteColor].CGColor;
        [s_floatBall setTitle:@"作弊" forState:UIControlStateNormal];
        [s_floatBall setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        s_floatBall.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleBallPan:)];
        [s_floatBall addGestureRecognizer:pan];
        
        [s_floatBall addTarget:self action:@selector(toggleCustomPanel) forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:s_floatBall];
        
        // 构建控制面板
        [self buildCustomPanelInView:vc.view screenBounds:screenBounds];
        
        [s_overlayWin makeKeyAndVisible];
        s_overlayWin.hidden = NO;
        AddLog(@"[✓] BlackEra 修改器界面加载完成！");
    });
}

+ (void)handleBallPan:(UIPanGestureRecognizer *)pan {
    CGPoint trans = [pan translationInView:pan.view.superview];
    pan.view.center = CGPointMake(pan.view.center.x + trans.x, pan.view.center.y + trans.y);
    [pan setTranslation:CGPointMake(0, 0) inView:pan.view.superview];
}

+ (void)buildCustomPanelInView:(UIView *)parent screenBounds:(CGRect)bounds {
    CGFloat panelW = MIN(320, bounds.size.width - 40);
    CGFloat panelH = 390;
    
    g_panelView = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width - panelW) / 2, (bounds.size.height - panelH) / 2, panelW, panelH)];
    g_panelView.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:0.96];
    g_panelView.layer.cornerRadius = 16;
    g_panelView.layer.borderWidth = 1.5;
    g_panelView.layer.borderColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.2 alpha:0.8].CGColor;
    g_panelView.clipsToBounds = YES;
    g_panelView.hidden = YES;
    
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, panelW - 32, 24)];
    titleLabel.text = @"⚡ 修仙修改器控制台 ⚡";
    titleLabel.textColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.3 alpha:1.0];
    titleLabel.font = [UIFont boldSystemFontOfSize:16];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [g_panelView addSubview:titleLabel];
    
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(12, 44, panelW - 24, panelH - 95)];
    scroll.showsVerticalScrollIndicator = YES;
    
    CGFloat btnY = 6;
    CGFloat btnH = 40;
    CGFloat btnSpacing = 8;
    CGFloat btnW = panelW - 24;
    
    // 按钮 1：领灵石
    UIButton *b1 = [self makeButtonWithFrame:CGRectMake(0, btnY, btnW, btnH) title:@"💎 领灵石 (设置/商城界面点)" bg:[UIColor colorWithRed:0.18 green:0.4 blue:0.8 alpha:1.0]];
    [b1 addTarget:self action:@selector(actionClaimStones) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:b1];
    btnY += btnH + btnSpacing;
    
    // 按钮 2：制造/强化
    UIButton *b2 = [self makeButtonWithFrame:CGRectMake(0, btnY, btnW, btnH) title:@"⚒️ 炼丹/炼器/强化 (制造界面点)" bg:[UIColor colorWithRed:0.2 green:0.6 blue:0.4 alpha:1.0]];
    [b2 addTarget:self action:@selector(actionInstantMake) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:b2];
    btnY += btnH + btnSpacing;

    // 按钮 3：灵宠洗练
    UIButton *b3 = [self makeButtonWithFrame:CGRectMake(0, btnY, btnW, btnH) title:@"🐾 灵宠洗练/重置 (灵宠界面点)" bg:[UIColor colorWithRed:0.5 green:0.3 blue:0.7 alpha:1.0]];
    [b3 addTarget:self action:@selector(actionFreePet) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:b3];
    btnY += btnH + btnSpacing;

    // 按钮 4：功能六开关
    UIButton *b4 = [self makeButtonWithFrame:CGRectMake(0, btnY, btnW, btnH) title:@"⚙️ 功能六开关:【已关闭】" bg:[UIColor colorWithRed:0.3 green:0.3 blue:0.35 alpha:1.0]];
    [b4 addTarget:self action:@selector(actionToggleF6:) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:b4];
    btnY += btnH + btnSpacing;

    // 按钮 5：执行功能六
    UIButton *b5 = [self makeButtonWithFrame:CGRectMake(0, btnY, btnW, btnH) title:@"🎁 一键注入全装备材料 (背包点)" bg:[UIColor colorWithRed:0.8 green:0.25 blue:0.2 alpha:1.0]];
    [b5 addTarget:self action:@selector(actionInjectGear) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:b5];
    btnY += btnH + btnSpacing;

    // 按钮 6：公告拦截开关
    UIButton *b6 = [self makeButtonWithFrame:CGRectMake(0, btnY, btnW, btnH) title:@"🔇 全服公告拦截:【已开启】" bg:[UIColor colorWithRed:0.25 green:0.45 blue:0.35 alpha:1.0]];
    [b6 addTarget:self action:@selector(actionToggleAnnounce:) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:b6];
    btnY += btnH + btnSpacing;

    // 按钮 7：HUD日志开关
    UIButton *b7 = [self makeButtonWithFrame:CGRectMake(0, btnY, btnW, btnH) title:@"📊 切换 HUD 实时日志面板" bg:[UIColor colorWithRed:0.35 green:0.35 blue:0.4 alpha:1.0]];
    [b7 addTarget:self action:@selector(actionToggleHUD) forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:b7];
    btnY += btnH + btnSpacing;
    
    scroll.contentSize = CGSizeMake(btnW, btnY);
    [g_panelView addSubview:scroll];
    
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(16, panelH - 44, panelW - 32, 36);
    closeBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.22 alpha:1.0];
    closeBtn.layer.cornerRadius = 8;
    [closeBtn setTitle:@"✕ 关闭控制台" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [closeBtn addTarget:self action:@selector(toggleCustomPanel) forControlEvents:UIControlEventTouchUpInside];
    [g_panelView addSubview:closeBtn];

    [parent addSubview:g_panelView];
    
    // HUD 日志视图
    g_logView = [[UITextView alloc] initWithFrame:CGRectMake(bounds.size.width - 250, 40, 240, 150)];
    g_logView.font = [UIFont fontWithName:@"Menlo" size:9];
    g_logView.textColor = [UIColor greenColor];
    g_logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    g_logView.layer.cornerRadius = 8;
    g_logView.editable = NO;
    g_logView.hidden = YES;
    [parent addSubview:g_logView];
}

+ (UIButton *)makeButtonWithFrame:(CGRect)frame title:(NSString *)title bg:(UIColor *)bg {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = frame;
    btn.backgroundColor = bg;
    btn.layer.cornerRadius = 8;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    return btn;
}

#pragma mark - ============ 按钮点击事件分发 ============

+ (void)toggleCustomPanel {
    if (!g_panelView) return;
    g_panelView.hidden = !g_panelView.hidden;
}

+ (void)actionClaimStones {
    [[ModManager shared] claimSpiritStonesLoop];
}

+ (void)actionInstantMake {
    [[ModManager shared] triggerMakeActions];
}

+ (void)actionFreePet {
    [[ModManager shared] triggerPetRebirth];
}

+ (void)actionToggleF6:(UIButton *)btn {
    g_feature6_enabled = !g_feature6_enabled;
    NSString *title = g_feature6_enabled ? @"⚙️ 功能六开关:【已开启】" : @"⚙️ 功能六开关:【已关闭】";
    [btn setTitle:title forState:UIControlStateNormal];
    btn.backgroundColor = g_feature6_enabled ? [UIColor colorWithRed:0.1 green:0.65 blue:0.2 alpha:1.0] : [UIColor colorWithRed:0.3 green:0.3 blue:0.35 alpha:1.0];
    AddLog(g_feature6_enabled ? @"[⚙️] 功能六已开启" : @"[⚙️] 功能六已关闭");
}

+ (void)actionInjectGear {
    [[ModManager shared] triggerFeature6];
}

+ (void)actionToggleAnnounce:(UIButton *)btn {
    g_intercept_announce = !g_intercept_announce;
    NSString *title = g_intercept_announce ? @"🔇 全服公告拦截:【已开启】" : @"🔊 全服公告拦截:【已关闭】";
    [btn setTitle:title forState:UIControlStateNormal];
    AddLog(g_intercept_announce ? @"[🛡️] 公告拦截已开启" : @"[🛡️] 公告拦截已关闭");
}

+ (void)actionToggleHUD {
    g_hudVisible = !g_hudVisible;
    if (g_logView) g_logView.hidden = !g_hudVisible;
    AddLog(g_hudVisible ? @"[📊] HUD 日志已显示" : @"[📊] HUD 日志已隐藏");
}

@end

#pragma mark - ============ 构造器安全入口 ============

__attribute__((constructor))
static void BlackEraModMain(void) {
    // 启动 1.5 秒后在最顶层展示自定义控制台
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [FloatingMenuUI showFloatingBall];
    });

    // 1. Hook Bmob 全服广播拦截
    Class BC = objc_getClass("BmobCloud");
    if (BC) {
        Method m = class_getInstanceMethod(BC, @selector(callFunctionInBackground:withParameters:block:));
        if (m) orig_bcloud_callFunc_IMP = method_setImplementation(m, (IMP)BE_Bcloud_CallFunc);
    }
    
    // 2. Hook Socket 广播拦截
    Class BSI = objc_getClass("BmobSocketIO");
    if (BSI) {
        Method m1 = class_getInstanceMethod(BSI, @selector(sendEvent:withData:));
        if (m1) orig_sendEvent_IMP = method_setImplementation(m1, (IMP)BE_SocketIO_SendEvent);
    }
}
