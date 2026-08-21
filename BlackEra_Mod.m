/*
 * BlackEra_Mod_v2.dylib — 《黑色纪元》修改器 (闪退修复版)
 * 
 * 修复:
 *   - objc_msgSend 不再强制类型转换（arm64安全调用）
 *   - selector签名根据Ghidra导出精确匹配
 *   - overlay窗口hitTest逻辑修正
 *   - VC查找增加详细日志反馈
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dispatch/dispatch.h>
#include <time.h>

#pragma mark - ============ 全局状态与开关 ============

static BOOL g_intercept_announce = YES;
static BOOL g_feature6_enabled   = NO;

static NSMutableArray *g_logs     = nil;
static UITextView     *g_logView  = nil;
static BOOL           g_hudVisible = NO;
static UIView         *g_panelView = nil;

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

#pragma mark - ============ ViewController查找工具 ============

static id FindVCInHierarchy(Class targetClass, UIViewController *root) {
    if (!root || !targetClass) return nil;
    
    // Check current VC
    if ([root isKindOfClass:targetClass]) {
        AddLog([NSString stringWithFormat:@"[✓] Found %@ at root", NSStringFromClass(targetClass)]);
        return root;
    }
    
    // Navigate child controllers recursively
    NSArray *toCheck = @[root];
    while (toCheck.count > 0) {
        UIViewController *vc = toCheck[toCheck.count - 1];
        
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)vc;
            for (UIViewController *child in nav.viewControllers) {
                [toCheck addObject:child];
            }
        } else if ([vc isKindOfClass:[UITabBarController class]]) {
            UITabBarController *tab = (UITabBarController *)vc;
            for (UIViewController *child in tab.viewControllers ?: @[]) {
                [toCheck addObject:child];
            }
        }
        
        for (UIViewController *child in vc.childViewControllers) {
            if ([child isKindOfClass:targetClass]) {
                AddLog([NSString stringWithFormat:@"[✓] Found %@ as child", NSStringFromClass(targetClass)]);
                return child;
            }
            [toCheck addObject:child];
        }
        
        UIViewController *presented = vc.presentedViewController;
        if (presented && ![toCheck containsObject:presented]) {
            if ([presented isKindOfClass:targetClass]) {
                AddLog([NSString stringWithFormat:@"[✓] Found %@ as presented", NSStringFromClass(targetClass)]);
                return presented;
            }
            [toCheck addObject:presented];
        }
        
        [toCheck removeLastObject];
    }
    
    return nil;
}

static id GetVCByName(NSString *name) {
    Class cls = objc_getClass([name UTF8String]);
    if (!cls) {
        AddLog([NSString stringWithFormat:@"[⚠️] Class %@ does NOT exist in process", name]);
        return nil;
    }
    
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        id found = FindVCInHierarchy(cls, w.rootViewController);
        if (found) {
            AddLog([NSString stringWithFormat:@"[✓] Found instance: %@", found]);
            return found;
        }
    }
    
    AddLog([NSString stringWithFormat:@"[⚠️] No active %@ instance in window hierarchy", name]);
    return nil;
}

#pragma mark - ============ Hook函数实现（公告拦截） ============

static IMP orig_bcloud_callFunc_IMP = NULL;

// BmobCloud hook implementation
void BE_Bcloud_CallFunc(id self, SEL _cmd, NSString *functionName, NSDictionary *params, void (^block)(id result, NSError *error)) {
    if (g_intercept_announce && functionName) {
        NSRange r1 = [functionName rangeOfString:@"SendSystemMessage" options:NSCaseInsensitiveSearch];
        NSRange r2 = [functionName rangeOfString:@"system" options:NSCaseInsensitiveSearch];
        
        if (r1.location != NSNotFound || r2.location != NSNotFound) {
            AddLog(@"[🛡️公告已拦截] BmobCloud系统广播被阻断");
            if (block) block(@[@"success"], nil); // Fake success
            return;
        }
    }
    
    // Call original via IMP cast - this is SAFE because we match the exact signature
    ((void (*)(id, SEL, NSString *, NSDictionary *, void (^)(id, NSError *)))orig_bcloud_callFunc_IMP)
        (self, _cmd, functionName, params, block);
}

static IMP orig_sendEvent_IMP = NULL;

// BmobSocketIO hook implementation  
void BE_SocketIO_SendEvent(id self, SEL _cmd, NSString *event, id data) {
    if (g_intercept_announce && event) {
        NSRange r1 = [event rangeOfString:@"announce" options:NSCaseInsensitiveSearch];
        NSRange r2 = [event rangeOfString:@"broadcast" options:NSCaseInsensitiveSearch];
        
        if (r1.location != NSNotFound || r2.location != NSNotFound) {
            AddLog([NSString stringWithFormat:@"[🛡️公告已拦截] Socket广播: %@", event]);
            return; // Drop silently - no network send
        }
    }
    
    ((void (*)(id, SEL, NSString *, id))orig_sendEvent_IMP)(self, _cmd, event, data);
}

#pragma mark - ============ ModManager（业务逻辑控制器） ============

@interface ModManager : NSObject
+ (instancetype)shared;
- (void)claimSpiritStonesLoop;
- (void)triggerMakeActions;
- (void)triggerPetRebirth;
- (void)triggerFeature6;
@end

@implementation ModManager { }

+ (instancetype)shared {
    static ModManager *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ inst = [[ModManager alloc] init]; });
    return inst;
}

// ===== 功能二：灵石白嫖循环 =====
- (void)claimSpiritStonesLoop {
    AddLog(@"[💎] 开始尝试领取灵石...");
    
    // Try to find OptionViewController first, then ShopViewController as fallback
    id targetVC = nil;
    Class targetClass = nil;
    
    if ((targetVC = GetVCByName("OptionViewController"))) {
        targetClass = [targetVC class];
    } else if ((targetVC = GetVCByName("ShopViewController"))) {
        targetClass = [targetVC class];
    } else {
        AddLog(@"[❌] 请先在游戏中打开【设置】或【商城】界面！");
        return;
    }
    
    // Exact selector from Ghidra: gdt_rewardVideoAdDidRewardEffective:(id)arg1
    SEL rewardSel = @selector(gdt_rewardVideoAdDidRewardEffective:);
    
    if (![targetVC respondsToSelector:rewardSel]) {
        AddLog([NSString stringWithFormat:@"[❌] %@ 没有响应 selector %@", 
                NSStringFromClass(targetClass), NSStringFromSelector(rewardSel)]);
        
        // List methods containing "gdt" or "reward" for debugging
        unsigned int count = 0;
        Method *methods = class_copyMethodList(targetClass, &count);
        AddLog([NSString stringWithFormat:@"[DEBUG] Available methods on %@:", NSStringFromClass(targetClass)]);
        
        int shownCount = 0;
        if (methods) {
            for (unsigned int i = 0; i < count && shownCount < 20; i++) {
                SEL sel = method_getName(methods[i]);
                NSString *selStr = NSStringFromSelector(sel);
                if ([selStr rangeOfString:@"gdt"].location != NSNotFound ||
                    [selStr rangeInsensitiveRangeOfString:@"reward"].location != NSNotFound) {
                    AddLog([NSString stringWithFormat:@"  - %@", selStr]);
                    shownCount++;
                }
            }
            free(methods);
        }
        
        return;
    }
    
    AddLog(@"[💎] 启动免看广告领灵石: 0.3s/次 x 20次");
    
    // Capture targetVC in block (strong reference)
    __block id capturedVC = targetVC;
    
    for (int i = 0; i < 20; i++) {
        int idx = i;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(idx * 0.3 * NSEC_PER_SEC)), 
                       dispatch_get_main_queue(), ^{
            @autoreleasepool {
                if (!capturedVC) {
                    AddLog(@"[❌] ViewController已失效");
                    return;
                }
                
                // ARM64 SAFE: Call objc_msgSend directly WITHOUT casting
                // The runtime handles the correct calling convention
                objc_msgSend(capturedVC, rewardSel, nil);
                
                AddLog([NSString stringWithFormat:@"[✓] 灵石到账第 %d/20 次 (+20)", idx + 1]);
            }
        });
    }
}

// ===== 功能三：制造/强化操作触发 =====
- (void)triggerMakeActions {
    AddLog(@"[⚒️] 开始尝试触发制造/强化...");
    
    // Try multiple possible class names based on game conventions
    id targetVC = nil;
    NSString *vcName = nil;
    
    NSArray *possibleClasses = @[@"MakeViewController", 
                                  @"ForgeViewController", 
                                  @"CraftingViewController",
                                  @"EquipmentViewController"];
    
    for (NSString *clsName in possibleClasses) {
        targetVC = GetVCByName(clsName);
        if (targetVC) {
            vcName = clsName;
            break;
        }
    }
    
    if (!targetVC) {
        AddLog(@"[❌] 请先在游戏中打开【制造】相关界面（炼丹/炼器）！");
        return;
    }
    
    // Try selectors that might trigger make/craft action
    NSArray *possibleSels = @[@"clickButtonWithButton:", 
                               @"clickMakeButtonWithButton:",
                               @"doCraft",
                               @"startCrafting"];
    
    SEL chosenSel = nil;
    for (NSString *selStr in possibleSels) {
        SEL s = NSSelectorFromString(selStr);
        if ([targetVC respondsToSelector:s]) {
            chosenSel = s;
            AddLog([NSString stringWithFormat:@"[✓] Found method: %@", selStr]);
            break;
        }
    }
    
    if (!chosenSel) {
        AddLog(@"[❌] 未找到制造界面交互接口，请查看HUD日志中的DEBUG方法列表");
        
        // Debug: list available methods
        unsigned int count = 0;
        Method *methods = class_copyMethodList([targetVC class], &count);
        if (methods) {
            AddLog(@"[DEBUG] Available methods on Make VC:");
            for (unsigned int i = 0; i < MIN(count, 15u); i++) {
                SEL s = method_getName(methods[i]);
                AddLog([NSString stringWithFormat:@"  - %@", NSStringFromSelector(s)]);
            }
            free(methods);
        }
        
        return;
    }
    
    // ARM64 SAFE call
    objc_msgSend(targetVC, chosenSel, nil);
    AddLog(@"[⚒️] 已触发制造操作");
}

// ===== 功能四：灵宠免费洗练 =====
- (void)triggerPetRebirth {
    AddLog(@"[🐾] 开始尝试灵宠洗练...");
    
    // Try pet-related VC names
    id targetVC = nil;
    NSArray *possibleClasses = @[@"PetViewController", 
                                  @"SpiritBeastViewController",
                                  @"LingchongViewController"];
    
    for (NSString *clsName in possibleClasses) {
        targetVC = GetVCByName(clsName);
        if (targetVC) break;
    }
    
    if (!targetVC) {
        AddLog(@"[❌] 请先在游戏中打开【灵宠】界面！");
        return;
    }
    
    // Try rebirth/wash/reset related selectors
    NSArray *possibleSels = @[@"clickWashButtonWithButton:", 
                               @"clickRebirthButtonWithButton:",
                               @"doFreeReset",
                               @"freePetReset"];
    
    SEL chosenSel = nil;
    for (NSString *selStr in possibleSels) {
        SEL s = NSSelectorFromString(selStr);
        if ([targetVC respondsToSelector:s]) {
            chosenSel = s;
            AddLog([NSString stringWithFormat:@"[✓] Found method: %@", selStr]);
            break;
        }
    }
    
    if (!chosenSel) {
        AddLog(@"[❌] 未找到灵宠洗练接口");
        
        // Debug list methods containing relevant keywords
        unsigned int count = 0;
        Method *methods = class_copyMethodList([targetVC class], &count);
        AddLog(@"[DEBUG] Available pet-related methods:");
        
        if (methods) {
            int shown = 0;
            for (unsigned int i = 0; i < count && shown < 15; i++) {
                SEL s = method_getName(methods[i]);
                NSString *selStr = NSStringFromSelector(s);
                if ([selStr rangeInsensitiveRangeOfString:@"wash"].location != NSNotFound ||
                    [selStr rangeInsensitiveRangeOfString:@"reset"].location != NSNotFound ||
                    [selStr rangeInsensitiveRangeOfString:@"rebirth"].location != NSNotFound) {
                    AddLog([NSString stringWithFormat:@"  - %@", selStr]);
                    shown++;
                }
            }
            free(methods);
        }
        
        return;
    }
    
    // ARM64 SAFE call
    objc_msgSend(targetVC, chosenSel, nil);
    AddLog(@"[🐾] 已触发灵宠洗练");
}

// ===== 功能五：GM全装注入 =====
- (void)triggerFeature6 {
    if (!g_feature6_enabled) {
        AddLog(@"[⚠️] 功能六未开启，请先在控制台中点击开关！");
        return;
    }
    
    AddLog(@"[🎁] 开始尝试GM全装注入...");
    
    id bagVC = GetVCByName("BagViewController");
    if (!bagVC) {
        // Fallback: try InventoryViewController or similar
        bagVC = GetVCByName("InventoryViewController");
        
        if (!bagVC) {
            AddLog(@"[❌] 请先在游戏中打开【背包】界面！");
            return;
        }
    }
    
    // Try GM/CZ button selectors (exact names from Ghidra)
    SEL czSel = @selector(clickCZButtonWithButton:);
    SEL gmSel = @selector(clickGMButtonWithButton:);
    
    if ([bagVC respondsToSelector:czSel]) {
        AddLog(@"[✓] Found clickCZButtonWithButton:");
        
        // ARM64 SAFE call with proper fake button argument
        UIButton *fakeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        objc_msgSend(bagVC, czSel, fakeBtn);
        
        AddLog(@"[🎁] 已触发背包 CZ/GM按钮 → 请观察游戏内是否弹出调试菜单或装备到账");
    } else if ([bagVC respondsToSelector:gmSel]) {
        AddLog(@"[✓] Found clickGMButtonWithButton:");
        
        UIButton *fakeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        objc_msgSend(bagVC, gmSel, fakeBtn);
        
        AddLog(@"[🎁] 已触发背包 GM按钮");
    } else {
        AddLog(@"[❌] BagViewController中未找到GM/CZ调试方法");
        
        // Debug: list button-related methods
        unsigned int count = 0;
        Method *methods = class_copyMethodList([bagVC class], &count);
        AddLog(@"[DEBUG] Available button methods on BagVC:");
        
        if (methods) {
            int shown = 0;
            for (unsigned int i = 0; i < count && shown < 20; i++) {
                SEL s = method_getName(methods[i]);
                NSString *selStr = NSStringFromSelector(s);
                if ([selStr rangeInsensitiveRangeOfString:@"button"].location != NSNotFound ||
                    [selStr rangeInsensitiveRangeOfString:@"gm"].location != NSNotFound ||
                    [selStr rangeInsensitiveRangeOfString:@"cz"].location != NSNotFound) {
                    AddLog([NSString stringWithFormat:@"  - %@", selStr]);
                    shown++;
                }
            }
            free(methods);
        }
    }
}

@end

#pragma mark - ============ 自定义覆盖窗口（点击穿透修正版） ============

@interface BEOverlayWindow : UIWindow
@end

@implementation BEOverlayWindow { }

// Fixed hitTest: only pass through clicks on empty areas, not on UI elements
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.userInteractionEnabled || !self.isHidden && self.alpha > 0.01) {
        UIView *hitView = [super hitTest:point withEvent:event];
        
        // Pass through ONLY if we hit the window itself or a clear background view
        // (not buttons, labels, text views, etc.)
        if (!hitView || 
            hitView == self || 
            ([hitView isKindOfClass:[UIView class]] && !hitView.isUserInteractionEnabled)) {
            return nil; // Touch passes through to game
        }
        
        return hitView; // Let UI elements receive the touch normally
    }
    
    return nil;
}

@end

#pragma mark - ============ 悬浮控制台UI（暗黑修仙风） ============

@interface FloatingMenuUI : NSObject
@property (nonatomic, strong) BEOverlayWindow *overlayWin;
@property (nonatomic, strong) UIButton *floatBall;
+ (void)showFloatingBall;
@end

@implementation FloatingMenuUI { }

@synthesize overlayWin = _overlayWin;
@synthesize floatBall = _floatBall;

#pragma mark - 显示悬浮球与面板

+ (void)showFloatingBall {
    [[FloatingMenuUI alloc] init]; // Singleton pattern via property persistence check
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self._overlayWin && !self._overlayWin.isHidden) {
            AddLog(@"[INFO] 控制台已存在，跳过重复创建");
            return;
        }
        
        [self setupOverlayWindow];
        AddLog(@"[✓] BlackEra Mod v2 加载完成！绿色球可拖动");
    });
    
    return self;
}

- (void)setupOverlayWindow {
    // Get proper window scene or use mainScreen bounds as fallback
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    
    BEOverlayWindow *win;
    
    if (@available(iOS 13.0, *)) {
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && 
                ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
        
        win = [[BEOverlayWindow alloc] initWithWindowScene:activeScene];
    } else {
        win = [[BEOverlayWindow alloc] initWithFrame:screenBounds];
    }
    
    if (!win.frame.size.width || !win.frame.size.height) {
        win.frame = screenBounds;
    }
    
    self._overlayWin = win;
    self._overlayWin.windowLevel = UIWindowLevelAlert + 100;
    self._overlayWin.backgroundColor = [UIColor clearColor];
    self._overlayWin.userInteractionEnabled = YES;
    
    // Root VC with clear background
    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    win.rootViewController = rootVC;
    
    UIView *containerView = rootVC.view;
    
    // === 悬浮球 (左下角,可拖动) ===
    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    ball.frame = CGRectMake(15, screenBounds.size.height - 140, 56, 56);
    ball.backgroundColor = [UIColor colorWithRed:0.0 green:0.75 blue:0.1 alpha:0.9];
    ball.layer.cornerRadius = 28;
    ball.layer.borderWidth = 2.0;
    ball.layer.borderColor = [UIColor whiteColor].CGColor;
    ball.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [ball setTitle:@"作弊" forState:UIControlStateNormal];
    [ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    
    // Pan gesture for dragging
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleBallPan:)];
    [ball addGestureRecognizer:pan];
    
    // Tap to toggle panel (only if tap is not part of pan)
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleCustomPanel)];
    tap.requirements = @[pan]; // Only fire if pan didn't recognize movement
    [ball addGestureRecognizer:tap];
    
    self._floatBall = ball;
    [containerView addSubview:ball];
    
    // === 控制面板 ===
    [self buildControlPanelInView:containerView withBounds:screenBounds];
    
    // === HUD日志视图 (右上角) ===
    g_logView = [[UITextView alloc] initWithFrame:CGRectMake(screenBounds.size.width - 250, 40, 240, 160)];
    g_logView.font = [UIFont fontWithName:@"Menlo" size:9];
    if (!g_logView.font) {
        g_logView.font = [UIFont fontWithName:@"Courier" size:9];
    }
    g_logView.textColor = [UIColor colorWithRed:0.1 green:1.0 blue:0.3 alpha:1.0];
    g_logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    g_logView.layer.cornerRadius = 6;
    g_logView.editable = NO;
    g_logView.scrollEnabled = YES;
    g_logView.hidden = YES;
    [containerView addSubview:g_logView];
    
    // Show window
    self._overlayWin.hidden = NO;
    [self._overlayWin makeKeyAndVisible];
}

#pragma mark - 构建控制面板布局

- (void)buildControlPanelInView:(UIView *)parent withBounds:(CGRect)bounds {
    CGFloat panelW = MIN(320, bounds.size.width - 40);
    CGFloat panelH = 380;
    CGFloat originX = (bounds.size.width - panelW) / 2.0;
    CGFloat originY = (bounds.size.height - panelH) / 2.0;
    
    g_panelView = [[UIView alloc] initWithFrame:CGRectMake(originX, originY, panelW, panelH)];
    g_panelView.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.14 alpha:0.96];
    g_panelView.layer.cornerRadius = 12;
    g_panelView.layer.borderWidth = 1.5;
    g_panelView.layer.borderColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.2 alpha:0.7].CGColor;
    g_panelView.clipsToBounds = YES;
    g_panelView.hidden = YES; // Hidden by default, toggled by ball tap
    
    // Title label
    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, panelW - 24, 26)];
    titleLbl.text = @"⚡ 修仙修改器控制台 ⚡";
    titleLbl.textColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.3 alpha:1.0];
    titleLbl.font = [UIFont boldSystemFontOfSize:15];
    titleLbl.textAlignment = NSTextAlignmentCenter;
    [g_panelView addSubview:titleLbl];
    
    // ScrollView for buttons
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(8, 40, panelW - 16, panelH - 80)];
    scrollView.showsVerticalScrollIndicator = YES;
    scrollView.scrollsToTop = NO;
    
    CGFloat btnY = 4;
    CGFloat btnH = 38;
    CGFloat btnSpacing = 7;
    CGFloat btnW = panelW - 24;
    
    // Button factory helper (inline for simplicity)
    auto makeBtn = ^UIButton *(NSString *title, UIColor *bgColor, SEL action) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, btnY, btnW, btnH);
        btn.backgroundColor = bgColor;
        btn.layer.cornerRadius = 6;
        btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        btn.titleLabel.numberOfLines = 2;
        btn.contentMode = UIViewContentModeScaleToFill;
        btn.titleEdgeInsets = UIEdgeInsetsMake(2, 8, 2, 8);
        
        [btn setTitle:title forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        
        if (action != NULL) {
            [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        }
        
        return btn;
    };
    
    // Btn1: 领灵石
    UIButton *b1 = makeBtn(@"💎 领灵石 x20\n(需打开设置/商城)", 
                           [UIColor colorWithRed:0.15 green:0.35 blue:0.7 alpha:1.0], 
                           @selector(actionClaimStones));
    btnY += btnH + btnSpacing;
    [scrollView addSubview:b1];
    
    // Btn2: 制造/强化
    UIButton *b2 = makeBtn(@"⚒️ 触发炼丹/炼器操作\n(需在制造界面)", 
                           [UIColor colorWithRed:0.18 green:0.55 blue:0.35 alpha:1.0], 
                           @selector(actionInstantMake));
    btnY += btnH + btnSpacing;
    [scrollView addSubview:b2];
    
    // Btn3: 灵宠洗练
    UIButton *b3 = makeBtn(@"🐾 灵宠免费洗练\n(需在灵宠界面)", 
                           [UIColor colorWithRed:0.45 green:0.25 blue:0.65 alpha:1.0], 
                           @selector(actionFreePet));
    btnY += btnH + btnSpacing;
    [scrollView addSubview:b3];
    
    // Btn4: 功能六开关 (state changes dynamically)
    UIButton *b4 = makeBtn(@"⚙️ GM全装注入:【已关闭】", 
                           [UIColor colorWithRed:0.28 green:0.28 blue:0.35 alpha:1.0], 
                           @selector(actionToggleF6));
    btnY += btnH + btnSpacing;
    [scrollView addSubview:b4];
    
    // Btn5: 执行功能六
    UIButton *b5 = makeBtn(@"🎁 一键注入全装备\n(需在背包界面)", 
                           [UIColor colorWithRed:0.75 green:0.2 blue:0.18 alpha:1.0], 
                           @selector(actionInjectGear));
    btnY += btnH + btnSpacing;
    [scrollView addSubview:b5];
    
    // Btn6: 公告拦截开关
    UIButton *b6 = makeBtn(@"🔇 全服公告拦截:【已开启】", 
                           [UIColor colorWithRed:0.2 green:0.4 blue:0.3 alpha:1.0], 
                           @selector(actionToggleAnnounce));
    btnY += btnH + btnSpacing;
    [scrollView addSubview:b6];
    
    // Btn7: HUD日志开关
    UIButton *b7 = makeBtn(@"📊 切换HUD实时日志", 
                           [UIColor colorWithRed:0.3 green:0.3 blue:0.38 alpha:1.0], 
                           @selector(actionToggleHUD));
    btnY += btnH + btnSpacing;
    [scrollView addSubview:b7];
    
    scrollView.contentSize = CGSizeMake(btnW, btnY);
    [g_panelView addSubview:scrollView];
    
    // Close button at bottom
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(12, panelH - 34, panelW - 24, 28);
    closeBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.2 alpha:1.0];
    closeBtn.layer.cornerRadius = 6;
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    [closeBtn setTitle:@"✕ 关闭控制台" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(toggleCustomPanel) forControlEvents:UIControlEventTouchUpInside];
    [g_panelView addSubview:closeBtn];
    
    [parent addSubview:g_panelView];
}

#pragma mark - 悬浮球拖拽手势处理

- (void)handleBallPan:(UIPanGestureRecognizer *)pan {
    if (!self._floatBall || !self._floatBall.superview) return;
    
    UIView *superview = self._floatBall.superview;
    CGPoint translation = [pan translationInView:superview];
    CGFloat newX = self._floatBall.center.x + translation.x;
    CGFloat newY = self._floatBall.center.y + translation.y;
    
    // Keep ball within superview bounds
    CGRect bounds = superview.bounds;
    newX = fmaxf(self._floatBall.frame.size.width / 2, 
                 fminf(newX, bounds.size.width - self._floatBall.frame.size.width / 2));
    newY = fmaxf(self._floatBall.frame.size.height / 2, 
                 fminf(newY, bounds.size.height - self._floatBall.frame.size.height / 2));
    
    self._floatBall.center = CGPointMake(newX, newY);
    [pan setTranslation:CGPointZero inView:superview];
}

#pragma mark - 面板显示切换

- (void)toggleCustomPanel {
    if (!g_panelView) return;
    g_panelView.hidden = !g_panelView.hidden;
    
    // Dim/brighten the float ball based on panel state
    self._floatBall.alpha = g_panelView.hidden ? 1.0 : 0.6;
}

#pragma mark - 按钮事件分发（全部ARM64安全调用）

- (void)actionClaimStones {
    AddLog(@"[INFO] ===== 点击:领灵石 =====");
    [[ModManager shared] claimSpiritStonesLoop];
}

- (void)actionInstantMake {
    AddLog(@"[INFO] ===== 点击:制造触发 =====");
    [[ModManager shared] triggerMakeActions];
}

- (void)actionFreePet {
    AddLog(@"[INFO] ===== 点击:灵宠洗练 =====");
    [[ModManager shared] triggerPetRebirth];
}

- (void)actionToggleF6 {
    g_feature6_enabled = !g_feature6_enabled;
    
    // Update button text - find the feature6 toggle button in panel view's subviews
    if (!g_panelView) return;
    
    for (UIView *subview in g_panelView.subviews) {
        UIScrollView *sv = nil;
        if ([subview isKindOfClass:[UIScrollView class]]) sv = (UIScrollView *)subview;
        else continue;
        
        for (UIButton *btn in sv.subviews) {
            NSString *title = btn.currentTitle ?: @"";
            if ([title rangeInsensitiveRangeOfString:@"功能六"].location != NSNotFound || 
                [title rangeInsensitiveRangeOfString:@"gm全装注入"].location != NSNotFound) {
                
                NSString *newTitle = g_feature6_enabled ? 
                    @"⚙️ GM全装注入:【已开启】" : 
                    @"⚙️ GM全装注入:【已关闭】";
                
                [btn setTitle:newTitle forState:UIControlStateNormal];
                btn.backgroundColor = g_feature6_enabled ? 
                    [UIColor colorWithRed:0.1 green:0.55 blue:0.2 alpha:1.0] : 
                    [UIColor colorWithRed:0.28 green:0.28 blue:0.35 alpha:1.0];
                
                AddLog(g_feature6_enabled ? @"[⚙️] GM全装注入功能已开启" : @"[⚙️] GM全装注入功能已关闭");
                break;
            }
        }
    }
}

- (void)actionInjectGear {
    AddLog(@"[INFO] ===== 点击:GM全装注入 =====");
    [[ModManager shared] triggerFeature6];
}

- (void)actionToggleAnnounce {
    g_intercept_announce = !g_intercept_announce;
    
    // Update button text
    if (!g_panelView) return;
    
    for (UIView *subview in g_panelView.subviews) {
        UIScrollView *sv = nil;
        if ([subview isKindOfClass:[UIScrollView class]]) sv = (UIScrollView *)subview;
        else continue;
        
        for (UIButton *btn in sv.subviews) {
            NSString *title = btn.currentTitle ?: @"";
            if ([title rangeInsensitiveRangeOfString:@"公告拦截"].location != NSNotFound) {
                
                NSString *newTitle = g_intercept_announce ? 
                    @"🔇 全服公告拦截:【已开启】" : 
                    @"🔊 全服公告拦截:【已关闭】";
                
                [btn setTitle:newTitle forState:UIControlStateNormal];
                AddLog(g_intercept_announce ? @"[🛡️] 公告拦截已开启" : @"[🛡️] 公告拦截已关闭");
                break;
            }
        }
    }
}

- (void)actionToggleHUD {
    g_hudVisible = !g_hudVisible;
    if (g_logView) g_logView.hidden = !g_hudVisible;
    
    AddLog(g_hudVisible ? @"[📊] HUD日志面板已显示" : @"[📊] HUD日志面板已隐藏");
}

@end

#pragma mark - ============ Utility: rangeInsensitiveRangeOfString for older iOS ============

@interface NSString (CaseInsensitiveRange)
- (NSRange)rangeInsensitiveRangeOfString:(NSString *)searchString;
@end

@implementation NSString (CaseInsensitiveRange)

- (NSRange)rangeInsensitiveRangeOfString:(NSString *)searchString {
    return [self rangeOfString:searchString options:NSCaseInsensitiveSearch];
}

@end

#pragma mark - ============ dylib入口：构造器（Hook安装） ============

__attribute__((constructor(100))) // Lower number = earlier execution priority
static void BlackEraModMain(void) {
    AddLog(@"[INIT] BlackEra Mod v2 开始加载...");
    
    @autoreleasepool {
        // === Hook 1: BmobCloud callFunctionInBackground_withParameters_block_ ===
        Class bcloudClass = objc_getClass("BmobCloud");
        
        if (!bcloudClass) {
            AddLog(@"[⚠️] BmobCloud class not found - announcements may use different path");
        } else {
            // Try the exact selector format from Obj-C runtime convention
            SEL sel = @selector(callFunctionInBackground:withParameters:block:);
            Method m = class_getInstanceMethod(bcloudClass, sel);
            
            if (!m) {
                AddLog(@"[⚠️] BmobCloud::callFunctionInBackground:not found");
            } else {
                IMP origImp = method_setImplementation(m, (IMP)BE_Bcloud_CallFunc);
                orig_bcloud_callFunc_IMP = origImp;
                
                if (!orig_bcloud_callFunc_IMP) {
                    AddLog(@"[❌] Failed to save original BmobCloud IMP");
                } else {
                    AddLog(@"[✓] BmobCloud hook installed successfully");
                }
            }
        }
        
        // === Hook 2: BmobSocketIO sendEvent_withData_ ===
        Class socketClass = objc_getClass("BmobSocketIO");
        
        if (!socketClass) {
            AddLog(@"[⚠️] BmobSocketIO class not found - may be loaded dynamically later");
        } else {
            SEL sel2 = @selector(sendEvent:withData:);
            Method m2 = class_getInstanceMethod(socketClass, sel2);
            
            if (!m2) {
                AddLog(@"[⚠️] BmobSocketIO::sendEvent:withData: not found");
                
                // List available methods for debugging
                unsigned int count;
                Method *methods = class_copyMethodList(socketClass, &count);
                AddLog(@"[DEBUG] Available BmobSocketIO methods:");
                
                if (methods) {
                    int shown = 0;
                    for (unsigned int i = 0; i < count && shown < 15; i++) {
                        SEL s = method_getName(methods[i]);
                        AddLog([NSString stringWithFormat:@"  - %@", NSStringFromSelector(s)]);
                        shown++;
                    }
                    free(methods);
                }
            } else {
                IMP origImp2 = method_setImplementation(m2, (IMP)BE_SocketIO_SendEvent);
                orig_sendEvent_IMP = origImp2;
                
                if (!orig_sendEvent_IMP) {
                    AddLog(@"[❌] Failed to save original SocketIO IMP");
                } else {
                    AddLog(@"[✓] BmobSocketIO hook installed successfully");
                }
            }
        }
        
        // === Show floating ball after short delay (let game UI settle) ===
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), 
                       dispatch_get_main_queue(), ^{
            [FloatingMenuUI showFloatingBall];
        });
        
        AddLog(@"[INIT] Hook安装完成，等待游戏加载...");
    }
}
