#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dispatch/dispatch.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <dlfcn.h>

#pragma mark - ============ 全局状态与开关 ============

static BOOL g_intercept_announce = NO;
static BOOL g_feature_gear_inject= NO;

static NSMutableArray *g_logs       = nil;
static UIWindow       *g_win        = nil;
static UILabel        *g_statusBar  = nil;
static UITextView     *g_logView    = nil;
static BOOL           g_hudVisible = NO;

#pragma mark - ============ 自定义点击穿透 Window ============

// 保证悬浮窗和日志不会阻挡游戏原本的点击操作
@interface BEPassthroughWindow : UIWindow
@end

@implementation BEPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil; // 点击穿透到游戏主界面
    }
    return hitView;
}
@end

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
    if (g_logs.count > 120) [g_logs removeObjectsInRange:NSMakeRange(0, g_logs.count - 120)];
    
    NSLog(@"[BlackEra] %@", full);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_logView || !g_hudVisible) return;
        
        NSMutableString *all = [NSMutableString string];
        for (NSString *line in g_logs) {
            [all appendString:line];
            [all appendString:@"\n"];
        }
        g_logView.text = all;
        NSRange end = NSMakeRange(MAX(0, [all length] - 1), 1);
        [g_logView scrollRangeToVisible:end];
    });
}

#pragma mark - ============ SocketIO / 网络拦截函数 ============

static IMP orig_sendEvent_IMP    = NULL;
static IMP orig_sendMessage_IMP  = NULL;
static IMP orig_sendJSON_IMP     = NULL;

