#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <time.h>

#pragma mark - ============ 全局状态与开关 ============

static BOOL g_intercept_announce  = YES; // 默认开启公告拦截
static BOOL g_arc4random_hijack   = YES; // 默认开启 100% 突破/极品判定
static BOOL g_feature6_enabled    = NO;  // 功能六独立开关

static NSMutableArray *g_logs     = nil;
static UIWindow       *g_hudWin   = nil;
static UITextView     *g_logView  = nil;
static BOOL           g_hudVisible= NO;

// 计算 ASLR 真实内存地址 (基址 0x100000000)
static uintptr_t get_real_addr(uintptr_t static_addr) {
    return _dyld_get_image_vmaddr_slide(0) + static_addr;
}

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

#pragma mark - ============ 第一项：绝对拦截所有上报公告 ============

static IMP orig_bcloud_callFunc_IMP = NULL;
static void BE_Bcloud_CallFunc(id self, SEL _cmd, NSString *functionName, NSDictionary *params, void (^block)(id result, NSError *error)) {
    if (g_intercept_announce && functionName && 
       ([functionName rangeOfString:@"SendSystemMessage" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [functionName rangeOfString:@"system" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        AddLog(@"[🛡️公告已拦截] 阻止向全服发送系统广播");
        if (block) block(@[@"success"], nil);
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

#pragma mark - ============ 广告劫持：点击原生看广告直接免看发奖 ============

static IMP orig_OptionVC_adClick_IMP = NULL;
static void BE_OptionVC_adClick(id self, SEL _cmd, id sender) {
    AddLog(@"[💎] 触发设置界面免看广告，直接下发 20 灵石");
    // 直接执行底层原生发奖函数 0x1000703e8
    typedef void (*ClaimFunc_t)(void);
    ClaimFunc_t claim = (ClaimFunc_t)get_real_addr(0x1000703e8);
    claim();
}

static IMP orig_ShopVC_adClick_IMP = NULL;
static void BE_ShopVC_adClick(id self, SEL _cmd, id sender) {
    AddLog(@"[💎] 触发商城界面免看广告，直接下发 20 灵石");
    // 优先调用原生代理发奖
    SEL sel = @selector(gdt_rewardVideoAdDidRewardEffective:info:);
    if ([self respondsToSelector:sel]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(self, sel, nil, nil);
    } else {
        typedef void (*ClaimFunc_t)(void);
        ClaimFunc_t claim = (ClaimFunc_t)get_real_addr(0x1000703e8);
        claim();
    }
}

#pragma mark - ============ 业务调度管理类 ============

@interface ModManager : NSObject
+ (instancetype)shared;
- (void)claimSpiritStonesLoop;
- (void)freePetRebirth;
- (void)triggerFeature6;
- (void)instantMakeComplete;
@end

@implementation ModManager

+ (instancetype)shared {
    static id inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [[ModManager alloc] init]; });
    return inst;
}

// 第二项：间隔0.5秒领取灵石，循环20次
- (void)claimSpiritStonesLoop {
    AddLog(@"[💎] 启动灵石连刷: 0.5s/次 x 20次");
    typedef void (*ClaimFunc_t)(void);
    ClaimFunc_t claim = (ClaimFunc_t)get_real_addr(0x1000703e8);
    
    for (int i = 0; i < 20; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            claim();
            AddLog([NSString stringWithFormat:@"[✓] 灵石到账第 %d/20 次 (+20灵石)", i + 1]);
        });
    }
}

// 第四项：制造秒完成
- (void)instantMakeComplete {
    typedef void (*MakeFunc_t)(long);
    MakeFunc_t make = (MakeFunc_t)get_real_addr(0x10031f14c);
    make(5); // 恒定传入 5，直接达成完成阈值
    AddLog(@"[⚒️] 已执行制造 0 秒极速完成！");
}

// 第五项：灵宠 0 灵石重置/洗练
- (void)freePetRebirth {
    typedef void (*RebirthFunc_t)(void);
    RebirthFunc_t rebirth = (RebirthFunc_t)get_real_addr(0x10077a7f4);
    rebirth();
    AddLog(@"[🐾] 灵宠 0 灵石免费重置/洗练已完成！");
}

// 第六项：GM全装备注入 (带独立开关)
- (void)triggerFeature6 {
    if (!g_feature6_enabled) {
        AddLog(@"[⚠️] 功能六开关当前处于关闭状态，请先在菜单中开启！");
        return;
    }
    typedef void (*GMInjectFunc_t)(void *);
    GMInjectFunc_t inject = (GMInjectFunc_t)get_real_addr(0x1005e7944);
    inject(NULL);
    AddLog(@"[🎁] 一键全装备与材料注入指令已执行！");
}

@end

#pragma mark - ============ 穿透点击 UIWindow ============

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

#pragma mark - ============ 悬浮球控制面板（完美适配 iOS 13~18） ============

@interface FloatingMenuUI : NSObject
@end

@implementation FloatingMenuUI

+ (void)showFloatingBall {
    static BEOverlayWindow *ballWin = nil;
    if (ballWin) return;
    
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
            ballWin = [[BEOverlayWindow alloc] initWithWindowScene:activeScene];
            ballWin.frame = CGRectMake(15, screenBounds.size.height - 130, 60, 60);
        } else {
            ballWin = [[BEOverlayWindow alloc] initWithFrame:CGRectMake(15, screenBounds.size.height - 130, 60, 60)];
        }

        ballWin.windowLevel = UIWindowLevelAlert + 100;
        ballWin.backgroundColor = [UIColor clearColor];
        
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        ballWin.rootViewController = vc;
        
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, 0, 60, 60);
        btn.backgroundColor = [UIColor colorWithRed:0.0 green:0.75 blue:0.1 alpha:0.9];
        btn.layer.cornerRadius = 30;
        btn.layer.borderWidth = 2.0;
        btn.layer.borderColor = [UIColor whiteColor].CGColor;
        [btn setTitle:@"作弊" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        
        [btn addTarget:self action:@selector(openCheatMenu) forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:btn];
        
        [ballWin makeKeyAndVisible];
        ballWin.hidden = NO;
        AddLog(@"[✓] 作弊悬浮球挂载成功！");
    });
}

