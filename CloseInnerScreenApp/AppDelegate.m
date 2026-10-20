//
//  AppDelegate.m
//  CloseInnerScreenApp
//
//  Created by weixin on 3/8/19.
//  Copyright © 2019 weixin. All rights reserved.
//

#import "AppDelegate.h"
#import <dlfcn.h>
#import <notify.h>

// 私有 SkyLight 符号：在显示器重配置事务中启用/禁用指定显示器。
// 对内建屏置 false 等同物理拔掉 —— WindowServer 停止渲染、背光断电，
// 效果与合盖模式一致，但盖子可以保持打开。
typedef CGError (*CGSConfigureDisplayEnabledFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);
// CGGetOnlineDisplayList 只返回在线（未禁用）显示器；
// CGSGetDisplayList 能列出包括被禁用的显示器，恢复内建屏时必须用它定位。
typedef CGError (*CGSGetDisplayListFn)(uint32_t, CGDirectDisplayID *, uint32_t *);

static CGSConfigureDisplayEnabledFn sConfigureDisplayEnabled;
static CGSGetDisplayListFn sGetDisplayList;

@interface AppDelegate () <NSMenuDelegate>
@property (strong) NSMenu *statusMenu;
// 状态栏图标
@property (strong) NSImage *statusImage;
// 状态栏
@property (strong) NSStatusItem *statusItem;
// 内建屏 ID，会话内不变（禁用后会从在线列表消失，必须在启动时就缓存）
@property (nonatomic, assign) CGDirectDisplayID builtinDisplay;
// 内建屏是否是被本程序关闭的（区别于物理合盖）
@property (assign) BOOL intentDisabled;
// powerd 广播的合盖状态通知 token
@property (assign) int clamshellNotifyToken;
@end

@implementation AppDelegate

// 显示器插拔/配置变更回调：比 NSApplicationDidChangeScreenParametersNotification 更底层更早
static void displayReconfigCallback(CGDirectDisplayID display,
                                    CGDisplayChangeSummaryFlags flags,
                                    void *userInfo) {
    if (flags & kCGDisplayBeginConfigurationFlag) return;   // 配置进行中状态未稳定，跳过
    AppDelegate *delegate = (__bridge AppDelegate *)userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate enforceSafety];
    });
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    void *rtld = RTLD_DEFAULT;
    sConfigureDisplayEnabled = (CGSConfigureDisplayEnabledFn)dlsym(rtld, "CGSConfigureDisplayEnabled");
    sGetDisplayList = (CGSGetDisplayListFn)dlsym(rtld, "CGSGetDisplayList");

    notify_register_check("com.apple.system.powermanagement.clamshellstate",
                          &_clamshellNotifyToken);

    [self setMainStatus];

    CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, (__bridge void *)self);

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(enforceSafety)
                                               name:NSApplicationDidChangeScreenParametersNotification
                                             object:nil];

    // 系统唤醒：唤醒瞬间显示器枚举可能尚未就绪，立即对账一次、稍后再对账一次
    [[NSWorkspace sharedWorkspace].notificationCenter addObserver:self
                                                         selector:@selector(onWake:)
                                                             name:NSWorkspaceDidWakeNotification
                                                           object:nil];

    // 启动对账：覆盖"上次崩溃导致内建屏残留禁用，重启 app 时已无外接屏"的场景
    [self enforceSafety];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
    // 退出前恢复我们关掉的内建屏；物理合盖时由系统管理，不插手
    if (self.intentDisabled && [self lidIsOpen]) {
        [self setBuiltinDisplayEnabled:YES];
        self.intentDisabled = NO;
    }
    CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, (__bridge void *)self);
    if (_clamshellNotifyToken != 0) notify_cancel(_clamshellNotifyToken);
}

- (void)setMainStatus {
    self.statusImage = [NSImage imageNamed:@"screen"];
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [self.statusItem.button setImage:self.statusImage];

    self.statusMenu = [[NSMenu alloc] init];
    self.statusMenu.delegate = self;
    [self.statusMenu addItem:[self menuItemWithAction:@selector(toggleInnerScreen:)]];
    [self.statusMenu addItem:[self menuItemWithAction:@selector(exit:)]];

    [self.statusItem setMenu:self.statusMenu];
}

- (NSMenuItem *)menuItemWithAction:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"" action:action keyEquivalent:@""];
    item.target = self;
    return item;
}

// MARK: - 菜单动作