static void BE_SocketIO_SendEvent(id self, SEL _cmd, NSString *event, id data) {
    if (g_intercept_announce && event && (
        [event rangeOfString:@"announce" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [event rangeOfString:@"broadcast" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [event rangeOfString:@"system" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        AddLog([NSString stringWithFormat:@"[🛡️已拦截] SocketIO 广播: %@", event]);
        return;
    }

    if (orig_sendEvent_IMP) {
        ((void (*)(id, SEL, NSString *, id))orig_sendEvent_IMP)(self, _cmd, event, data);
    }
}

static void BE_SocketIO_SendMessage(id self, SEL _cmd, NSString *message) {
    if (g_intercept_announce && message && [message rangeOfString:@"announce" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        AddLog(@"[🛡️已拦截] SocketIO 文本消息");
        return;
    }
    if (orig_sendMessage_IMP) {
        ((void (*)(id, SEL, NSString *))orig_sendMessage_IMP)(self, _cmd, message);
    }
}

static void BE_SocketIO_SendJSON(id self, SEL _cmd, NSDictionary *json) {
    if (orig_sendJSON_IMP) {
        ((void (*)(id, SEL, NSDictionary *))orig_sendJSON_IMP)(self, _cmd, json);
    }
}

#pragma mark - ============ BmobCloud Hook ============

static IMP orig_bcloud_callFunc_IMP = NULL;

static void BE_Bcloud_CallFunc(id self, SEL _cmd, NSString *functionName, NSDictionary *params, void (^block)(id result, NSError *error)) {
    if (functionName && ([functionName rangeOfString:@"SendSystemMessage" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                         [functionName rangeOfString:@"system" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        AddLog(@"[🛡️已拦截] BmobCloud 全服广播请求");
        if (block) block(@[@"success"], nil); // 伪造成功回调，防止游戏挂起
        return;
    }

    if (orig_bcloud_callFunc_IMP) {
        ((void (*)(id, SEL, NSString *, NSDictionary *, id))orig_bcloud_callFunc_IMP)(self, _cmd, functionName, params, block);
    }
}

#pragma mark - ============ 业务调度管理类 ============

@interface ModManager : NSObject
+ (instancetype)shared;
- (void)claimSpiritStonesLoop:(int)count interval:(double)intervalSecs;
- (void)freePetRebirthCall;
- (void)toggleFeatureGearInject:(BOOL)enable;
@end

@implementation ModManager

+ (instancetype)shared {
    static id inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [[ModManager alloc] init]; });
    return inst;
}

// 灵石领取循环
- (void)claimSpiritStonesLoop:(int)count interval:(double)intervalSecs {
    AddLog([NSString stringWithFormat:@"[⚡] 启动领灵石循环: %d 次, 间隔: %.1fs", count, intervalSecs]);
    
    Class optClass = objc_getClass("OptionViewController");
    if (!optClass) {
        AddLog(@"[❌] 未找到 OptionViewController 类");
        return;
    }

    id optionVC = nil;
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        optionVC = [self findViewControllerOfClass:optClass inRootVC:win.rootViewController];
        if (optionVC) break;
    }

    if (!optionVC) {
        AddLog(@"[⚠️] 请先进入游戏【设置/选项】界面后再点击！");
        return;
    }

    SEL sel = @selector(gdt_rewardVideoAdDidRewardEffective:);
    SEL altSel = @selector(gdt_rewardVideoAdDidRewardEffective:info:);
    
    SEL targetSel = [optionVC respondsToSelector:sel] ? sel : ([optionVC respondsToSelector:altSel] ? altSel : nil);

    if (!targetSel) {
        AddLog(@"[❌] 未找到激励广告发奖方法！");
        return;
    }

    for (int i = 0; i < count; i++) {
        int idx = i;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(idx * intervalSecs * NSEC_PER_SEC)), 
                       dispatch_get_main_queue(), ^{
            @autoreleasepool {
                if (targetSel == altSel) {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(optionVC, targetSel, nil, nil);
                } else {
                    ((void (*)(id, SEL, id))objc_msgSend)(optionVC, targetSel, nil);
                }
                AddLog([NSString stringWithFormat:@"[💎] 第 %d/%d 次发奖完成 (+20灵石)", idx + 1, count]);
            }
        });
    }
}

// 灵宠免费洗练
- (void)freePetRebirthCall {
    AddLog(@"[⚡] 尝试触发灵宠免费重置/洗练...");
    Class petClass = objc_getClass("PetViewController") ?: objc_getClass("LingchongViewController");
    if (!petClass) {
        AddLog(@"[❌] 未找到 PetViewController 类");
        return;
    }
    
    id petVC = nil;
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        petVC = [self findViewControllerOfClass:petClass inRootVC:win.rootViewController];
        if (petVC) break;
    }

    if (!petVC) {
        AddLog(@"[⚠️] 请先打开【灵宠】界面后再点击！");
        return;
    }
    
    AddLog(@"[✓] 已定位灵宠界面实例");
}

- (void)toggleFeatureGearInject:(BOOL)enable {
    g_feature_gear_inject = enable;
    AddLog(enable ? @"[⚙️] GM全装注入开关: 已开启" : @"[⚙️] GM全装注入开关: 已关闭");
}

- (id)findViewControllerOfClass:(Class)targetClass inRootVC:(UIViewController *)root {
    if (!root || !targetClass) return nil;
    if ([root isKindOfClass:targetClass]) return root;
    for (UIViewController *child in root.childViewControllers) {
        id found = [self findViewControllerOfClass:targetClass inRootVC:child];
        if (found) return found;
    }
    if (root.presentedViewController) {
        id found = [self findViewControllerOfClass:targetClass inRootVC:root.presentedViewController];
        if (found) return found;
    }
    return nil;
}

@end

#pragma mark - ============ HUD 日志面板 ============

static void ToggleHUDVisibility(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_win) return;
        g_hudVisible = !g_hudVisible;
        g_win.hidden = !g_hudVisible;
        AddLog(g_hudVisible ? @"[HUD] 已显示" : @"[HUD] 已隐藏");
    });
}

static void HUDInit(void) {
    if (g_win) return;
    CGRect b = [UIScreen mainScreen].bounds;
    
    // 创建支持点击穿透的 Window 并配置 rootViewController
    g_win = [[BEPassthroughWindow alloc] initWithFrame:b];
    g_win.windowLevel = UIWindowLevelAlert + 90;
    g_win.backgroundColor = [UIColor clearColor];
    
    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    rootVC.view.userInteractionEnabled = NO;
    g_win.rootViewController = rootVC;
    
    g_statusBar = [[UILabel alloc] initWithFrame:CGRectMake(b.size.width - 260, 40, 250, 30)];
    g_statusBar.font = [UIFont systemFontOfSize:11];
    g_statusBar.textColor = [UIColor whiteColor];
    g_statusBar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    g_statusBar.layer.cornerRadius = 6;
    g_statusBar.layer.masksToBounds = YES;
    g_statusBar.text = @" 状态: 运行中";
    
    g_logView = [[UITextView alloc] initWithFrame:CGRectMake(b.size.width - 260, 75, 250, 150)];
    g_logView.font = [UIFont fontWithName:@"Menlo" size:9];
    g_logView.textColor = [UIColor greenColor];
    g_logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
    g_logView.layer.cornerRadius = 6;
    g_logView.editable = NO;
    
    [rootVC.view addSubview:g_statusBar];
    [rootVC.view addSubview:g_logView];
    g_win.hidden = YES; // 默认先隐藏，点击悬浮球可开启
}