+ (void)openCheatMenu {
    UIWindow *keyWin = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { keyWin = w; break; }
    }
    if (!keyWin) keyWin = [UIApplication sharedApplication].windows.firstObject;
    
    UIViewController *root = keyWin.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚡ 修仙辅助控制台 ⚡" 
                                                                   message:@"选择需要触发的破解功能" 
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    // 1. 灵石连刷
    [alert addAction:[UIAlertAction actionWithTitle:@"💎 领灵石 (0.5s/次 x 20下)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[ModManager shared] claimSpiritStonesLoop];
    }]];

    // 2. 制造秒完成
    [alert addAction:[UIAlertAction actionWithTitle:@"⚒️ 炼丹/炼器 0秒极速完成" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[ModManager shared] instantMakeComplete];
    }]];

    // 3. 灵宠重置
    [alert addAction:[UIAlertAction actionWithTitle:@"🐾 灵宠 0灵石重置/洗练资质" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[ModManager shared] freePetRebirth];
    }]];

    // 4. 功能六独立开关
    NSString *f6Title = g_feature6_enabled ? @"⚙️ [功能六] GM全装注入:【已开启】" : @"⚙️ [功能六] GM全装注入:【已关闭】";
    [alert addAction:[UIAlertAction actionWithTitle:f6Title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        g_feature6_enabled = !g_feature6_enabled;
        AddLog(g_feature6_enabled ? @"[⚙️] 功能六已开启" : @"[⚙️] 功能六已关闭");
    }]];

    // 5. 执行功能六
    [alert addAction:[UIAlertAction actionWithTitle:@"🎁 执行功能六：一键全装备注入" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[ModManager shared] triggerFeature6];
    }]];

    // 6. 公告拦截开关
    NSString *annTitle = g_intercept_announce ? @"🔇 全服公告拦截:【开启中】" : @"🔊 全服公告拦截:【已关闭】";
    [alert addAction:[UIAlertAction actionWithTitle:annTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        g_intercept_announce = !g_intercept_announce;
        AddLog(g_intercept_announce ? @"[🛡️] 公告拦截已开启" : @"[🛡️] 公告拦截已关闭");
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [root presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - ============ 构造器入口 ============

__attribute__((constructor))
static void BlackEraModMain(void) {
    // 循环轮询检测 UI 场景，一旦游戏 Scene 准备就绪立即挂载悬浮窗
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (int i = 0; i < 30; i++) {
            [NSThread sleepForTimeInterval:1.0];
            dispatch_sync(dispatch_get_main_queue(), ^{
                if ([UIApplication sharedApplication].windows.count > 0) {
                    [FloatingMenuUI showFloatingBall];
                }
            });
        }
    });

    // 1. Hook Bmob 全服广播
    Class BC = objc_getClass("BmobCloud");
    if (BC) {
        Method m = class_getInstanceMethod(BC, @selector(callFunctionInBackground:withParameters:block:));
        if (m) orig_bcloud_callFunc_IMP = method_setImplementation(m, (IMP)BE_Bcloud_CallFunc);
    }
    
    // 2. Hook Socket 广播
    Class BSI = objc_getClass("BmobSocketIO");
    if (BSI) {
        Method m1 = class_getInstanceMethod(BSI, @selector(sendEvent:withData:));
        if (m1) orig_sendEvent_IMP = method_setImplementation(m1, (IMP)BE_SocketIO_SendEvent);
    }

    // 3. 广告点击劫持（解决原版广告点不开不发奖的问题）
    Class OptVC = objc_getClass("OptionViewController");
    if (OptVC) {
        Method mOpt = class_getInstanceMethod(OptVC, @selector(gdt_rewardVideoAdDidRewardEffective:info:));
        if (mOpt) orig_OptionVC_adClick_IMP = method_setImplementation(mOpt, (IMP)BE_OptionVC_adClick);
    }
    
    Class ShopVC = objc_getClass("ShopViewController");
    if (ShopVC) {
        Method mShop = class_getInstanceMethod(ShopVC, @selector(gdt_rewardVideoAdDidRewardEffective:info:));
        if (mShop) orig_ShopVC_adClick_IMP = method_setImplementation(mShop, (IMP)BE_ShopVC_adClick);
    }
}
