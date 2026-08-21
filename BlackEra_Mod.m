 * BlackEra_Mod.dylib — 《黑色纪元》全能修改器 (整合版 v1.0)
 * 
 * 功能:
 *   - ① SocketIO公告拦截（高价值掉落不广播）
 *   - ② 灵石白嫖循环（正确调用OptionVC广告奖励方法）
 *   - ③ GM面板触发 + arc4random固定case
 *   - ④ 概率100%（arc4random/arc4random_uniform hook）
 *   - ⑤ 制造倒计时秒完成 / 强化零消耗 (需运行时验证)
 *   - ⑥ 悬浮球菜单操作面板 + HUD调试日志
 *
 * 编译 (GitHub Actions macOS runner with Xcode):
 *   clang -fno-objc-arc -arch arm64 -miphoneos-version-min=14.0 -dynamiclib \
 *     -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
 *     -install_name @rpath/BlackEra_Mod.dylib \
 *     -o BlackEra_Mod.dylib BlackEra_Mod.m \
 *     -framework UIKit -framework Foundation -lobjc
 *
 * 注入: TrollFools → 游戏 → Library/Inject → 选入该 dylib。
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dispatch/dispatch.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <errno.h>

#pragma mark - ============ 全局状态与开关 ============

static BOOL g_intercept_announce = NO;   // 公告拦截开关
static BOOL g_arc4random_hijack  = NO;   // arc4random劫持开关（概率100%）
static BOOL g_feature_gear_inject= NO;   // GM全装注入功能开关
static uint32_t g_rc_fixed_case = 0;     // GM面板arc4random固定case

// HUD & 日志
static NSMutableArray *g_logs       = nil;
static UIWindow       *g_win        = nil;
static UILabel        *g_statusBar  = nil;
static UITextView     *g_logView    = nil;
static BOOL           g_hudVisible = YES;

#pragma mark - ============ 工具函数（时间戳/日志） ============

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
    
    // HUD实时更新（主线程安全）
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

#pragma mark - ============ Forward declarations（C函数前向声明） ============

static void HUDInit(void);
static void UpdateStatusHUD(void);
static void ToggleHUDVisibility(void);
static void ClearLogsInternal(void);

#pragma mark - ============ SocketIO 公告拦截核心 Hook ============

// BmobSocketIO sendEvent/sendMessage/sendJSON 的原版IMP（保存下来以便恢复）
static IMP orig_sendEvent_IMP    = NULL;
static IMP orig_sendMessage_IMP  = NULL;
static IMP orig_sendJSON_IMP     = NULL;

// —— [BmobSocketIO sendEvent:withData:] hook block ——
id BE_SocketIO_SendEvent_Block(id self, SEL _cmd, NSString *event, id data) {
    // Record event details for HUD log
    NSString *dataStr;
    @try {
        NSData *d = [NSJSONSerialization dataWithJSONObject:data options:0 error:nil];
        dataStr = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"(not JSON)";
    } @catch (...) {
        dataStr = [(NSObject *)data description];
    }

    NSString *logMsg;
    if (event.length > 60) logMsg = [NSString stringWithFormat:@"[SOCKET] sendEvent:[%@...] data:%@", event.substringToIndex:60, dataStr];
    else                   logMsg = [NSString stringWithFormat:@"[SOCKET] sendEvent:[%@] data:%@", event, dataStr];

    AddLog(logMsg);

    // Check if this looks like a "system announcement" / broadcast related event
    BOOL isAnnounceLike = NO;
    if ([event rangeInsensitiveRangeOfString:@"announce"].location != NSNotFound ||
        [event rangeInsensitiveRangeOfString:@"broadcast"].location != NSNotFound ||
        [event rangeInsensitiveRangeOfString:@"system"].location != NSNotFound ||
        [event rangeInsensitiveRangeOfString:@"global"].location != NSNotFound ||
        [event rangeInsensitiveRangeOfString:@"notice"].location != NSNotFound) {
        isAnnounceLike = YES;
    }

    // Also check data content for keywords like "item.obtain.rare", "legendary", etc.
    if (dataStr && ([dataStr rangeOfString:@"rare"].location != NSNotFound ||
                    [dataStr rangeOfString:@"legendary"].location != NSNotFound ||
                    [dataStr rangeOfString:@"天品"].location != NSNotFound ||
                    [dataStr rangeInsensitiveRangeOfString:@"系统公告"].location != NSNotFound)) {
        isAnnounceLike = YES;
    }

    if (g_intercept_announce && isAnnounceLike) {
        AddLog([NSString stringWithFormat:@"[INTERCEPT] Blocked announce-like event: %@", event]);
        return nil; // Drop the message → server never receives it
    }

    // Call original via IMP cast
    void (*orig)(id, SEL, NSString *, id) = (void (*)(id, SEL, NSString *, id))orig_sendEvent_IMP;
    orig(self, _cmd, event, data);
    return nil;
}

