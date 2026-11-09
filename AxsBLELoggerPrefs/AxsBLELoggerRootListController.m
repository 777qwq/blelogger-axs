// 设置面板：只读写 plist，不碰蓝牙、不枚举已安装 App。
//
// 抓包跑在目标 App 自己的进程里（见 Sources/AxsBLELoggerHook.m），
// 把帧写进 /var/mobile/Library/Preferences/com.qwq.blelogger.app.plist，
// 面板只负责把这份文件渲染成列表。面板不持有蓝牙对象，所以面板崩了
// 不影响抓包，反之亦然。
//
// 1.2.1 点进来就闪退的根因是这里调了 LSApplicationWorkspace 的
// allInstalledApplications（iOS 16 已移除）。现在不需要 App 白名单，
// 那段代码整个不存在。

#import "AxsBLELoggerRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kConfigPath   = @"/var/mobile/Library/Preferences/com.qwq.blelogger.plist";
static NSString *const kDataPath     = @"/var/mobile/Library/Preferences/com.qwq.blelogger.capture.plist";
static NSString *const kAppDataPath  = @"/var/mobile/Library/Preferences/com.qwq.blelogger.app.plist";
static NSString *const kPrefsChanged = @"com.qwq.blelogger.preferences-changed";
static const NSUInteger kShowFrames  = 20;
static const NSUInteger kShowLatest  = 6;

static NSDictionary *AXRead(NSString *path) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

static NSString *AXString(id v) {
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static BOOL AXWriteConfig(NSString *key, id value) {
    if (key.length == 0) return NO;
    NSMutableDictionary *d = [AXRead(kConfigPath) mutableCopy];
    if (value) {
        d[key] = value;
    } else {
        [d removeObjectForKey:key];
    }
    BOOL ok = [d writeToFile:kConfigPath atomically:YES];
    if (ok) {
        // 已经跑起来的 App 不会重新读配置，这个通知留给以后的运行时开关用
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)kPrefsChanged, NULL, NULL, 1);
    }
    return ok;
}

// 存储层写的是紧凑 hex（FF00023200AA），给人看要断成字节
static NSString *AXSpaceHex(NSString *hex) {
    if (![hex isKindOfClass:[NSString class]] || hex.length == 0) return @"";
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < hex.length; i++) {
        if (i && (i % 2) == 0) [out appendString:@" "];
        [out appendFormat:@"%C", [hex characterAtIndex:i]];
    }
    return out;
}

@interface AxsBLELoggerRootListController ()
@property (nonatomic, strong) NSTimer *tickTimer;
@property (nonatomic, assign) NSUInteger lastCount;
@end

// PSButtonCell 被点时，会把 specifier 上的 action 发给 target。
// 这里不直接写 spec->action：私有头里这个 ivar 是 protected，而且各版本
// SDK 的声明还不一样，编译期就会挂。走运行时拿偏移量最保险，取不到就静默跳过
// （按钮点不动，但绝不崩）。
static BOOL g_axsCellActionWritable = NO;

static void AXSetCellAction(PSSpecifier *spec, SEL action) {
    if (!spec || !action) return;

    Ivar iv = class_getInstanceVariable([PSSpecifier class], "action");
    if (iv) {
        *(SEL *)((char *)(__bridge void *)spec + ivar_getOffset(iv)) = action;
        g_axsCellActionWritable = YES;
        return;
    }
    if ([spec respondsToSelector:@selector(setButtonAction:)]) {
        ((void (*)(id, SEL, SEL))objc_msgSend)(spec, @selector(setButtonAction:), action);
        g_axsCellActionWritable = YES;
    }
}

