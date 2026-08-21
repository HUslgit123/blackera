/*
 * BlackEra_Mod_v4.dylib — 《黑色纪元》修改器 (UI修复+BmobCloud Hook修复版)
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dispatch/dispatch.h>
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
    
    // Always update log view content regardless of visibility flag
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_logView) return;
        
        NSMutableString *all = [NSMutableString string];
        for (NSString *line in g_logs) {
            [all appendString:line];
            [all appendString:@"\n"];
        }
        g_logView.text = all;
        
        if (all.length > 0 && g_hudVisible) {
            NSRange end = NSMakeRange(all.length - 1, 1);
            [g_logView scrollRangeToVisible:end];
        }
    });
}

#pragma mark - ============ Swift混淆穿透查找引擎 ============

static SEL FindMethodBySubstring(Class cls, NSString *keyword) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *selName = NSStringFromSelector(sel);
        
        if ([selName rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            free(methods);
            return sel;
        }
    }
    
    if (methods) free(methods);
    return nil;
}

static id GetVCByClassName(NSString *keyword) {
    NSArray *windows = [UIApplication sharedApplication].windows;
    
    for (UIWindow *w in windows) {
        NSMutableArray *toCheck = [NSMutableArray arrayWithObject:w.rootViewController];
        
        while (toCheck.count > 0) {
            UIViewController *vc = [toCheck lastObject];
            [toCheck removeLastObject];
            
            if (!vc) continue;
            
            NSString *clsName = NSStringFromClass([vc class]);
            
            if ([clsName rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
                AddLog([NSString stringWithFormat:@"[✓] 定位真实实例: %@", clsName]);
                return vc;
            }
            
            // Recurse into navigation/tab/child/presented VCs
            if ([vc isKindOfClass:[UINavigationController class]]) {
                UINavigationController *nav = (UINavigationController *)vc;
                [toCheck addObjectsFromArray:nav.viewControllers];
            } else if ([vc isKindOfClass:[UITabBarController class]]) {
                UITabBarController *tab = (UITabBarController *)vc;
                if (tab.viewControllers) {
                    [toCheck addObjectsFromArray:tab.viewControllers];
                }
            }
            
            if (vc.childViewControllers.count > 0) {
                [toCheck addObjectsFromArray:vc.childViewControllers];
            }
            
            if (vc.presentedViewController) {
                [toCheck addObject:vc.presentedViewController];
            }
        }
    }
    
    AddLog([NSString stringWithFormat:@"[⚠️] 未找到包含 '%@' 的界面", keyword]);
    return nil;
}

#pragma mark - ============ Hook实现：广播拦截（BmobCloud模糊匹配） ============

static IMP orig_bcloud_callFunc_IMP = NULL;
static SEL bcloud_hooked_sel = NULL;

// Try multiple possible selector signatures for Bmob Cloud function call
static void InstallBmobCloudHook(Class cls) {
    const char *candidates[] = {
        "callFunctionInBackground:withParameters:block:",
        "callFunctionWithParams:block:",
        "callFunction:params:block:",
        NULL
    };
    
    // Try known selector signatures first
    for (int i = 0; candidates[i] != NULL; i++) {
        SEL sel = NSSelectorFromString([NSString stringWithUTF8String:candidates[i]]);
        Method m = class_getInstanceMethod(cls, sel);
        
        if (m) {
            IMP origImp = method_setImplementation(m, (IMP)BE_Bcloud_CallFunc);
            orig_bcloud_callFunc_IMP = origImp;
            bcloud_hooked_sel = sel;
            
            AddLog([NSString stringWithFormat:@"[✓] BmobCloud hook installed on: %@", NSStringFromSelector(sel)]);
            return;
        }
    }
    
    // Fallback: find ANY method containing "callFunction" or "cloudCall" or "execute"
    SEL foundSel = FindMethodBySubstring(cls, @"callFunction");
    if (!foundSel) foundSel = FindMethodBySubstring(cls, @"cloudCall");
    if (!foundSel) foundSel = FindMethodBySubstring(cls, @"execute");
    
    if (foundSel && !bcloud_hooked_sel) {
        Method m = class_getInstanceMethod(cls, foundSel);
        IMP origImp = method_setImplementation(m, (IMP)BE_Bcloud_CallFunc);
        
        orig_bcloud_callFunc_IMP = origImp;
        bcloud_hooked_sel = foundSel;
        
        AddLog([NSString stringWithFormat:@"[⚠️] BmobCloud: using fallback selector %@", NSStringFromSelector(foundSel)]);
    } else {
        AddLog(@"[❌] BmobCloud hook failed - no matching callFunction method found");
        
        // Debug list all methods on this class
        unsigned int count;
        Method *methods = class_copyMethodList(cls, &count);
        if (methods) {
            AddLog([NSString stringWithFormat:@"[DEBUG] Available %lu methods:", (unsigned long)MIN(count, 20)]);
            
            for (unsigned int i = 0; i < MIN(count, 20u); i++) {
                SEL s = method_getName(methods[i]);
                AddLog([NSString stringWithFormat:@"  - %@", NSStringFromSelector(s)]);
            }
            
            free(methods);
        }
    }
}

static IMP orig_sendEvent_IMP = NULL;

#pragma mark - ============ ModManager（业务逻辑） ============

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

- (void)claimSpiritStonesLoop {
    AddLog(@"[💎] 正在扫描设置/商城界面...");
    
    id targetVC = GetVCByClassName(@"OptionViewController");
    if (!targetVC) targetVC = GetVCByClassName(@"ShopViewController");
    
    if (!targetVC) {
        AddLog(@"[❌] 请先在游戏中打开【设置】或【商城】界面！");
        return;
    }
    
    // Fuzzy find the reward method (Ghidra: gdt_rewardVideoAdDidRewardEffective:)
    SEL rewardSel = FindMethodBySubstring([targetVC class], @"rewardVideoAdDidRewardEffective");
    
    if (!rewardSel) {
        AddLog(@"[❌] 该界面未找到广告发奖接口");
        
        // Debug: list methods containing "gdt" or "reward"
        unsigned int count = 0;
        Method *methods = class_copyMethodList([targetVC class], &count);
        AddLog([NSString stringWithFormat:@"[DEBUG] %@ methods:", NSStringFromClass([targetVC class])]);
        
        if (methods) {
            int shown = 0;
            for (unsigned int i = 0; i < count && shown < 20; i++) {
                SEL s = method_getName(methods[i]);
                NSString *selStr = NSStringFromSelector(s);
                
                if ([selStr rangeOfString:@"gdt" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [selStr rangeOfString:@"reward" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    
                    AddLog([NSString stringWithFormat:@"  - %@", selStr]);
                    shown++;
                }
            }
            
            free(methods);
        }
        
        return;
    }
    
    AddLog(@"[💎] 启动自动刷灵石: 0.3s/次 x 20次");
    
    // Capture VC weakly (__unsafe_unretained for MRC compatibility)
    __unsafe_unretained id weakSelfVC = targetVC;
    
    for (int i = 0; i < 20; i++) {
        int idx = i;
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(idx * 0.3 * NSEC_PER_SEC)), 
                       dispatch_get_main_queue(), ^{
            id strongVC = weakSelfVC;
            if (!strongVC) return;
            
            // ARM64 SAFE: Use properly cast function pointer matching parameter count
            ((void (*)(id, SEL, id))objc_msgSend)(strongVC, rewardSel, nil);
            
            AddLog([NSString stringWithFormat:@"[✓] 灵石到账第 %d/20 次", idx + 1]);
        });
    }
}

- (void)triggerMakeActions {
    AddLog(@"[⚒️] 正在扫描制造界面...");
    
    id targetVC = GetVCByClassName(@"MakeViewController");
    if (!targetVC) targetVC = GetVCByClassName(@"EquipmentViewController");
    if (!targetVC) targetVC = GetVCByClassName(@"ForgeViewController");
    
    if (!targetVC) {
        AddLog(@"[❌] 请先打开【制造/炼器/强化】界面！");
        return;
    }
    
    // Try specific method first, then generic fallback
    SEL chosenSel = FindMethodBySubstring([targetVC class], @"clickMakeButton") ?: 
                    FindMethodBySubstring([targetVC class], @"startCraft");
    
    if (!chosenSel) {
        // Last resort: find any "click" method (risky but may work)
        chosenSel = FindMethodBySubstring([targetVC class], @"clickButton");
        
        if (!chosenSel) {
            AddLog(@"[❌] 未匹配到制造方法，请查看DEBUG日志中的可用方法列表");
            
            // Debug list all methods
            unsigned int count;
            Method *methods = class_copyMethodList([targetVC class], &count);
            if (methods) {
                AddLog(@"[DEBUG] Available methods:");
                for (unsigned int j = 0; j < MIN(count, 25u); j++) {
                    SEL s = method_getName(methods[j]);
                    AddLog([NSString stringWithFormat:@"  - %@", NSStringFromSelector(s)]);
                }
                free(methods);
            }
            
            return;
        }
    }
    
    UIButton *fakeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    
    // ARM64 SAFE: Cast to match (id, SEL, id) signature
    ((void (*)(id, SEL, id))objc_msgSend)(targetVC, chosenSel, fakeBtn);
    
    AddLog([NSString stringWithFormat:@"[⚒️] 成功触发制造接口: %@", NSStringFromSelector(chosenSel)]);
}

- (void)triggerPetRebirth {
    AddLog(@"[🐾] 正在扫描灵宠界面...");
    
    id targetVC = GetVCByClassName(@"PetViewController");
    if (!targetVC) targetVC = GetVCByClassName(@"SpiritBeastViewController");
    if (!targetVC) targetVC = GetVCByClassName(@"LingchongViewController");
    
    if (!targetVC) {
        AddLog(@"[❌] 请先打开【灵宠】界面！");
        return;
    }
    
    SEL chosenSel = FindMethodBySubstring([targetVC class], @"clickWashButton") ?:
                    FindMethodBySubstring([targetVC class], @"freeReset");
    
    if (!chosenSel) {
        AddLog(@"[❌] 未匹配到洗练方法");
        
        // Debug: list wash/reset/rebirth related methods
        unsigned int count;
        Method *methods = class_copyMethodList([targetVC class], &count);
        AddLog(@"[DEBUG] Pet-related methods:");
        
        if (methods) {
            int shown = 0;
            for (unsigned int i = 0; i < count && shown < 20; i++) {
                SEL s = method_getName(methods[i]);
                NSString *selStr = NSStringFromSelector(s);
                
                if ([selStr rangeOfString:@"wash" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [selStr rangeOfString:@"reset" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [selStr rangeOfString:@"rebirth" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    
                    AddLog([NSString stringWithFormat:@"  - %@", selStr]);
                    shown++;
                }
            }
            
            free(methods);
        }
        
        return;
    }
    
    UIButton *fakeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    
    ((void (*)(id, SEL, id))objc_msgSend)(targetVC, chosenSel, fakeBtn);
    
    AddLog([NSString stringWithFormat:@"[🐾] 成功触发灵宠洗练接口: %@", NSStringFromSelector(chosenSel)]);
}

- (void)triggerFeature6 {
    if (!g_feature6_enabled) {
        AddLog(@"[⚠️] 功能六未开启，请先开启控制台开关！");
        return;
    }
    
    AddLog(@"[🎁] 正在扫描背包界面...");
    
    id bagVC = GetVCByClassName(@"BagViewController");
    if (!bagVC) bagVC = GetVCByClassName(@"InventoryViewController");
    
    if (!bagVC) {
        AddLog(@"[❌] 请先打开【背包】界面！");
        return;
    }
    
    SEL czSel = FindMethodBySubstring([bagVC class], @"clickCZButton");
    SEL gmSel = FindMethodBySubstring([bagVC class], @"clickGMButton");
    
    UIButton *fakeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    
    if (czSel) {
        // ARM64 SAFE cast
        ((void (*)(id, SEL, id))objc_msgSend)(bagVC, czSel, fakeBtn);
        AddLog(@"[🎁] 已触发 CZ/GM 全装注入");
        
    } else if (gmSel) {
        ((void (*)(id, SEL, id))objc_msgSend)(bagVC, gmSel, fakeBtn);
        AddLog(@"[🎁] 已触发 GM 菜单");
        
    } else {
        AddLog(@"[❌] 该界面未暴露GM接口，请查看DEBUG列表中的button相关方法");
        
        // Debug list button methods
        unsigned int count;
        Method *methods = class_copyMethodList([bagVC class], &count);
        if (methods) {
            AddLog(@"[DEBUG] Button-related methods on BagVC:");
            
            for (unsigned int i = 0; i < MIN(count, 30u); i++) {
                SEL s = method_getName(methods[i]);
                NSString *selStr = NSStringFromSelector(s);
                
                if ([selStr rangeOfString:@"button" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [selStr rangeOfString:@"gm" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [selStr rangeOfString:@"cz" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    
                    AddLog([NSString stringWithFormat:@"  - %@", selStr]);
                }
            }
            
            free(methods);
        }
    }
}

@end

#pragma mark - ============ 穿透Overlay窗口（hitTest修复） ============

@interface BEOverlayWindow : UIWindow
@end

@implementation BEOverlayWindow { }

// FIXED: Properly filter out rootVC.view to allow clicks through empty areas
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.userInteractionEnabled || self.isHidden || self.alpha <= 0.01f) {
        return nil;
    }
    
    UIView *hitView = [super hitTest:point withEvent:event];
    
    // Pass through clicks on:
    // - the window itself (empty area)
    // - rootVC's view (transparent container)  
    // - any non-interactive subviews
    if (!hitView || 
        hitView == self ||
        hitView == self.rootViewController.view ||
        ([hitView isKindOfClass:[UIView class]] && !hitView.userInteractionEnabled)) {
        
        return nil; // Click passes through to game
    }
    
    return hitView; // Let UI elements (buttons, scroll views) receive touch normally
}

@end

#pragma mark - ============ 悬浮UI界面（按钮布局完全重写） ============

@interface FloatingMenuUI : NSObject
@property (nonatomic, strong) BEOverlayWindow *overlayWin;
@property (nonatomic, strong) UIButton *floatBall;
+ (instancetype)shared;
+ (void)showFloatingBall;
@end

@implementation FloatingMenuUI { }

@synthesize overlayWin = _overlayWin;
@synthesize floatBall  = _floatBall;

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
    if (self.overlayWin && !self.overlayWin.isHidden) {
        AddLog(@"[INFO] 控制台已存在，跳过重复创建");
        return;
    }
    
    CGRect bounds = [UIScreen mainScreen].bounds;
    
    // Get proper window scene for iOS 13+
    UIWindowScene *activeScene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && 
                ((UIWindowScene *)scene).activationState == UISceneActivationStateForegroundActive) {
                
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
    }
    
    self.overlayWin = activeScene ? [[BEOverlayWindow alloc] initWithWindowScene:activeScene] 
                                 : [[BEOverlayWindow alloc] initWithFrame:bounds];
    
    // Ensure valid frame
    if (!self.overlayWin.frame.size.width || !self.overlayWin.frame.size.height) {
        self.overlayWin.frame = bounds;
    }
    
    self.overlayWin.windowLevel = UIWindowLevelAlert + 100;
    self.overlayWin.backgroundColor = [UIColor clearColor];
    
    // Root VC with clear background view
    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    self.overlayWin.rootViewController = rootVC;
    
    UIView *containerView = rootVC.view;
    
    // === 悬浮球 (左下角,可拖动) ===
    UIButton *ball = [UIButton buttonWithType:UIButtonTypeCustom];
    ball.frame = CGRectMake(15, bounds.size.height - 140, 56, 56);
    ball.backgroundColor = [UIColor colorWithRed:0.0 green:0.75 blue:0.1 alpha:0.9];
    ball.layer.cornerRadius = 28;
    ball.layer.borderWidth = 2.0f;
    ball.layer.borderColor = [UIColor whiteColor].CGColor;
    ball.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    
    [ball setTitle:@"作弊" forState:UIControlStateNormal];
    [ball setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    
    // Pan gesture for dragging (must be added first)
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleBallPan:)];
    [ball addGestureRecognizer:pan];
    
    // Tap gesture - FIXED: Use requireGestureRecognizerToFail instead of .requirements property
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleCustomPanel)];
    [tap requireGestureRecognizerToFail:pan];
    [ball addGestureRecognizer:tap];
    
    self.floatBall = ball;
    [containerView addSubview:ball];
    
    // Build control panel and HUD (completely rewritten layout)
    [self buildControlPanelInView:containerView withBounds:bounds];
    
    g_logView = [[UITextView alloc] initWithFrame:CGRectMake(bounds.size.width - 250, 40, 240, 160)];
    UIFont *logFont = [UIFont fontWithName:@"Menlo" size:9];
    if (!logFont) {
        logFont = [UIFont systemFontOfSize:9];
    }
    g_logView.font = logFont;
    
    g_logView.textColor = [UIColor colorWithRed:0.1 green:1.0 blue:0.3 alpha:1.0];
    g_logView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    g_logView.layer.cornerRadius = 6;
    g_logView.editable = NO;
    g_logView.hidden = YES;
    
    // Panel starts HIDDEN - show only when user taps floating ball twice or swipes up
    g_panelView.hidden = YES;
    
    self.overlayWin.userInteractionEnabled = YES;
    // FIXED: Don't makeKeyAndVisible - this causes overlay to steal all events.
    // Using hidden=NO with high windowLevel is enough for hitTest routing.
    self.overlayWin.hidden = NO;
    
    AddLog(@"[✓] BlackEra Mod v4 界面挂载成功");
}

#pragma mark - 构建控制面板（完全重写，不用block避免capture问题）

- (void)buildControlPanelInView:(UIView *)parent withBounds:(CGRect)bounds {
    CGFloat panelW = MIN(320.0f, bounds.size.width - 40);
    CGFloat panelH = 380;
    
    // Create main panel view
    g_panelView = [[UIView alloc] initWithFrame:CGRectMake((bounds.size.width - panelW) / 2.0f, 
                                                           (bounds.size.height - panelH) / 2.0f, 
                                                           panelW, panelH)];
    g_panelView.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.14 alpha:0.96];
    g_panelView.layer.cornerRadius = 12;
    g_panelView.layer.borderWidth = 1.5f;
    g_panelView.layer.borderColor = [UIColor colorWithRed:0.0 green:0.8 blue:0.2 alpha:0.7].CGColor;
    
    // Title label at top
    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, panelW - 24, 26)];
    titleLbl.text = @"⚡ 修仙修改器控制台 ⚡";
    titleLbl.textColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.3 alpha:1.0];
    titleLbl.font = [UIFont boldSystemFontOfSize:15];
    titleLbl.textAlignment = NSTextAlignmentCenter;
    [g_panelView addSubview:titleLbl];
    
    // Create ScrollView with explicit contentSize and scrollEnabled
    CGFloat scrollViewW = panelW - 16;
    CGFloat scrollViewH = panelH - 80; // Leave space for title and close button
    
    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:CGRectMake(8, 42, scrollViewW, scrollViewH)];
    scrollView.backgroundColor = [UIColor clearColor];
    scrollView.showsVerticalScrollIndicator = YES;
    
    // Button dimensions
    CGFloat btnY = 4;
    CGFloat btnH = 36;
    CGFloat btnSpacing = 5;
    CGFloat btnW = scrollViewW;
    
    // Create each button DIRECTLY (no block capture issues)
    
    // Btn1: 领灵石
    UIButton *b1 = [[UIButton alloc] init];
    b1.frame = CGRectMake(0, btnY, btnW, btnH);
    b1.backgroundColor = [UIColor colorWithRed:0.15 green:0.35 blue:0.7 alpha:1.0];
    b1.layer.cornerRadius = 6;
    b1.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b1.titleLabel.numberOfLines = 2;
    b1.titleEdgeInsets = UIEdgeInsetsMake(2, 8, 2, 8);
    [b1 setTitle:@"💎 领灵石 x20\n(需打开设置/商城)" forState:UIControlStateNormal];
    [b1 setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b1 addTarget:self action:@selector(actionClaimStones) forControlEvents:UIControlEventTouchUpInside];
    btnY += btnH + btnSpacing;
    
    // Btn2: 制造/强化
    UIButton *b2 = [[UIButton alloc] init];
    b2.frame = CGRectMake(0, btnY, btnW, btnH);
    b2.backgroundColor = [UIColor colorWithRed:0.18 green:0.55 blue:0.35 alpha:1.0];
    b2.layer.cornerRadius = 6;
    b2.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b2.titleLabel.numberOfLines = 2;
    b2.titleEdgeInsets = UIEdgeInsetsMake(2, 8, 2, 8);
    [b2 setTitle:@"⚒️ 触发炼丹/炼器\n(需在制造界面)" forState:UIControlStateNormal];
    [b2 setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b2 addTarget:self action:@selector(actionInstantMake) forControlEvents:UIControlEventTouchUpInside];
    btnY += btnH + btnSpacing;
    
    // Btn3: 灵宠洗练
    UIButton *b3 = [[UIButton alloc] init];
    b3.frame = CGRectMake(0, btnY, btnW, btnH);
    b3.backgroundColor = [UIColor colorWithRed:0.45 green:0.25 blue:0.65 alpha:1.0];
    b3.layer.cornerRadius = 6;
    b3.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b3.titleLabel.numberOfLines = 2;
    b3.titleEdgeInsets = UIEdgeInsetsMake(2, 8, 2, 8);
    [b3 setTitle:@"🐾 灵宠免费洗练\n(需在灵宠界面)" forState:UIControlStateNormal];
    [b3 setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b3 addTarget:self action:@selector(actionFreePet) forControlEvents:UIControlEventTouchUpInside];
    btnY += btnH + btnSpacing;
    
    // Btn4: 功能六开关
    UIButton *b4 = [[UIButton alloc] init];
    b4.frame = CGRectMake(0, btnY, btnW, btnH);
    b4.backgroundColor = [UIColor colorWithRed:0.28 green:0.28 blue:0.35 alpha:1.0];
    b4.layer.cornerRadius = 6;
    b4.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b4.titleEdgeInsets = UIEdgeInsetsMake(2, 8, 2, 8);
    [b4 setTitle:@"⚙️ GM全装注入:【已关闭】" forState:UIControlStateNormal];
    [b4 setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b4 addTarget:self action:@selector(actionToggleF6) forControlEvents:UIControlEventTouchUpInside];
    btnY += btnH + btnSpacing;
    
    // Btn5: 执行功能六
    UIButton *b5 = [[UIButton alloc] init];
    b5.frame = CGRectMake(0, btnY, btnW, btnH);
    b5.backgroundColor = [UIColor colorWithRed:0.75 green:0.2 blue:0.18 alpha:1.0];
    b5.layer.cornerRadius = 6;
    b5.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b5.titleEdgeInsets = UIEdgeInsetsMake(2, 8, 2, 8);
    [b5 setTitle:@"🎁 一键注入全装备\n(需在背包界面)" forState:UIControlStateNormal];
    [b5 setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b5 addTarget:self action:@selector(actionInjectGear) forControlEvents:UIControlEventTouchUpInside];
    btnY += btnH + btnSpacing;
    
    // Btn6: 公告拦截开关
    UIButton *b6 = [[UIButton alloc] init];
    b6.frame = CGRectMake(0, btnY, btnW, btnH);
    b6.backgroundColor = [UIColor colorWithRed:0.2 green:0.4 blue:0.3 alpha:1.0];
    b6.layer.cornerRadius = 6;
    b6.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b6.titleEdgeInsets = UIEdgeInsetsMake(2, 8, 2, 8);
    [b6 setTitle:@"🔇 全服公告拦截:【已开启】" forState:UIControlStateNormal];
    [b6 setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b6 addTarget:self action:@selector(actionToggleAnnounce) forControlEvents:UIControlEventTouchUpInside];
    btnY += btnH + btnSpacing;
    
    // Btn7: HUD日志开关 (LAST BUTTON - this one was visible before)
    UIButton *b7 = [[UIButton alloc] init];
    b7.frame = CGRectMake(0, btnY, btnW, btnH);
    b7.backgroundColor = [UIColor colorWithRed:0.3 green:0.3 blue:0.38 alpha:1.0];
    b7.layer.cornerRadius = 6;
    b7.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    b7.titleEdgeInsets = UIEdgeInsetsMake(2, 8, 2, 8);
    [b7 setTitle:@"📊 切换HUD实时日志" forState:UIControlStateNormal];
    [b7 setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b7 addTarget:self action:@selector(actionToggleHUD) forControlEvents:UIControlEventTouchUpInside];
    btnY += btnH + btnSpacing;
    
    // Set contentSize BEFORE adding buttons to ensure scroll works
    CGFloat totalHeight = btnY + 10;
    scrollView.contentSize = CGSizeMake(btnW, totalHeight);
    
    // Add all buttons to scrollView AFTER setting frames and contentSize
    [scrollView addSubview:b1];
    [scrollView addSubview:b2];
    [scrollView addSubview:b3];
    [scrollView addSubview:b4];
    [scrollView addSubview:b5];
    [scrollView addSubview:b6];
    [scrollView addSubview:b7];
    
    // Close button at bottom of panel
    UIButton *closeBtn = [[UIButton alloc] init];
    closeBtn.frame = CGRectMake(12, panelH - 34, panelW - 24, 28);
    closeBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.2 alpha:1.0];
    closeBtn.layer.cornerRadius = 6;
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    
    [closeBtn setTitle:@"✕ 关闭控制台" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(toggleCustomPanel) forControlEvents:UIControlEventTouchUpInside];
    
    // Add scrollView and HUD log view to container BEFORE adding panel
    [containerView addSubview:g_logView];
    
    // Add panel with all subviews already built
    [g_panelView addSubview:scrollView];
    [g_panelView addSubview:closeBtn];
    [parent addSubview:g_panelView];
}

#pragma mark - 悬浮球拖拽手势处理

- (void)handleBallPan:(UIPanGestureRecognizer *)pan {
    if (!self.floatBall || !self.floatBall.superview) return;
    
    UIView *superview = self.floatBall.superview;
    CGPoint translation = [pan translationInView:superview];
    
    CGFloat newX = self.floatBall.center.x + translation.x;
    CGFloat newY = self.floatBall.center.y + translation.y;
    
    // Keep ball within superview bounds (ball radius is 28)
    CGRect bounds = superview.bounds;
    newX = fmaxf(28, fminf(newX, bounds.size.width - 28));
    newY = fmaxf(28, fminf(newY, bounds.size.height - 28));
    
    self.floatBall.center = CGPointMake(newX, newY);
    [pan setTranslation:CGPointMake(0, 0) inView:superview];
}

#pragma mark - 面板显示切换

- (void)toggleCustomPanel {
    if (!g_panelView) return;
    
    g_panelView.hidden = !g_panelView.hidden;
    self.floatBall.alpha = g_panelView.hidden ? 1.0f : 0.6f;
}

#pragma mark - 按钮事件分发（全部使用ARM64 SAFE强转）

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
    
    // Find and update the feature6 toggle button in panel view's scrollview
    if (!g_panelView) return;
    
    for (UIView *subview in g_panelView.subviews) {
        if ([subview isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)subview;
            
            for (UIButton *btn in sv.subviews) {
                NSString *title = btn.currentTitle ?: @"";
                
                if ([title rangeOfString:@"gm全装注入" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    [btn setTitle:g_feature6_enabled ? 
                        @"⚙️ GM全装注入:【已开启】" : 
                        @"⚙️ GM全装注入:【已关闭】" 
                        forState:UIControlStateNormal];
                    
                    btn.backgroundColor = g_feature6_enabled ? 
                        [UIColor colorWithRed:0.1 green:0.55 blue:0.2 alpha:1.0] : 
                        [UIColor colorWithRed:0.28 green:0.28 blue:0.35 alpha:1.0];
                    
                    AddLog(g_feature6_enabled ? @"[⚙️] GM全装注入功能已开启" : @"[⚙️] GM全装注入功能已关闭");
                    return;
                }
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
    
    // Find and update announce toggle button
    if (!g_panelView) return;
    
    for (UIView *subview in g_panelView.subviews) {
        if ([subview isKindOfClass:[UIScrollView class]]) {
            UIScrollView *sv = (UIScrollView *)subview;
            
            for (UIButton *btn in sv.subviews) {
                NSString *title = btn.currentTitle ?: @"";
                
                if ([title rangeOfString:@"公告拦截" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    [btn setTitle:g_intercept_announce ? 
                        @"🔇 全服公告拦截:【已开启】" : 
                        @"🔊 全服公告拦截:【已关闭】" 
                        forState:UIControlStateNormal];
                    
                    AddLog(g_intercept_announce ? @"[🛡️] 公告拦截已开启" : @"[🛡️] 公告拦截已关闭");
                    return;
                }
            }
        }
    }
}

- (void)actionToggleHUD {
    g_hudVisible = !g_hudVisible;
    
    if (g_logView) {
        g_logView.hidden = !g_hudVisible;
    }
    
    AddLog(g_hudVisible ? @"[📊] HUD日志面板已显示" : @"[📊] HUD日志面板已隐藏");
}

@end

#pragma mark - ============ dylib入口：构造器（Hook安装） ============

__attribute__((constructor(100))) // Lower number = earlier priority
static void BlackEraModMain(void) {
    AddLog(@"[INIT] BlackEra Mod v4.1 开始加载...");
    
    @autoreleasepool {
        // === Hook 1: BmobCloud (try multiple selector names) ===
        Class bcloudClass = objc_getClass("BmobCloud");
        
        if (!bcloudClass) {
            AddLog(@"[⚠️] BmobCloud class not found - announcements may use different path");
        } else {
            InstallBmobCloudHook(bcloudClass);
        }
        
        // === Hook 2: BmobSocketIO ===
        Class socketClass = objc_getClass("BmobSocketIO");
        
        if (!socketClass) {
            AddLog(@"[⚠️] BmobSocketIO class not found - may be loaded dynamically later");
            
            // Try to find it by name pattern in all classes
            unsigned int numClasses;
            Class *allClasses = objc_getClassList(NULL, 0);
            
            for (unsigned int i = 0; i < numClasses; i++) {
                NSString *className = NSStringFromClass(allClasses[i]);
                
                if ([className rangeOfString:@"Bmob" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [className rangeOfString:@"SocketIO" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                    
                    AddLog([NSString stringWithFormat:@"[DEBUG] Found class: %@", className]);
                }
            }
            
            free(allClasses);
        } else {
            SEL sel2 = @selector(sendEvent:withData:);
            Method m2 = class_getInstanceMethod(socketClass, sel2);
            
            if (!m2) {
                AddLog(@"[⚠️] BmobSocketIO::sendEvent:withData: not found");
                
                // Debug list available methods
                unsigned int count;
                Method *methods = class_copyMethodList(socketClass, &count);
                if (methods) {
                    AddLog(@"[DEBUG] Available BmobSocketIO methods:");
                    
                    for (unsigned int i = 0; i < MIN(count, 15u); i++) {
                        SEL s = method_getName(methods[i]);
                        AddLog([NSString stringWithFormat:@"  - %@", NSStringFromSelector(s)]);
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
        
        // === Show floating ball after game UI settles ===
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), 
                       dispatch_get_main_queue(), ^{
            [FloatingMenuUI showFloatingBall];
        });
        
        AddLog(@"[INIT] Hook安装完成，等待游戏加载...");
    }
}

// Recursively extract all strings from complex data structures (used by both hooks)
static NSString *ExtractTextFromObject(id obj) {
    if (!obj || [obj isKindOfClass:[NSString class]]) return (NSString *)obj ?: @"";
    
    NSMutableString *result = [NSMutableString string];
    
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        for (id key in dict) {
            id val = dict[key];
            NSString *txt = ExtractTextFromObject(val);
            if (txt.length > 0) [result appendFormat:@"%@ ", txt];
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)obj;
        for (id item in arr) {
            NSString *txt = ExtractTextFromObject(item);
            if (txt.length > 0) [result appendFormat:@"%@ ", txt];
        }
    }
    
    return result.length > 0 ? result : @"";
}

// Check if text contains reward/announcement keywords that would trigger server broadcasts
static BOOL ContainsAnnouncementKeywords(NSString *text) {
    static NSArray *keywords;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keywords = @[
            @"得到了", @"在观看广告时", @"获得了", @"抽取了", @"合成成功",
            @"神兵符碎片", @"极品", @"传说", @"神器", @"突破到", 
            @"在修炼过程中", @"击败了", @"击杀了BOSS", @"掉落了"
        ];
    });
    
    for (NSString *kw in keywords) {
        if ([text rangeOfString:kw].location != NSNotFound) return YES;
    }
    return NO;
}


#pragma mark - ============ SocketIO Hook Implementation ============

static BOOL IsRewardReportingSocketEvent(NSString *event, id data) {
    static NSArray *reportEvents;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        reportEvents = @[
            @"reward_claimed", @"ad_reward_received", @"show_reward",
            @"get_item", @"claim_prize"
        ];
    });
    
    for (NSString *e in reportEvents) {
        if ([event rangeOfString:e options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    
    // Also scan data payload for reward keywords
    NSString *dataText = ExtractTextFromObject(data);
    return ContainsAnnouncementKeywords(dataText);
}

static void BE_SocketIO_SendEvent(id self, SEL _cmd, NSString *event, id data) {
    
    // BLOCK OUTGOING reward reports (client -> server) so server never broadcasts our name
    if (IsRewardReportingSocketEvent(event, data)) {
        AddLog([NSString stringWithFormat:@"[🛡️] Socket上报已阻断 event=%@", event]);
        return;  // Don't call original - server never knows we got the reward
    }
    
    // For other events, log for debugging and let through normally
    if (g_intercept_announce && event) {
        AddLog([NSString stringWithFormat:@"[NetInterceptor] SocketEvent: %@", event]);
    }
    
    ((void (*)(id, SEL, NSString *, id))orig_sendEvent_IMP)(self, _cmd, event, data);
}

#pragma mark - ============ BmobCloud Hook Implementation (generic handler) ============

static void BE_Bcloud_CallFunc(id self, SEL _cmd, id arg1, id arg2, void (^block)(id result, NSError *error)) {
    NSString *funcName = nil;
    
    // First arg is likely function name or dictionary containing it
    if ([arg1 isKindOfClass:[NSString class]]) {
        funcName = (NSString *)arg1;
    } else if ([arg1 isKindOfClass:[NSDictionary class]]) {
        funcName = ((NSDictionary *)arg1)[@"function"];
    }
    
    // Check if this is a reward-reporting/announcement call that would trigger server broadcast
    BOOL shouldBlock = NO;
    
    if (funcName) {
        NSArray *blockFuncs = @[
            @"SendSystemMessage", @"system_announcement", @"broadcast_reward",
            @"announce", @"reward_broadcast", @"show_reward", @"report_reward"
        ];
        
        for (NSString *name in blockFuncs) {
            if ([funcName rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound) {
                shouldBlock = YES;
                break;
            }
        }
    }
    
    // Also check arg2 params content for reward keywords (catches any "bragging" data)
    NSString *paramsText = ExtractTextFromObject(arg2);
    if ([paramsText length] > 0 && ContainsAnnouncementKeywords(paramsText)) {
        shouldBlock = YES;
    }
    
    // BLOCK outgoing call - server never knows we got the reward!
    if (shouldBlock) {
        AddLog([NSString stringWithFormat:@"[🛡️] BmobCloud上报已阻断 function=%@", funcName ?: @"unknown"]);
        
        // Return fake success to satisfy callback without notifying server
        if (block) block(@{}, nil);
        return;
    }
    
    ((void (*)(id, SEL, id, id, void (^)(id, NSError *)))orig_bcloud_callFunc_IMP)(self, _cmd, arg1, arg2, block);
}