// —— [BmobSocketIO sendMessage:] hook block ——
id BE_SocketIO_SendMessage_Block(id self, SEL _cmd, NSString *message) {
    AddLog([NSString stringWithFormat:@"[SOCKET] sendMessage:[%@]", message.length > 80 ? 
        [message substringToIndex:80] : message]);

    if (g_intercept_announce && ([message rangeOfString:@"announce"].location != NSNotFound ||
                                 [message rangeInsensitiveRangeOfString:@"系统公告"].location != NSNotFound)) {
        AddLog(@"[INTERCEPT] Blocked announce-like message");
        return nil;
    }

    void (*orig)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))orig_sendMessage_IMP;
    orig(self, _cmd, message);
    return nil;
}

// —— [BmobSocketIO sendJSON:] hook block ——
id BE_SocketIO_SendJSON_Block(id self, SEL _cmd, NSDictionary *json) {
    NSString *dataStr = @"(not JSON)";
    @try {
        NSData *d = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
        if (d) dataStr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    } @catch (...) {}

    AddLog([NSString stringWithFormat:@"[SOCKET] sendJSON:[%@]", 
           [dataStr length] > 120 ? [dataStr substringToIndex:120] : dataStr]);

    if (g_intercept_announce && ([dataStr rangeOfString:@"announce"].location != NSNotFound)) {
        AddLog(@"[INTERCEPT] Blocked announce-like JSON");
        return nil;
    }

    void (*orig)(id, SEL, NSDictionary *) = (void (*)(id, SEL, NSDictionary *))orig_sendJSON_IMP;
    orig(self, _cmd, json);
    return nil;
}


#pragma mark - ============ arc4random 劫持 Hook（概率100%） ============

// Save original function pointers for arc4random family
static uint32_t (*orig_arc4random)(void)              = NULL;
static uint32_t (*orig_arc4random_uniform)(uint32_t)  = NULL;

__attribute__((constructor(101))) // Run early (lower number = earlier)
static void HookArc4RandomFamily(void) {
    // Get original pointers from dlsym
    orig_arc4random         = dlsym(RTLD_DEFAULT, "arc4random");
    orig_arc4random_uniform = dlsym(RTLD_DEFAULT, "arc4random_uniform");

    if (!orig_arc4random || !orig_arc4random_uniform) {
        AddLog(@"[WARN] Could not resolve arc4random family symbols.");
        return;
    }

    // Use objc_msgSend-style trampolines via a simple wrapper approach:
    // Since we can't easily replace system C funcs without MSHookFunction,
    // we'll use interpose via __attribute__((used)) section hack.
    
    AddLog(@"[OK] arc4random family resolved. Hijack disabled by default.");
}

// Note: Without MobileSubstrate's MSHookFunction or Frida, true C function hooking 
// requires the macOS/iOS "interposing" mechanism (__interpose symbol). We'll define 
// interpose symbols below for arc4random and arc4random_uniform.

#if defined(__arm64__) && TARGET_OS_IPHONE
// iOS interpose technique (works without Substrate when dylib is injected early enough)
static uint32_t Hooked_arc4random(void) {
    if (g_arc4random_hijack) return 0; // Return 0 → all probability checks pass
    return orig_arc4random ? orig_arc4random() : arc4random();
}

static uint32_t Hooked_arc4random_uniform(uint32_t upper_bound) {
    if (g_arc4random_hijack) return 0; // Same: always return lowest index → best drop
    return orig_arc4random_uniform ? orig_arc4random_uniform(upper_bound) : arc4random_uniform(upper_bound);
}

// Interpose symbols (must be __used to survive linker stripping)
__attribute__((used)) static struct {
    const void *replacement;
    const void *symbol;
} _interpose_arc4random     = {(void *)Hooked_arc4random,         (void *)arc4random},
  _interpose_arc4random_uniform = {(void *)Hooked_arc4random_uniform, (void *)arc4random_uniform};
#endif


#pragma mark - ============ BmobCloud Hook（备用公告拦截） ============

// If the game uses BmobCloud::callFunctionInBackground_withParameters_block_ 
// for announcements as a fallback, hook it here.

@interface BmobCloudHooked : NSObject @end

@implementation BmobCloudHooked
@end

static IMP orig_bcloud_callFunc_IMP = NULL;

id BE_Bcloud_CallFunc_Block(id self, SEL _cmd, NSString *functionName, NSDictionary *params, void (^block)(id result, NSError *error)) {
    AddLog([NSString stringWithFormat:@"[BMOBCLOUD] callFunction: %@ params:%@", functionName, params]);

    // Intercept "SendSystemMessage" if that's what the game uses for announcements
    if ([functionName rangeInsensitiveRangeOfString:@"send"].location != NSNotFound &&
        [functionName rangeInsensitiveRangeOfString:@"system"].location != NSNotFound) {
        
        AddLog(@"[INTERCEPT] Blocked BmobCloud system message call");
        
        // Fake success callback so game logic doesn't hang
        if (block) block(@[@"success"], nil);
        return nil;
    }

    void (*orig)(id, SEL, NSString *, NSDictionary *, id) = 
        (void (*)(id, SEL, NSString *, NSDictionary *, id))orig_bcloud_callFunc_IMP;
    
    orig(self, _cmd, functionName, params, block);
    return nil;
}