// 分组头：不同 iOS 版本的 PSSpecifier 工厂方法名不一样，逐个探测，
// 最后退回最老最稳的 preferenceSpecifierNamed:+PSGroupCell。
// 早先直接调 groupSpecifierWithName:，万一系统没这个方法就是
// unrecognized selector —— 整个 -specifiers 抛异常，页面就是白的。
static PSSpecifier *AXGroup(NSString *title) {
    Class c = [PSSpecifier class];
    id (*send0)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id (*send1)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;

    PSSpecifier *spec = nil;
    if ([c respondsToSelector:@selector(groupSpecifierWithName:)]) {
        spec = send1(c, @selector(groupSpecifierWithName:), title ?: @"");
    } else if ([c respondsToSelector:@selector(groupSpecifier)]) {
        spec = send0(c, @selector(groupSpecifier));
    } else if ([c respondsToSelector:@selector(emptyGroupSpecifier)]) {
        spec = send0(c, @selector(emptyGroupSpecifier));
    }
    if (!spec) {
        spec = [PSSpecifier preferenceSpecifierNamed:title ?: @""
                                             target:nil set:nil get:nil
                                             detail:nil cell:PSGroupCell edit:nil];
        return spec;
    }
    if (title.length) [spec setProperty:title forKey:@"label"];
    return spec;
}

static PSSpecifier *AXButtonRow(NSString *label, id target, SEL action) {
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:label
                                                     target:target
                                                        set:nil
                                                        get:nil
                                                     detail:nil
                                                       cell:PSButtonCell
                                                       edit:nil];
    AXSetCellAction(row, action);
    // 兜底：万一 action ivar 写不进去（不同版本 PSSpecifier），
    // 由 didSelectRowAtIndexPath 按这个名字自己派发。
    [row setProperty:NSStringFromSelector(action) forKey:@"axs_action"];
    return row;
}

static PSSpecifier *AXValueRow(NSString *label, NSString *value) {
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:label
                                                     target:nil set:nil get:nil
                                                     detail:nil
                                                       cell:PSTitleValueCell
                                                       edit:nil];
    [row setProperty:value ?: @"" forKey:@"value"];
    return row;
}

@implementation AxsBLELoggerRootListController

#pragma mark - 数据

- (NSDictionary *)config { return AXRead(kConfigPath); }
- (NSDictionary *)capture { return AXRead(kDataPath); }

// 抓包数据只有注入模式这一个来源
- (NSArray *)frames {
    NSArray *f = AXRead(kAppDataPath)[@"frames"];
    return [f isKindOfClass:[NSArray class]] ? f : @[];
}

- (NSString *)stateText {
    NSString *s = AXString(self.capture[@"state"]);
    return s.length ? s : @"还没有 App 上报，打开目标 App 操作一次再看";
}

// 每个特征只留最新一帧，用来一眼看出哪个值在变
- (NSArray *)latestByCharacteristic {
    NSMutableDictionary *latest = [NSMutableDictionary dictionary];
    for (NSDictionary *f in self.frames) {
        NSString *chr = AXString(f[@"chr"]) ?: @"?";
        latest[chr] = f;
    }

    NSMutableArray *list = [NSMutableArray array];
    for (NSString *chr in [latest allKeys]) {
        [list addObject:latest[chr]];
    }
    return [list sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [(AXString(a[@"chr"]) ?: @"") compare:(AXString(b[@"chr"]) ?: @"")];
    }];
}

#pragma mark - 生命周期

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.lastCount = self.frames.count;
    [self.tickTimer invalidate];
    // 帧数没变就不重建列表，避免每秒闪一下
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(tick)
                                                    userInfo:nil
                                                     repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.tickTimer invalidate];
    self.tickTimer = nil;
}

- (void)tick {
    if (!self.isViewLoaded) return;
    if (self.navigationController && self.navigationController.topViewController != self) return;
    if (self.frames.count == self.lastCount) return;
    self.lastCount = self.frames.count;
    // 先重建一份塞进 _specifiers，再让表格刷新 —— 只调 reloadSpecifiers
    // 有些版本会拿旧的 ivar 重画，界面上什么都不会变。
    [self specifiers];
    [self reloadSpecifiers];
}

#pragma mark - 列表

