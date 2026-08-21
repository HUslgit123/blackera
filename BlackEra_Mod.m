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

#pragma mark - ============ Global States ============

static BOOL g_intercept_announce = NO;
static BOOL g_arc4random_hijack  = NO;
static BOOL g_feature_gear_inject= NO;

static NSMutableArray *g_logs       = nil;
static UIWindow       *g_win        = nil;
static UILabel        *g_statusBar  = nil;
static UITextView     *g_logView    = nil;
static BOOL           g_hudVisible = YES;

#pragma mark - ============ Utilities ============

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

#pragma mark - ============ Forward Declarations ============

static void HUDInit(void);
static void ToggleHUDVisibility(void);
static void ClearLogsInternal(void);

#pragma mark - ============ SocketIO Interception ============

static IMP orig_sendEvent_IMP    = NULL;
static IMP orig_sendMessage_IMP  = NULL;
static IMP orig_sendJSON_IMP     = NULL;

id BE_SocketIO_SendEvent_Block(id self, SEL _cmd, NSString *event, id data) {
    if (g_intercept_announce && (
        [event rangeOfString:@"announce" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [event rangeOfString:@"broadcast" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [event rangeOfString:@"system" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        AddLog([NSString stringWithFormat:@"[INTERCEPT] Blocked event: %@", event]);
        return nil;
    }

    void (*orig)(id, SEL, NSString *, id) = (void (*)(id, SEL, NSString *, id))orig_sendEvent_IMP;
    orig(self, _cmd, event, data);
    return nil;
}

id BE_SocketIO_SendMessage_Block(id self, SEL _cmd, NSString *message) {
    if (g_intercept_announce && [message rangeOfString:@"announce" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        AddLog(@"[INTERCEPT] Blocked message");
        return nil;
    }
    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))orig_sendMessage_IMP;
    orig(self, _cmd, message);
    return nil;
}

id BE_SocketIO_SendJSON_Block(id self, SEL _cmd, NSDictionary *json) {
    void (*orig)(id, SEL, NSDictionary *) = (void (*)(id, SEL, NSDictionary *))orig_sendJSON_IMP;
    orig(self, _cmd, json);
    return nil;
}

#pragma mark - ============ BmobCloud Hook ============

static IMP orig_bcloud_callFunc_IMP = NULL;

id BE_Bcloud_CallFunc_Block(id self, SEL _cmd, NSString *functionName, NSDictionary *params, void (^block)(id result, NSError *error)) {
    if ([functionName rangeOfString:@"SendSystemMessage" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [functionName rangeOfString:@"system" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        AddLog(@"[INTERCEPT] Blocked BmobCloud broadcast");
        if (block) block(@[@"success"], nil);
        return nil;
    }

    void (*orig)(id, SEL, NSString *, NSDictionary *, id) = 
        (void (*)(id, SEL, NSString *, NSDictionary *, id))orig_bcloud_callFunc_IMP;
    orig(self, _cmd, functionName, params, block);
    return nil;
}

#pragma mark - ============ ModManager ============

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

- (void)claimSpiritStonesLoop:(int)count interval:(double)intervalSecs {
    AddLog([NSString stringWithFormat:@"[FEATURE] Starting claim loop: %d times", count]);
    
    Class optClass = objc_getClass("OptionViewController");
    if (!optClass) {
        AddLog(@"[ERROR] OptionViewController not found");
        return;
    }

    id optionVC = nil;
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        optionVC = [self findViewControllerOfClass:optClass inRootVC:win.rootViewController];
        if (optionVC) break;
    }

    if (!optionVC) {
        AddLog(@"[ERROR] OptionViewController instance not found. Open Options screen first.");
        return;
    }

    SEL sel = @selector(gdt_rewardVideoAdDidRewardEffective:);
    if (![optionVC respondsToSelector:sel]) {
        AddLog(@"[ERROR] Selector not found on OptionViewController");
        return;
    }

    for (int i = 0; i < count; i++) {
        int idx = i;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(idx * intervalSecs * NSEC_PER_SEC)), 
                       dispatch_get_main_queue(), ^{
            @autoreleasepool {
                // 解决 objc_msgSend 类型转换报错，明确定义函数指针签名
                ((void (*)(id, SEL, id))objc_msgSend)(optionVC, sel, nil);
                AddLog([NSString stringWithFormat:@"[CLAIM] Executed #%d", idx + 1]);
            }
        });
    }
}

- (void)freePetRebirthCall {
    AddLog(@"[FEATURE] Triggering pet rebirth...");
    Class petClass = objc_getClass("PetViewController") ?: objc_getClass("LingchongViewController");
    if (!petClass) {
        AddLog(@"[ERROR] PetViewController class not found");
        return;
    }
    
    id petVC = nil;
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        petVC = [self findViewControllerOfClass:petClass inRootVC:win.rootViewController];
        if (petVC) break;
    }

    if (!petVC) {
        AddLog(@"[ERROR] Open Pet screen first.");
        return;
    }
    
    AddLog(@"[OK] Pet screen detected.");
}

- (void)toggleFeatureGearInject:(BOOL)enable {
    g_feature_gear_inject = enable;
    AddLog(enable ? @"[FEATURE] Gear Injection ENABLED" : @"[FEATURE] Gear Injection DISABLED");
}

- (id)findViewControllerOfClass:(Class)targetClass inRootVC:(UIViewController *)root {
    if (!root || !targetClass) return nil;
    
    if ([root isKindOfClass:targetClass]) return root;
    
    // 修复：将 root.children 改为兼容性更好的 childViewControllers
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

#pragma mark - ============ Floating Ball UI ============

@interface FloatingBallUI : NSObject
@property (nonatomic, strong) UIWindow *overlayWindow;
@end

@implementation FloatingBallUI

+ (void)showMenu {
    static UIWindow *win = nil;
    if (win) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect b = [UIScreen mainScreen].bounds;
        win = [[UIWindow alloc] initWithFrame:b];
        win.windowLevel = UIWindowLevelAlert + 100;
        win.backgroundColor = [UIColor clearColor];
        
        UIButton *floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        floatBtn.frame = CGRectMake(15, b.size.height - 100, 60, 60);
        floatBtn.backgroundColor = [UIColor colorWithRed:0 green:0.7 blue:0 alpha:0.8];
        floatBtn.layer.cornerRadius = 30;
        floatBtn.layer.borderWidth = 2;
        floatBtn.layer.borderColor = [UIColor whiteColor].CGColor;
        [floatBtn setTitle:@"作弊" forState:UIControlStateNormal];
        [floatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        floatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        
        [floatBtn addTarget:self action:@selector(openActionSheet) forControlEvents:UIControlEventTouchUpInside];
        [win addSubview:floatBtn];
        win.hidden = NO;
    });
}

+ (void)openActionSheet {
    // 兼容 iOS 13+ 的活跃窗口获取方式
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
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⚡ 修仙辅助控制台 ⚡" message:@"选择功能" preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:g_intercept_announce ? @"🔇 公告拦截: ON" : @"🔊 公告拦截: OFF" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        g_intercept_announce = !g_intercept_announce;
        AddLog(g_intercept_announce ? @"[SET] Announce ON" : @"[SET] Announce OFF");
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"💎 领灵石 x20 (间隔0.5s)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[ModManager shared] claimSpiritStonesLoop:20 interval:0.5];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"🐾 灵宠免费洗练" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [[ModManager shared] freePetRebirthCall];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [root presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - ============ HUD Panel ============

static void HUDInit(void) {
    if (g_win) return;
    CGRect b = [UIScreen mainScreen].bounds;
    
    g_win = [[UIWindow alloc] initWithFrame:b];
    g_win.windowLevel = UIWindowLevelAlert + 90;
    g_win.backgroundColor = [UIColor clearColor];
    
    g_statusBar = [[UILabel alloc] initWithFrame:CGRectMake(b.size.width - 260, 40, 250, 30)];
    g_statusBar.font = [UIFont systemFontOfSize:11];
    g_statusBar.textColor = [UIColor whiteColor];
    g_statusBar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
    g_statusBar.text = @"状态: 运行中";
    
    g_logView = [[UITextView alloc] initWithFrame:CGRectMake(b.size.width - 260, 72, 250, 150)];
    g_logView.font = [UIFont fontWithName:@"Menlo" size:9];
    g_logView.textColor = [UIColor whiteColor];
    g_logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    g_logView.editable = NO;
    
    [g_win addSubview:g_statusBar];
    [g_win addSubview:g_logView];
    g_win.hidden = NO;
}

#pragma mark - ============ Constructor Entry ============

__attribute__((constructor))
static void BlackEraModMain(void) {
    AddLog(@"BlackEra_Mod loaded.");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        @autoreleasepool {
            HUDInit();
            [FloatingBallUI showMenu];
            
            // Hook BmobSocketIO
            Class BSI = objc_getClass("BmobSocketIO");
            if (BSI) {
                Method m_sendEvent = class_getInstanceMethod(BSI, @selector(sendEvent:withData:));
                if (m_sendEvent) {
                    orig_sendEvent_IMP = method_setImplementation(m_sendEvent, imp_implementationWithBlock((id)&BE_SocketIO_SendEvent_Block));
                    AddLog(@"[OK] Hooked BmobSocketIO sendEvent");
                }
            }
            
            // Hook BmobCloud
            Class BC = objc_getClass("BmobCloud");
            if (BC) {
                Method m_callFunc = class_getInstanceMethod(BC, @selector(callFunctionInBackground:withParameters:block:));
                if (m_callFunc) {
                    orig_bcloud_callFunc_IMP = method_setImplementation(m_callFunc, imp_implementationWithBlock((id)&BE_Bcloud_CallFunc_Block));
                    AddLog(@"[OK] Hooked BmobCloud");
                }
            }
        }
    });
}