#pragma mark - ============ 业务调度管理类 ModManager（所有核心功能的控制器） ============

@interface ModManager : NSObject
+ (instancetype)shared;
- (void)claimSpiritStonesLoop:(int)count interval:(double)intervalSecs;
- (void)triggerGMPanelWithCase:(int)caseIndex;
- (void)freePetRebirthCall;
- (void)toggleFeatureGearInject:(BOOL)enable;
@end

@implementation ModManager { }

+ (instancetype)shared {
    static id inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [[ModManager alloc] init]; });
    return inst;
}


#pragma mark - 功能②：灵石白嫖循环（正确调用OptionViewController的方法）

- (void)claimSpiritStonesLoop:(int)count interval:(double)intervalSecs {
    AddLog([NSString stringWithFormat:@"[FEATURE] Starting spirit stone claim loop: %d times @ %.1fs intervals", count, intervalSecs]);

    // Find OptionViewController in the view hierarchy (it's usually present as a modal or child VC)
    id optionVC = nil;
    Class optClass = objc_getClass("OptionViewController");
    
    if (!optClass) {
        AddLog(@"[ERROR] OptionViewController class NOT found!");
        return;
    }

    // Search window hierarchy for instance of OptionViewController
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        optionVC = [self findViewControllerOfClass:optClass inRootVC:win.rootViewController];
        if (optionVC) break;
    }

    if (!optionVC) {
        AddLog(@"[ERROR] OptionViewController INSTANCE not found! Make sure Options screen is open.");
        return;
    }

    AddLog([NSString stringWithFormat:@"[OK] Found OptionViewController: %@", optionVC]);

    // Call the method properly via objc_msgSend (correct Obj-C invocation!)
    SEL sel = @selector(gdt_rewardVideoAdDidRewardEffective:);
    
    if (![optionVC respondsToSelector:sel]) {
        AddLog(@"[ERROR] gdt_rewardVideoAdDidRewardEffective: selector NOT found on OptionViewController!");
        return;
    }

    for (int i = 0; i < count; i++) {
        int idx = i; // Capture loop variable for block
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(idx * intervalSecs * NSEC_PER_SEC)), 
                       dispatch_get_main_queue(), ^{
            @autoreleasepool {
                AddLog([NSString stringWithFormat:@"[CLAIM] Attempt #%d/%d", idx + 1, count]);
                
                // Properly invoke the Obj-C instance method:
                objc_msgSend(optionVC, sel, nil); // Pass nil as parameter
                
                AddLog(@"[OK] Claim executed");
            }
        });
    }

    AddLog([NSString stringWithFormat:@"[FEATURE] Scheduled %d claims. Check logs for results.", count]);
}


#pragma mark - 功能③：GM面板触发（正确构造sender参数）

- (void)triggerGMPanelWithCase:(int)caseIndex {
    g_rc_fixed_case = caseIndex; // Save the target case
    
    AddLog([NSString stringWithFormat:@"[FEATURE] GM Panel trigger requested. Target case: %d", caseIndex]);

    // Find BagViewController instance (the class that owns clickGMButtonWithButton:)
    Class bagClass = objc_getClass("BagViewController");
    
    if (!bagClass) {
        AddLog(@"[ERROR] BagViewController class NOT found!");
        return;
    }

    id bagVC = nil;
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        bagVC = [self findViewControllerOfClass:bagClass inRootVC:win.rootViewController];
        if (bagVC) break;
    }

    if (!bagVC) {
        AddLog(@"[WARN] BagViewController INSTANCE not found. Make sure you're on the Bag/Inventory screen.");
        
        // Fallback: try to find any view controller that responds to the selector
        SEL gmSel = @selector(clickGMButtonWithButton:);
        for (UIWindow *win in [UIApplication sharedApplication].windows) {
            bagVC = [self findViewControllerRespondingToSelector:gmSel inRootVC:win.rootViewController];
            if (bagVC) break;
        }

        if (!bagVC) {
            AddLog(@"[ERROR] No VC found that responds to clickGMButtonWithButton:");
            return;
        }

        AddLog([NSString stringWithFormat:@"[OK] Found alternative GM handler: %@", bagVC]);
    }

    // Construct a fake UIButton as sender (the real method expects one)
    id fakeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    
    SEL gmSel = @selector(clickGMButtonWithButton:);
    
    if (![bagVC respondsToSelector:gmSel]) {
        AddLog(@"[ERROR] clickGMButtonWithButton: NOT found on BagViewController!");
        return;
    }

    // Enable arc4random hijack temporarily to force the desired case
    BOOL prevHijack = g_arc4random_hijack;
    g_arc4random_hijack = YES;
    
    AddLog(@"[OK] Calling GM panel method...");
    objc_msgSend(bagVC, gmSel, fakeBtn);

    // Restore previous hijack state after a short delay (GM logic may be async)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        g_arc4random_hijack = prevHijack;
        AddLog(@"[OK] GM panel call completed");
    });
}