#pragma mark - ============ 悬浮球控制面板 ============

@interface FloatingBallUI : NSObject
@end

@implementation FloatingBallUI

+ (void)showMenu {
    static BEPassthroughWindow *floatWin = nil;
    if (floatWin) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect b = [UIScreen mainScreen].bounds;
        floatWin = [[BEPassthroughWindow alloc] initWithFrame:CGRectMake(15, b.size.height - 120, 60, 60)];
        floatWin.windowLevel = UIWindowLevelAlert + 100;
        floatWin.backgroundColor = [UIColor clearColor];
        
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        floatWin.rootViewController = vc;
        
        UIButton *floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        floatBtn.frame = CGRectMake(0, 0, 60, 60);
        floatBtn.backgroundColor = [UIColor colorWithRed:0 green:0.65 blue:0 alpha:0.85];
        floatBtn.layer.cornerRadius = 30;
        floatBtn.layer.borderWidth = 2;
        floatBtn.layer.borderColor = [UIColor whiteColor].CGColor;
        [floatBtn setTitle:@"作弊" forState:UIControlStateNormal];
        [floatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        floatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        
        [floatBtn addTarget:self action:@selector(openActionSheet) forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:floatBtn];
        floatWin.hidden = NO;
    });
}

+ (void)openActionSheet {
    UIWindow *targetWindow = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) {
            targetWindow = window;
            break;
        }
    }
    if (!targetWindow) targetWindow = [UIApplication sharedApplication].windows.firstObject;

    UIViewController *root = targetWindow.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚡ 修仙辅助控制台 ⚡" message:@"选择要执行的功能" preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:g_intercept_announce ? @"🔇 公告拦截:【已开启】" : @"🔊 公告拦截:【已关闭】" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        g_intercept_announce = !g_intercept_announce;
        AddLog(g_intercept_announce ? @"[SET] 公告拦截已开启" : @"[SET] 公告拦截已关闭");
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"💎 领灵石 x20 (0.5s/次)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[ModManager shared] claimSpiritStonesLoop:20 interval:0.5];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"🐾 灵宠免费重置/洗练" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[ModManager shared] freePetRebirthCall];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:g_hudVisible ? @"📊 隐藏 HUD 日志" : @"📊 显示 HUD 日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        ToggleHUDVisibility();
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [root presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - ============ 构造器安全入口 ============

__attribute__((constructor))
static void BlackEraModMain(void) {
    // 监听应用完成启动通知，确保 UIWindow 环境就绪后再挂载悬浮窗
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            HUDInit();
            [FloatingBallUI showMenu];
            AddLog(@"[✓] BlackEra_Mod 插件初始化成功！");
        });
    }];
    
    // 安全注入 SocketIO 拦截
    Class BSI = objc_getClass("BmobSocketIO");
    if (BSI) {
        Method m_sendEvent = class_getInstanceMethod(BSI, @selector(sendEvent:withData:));
        if (m_sendEvent) {
            orig_sendEvent_IMP = method_setImplementation(m_sendEvent, (IMP)BE_SocketIO_SendEvent);
        }
        Method m_sendMsg = class_getInstanceMethod(BSI, @selector(sendMessage:));
        if (m_sendMsg) {
            orig_sendMessage_IMP = method_setImplementation(m_sendMsg, (IMP)BE_SocketIO_SendMessage);
        }
        Method m_sendJSON = class_getInstanceMethod(BSI, @selector(sendJSON:));
        if (m_sendJSON) {
            orig_sendJSON_IMP = method_setImplementation(m_sendJSON, (IMP)BE_SocketIO_SendJSON);
        }
    }
    
    // 安全注入 BmobCloud 拦截
    Class BC = objc_getClass("BmobCloud");
    if (BC) {
        Method m_callFunc = class_getInstanceMethod(BC, @selector(callFunctionInBackground:withParameters:block:));
        if (m_callFunc) {
            orig_bcloud_callFunc_IMP = method_setImplementation(m_callFunc, (IMP)BE_Bcloud_CallFunc);
        }
    }
}