// 关键：PSListController 的表格数据源读的是 _specifiers 这个 ivar，
// 不是 -specifiers 的返回值。只 return 不赋值 = 0 行 = 一片空白。
- (NSMutableArray *)specifiers {
    NSMutableArray *items = nil;
    @try {
        items = [self axsBuildSpecifiers];
    } @catch (NSException *e) {
        // 宁可显示一行错误，也不要给用户一页白板
        items = [NSMutableArray array];
        PSSpecifier *g = AXGroup(@"面板出错");
        [g setProperty:[NSString stringWithFormat:@"%@：%@", e.name, e.reason ?: @"未知"]
                forKey:@"footerText"];
        [items addObject:g];
    }
    if (!items) items = [NSMutableArray array];
    _specifiers = items;
    return items;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // 有些版本的 Preferences 不会主动调 -specifiers，这里先填一次
    [self specifiers];
}

- (NSMutableArray *)axsBuildSpecifiers {
    NSMutableArray *items = [NSMutableArray array];

    // ---- 概览 ----
    PSSpecifier *intro = AXGroup(@"BLE Logger");
    [intro setProperty:@"注入目标 App，hook CoreBluetooth 的写入和接收回调，把每一帧记下来。"
                       @"这里只是查看器，不需要保持打开。"
     forKey:@"footerText"];
    [items addObject:intro];

    PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:@"启用记录"
                                                          target:self
                                                             set:@selector(setEnabled:specifier:)
                                                             get:@selector(getEnabled:)
                                                          detail:nil
                                                            cell:PSSwitchCell
                                                            edit:nil];
    [items addObject:enabled];

    // ---- 状态 ----
    NSArray *frames = self.frames;
    PSSpecifier *statusGroup = AXGroup(@"状态");
    [statusGroup setProperty:(frames.count == 0
        ? @"还没有任何帧。确认开关是开的，然后把目标 App 从后台划掉重新打开，操作一遍。"
        : [NSString stringWithFormat:@"已记录 %lu 条。开关关掉后新开的 App 不再抓，已经注入的 App 要重启才生效。",
           (unsigned long)frames.count])
                     forKey:@"footerText"];
    [items addObject:statusGroup];

    [items addObject:AXValueRow(@"最近注入", self.stateText)];

    // ---- 最近值（按特征）----
    NSArray *latest = [self latestByCharacteristic];
    if (latest.count) {
        PSSpecifier *latestGroup = AXGroup(@"最近值（按特征）");
        [latestGroup setProperty:@"每个特征只显示最后一帧，点按复制。" forKey:@"footerText"];
        [items addObject:latestGroup];

        NSUInteger n = 0;
        for (NSDictionary *f in latest) {
            if (n++ >= kShowLatest) break;
            NSString *chr = AXString(f[@"chr"]) ?: @"?";
            NSString *short8 = chr.length > 8 ? [chr substringToIndex:8] : chr;
            NSString *label = [NSString stringWithFormat:@"%@  %@",
                               short8, AXSpaceHex(AXString(f[@"hex"]))];
            PSSpecifier *row = AXButtonRow(label, self, @selector(copyFrame:));
            [row setProperty:f forKey:@"axs_frame"];
            [items addObject:row];
        }
    }

    // ---- 最近帧 ----
    if (frames.count) {
        PSSpecifier *frameGroup = AXGroup(
            [NSString stringWithFormat:@"最近帧（共 %lu 条，点按复制）",
             (unsigned long)frames.count]);
        [items addObject:frameGroup];

        NSUInteger start = frames.count > kShowFrames ? frames.count - kShowFrames : 0;
        for (NSUInteger i = start; i < frames.count; i++) {
            NSDictionary *f = frames[i];
            if (![f isKindOfClass:[NSDictionary class]]) continue;

            NSString *t   = AXString(f[@"t"]) ?: @"--:--:--";
            NSString *dir = AXString(f[@"dir"]) ?: @"?";
            NSString *chr = AXString(f[@"chr"]) ?: @"?";
            NSString *short8 = chr.length > 8 ? [chr substringToIndex:8] : chr;

            PSSpecifier *row = AXButtonRow(
                [NSString stringWithFormat:@"%@ %@ %@  %@",
                 t, dir, short8, AXSpaceHex(AXString(f[@"hex"]))],
                self, @selector(copyFrame:));
            [row setProperty:f forKey:@"axs_frame"];
            [items addObject:row];
        }
    }

    // ---- 操作 ----
    PSSpecifier *actions = AXGroup(@"");
    [items addObject:actions];

    if (frames.count) {
        [items addObject:AXButtonRow(@"复制全部日志", self, @selector(copyAll:))];
    }
    [items addObject:AXButtonRow(@"清空日志", self, @selector(clearFrames:))];

    return items;
}