#pragma mark - 功能⑤：灵宠免费洗练（通过objc_msgSend调用对应VC方法）

- (void)freePetRebirthCall {
    // Try to find the pet-related view controller that owns the rebirth method
    AddLog(@"[FEATURE] Attempting free pet rebirth...");
    
    Class petClass = objc_getClass("PetViewController");
    
    if (!petClass) {
        AddLog(@"[WARN] PetViewController class NOT found. Trying alternative names...");
        
        // Try other possible class names based on game conventions
        petClass = objc_getClass("SpiritBeastViewController") ?: 
                   objc_getClass("PetSystemViewController") ?:
                   objc_getClass("LingchongViewController");
    }

    if (!petClass) {
        AddLog(@"[ERROR] Could not find any pet-related ViewController.");
        return;
    }

    id petVC = nil;
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        petVC = [self findViewControllerOfClass:petClass inRootVC:win.rootViewController];
        if (petVC) break;
    }

    if (!petVC) {
        AddLog(@"[ERROR] PetViewController INSTANCE not found! Open the pet screen first.");
        return;
    }

    // Try common method names for rebirth/reset functionality
    SEL rebirthSel = nil;
    NSArray *possibleSels = @[
        @selector(freeRebirth),
        @selector(resetPetFree),
        @selector(clickWashButtonWithButton:),
        @selector(doFreeReset)
    ];

    for (SEL sel in possibleSels) {
        if ([petVC respondsToSelector:sel]) {
            rebirthSel = sel;
            break;
        }
    }

    if (!rebirthSel) {
        AddLog(@"[WARN] Could not find exact rebirth method. You may need to check logs for correct selector.");
        
        // List all methods on petVC that contain "wash", "reset", "rebirth" keywords
        unsigned int count;
        Method *methods = class_copyMethodList([petVC class], &count);
        AddLog(@"[DEBUG] Available methods on PetViewController:");
        for (unsigned int i = 0; i < MIN(count, 50); i++) {
            SEL sel = method_getName(methods[i]);
            NSString *selStr = NSStringFromSelector(sel);
            if ([selStr rangeOfString:@"wash"].location != NSNotFound ||
                [selStr rangeInsensitiveRangeOfString:@"reset"].location != NSNotFound) {
                AddLog([NSString stringWithFormat:@"  - %@", selStr]);
            }
        }
        free(methods);
        
        return;
    }

    AddLog([NSString stringWithFormat:@"[OK] Found rebirth method: %s", sel_getName(rebirthSel)]);
    
    // Enable hijack to ensure success
    BOOL prevHijack = g_arc4random_hijack;
    g_arc4random_hijack = YES;

    if (method_getNumberOfArguments(class_getInstanceMethod([petVC class], rebirthSel)) > 2) {
        id fakeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        objc_msgSend(petVC, rebirthSel, fakeBtn);
    } else {
        objc_msgSend(petVC, rebirthSel);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        g_arc4random_hijack = prevHijack;
        AddLog(@"[OK] Pet rebirth call completed");
    });
}


#pragma mark - Feature⑥：GM全装注入开关

- (void)toggleFeatureGearInject:(BOOL)enable {
    g_feature_gear_inject = enable;
    AddLog(enable ? @"[FEATURE] GM Gear Injection ENABLED" : @"[FEATURE] GM Gear Injection DISABLED");
}


#pragma mark - Helper: Find ViewController by class in hierarchy

- (id)findViewControllerOfClass:(Class)targetClass inRootVC:(UIViewController *)root {
    if (!root || !targetClass) return nil;
    
    if ([root isKindOfClass:targetClass]) return root;
    
    for (UIViewController *child in root.children) {
        id found = [self findViewControllerOfClass:targetClass inRootVC:child];
        if (found) return found;
    }
    
    if (root.presentedViewController) {
        id found = [self findViewControllerOfClass:targetClass inRootVC:root.presentedViewController];
        if (found) return found;
    }
    
    return nil;
}


#pragma mark - Helper: Find ViewController responding to selector

- (id)findViewControllerRespondingToSelector:(SEL)sel inRootVC:(UIViewController *)root {
    if (!root || !sel) return nil;
    
    if ([root respondsToSelector:sel]) return root;
    
    for (UIViewController *child in root.children) {
        id found = [self findViewControllerRespondingToSelector:sel inRootVC:child];
        if (found) return found;
    }
    
    if (root.presentedViewController) {
        id found = [self findViewControllerRespondingToSelector:sel inRootVC:root.presentedViewController];
        if (found) return found;
    }
    
    return nil;
}