- (IBAction)toggleInnerScreen:(NSMenuItem *)sender {
    if (!sConfigureDisplayEnabled) {
        [self showAlert:@"当前系统不支持"
                    msg:@"无法调用 CGSConfigureDisplayEnabled 接口。"];
        return;
    }

    if ([self isBuiltinActive]) {
        // 关闭内建屏：没有外接显示器时禁止，否则全黑无法操作
        if (![self hasExternalDisplay]) {
            [self showAlert:@"无法关闭内建显示器"
                        msg:@"未连接外接显示器，关闭内建屏会导致全黑，已取消操作。"];
            return;
        }
        CGError err = [self setBuiltinDisplayEnabled:NO];
        if (err != kCGErrorSuccess) {
            [self showAlert:@"关闭内建显示器失败"
                        msg:[NSString stringWithFormat:@"CGError %d", err]];
            return;
        }
        self.intentDisabled = YES;
    } else {
        // 开启内建屏：物理合盖状态下禁止操作（面板归系统管，不应点亮合上的屏幕）
        if (![self lidIsOpen]) {
            [self showAlert:@"无法开启内建显示器"
                        msg:@"检测到盖子处于合上状态，请开盖后再试。"];
            return;
        }
        CGError err = [self setBuiltinDisplayEnabled:YES];
        if (err != kCGErrorSuccess) {
            [self showAlert:@"开启内建显示器失败"
                        msg:[NSString stringWithFormat:@"CGError %d", err]];
            return;
        }
        self.intentDisabled = NO;
    }
    [self updateMenuTitles];
}

- (IBAction)exit:(id)sender {
    [NSApp terminate:self];
}

// MARK: - 安全对账

// 统一的状态校正：显示配置变化、唤醒后都会走到这里
- (void)enforceSafety {
    if (![self lidIsOpen]) return;   // 物理合盖期间显示器归系统管理，不插手

    BOOL builtinActive = [self isBuiltinActive];
    BOOL external = [self hasExternalDisplay];

    if (!builtinActive && !external) {
        // 外接没了而内建屏仍关着 -> 全黑风险，立即恢复
        [self setBuiltinDisplayEnabled:YES];
        self.intentDisabled = NO;
    } else if (self.intentDisabled && builtinActive && external) {
        // 用户意图是关，但系统又把它点亮了（如唤醒丢状态）-> 重新关闭
        [self setBuiltinDisplayEnabled:NO];
    }
    [self updateMenuTitles];
}

- (void)onWake:(NSNotification *)note {
    [self enforceSafety];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self enforceSafety];
    });
}

// MARK: - 显示器操作

- (CGError)setBuiltinDisplayEnabled:(BOOL)enabled {
    CGDirectDisplayID builtin = self.builtinDisplay;
    if (builtin == 0) return kCGErrorFailure;

    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess) return err;

    err = sConfigureDisplayEnabled(config, builtin, enabled);
    if (err != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        return err;
    }
    // kCGConfigureForSession：仅当前登录会话生效，注销/重启自动还原
    return CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
}

// MARK: - 显示器查询

- (CGDirectDisplayID)builtinDisplay {
    if (_builtinDisplay == 0) _builtinDisplay = [self findBuiltinDisplay];
    return _builtinDisplay;
}

// 优先用 CGSGetDisplayList（能列出被禁用的显示器），兜底退回在线列表
- (CGDirectDisplayID)findBuiltinDisplay {
    CGDirectDisplayID ids[16] = {0};
    uint32_t count = 0;
    BOOL listed = NO;
    if (sGetDisplayList) {
        listed = (sGetDisplayList(16, ids, &count) == kCGErrorSuccess);
    }
    if (!listed) {
        listed = (CGGetOnlineDisplayList(16, ids, &count) == kCGErrorSuccess);
    }
    if (!listed) return 0;

    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(ids[i])) return ids[i];
    }
    return 0;
}

- (BOOL)isBuiltinActive {
    CGDirectDisplayID builtin = self.builtinDisplay;
    return builtin != 0 && CGDisplayIsActive(builtin);
}

- (BOOL)hasExternalDisplay {
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    if (CGGetOnlineDisplayList(16, ids, &count) != kCGErrorSuccess) return NO;
    for (uint32_t i = 0; i < count; i++) {
        if (!CGDisplayIsBuiltin(ids[i])) return YES;
    }
    return NO;
}

// 物理盖子是否打开。读不到状态时按"打开"处理：
// 宁可多恢复一次内建屏，也不冒全黑的风险
- (BOOL)lidIsOpen {
    if (_clamshellNotifyToken == 0) return YES;
    uint64_t state = 0;
    if (notify_get_state(_clamshellNotifyToken, &state) != NOTIFY_STATUS_OK) return YES;
    return state == 0;
}

// MARK: - UI 辅助

- (void)updateMenuTitles {
    NSString *toggleTitle = [self isBuiltinActive]
        ? NSLocalizedString(@"menu.close_inner_screen", nil)
        : NSLocalizedString(@"menu.open_inner_screen", nil);
    for (NSMenuItem *item in self.statusMenu.itemArray) {
        if (item.action == @selector(toggleInnerScreen:)) {
            item.title = toggleTitle;
        } else if (item.action == @selector(exit:)) {
            item.title = NSLocalizedString(@"menu.quit", nil);
        }
    }
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self updateMenuTitles];
}

- (void)showAlert:(NSString *)title msg:(NSString *)msg {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText = msg;
    [alert runModal];
}

@end