#pragma mark - 开关

// 配置里没写这个键就是刚装好，默认开
- (id)getEnabled:(PSSpecifier *)specifier {
    id v = self.config[@"enabled"];
    return v ? @([v boolValue]) : @YES;
}

- (void)setEnabled:(id)value specifier:(PSSpecifier *)specifier {
    AXWriteConfig(@"enabled", @([value boolValue]));

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf specifiers];
        [weakSelf reloadSpecifiers];
    });
}

#pragma mark - 点选兜底

// PSSpecifier 的 action ivar 谁都能写，但如果哪天苹果改了布局，
// AXSetCellAction 会写失败。这时按钮不会自己派发，由这里接手。
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    PSSpecifier *spec = nil;
    if ([self respondsToSelector:@selector(specifierAtIndexPath:)]) {
        spec = [self specifierAtIndexPath:indexPath];
    }
    NSString *name = AXString([spec propertyForKey:@"axs_action"]);
    if (name.length == 0) return;

    SEL sel = NSSelectorFromString(name);
    if (sel && [self respondsToSelector:sel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, sel, spec);
    }
}

#pragma mark - 复制 / 清空

- (void)toast:(NSString *)text {
    Class hud = NSClassFromString(@"UIAlertController");
    if (!hud) return;
    id alert = ((id (*)(id, SEL, id, id, id))objc_msgSend)(hud,
        @selector(alertControllerWithTitle:message:preferredStyle:),
        nil, text, (id)0);
    if (!alert) return;

    id action = ((id (*)(id, SEL, id, id, id))objc_msgSend)(NSClassFromString(@"UIAlertAction"),
        @selector(actionWithTitle:style:handler:), @"好", (id)0, nil);
    if (action) {
        ((void (*)(id, SEL, id))objc_msgSend)(alert, @selector(addAction:), action);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copyFrame:(PSSpecifier *)specifier {
    NSDictionary *f = [specifier propertyForKey:@"axs_frame"];
    if (![f isKindOfClass:[NSDictionary class]]) return;

    NSString *text = [NSString stringWithFormat:@"%@ %@ %@ %@",
                      AXString(f[@"t"]) ?: @"",
                      AXString(f[@"dir"]) ?: @"",
                      AXString(f[@"chr"]) ?: @"?",
                      AXSpaceHex(AXString(f[@"hex"]))];

    [UIPasteboard generalPasteboard].string = text;
    [self toast:@"已复制这一条"];
}

- (void)copyAll:(PSSpecifier *)specifier {
    NSArray *frames = self.frames;
    if (frames.count == 0) return;

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"# BLE Logger %lu 条\n", (unsigned long)frames.count];
    for (NSDictionary *f in frames) {
        if (![f isKindOfClass:[NSDictionary class]]) continue;
        [out appendFormat:@"%@ %@ %@ %@\n",
            AXString(f[@"t"]) ?: @"",
            AXString(f[@"dir"]) ?: @"",
            AXString(f[@"chr"]) ?: @"?",
            AXSpaceHex(AXString(f[@"hex"]))];
    }

    [UIPasteboard generalPasteboard].string = out;
    [self toast:[NSString stringWithFormat:@"已复制 %lu 条", (unsigned long)frames.count]];
}

- (void)clearFrames:(PSSpecifier *)specifier {
    [@{} writeToFile:kAppDataPath atomically:YES];
    [@{} writeToFile:kDataPath atomically:YES];

    self.lastCount = 0;
    [self specifiers];
    [self reloadSpecifiers];
    [self toast:@"已清空"];
}

@end