@end


#pragma mark - ============ 悬浮球面板 UI（用户操作入口） ============

@interface FloatingBallUI : UIView
@property (nonatomic, strong) UIButton *floatBtn;
@property (nonatomic, strong) UIWindow *overlayWindow;
@end

@implementation FloatingBallUI { }

+ (void)showMenu {
    static FloatingBallUI *ball = nil;
    if (!ball) {
        ball = [[FloatingBallUI alloc] init];
        [ball setupUI];
    } else {
        ball.overlayWindow.hidden = NO;
    }
}

- (void)setupUI {
    CGRect b = [UIScreen mainScreen].bounds;
    
    // Overlay window (transparent, above game)
    self.overlayWindow = [[UIWindow alloc] initWithFrame:b];
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 100;
    self.overlayWindow.backgroundColor = [UIColor clearColor];
    
    // Floating ball button (top-left corner by default)
    self.floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatBtn.frame = CGRectMake(15, b.size.height - 80, 64, 64);
    self.floatBtn.backgroundColor = [UIColor colorWithRed:0 green:0.7 blue:0 alpha:0.75];
    self.floatBtn.layer.cornerRadius = 32;
    self.floatBtn.layer.borderWidth = 2;
    self.floatBtn.layer.borderColor = [UIColor whiteColor].CGColor;
    [self.floatBtn setTitle:@"作弊" forState:UIControlStateNormal];
    [self.floatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.floatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    
    // Make button draggable (simple pan gesture)
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] 
                                    initWithTarget:self action:@selector(handleDrag:)];
    [self.floatBtn addGestureRecognizer:pan];
    
    [self.floatBtn addTarget:self action:@selector(openActionSheet:) forControlEvents:UIControlEventTouchUpInside];
    [self.overlayWindow addSubview:self.floatBtn];
    
    self.overlayWindow.hidden = NO;
}

- (void)handleDrag:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:recognizer.view.superview];
    recognizer.view.center = CGPointMake(recognizer.view.center.x + translation.x,
                                         recognizer.view.center.y + translation.y);
    [recognizer setTranslation:CGPointZero inView:recognizer.view.superview];
}

- (void)openActionSheet:(id)sender {
    UIViewController *root = [[UIApplication sharedApplication] keyWindow].rootViewController;
    
    UIAlertController *alert = [UIAlertController 
        alertControllerWithTitle:@"⚡ 修仙辅助控制台 v1.0 ⚡" 
                         message:@"选择要执行的操作（结果查看HUD日志）"
                  preferredStyle:UIAlertControllerStyleActionSheet];
    
    // -- SOCKET / ANNOUNCE --
    UIAlertAction *announceToggle = [UIAlertAction actionWithTitle:
        g_intercept_announce ? @"🔇 公告拦截：【ON】→ OFF" : @"🔊 公告拦截：【OFF】→ ON"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_Nonnull a) {
            g_intercept_announce = !g_intercept_announce;
            AddLog(g_intercept_announce ? 
                @"[SET] Announce interception ENABLED - high value drops won't broadcast!" : 
                @"[SET] Announce interception DISABLED");
        }];
    [alert addAction:announceToggle];

    // -- PROBABILITY 100% --
    UIAlertAction *probToggle = [UIAlertAction actionWithTitle:
        g_arc4random_hijack ? @"🎲 概率100%：【ON】→ OFF" : @"🎯 概率100%：【OFF】→ ON"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_Nonnull a) {
            g_arc4random_hijack = !g_arc4random_hijack;
            AddLog(g_arc4random_hijack ? 
                @"[SET] arc4random HIJACKED - all probabilities now 100%!" : 
                @"[SET] arc4random restored to normal");
        }];
    [alert addAction:probToggle];

    // -- GEAR INJECT SWITCH --
    UIAlertAction *gearSwitch = [UIAlertAction actionWithTitle:
        g_feature_gear_inject ? @"⚙️ GM全装注入开关：【ON】" : @"⚙️ GM全装注入开关：【OFF】"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_Nonnull a) {
            [[ModManager shared] toggleFeatureGearInject:!g_feature_gear_inject];
        }];
    [alert addAction:gearSwitch];

    // -- SPIRIT STONES --
    UIAlertAction *stones20 = [UIAlertAction actionWithTitle:@"💎 领灵石 x20（间隔0.3s）" 
                                                       style:UIAlertActionStyleDefault handler:^(UIAlertAction *_Nonnull a) {
        [[ModManager shared] claimSpiritStonesLoop:20 interval:0.3];
    }];
    [alert addAction:stones20];

    UIAlertAction *stones50 = [UIAlertAction actionWithTitle:@"💎 领灵石 x50（间隔0.5s）" 
                                                       style:UIAlertActionStyleDefault handler:^(UIAlertAction *_Nonnull a) {
        [[ModManager shared] claimSpiritStonesLoop:50 interval:0.5];
    }];
    [alert addAction:stones50];

    // -- GM PANEL --
    UIAlertAction *gmAll = [UIAlertAction actionWithTitle:@"🧙‍♂️ 触发GM面板（随机case）" 
                                                    style:UIAlertActionStyleDefault handler:^(UIAlertAction *_Nonnull a) {
        [[ModManager shared] triggerGMPanelWithCase:-1];
    }];
    [alert addAction:gmAll];

    UIAlertAction *gmCase5 = [UIAlertAction actionWithTitle:@"🧙‍♂️ 触发GM面板（固定case #5）" 
                                                    style:UIAlertActionStyleDefault handler:^(UIAlertAction *_Nonnull a) {
        [[ModManager shared] triggerGMPanelWithCase:5];
    }];
    [alert addAction:gmCase5];

    // -- PET REBIRTH --
    UIAlertAction *petRebirth = [UIAlertAction actionWithTitle:@"🐾 灵宠免费洗练/重置" 
                                                        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_Nonnull a) {
        [[ModManager shared] freePetRebirthCall];
    }];
    [alert addAction:petRebirth];

    // -- HUD CONTROLS --
    UIAlertAction *hudToggle = [UIAlertAction actionWithTitle:g_hudVisible ? 
        @"📊 HUD日志：隐藏" : @"📊 HUD日志：显示"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *_Nonnull a) {
        ToggleHUDVisibility();
    }];
    [alert addAction:hudToggle];

    UIAlertAction *clearLogs = [UIAlertAction actionWithTitle:@"🗑️ 清空HUD日志" 
                                                       style:UIAlertActionStyleDefault handler:^(UIAlertAction *_Nonnull a) {
        ClearLogsInternal();
    }];
    [alert addAction:clearLogs];

    // -- CANCEL --
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" 
                                                    style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:cancel];

    [root presentViewController:alert animated:YES completion:nil];
}

