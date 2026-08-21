/*
 * BlackEra_Mod.dylib — 《黑色纪元》修改器 (稳定整合版)
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

#pragma mark - ============ ViewController 查找 ============

static id FindVCInHierarchy(Class targetClass, UIViewController *root) {
    if (!root || !targetClass) return nil;
    if ([root isKindOfClass:targetClass]) return root;
    
    NSMutableArray *toCheck = [NSMutableArray arrayWithObject:root];
    while (toCheck.count > 0) {
        UIViewController *vc = [toCheck lastObject];
        [toCheck removeLastObject];
        
        if ([vc isKindOfClass:targetClass]) return vc;
        
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)vc;
            [toCheck addObjectsFromArray:nav.viewControllers];
        } else if ([vc isKindOfClass:[UITabBarController class]]) {
            UITabBarController *tab = (UITabBarController *)vc;
            if (tab.viewControllers) [toCheck addObjectsFromArray:tab.viewControllers];
        }
        
        if (vc.childViewControllers.count > 0) {
            [toCheck addObjectsFromArray:vc.childViewControllers];
        }
        if (vc.presentedViewController) {
            [toCheck addObject:vc.presentedViewController];
        }
    }
    return nil;
}

static id GetVCByName(const char *name) {
    Class cls = objc_getClass(name);
    if (!cls) {
        AddLog([NSString stringWithFormat:@"[⚠️] Class %s 不存在", name]);
        return nil;
    }
    
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *w in windows) {
        id found = FindVCInHierarchy(cls, w.rootViewController);
        if (found) {
            AddLog([NSString stringWithFormat:@"[✓] 找到实例: %s", name]);
            return found;
        }
    }
    AddLog([NSString stringWithFormat:@"[⚠️] 当前窗口层级未找到: %s", name]);
    return nil;
}

#pragma mark - ============ 广播拦截 Hook ============

static IMP orig_bcloud_callFunc_IMP = NULL;
static void BE_Bcloud_CallFunc(id self, SEL _cmd, NSString *functionName, NSDictionary *params, void (^block)(id result, NSError *error)) {
    if (g_intercept_announce && functionName) {
        if ([functionName rangeOfString:@"SendSystemMessage" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [functionName rangeOfString:@"system" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            AddLog(@"[🛡️] BmobCloud 系统广播已阻断");
            if (block) block(@[@"success"], nil);
            return;
        }
    }
    ((void (*)(id, SEL, NSString *, NSDictionary *, void (^)(id, NSError *)))orig_bcloud_callFunc_IMP)(self, _cmd, functionName, params, block);
}

static IMP orig_sendEvent_IMP = NULL;
static void BE_SocketIO_SendEvent(id self, SEL _cmd, NSString *event, id data) {
    if (g_intercept_announce && event) {
        if ([event rangeOfString:@"announce" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [event rangeOfString:@"broadcast" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            AddLog([NSString stringWithFormat:@"[🛡️] Socket 广播已阻断: %@", event]);
            return;
        }
    }
    ((void (*)(id, SEL, NSString *, id))orig_sendEvent_IMP)(self, _cmd, event, data);
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
    AddLog(@"[💎] 开始尝试领取灵石...");
    id targetVC = GetVCByName("OptionViewController");
    if (!targetVC) targetVC = GetVCByName("ShopViewController");
    
    if (!targetVC) {
        AddLog(@"[❌] 请先打开【设置】或【商城】界面！");
        return;
    }
    
    SEL rewardSel = @selector(gdt_rewardVideoAdDidRewardEffective:);
    if (![targetVC respondsToSelector:rewardSel]) {
        AddLog(@"[❌] 当前 VC 未实现激励视频回调 selector");
        return;
    }
    
    AddLog(@"[💎] 启动刷灵石: 0.3s/次 x 20次");
    __weak id weakVC = targetVC;
    for (int i = 0; i < 20; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id strongVC = weakVC;
            if (!strongVC) return;
            ((void (*)(id, SEL, id))objc_msgSend)(strongVC, rewardSel, nil);
            AddLog([NSString stringWithFormat:@"[✓] 灵石到账第 %d/20 次", i + 1]);
        });
    }
}

- (void)triggerMakeActions {
    AddLog(@"[⚒️] 尝试触发制造/强化...");
    const char *possibleClasses[] = {"MakeViewController", "ForgeViewController", "CraftingViewController", "EquipmentViewController", NULL};
    id targetVC = nil;
    for (int i = 0; possibleClasses[i] != NULL; i++) {
        if ((targetVC = GetVCByName(possibleClasses[i]))) break;
    }
    
    if (!targetVC) {
        AddLog(@"[❌] 请先打开【制造】相关界面！");
        return;
    }
    
    NSArray *possibleSels = @[@"clickButtonWithButton:", @"clickMakeButtonWithButton:", @"doCraft", @"startCrafting"];
    SEL chosenSel = nil;
    for (NSString *selStr in possibleSels) {
        SEL s = NSSelectorFromString(selStr);
        if ([targetVC respondsToSelector:s]) { chosenSel = s; break; }
    }
    
    if (!chosenSel) {
        AddLog(@"[❌] 未匹配到制造方法");
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(targetVC, chosenSel, nil);
    AddLog(@"[⚒️] 已触发制造");
}

- (void)triggerPetRebirth {
    AddLog(@"[🐾] 尝试灵宠洗练...");
    const char *possibleClasses[] = {"PetViewController", "SpiritBeastViewController", "LingchongViewController", NULL};
    id targetVC = nil;
    for (int i = 0; possibleClasses[i] != NULL; i++) {
        if ((targetVC = GetVCByName(possibleClasses[i]))) break;
    }
    
    if (!targetVC) {
        AddLog(@"[❌] 请先打开【灵宠】界面！");
        return;
    }
    
    NSArray *possibleSels = @[@"clickWashButtonWithButton:", @"clickRebirthButtonWithButton:", @"doFreeReset", @"freePetReset"];
    SEL chosenSel = nil;
    for (NSString *selStr in possibleSels) {
        SEL s = NSSelectorFromString(selStr);
        if ([targetVC respondsToSelector:s]) { chosenSel = s; break; }
    }
    
    if (!chosenSel) {
        AddLog(@"[❌] 未匹配到洗练方法");
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(targetVC, chosenSel, nil);
    AddLog(@"[🐾] 已触发洗练");
}

- (void)triggerFeature6 {
    if (!g_feature6_enabled) {
        AddLog(@"[⚠️] 功能六未开启，请先开启开关！");
        return;
    }
    id bagVC = GetVCByName("BagViewController");
    if (!bagVC) bagVC = GetVCByName("InventoryViewController");
    if (!bagVC) {
        AddLog(@"[❌] 请先打开【背包】界面！");
        return;
    }
    
    SEL czSel = @selector(clickCZButtonWithButton:);
    SEL gmSel = @selector(clickGMButtonWithButton:);
    UIButton *fakeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    
    if ([bagVC respondsToSelector:czSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(bagVC, czSel, fakeBtn);
        AddLog(@"[🎁] 已触发 CZ 注入");
    } else if ([bagVC respondsToSelector:gmSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(bagVC, gmSel, fakeBtn);
        AddLog(@"[🎁] 已触发 GM 注入");
    } else {
        AddLog(@"[❌] 未找到背包 GM 接口");
    }
}

@end

#pragma mark - ============ 穿透 Overlay 窗口 ============

@interface BEOverlayWindow : UIWindow
@end

@implementation BEOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view || (hitView && !hitView.userInteractionEnabled)) {
        return nil;
    }
    return hitView;
}

@end

#pragma mark - ============ 悬浮 UI 界面 ============

@interface FloatingMenuUI : NSObject
@property (nonatomic, strong) BEOverlayWindow *overlayWin;
@property (nonatomic, strong) UIButton *floatBall;
+ (instancetype)shared;
+ (void)showFloatingBall;
@end

@implementation FloatingMenuUI

+ (instancetype)shared {
    static FloatingMenuUI *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [[FloatingMenuUI alloc] init]; });
    return inst;
}

+ (void)showFloatingBall {
    [[FloatingMenuUI shared] setupOverlayWindow];
}

- (void)setupOverlayWindow {
    if (self.overlayWin && !self.overlayWin.isHidden) return;
    
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
    
    self.overlayWin = activeScene ? [[BEOverlayWindow alloc] initWithWindowScene:activeScene] : [[BEOverlayWindow alloc] initWithFrame:bounds];
    self.overlayWin.windowLevel = UIWindowLevelAlert + 100;
    self.overlayWin.backgroundColor = [UIColor clearColor];
    
    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    self.overlayWin.rootViewController = rootVC;
    
    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    ball.frame = CGRectMake(15, bounds.size.height - 140, 56, 56);
    ball.backgroundColor = [UIColor colorWithRed:0.0 green:0.75 blue:0.1 alpha:0.9];
    ball.layer.cornerRadius = 28;
    ball.layer.borderWidth = 2.0;
    ball.layer.borderColor = [UIColor whiteColor].CGColor;
    ball.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [ball setTitle:@"作弊" forState:UIControlStateNormal];
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleBallPan:)];
    [ball addGestureRecognizer:pan];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleCustomPanel)];
    [tap requireGestureRecognizerToFail:pan];
    [ball addGestureRecognizer:tap];
    
    self.floatBall = ball;
    [rootVC.view addSubview:ball];
    
    [self buildControlPanelInView:rootVC.view withBounds:bounds];
    
    g_logView = [[UITextView alloc] initWithFrame:CGRectMake(bounds.size.width - 250, 40, 240, 160)];
    g_logView.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    g_logView.textColor = [UIColor colorWithRed:0.1 green:1.0 blue:0.3 alpha:1.0];
    g_logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    g_logView.layer.cornerRadius = 6;
    g_logView.editable = NO;
    g_logView.hidden = YES;
    [rootVC.view addSubview:g_logView];
    
    self.overlayWin.hidden = NO;
    [self.overlayWin makeKeyAndVisible];
    AddLog(@"[✓] BlackEra Mod 控制台加载成功");
}

- (void)buildControlPanelInView:(UIView *)parent withBounds:(CGRect)bounds {
    CGFloat panelW = MIN(320, bounds.size.width - 40);
    CGFloat panelH = 380;
    
    g_panelView = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width - panelW) / 2.0, (bounds.size.height - panelH) / 2.0, panelW, panelH)];
    g_panelView.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.14 alpha:0.96];
    g_panelView.layer.cornerRadius = 12;
    g_panelView.layer.borderWidth = 1.5;
    g_panelView.layer.borderColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.2 alpha:0.7].CGColor;
    g_panelView.hidden = YES;
    
    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, panelW - 24, 26)];
    titleLbl.text = @"⚡ 修仙修改器控制台 ⚡";
    titleLbl.textColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.3 alpha:1.0];
    titleLbl.font = [UIFont boldSystemFontOfSize:15];
    titleLbl.textAlignment = NSTextAlignmentCenter;
    [g_panelView addSubview:titleLbl];
    
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(8, 40, panelW - 16, panelH - 80)];
    CGFloat btnY = 4, btnH = 38, btnSpacing = 7, btnW = panelW - 24;
    
    UIButton *(^makeBtn)(NSString *, UIColor *, SEL) = ^UIButton *(NSString *title, UIColor *bgColor, SEL action) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, btnY, btnW, btnH);
        btn.backgroundColor = bgColor;
        btn.layer.cornerRadius = 6;
        btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        btn.titleLabel.numberOfLines = 2;
        [btn setTitle:title forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        if (action) [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        return btn;
    };
    
    [scrollView addSubview:makeBtn(@"💎 领灵石 x20\n(需打开设置/商城)", [UIColor colorWithRed:0.15 green:0.35 blue:0.7 alpha:1.0], @selector(actionClaimStones))];
    btnY += btnH + btnSpacing;
    
    [scrollView addSubview:makeBtn(@"⚒️ 触发炼丹/炼器操作\n(需在制造界面)", [UIColor colorWithRed:0.18 green:0.55 blue:0.35 alpha:1.0], @selector(actionInstantMake))];
    btnY += btnH + btnSpacing;
    
    [scrollView addSubview:makeBtn(@"🐾 灵宠免费洗练\n(需在灵宠界面)", [UIColor colorWithRed:0.45 green:0.25 blue:0.65 alpha:1.0], @selector(actionFreePet))];
    btnY += btnH + btnSpacing;
    
    [scrollView addSubview:makeBtn(@"⚙️ GM全装注入:【已关闭】", [UIColor colorWithRed:0.28 green:0.28 blue:0.35 alpha:1.0], @selector(actionToggleF6:))];
    btnY += btnH + btnSpacing;
    
    [scrollView addSubview:makeBtn(@"🎁 一键注入全装备\n(需在背包界面)", [UIColor colorWithRed:0.75 green:0.2 blue:0.18 alpha:1.0], @selector(actionInjectGear))];
    btnY += btnH + btnSpacing;
    
    [scrollView addSubview:makeBtn(@"🔇 全服公告拦截:【已开启】", [UIColor colorWithRed:0.2 green:0.4 blue:0.3 alpha:1.0], @selector(actionToggleAnnounce:))];
    btnY += btnH + btnSpacing;
    
    [scrollView addSubview:makeBtn(@"📊 切换HUD实时日志", [UIColor colorWithRed:0.3 green:0.3 blue:0.38 alpha:1.0], @selector(actionToggleHUD))];
    btnY += btnH + btnSpacing;
    
    scrollView.contentSize = CGSizeMake(btnW, btnY);
    [g_panelView addSubview:scrollView];
    
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(12, panelH - 34, panelW - 24, 28);
    closeBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.2 alpha:1.0];
    closeBtn.layer.cornerRadius = 6;
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [closeBtn setTitle:@"✕ 关闭控制台" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(toggleCustomPanel) forControlEvents:UIControlEventTouchUpInside];
    [g_panelView addSubview:closeBtn];
    
    [parent addSubview:g_panelView];
}

- (void)handleBallPan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.floatBall.superview;
    CGPoint translation = [pan translationInView:superview];
    CGFloat newX = fmaxf(28, fminf(self.floatBall.center.x + translation.x, superview.bounds.size.width - 28));
    CGFloat newY = fmaxf(28, fminf(self.floatBall.center.y + translation.y, superview.bounds.size.height - 28));
    self.floatBall.center = CGPointMake(newX, newY);
    [pan setTranslation:CGPointMake(0, 0) inView:superview];
}

- (void)toggleCustomPanel {
    if (!g_panelView) return;
    g_panelView.hidden = !g_panelView.hidden;
    self.floatBall.alpha = g_panelView.hidden ? 1.0 : 0.6;
}

- (void)actionClaimStones { [[ModManager shared] claimSpiritStonesLoop]; }
- (void)actionInstantMake { [[ModManager shared] triggerMakeActions]; }
- (void)actionFreePet { [[ModManager shared] triggerPetRebirth]; }
- (void)actionInjectGear { [[ModManager shared] triggerFeature6]; }
- (void)actionToggleHUD {
    g_hudVisible = !g_hudVisible;
    if (g_logView) g_logView.hidden = !g_hudVisible;
}

- (void)actionToggleF6:(UIButton *)btn {
    g_feature6_enabled = !g_feature6_enabled;
    [btn setTitle:g_feature6_enabled ? @"⚙️ GM全装注入:【已开启】" : @"⚙️ GM全装注入:【已关闭】" forState:UIControlStateNormal];
    btn.backgroundColor = g_feature6_enabled ? [UIColor colorWithRed:0.1 green:0.55 blue:0.2 alpha:1.0] : [UIColor colorWithRed:0.28 green:0.28 blue:0.35 alpha:1.0];
}

- (void)actionToggleAnnounce:(UIButton *)btn {
    g_intercept_announce = !g_intercept_announce;
    [btn setTitle:g_intercept_announce ? @"🔇 全服公告拦截:【已开启】" : @"🔊 全服公告拦截:【已关闭】" forState:UIControlStateNormal];
}

@end

#pragma mark - ============ 构造器入口 ============

__attribute__((constructor))
static void BlackEraModMain(void) {
    @autoreleasepool {
        AddLog(@"[INIT] BlackEra Mod 加载中...");
        
        Class bcloudClass = objc_getClass("BmobCloud");
        if (bcloudClass) {
            Method m = class_getInstanceMethod(bcloudClass, @selector(callFunctionInBackground:withParameters:block:));
            if (m) orig_bcloud_callFunc_IMP = method_setImplementation(m, (IMP)BE_Bcloud_CallFunc);
        }
        
        Class socketClass = objc_getClass("BmobSocketIO");
        if (socketClass) {
            Method m2 = class_getInstanceMethod(socketClass, @selector(sendEvent:withData:));
            if (m2) orig_sendEvent_IMP = method_setImplementation(m2, (IMP)BE_SocketIO_SendEvent);
        }
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [FloatingMenuUI showFloatingBall];
        });
    }
}