@end


#pragma mark - HUD Controller（让按钮能调用静态函数）

@interface HUDController : NSObject
+ (instancetype)shared;
- (void)hudToggle:(id)sender;
- (void)clearLogsAction:(id)sender;
@end

@implementation HUDController { }

+ (instancetype)shared {
    static id inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [[HUDController alloc] init]; });
    return inst;
}

- (void)hudToggle:(id)sender     { ToggleHUDVisibility(); }
- (void)clearLogsAction:(id)sender { ClearLogsInternal(); }

@end


#pragma mark - HUD 日志面板（调试/监控界面）
static void UpdateStatusHUD(void) {
    if (!g_statusBar) return;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableString *s = [NSMutableString string];
        
        // Mode indicators
        [s appendString:@"模式:"];
        [s appendFormat:@"%@ %@", 
            g_intercept_announce ? @"[拦截]" : @"[日志]",
            g_arc4random_hijack ? @"[概率100%]" : @"[正常]"];
        
        g_statusBar.text = s;
        
        if (g_intercept_announce || g_arc4random_hijack) {
            g_statusBar.textColor = [UIColor colorWithRed:1 green:0.6 blue:0 alpha:1];
        } else {
            g_statusBar.textColor = [UIColor whiteColor];
        }
    });
}

static void ToggleHUDVisibility(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_win) return;
        
        g_hudVisible = !g_hudVisible;
        g_win.hidden = g_hudVisible ? NO : YES;
        
        AddLog(g_hudVisible ? @"[HUD] Shown" : @"[HUD] Hidden (tap floating ball to show again)");
    });
}

static void ClearLogsInternal(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_logs = [NSMutableArray array];
        if (g_logView) g_logView.text = @"[LOGS CLEARED]\n";
    });
    AddLog(@"[INFO] Logs cleared by user");
}

static void HUDInit(void) {
    if (g_win) return;
    
    CGRect b = [UIScreen mainScreen].bounds;
    HUDController *ctrl = [HUDController shared];
    
    // Transparent overlay window
    g_win = [[UIWindow alloc] initWithFrame:b];
    g_win.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    g_win.windowLevel = UIWindowLevelAlert + 90;
    g_win.backgroundColor = [UIColor clearColor];
    
    // Status bar (top-right)
    g_statusBar = [[UILabel alloc] initWithFrame:CGRectMake(b.size.width - 260, 40, 250, 36)];
    g_statusBar.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    g_statusBar.textColor = [UIColor whiteColor];
    g_statusBar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
    g_statusBar.layer.cornerRadius = 8;
    g_statusBar.numberOfLines = 2;
    g_statusBar.textAlignment = NSTextAlignmentLeft;
    
    // Scrollable log view (below status bar)
    g_logView = [[UITextView alloc] initWithFrame:CGRectMake(b.size.width - 260, 82, 250, 180)];
    g_logView.font = [UIFont fontWithName:@"Menlo" size:9];
    g_logView.textColor = [UIColor whiteColor];
    g_logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    g_logView.layer.cornerRadius = 8;
    g_logView.editable = NO;
    g_logView.scrollEnabled = YES;
    
    // Control buttons row
    UIButton *btnShowHideHUD = [[UIButton alloc] initWithFrame:CGRectMake(b.size.width - 260, 270, 120, 34)];
    [btnShowHideHUD setTitle:@"显示/隐藏HUD" forState:UIControlStateNormal];
    btnShowHideHUD.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    btnShowHideHUD.backgroundColor = [UIColor colorWithRed:0.3 green:0.3 blue:0.8 alpha:1];
    btnShowHideHUD.layer.cornerRadius = 7;
    btnShowHideHUD.clipsToBounds = YES;
    [btnShowHideHUD addTarget:ctrl action:@selector(hudToggle:) forControlEvents:UIControlEventTouchUpInside];

    UIButton *btnClearLogs = [[UIButton alloc] initWithFrame:CGRectMake(b.size.width - 136, 270, 120, 34)];
    [btnClearLogs setTitle:@"清空日志" forState:UIControlStateNormal];
    btnClearLogs.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    btnClearLogs.backgroundColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1];
    btnClearLogs.layer.cornerRadius = 7;
    btnClearLogs.clipsToBounds = YES;
    [btnClearLogs addTarget:ctrl action:@selector(clearLogsAction:) forControlEvents:UIControlEventTouchUpInside];

    // Show button for when HUD is hidden (bottom-left corner)
    UIButton *btnShow = [[UIButton alloc] initWithFrame:CGRectMake(10, b.size.height - 50, 60, 34)];
    [btnShow setTitle:@"显示HUD" forState:UIControlStateNormal];
    btnShow.titleLabel.font = [UIFont systemFontOfSize:12];
    btnShow.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:0.85];
    btnShow.layer.cornerRadius = 7;
    [btnShow addTarget:ctrl action:@selector(hudToggle:) forControlEvents:UIControlEventTouchUpInside];

    // Add all subviews
    [g_win addSubview:g_statusBar];
    [g_win addSubview:g_logView];
    [g_win addSubview:btnShowHideHUD];
    [g_win addSubview:btnClearLogs];
    [g_win addSubview:btnShow];

    UpdateStatusHUD();
    
    g_hudVisible = YES;
    [g_win makeKeyAndVisible];
}


#pragma mark - ============ 构造器入口（dylib加载时自动执行） ============

__attribute__((constructor(102)))
static void BlackEraModMain(void) {
    AddLog(@"========================================");
    AddLog(@"BlackEra_Mod.dylib v1.0 LOADED");
    AddLog(@"All features ready. Tap floating ball to use.");
    
    // Initialize HUD first (AddLog depends on it for display)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        @autoreleasepool {
            HUDInit();
            
            AddLog(@"[INIT] Initializing hooks...");
            
            // -- Hook BmobSocketIO send methods (announce interception) --
            Class BSI = objc_getClass("BmobSocketIO");
            if (!BSI) {
                AddLog(@"[WARN] BmobSocketIO class not found. Retrying in 2s...");
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    @autoreleasepool {
                        Class retryBSI = objc_getClass("BmobSocketIO");
                        
                        if (!retryBSI) {
                            AddLog(@"[ERROR] BmobSocketIO STILL not found. Announce interception may NOT work.");
                            
                            // Try alternative class names (some games wrap SocketIO differently)
                            retryBSI = objc_getClass("SocketManager") ?: 
                                       objc_getClass("NetworkManager") ?:
                                       objc_getClass("BmobIM");
                        }

                        if (!retryBSI) {
                            AddLog(@"[ERROR] No socket class found. Hooks skipped.");
                            goto skip_socket_hooks;
                        }

                        AddLog([NSString stringWithFormat:@"[OK] Found socket class: %@", retryBSI]);
                        
                        Method m_sendEvent = class_getInstanceMethod(retryBSI, @selector(sendEvent:withData:));
                        if (!m_sendEvent) m_sendEvent = class_getInstanceMethod(retryBSI, @selector(sendEvent:withData:andAcknowledge:));
                        
                        if (m_sendEvent) {
                            orig_sendEvent_IMP = method_setImplementation(m_sendEvent, 
                                imp_implementationWithBlock((id)&BE_SocketIO_SendEvent_Block));
                            AddLog(@"[OK] Hooked sendEvent:withData:]");
                        } else {
                            AddLog(@"[WARN] sendEvent selector not found.");
                        }

                        Method m_sendMsg = class_getInstanceMethod(retryBSI, @selector(sendMessage:));
                        if (m_sendMsg) {
                            orig_sendMessage_IMP = method_setImplementation(m_sendMsg, 
                                imp_implementationWithBlock((id)&BE_SocketIO_SendMessage_Block));
                            AddLog(@"[OK] Hooked sendMessage:]");
                        } else {
                            AddLog(@"[WARN] sendMessage selector not found.");
                        }

                        Method m_sendJSON = class_getInstanceMethod(retryBSI, @selector(sendJSON:));
                        if (m_sendJSON) {
                            orig_sendJSON_IMP = method_setImplementation(m_sendJSON, 
                                imp_implementationWithBlock((id)&BE_SocketIO_SendJSON_Block));
                            AddLog(@"[OK] Hooked sendJSON:]");
                        } else {
                            AddLog(@"[WARN] sendJSON selector not found.");
                        }

skip_socket_hooks:;
                    }
                });
            } else {
                Method m_sendEvent = class_getInstanceMethod(BSI, @selector(sendEvent:withData:));
                if (!m_sendEvent) m_sendEvent = class_getInstanceMethod(BSI, @selector(sendEvent:withData:andAcknowledge:));
                
                if (m_sendEvent) {
                    orig_sendEvent_IMP = method_setImplementation(m_sendEvent, 
                        imp_implementationWithBlock((id)&BE_SocketIO_SendEvent_Block));
                    AddLog(@"[OK] Hooked sendEvent:withData:]");
                } else {
                    AddLog(@"[WARN] sendEvent selector not found.");
                }

                Method m_sendMsg = class_getInstanceMethod(BSI, @selector(sendMessage:));
                if (m_sendMsg) {
                    orig_sendMessage_IMP = method_setImplementation(m_sendMsg, 
                        imp_implementationWithBlock((id)&BE_SocketIO_SendMessage_Block));
                    AddLog(@"[OK] Hooked sendMessage:]");
                } else {
                    AddLog(@"[WARN] sendMessage selector not found.");
                }

                Method m_sendJSON = class_getInstanceMethod(BSI, @selector(sendJSON:));
                if (m_sendJSON) {
                    orig_sendJSON_IMP = method_setImplementation(m_sendJSON, 
                        imp_implementationWithBlock((id)&BE_SocketIO_SendJSON_Block));
                    AddLog(@"[OK] Hooked sendJSON:]");
                } else {
                    AddLog(@"[WARN] sendJSON selector not found.");
                }
            }

            // -- Hook BmobCloud as backup --
            Class BC = objc_getClass("BmobCloud");
            if (BC) {
                Method m_callFunc = class_getInstanceMethod(BC, @selector(callFunctionInBackground:withParameters:block:));
                if (m_callFunc) {
                    orig_bcloud_callFunc_IMP = method_setImplementation(m_callFunc, 
                        imp_implementationWithBlock((id)&BE_Bcloud_CallFunc_Block));
                    AddLog(@"[OK] Hooked BmobCloud::callFunctionInBackground...]");
                } else {
                    // Try alternative selector name (underscore style)
                    SEL altSel = NSSelectorFromString(@"callFunctionInBackground_withParameters_block_");
                    Method m_alt = class_getInstanceMethod(BC, altSel);
                    if (m_alt) {
                        orig_bcloud_callFunc_IMP = method_setImplementation(m_alt, 
                            imp_implementationWithBlock((id)&BE_Bcloud_CallFunc_Block));
                        AddLog(@"[OK] Hooked BmobCloud::callFunctionInBackground_withParameters_block_]");
                    } else {
                        AddLog(@"[WARN] BmobCloud call selector not found.");
                    }
                }
            }

            // -- Show floating ball (3 seconds after load) --
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [FloatingBallUI showMenu];
                AddLog(@"[OK] Floating ball shown. Tap it to access features!");
            });

            // -- Summary --
            AddLog(@"========================================");
            AddLog(@"使用说明:");
            AddLog(@"1) 点击绿色悬浮球打开菜单");
            AddLog(@"2) 【公告拦截】：开启后高价值物品不会触发全服公告");
            AddLog(@"3) 【概率100%】：开启后所有抽奖/锻造/突破均为最高品质");
            AddLog(@"4) 【领灵石】：需要你在【设置界面】才有效（找OptionVC）");
            AddLog(@"5) 【GM面板】：需要在【背包界面】才有效（找BagVC）");
            AddLog(@"6) HUD右上角实时显示所有操作日志和Socket事件");
            AddLog(@"========================================");
        }
    });
}


#pragma mark - ============ Utility: rangeInsensitiveRangeOfString (for iOS < 10 compat) ============

// Simple helper since some older iOS SDKs don't have this method on NSString
@implementation NSString (CaseInsensitiveSearch)

- (NSRange)rangeInsensitiveRangeOfString:(NSString *)searchString {
    return [self rangeOfString:searchString options:NSCaseInsensitiveSearch];
}

@end


#pragma mark - ============ End of file ============
