// 设置面板：只读写 plist，不碰蓝牙、不枚举已安装 App。
//
// 数据有两个来源，面板合并显示：
//   1. capture.plist —— SpringBoard 里跑的直连扫描，设备推上来的帧
//   2. app.plist     —— 注入到目标 App 的 hook，收发双向
// 谁有数据算谁的。1.4.1 只有第 2 条，注入失败时面板一片空，看不出问题在哪。
//
// 1.2.1 点进来就闪退的根因是这里调了 LSApplicationWorkspace 的
// allInstalledApplications（iOS 16 已移除）。现在不需要 App 白名单，
// 那段代码整个不存在。

#import "AxsBLELoggerRootListController.h"
#import "AxsBLELoggerPaths.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define kConfigPath  AXSPath(@"config.plist")
#define kDataPath    AXSPath(@"capture.plist")
#define kAppDataPath AXSPath(@"app.plist")

static NSString *const kPrefsChanged = @"com.qwq.blelogger.preferences-changed";
static const NSUInteger kShowFrames  = 20;
static const NSUInteger kShowLatest  = 6;
static const NSUInteger kShowDevices = 8;

static NSString *AXString(id v) {
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static BOOL AXWriteConfig(NSString *key, id value) {
    if (key.length == 0) return NO;
    // 读的时候要跨目录找（配置可能还躺在旧位置），写固定写本进程目录
    NSMutableDictionary *d = [AXSReadAnyFile(@"config.plist", NULL) mutableCopy];
    if (value) {
        d[key] = value;
    } else {
        [d removeObjectForKey:key];
    }
    BOOL ok = [d writeToFile:kConfigPath atomically:YES];
    if (ok) {
        // SpringBoard 侧的扫描器靠这条通知重读配置（换目标设备、开关）
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
// 容器扫描结果，进页面时清一次
@property (nonatomic, strong) NSArray *appDataCache;
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

@implementation AxsBLELoggerRootListController

#pragma mark - 数据

- (NSDictionary *)config { return AXSReadAnyFile(@"config.plist", NULL); }
- (NSDictionary *)capture { return AXSReadAnyFile(@"capture.plist", NULL); }

// 注入方的数据可能不在全局目录里：目标 App 是沙盒进程，写不进 Caches 时
// 会退到自己容器的 Documents。1.4.1 就是栽在这里 —— 数据写成功了，
// 面板只认固定路径，读不到就说「被沙盒挡住了」。
// 这里在主路径为空时扫一遍容器，代价是几百次 stat，只在需要时做一次。
- (NSArray *)appDataFiles {
    if (self.appDataCache) return self.appDataCache;

    NSDictionary *main = AXSReadAnyFile(@"app.plist", NULL);
    if (main.count) {
        self.appDataCache = @[main];
        return self.appDataCache;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:NULL]) {
        NSString *p = [[root stringByAppendingPathComponent:uuid]
                       stringByAppendingPathComponent:@"Documents/app.plist"];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if ([d isKindOfClass:[NSDictionary class]] && d.count) [found addObject:d];
    }
    self.appDataCache = found;
    return self.appDataCache;
}

- (NSArray *)injected {
    NSMutableArray *all = [NSMutableArray array];
    for (NSDictionary *d in [self appDataFiles]) {
        NSArray *a = d[@"injected"];
        if ([a isKindOfClass:[NSArray class]]) [all addObjectsFromArray:a];
    }
    return all;
}

// 两路帧合并，按时间排。扫描帧没有 src 字段，统一补成 scan / app。
- (NSArray *)frames {
    NSMutableArray *all = [NSMutableArray array];

    NSArray *scan = self.capture[@"frames"];
    if ([scan isKindOfClass:[NSArray class]]) {
        for (NSDictionary *f in scan) {
            if (![f isKindOfClass:[NSDictionary class]]) continue;
            if (f[@"src"]) { [all addObject:f]; continue; }
            NSMutableDictionary *m = [f mutableCopy];
            m[@"src"] = @"scan";
            [all addObject:m];
        }
    }

    for (NSDictionary *d in [self appDataFiles]) {
        NSArray *app = d[@"frames"];
        if (![app isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *f in app) {
            if (![f isKindOfClass:[NSDictionary class]]) continue;
            if (f[@"src"]) { [all addObject:f]; continue; }
            NSMutableDictionary *m = [f mutableCopy];
            m[@"src"] = @"app";
            [all addObject:m];
        }
    }

    [all sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
        return [(AXString(x[@"t"]) ?: @"") compare:(AXString(y[@"t"]) ?: @"")];
    }];
    return all;
}

- (NSArray *)devices {
    NSArray *d = self.capture[@"devices"];
    return [d isKindOfClass:[NSArray class]] ? d : @[];
}

- (NSString *)targetUUID {
    return AXString(self.config[@"targetUUID"]) ?: @"";
}

- (NSString *)stateText {
    NSString *s = AXString(self.capture[@"state"]);
    return s.length ? s : @"还没有数据上报";
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
    // 容器扫描很慢，只在进页面时做一次，tick 刷新复用结果
    self.appDataCache = nil;
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
    [intro setProperty:@"两路同时抓：SpringBoard 直连扫描（不需要 App）+ 注入目标 App 的 "
                       @"CoreBluetooth hook（能抓到 App 发出去的帧）。这里只是查看器。"
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
    NSString *state;
    if (self.frames.count) {
        state = [NSString stringWithFormat:@"已记录 %lu 条。%@", (unsigned long)frames.count, self.stateText];
    } else {
        state = @"还没有任何帧。开启后把目标 App 从后台划掉重开，操作一遍；"
                 "或者直接在下面「附近设备」里选一台连上。";
    }
    state = [state stringByAppendingFormat:@"\n数据目录：%@", AXSDataDirDescription()];

    PSSpecifier *statusGroup = AXGroup(@"状态");
    [statusGroup setProperty:state forKey:@"footerText"];
    [items addObject:statusGroup];

    // ---- 已注入的 App（诊断）----
    // 空白面板最常见的原因不是抓不到，是 hook 压根没进目标 App。
    // 这个列表为空 = 注入没成功，那就得靠下面的直连扫描。
    NSArray *injected = [self injected];
    PSSpecifier *injectGroup = AXGroup(
        [NSString stringWithFormat:@"已注入的 App（%lu）", (unsigned long)injected.count]);

    NSMutableString *injectText = [NSMutableString string];
    if (injected.count == 0) {
        [injectText appendString:
            @"一个都没有 —— hook 没进任何 App。先把目标 App 从后台划掉重开；"
            @"RootHide 环境还要把它加进注入白名单。注入不通不影响下面的直连扫描。"];
    } else {
        for (NSDictionary *e in injected) {
            if (![e isKindOfClass:[NSDictionary class]]) continue;
            [injectText appendFormat:@"%@  %@\n", AXString(e[@"t"]) ?: @"", AXString(e[@"bid"]) ?: @"?"];
        }
    }
    [injectGroup setProperty:injectText forKey:@"footerText"];
    [items addObject:injectGroup];

    // ---- 附近设备 / 直连目标 ----
    // 注入抓不到东西时，用户得有个办法让扫描器连上设备。没选目标时
    // 扫描器只列表不连接，所以这一步是「让它开始抓」的开关。
    NSArray *devices = self.devices;
    NSString *uuid = [self targetUUID];
    NSString *targetLabel = uuid.length
        ? [NSString stringWithFormat:@"直连目标：%@", [[uuid componentsSeparatedByString:@"-"] firstObject]]
        : @"直连目标：未选择";

    PSSpecifier *devGroup = AXGroup(
        [NSString stringWithFormat:@"附近设备（%lu）", (unsigned long)devices.count]);
    NSString *devFooter = devices.count
        ? [NSString stringWithFormat:@"%@\n点一台设备开始直连抓包（只收设备推上来的帧）。再点一次取消。",
           targetLabel]
        : [NSString stringWithFormat:@"%@\n还没扫到设备。蓝牙要在打开状态，设备要在广播。",
           targetLabel];
    [devGroup setProperty:devFooter forKey:@"footerText"];
    [items addObject:devGroup];

    NSUInteger shown = 0;
    for (NSDictionary *d in devices) {
        if (shown++ >= kShowDevices) break;
        NSString *u = AXString(d[@"uuid"]) ?: @"";
        NSString *n = AXString(d[@"name"]) ?: @"";
        if (!u.length) continue;

        BOOL selected = [u caseInsensitiveCompare:uuid] == NSOrderedSame;
        NSString *label = [NSString stringWithFormat:@"%@ %@  %@",
                           selected ? @"✓" : @"　",
                           n.length ? n : @"(无名)",
                           u.length > 8 ? [u substringToIndex:8] : u];

        PSSpecifier *row = AXButtonRow(label, self, @selector(toggleTarget:));
        [row setProperty:u forKey:@"axs_uuid"];
        [items addObject:row];
    }

    if (uuid.length) {
        [items addObject:AXButtonRow(@"清除直连目标", self, @selector(clearTarget:))];
    }

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
            // 直 = SpringBoard 直连扫到的，注 = 从目标 App 里 hook 到的
            NSString *tag = [AXString(f[@"src"]) isEqualToString:@"app"] ? @"注" : @"直";

            PSSpecifier *row = AXButtonRow(
                [NSString stringWithFormat:@"%@ %@(%@) %@  %@",
                 t, dir, tag, short8, AXSpaceHex(AXString(f[@"hex"]))],
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

- (void)refresh {
    [self specifiers];
    [self reloadSpecifiers];
}

- (void)setEnabled:(id)value specifier:(PSSpecifier *)specifier {
    AXWriteConfig(@"enabled", @([value boolValue]));

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf refresh];
    });
}

#pragma mark - 直连目标

- (void)toggleTarget:(PSSpecifier *)specifier {
    NSString *uuid = AXString([specifier propertyForKey:@"axs_uuid"]);
    if (uuid.length == 0) return;

    if ([uuid caseInsensitiveCompare:[self targetUUID]] == NSOrderedSame) {
        [self clearTarget:specifier];
        return;
    }

    // 名字一起存：UUID 是主键，名字是兜底。设备重连后 UUID 不变，
    // 但广播名偶尔改（"XXX-APP" 之类），只存名字会匹配不上。
    NSString *name = @"";
    for (NSDictionary *d in self.devices) {
        if ([AXString(d[@"uuid"]) isEqualToString:uuid]) {
            name = AXString(d[@"name"]) ?: @"";
            break;
        }
    }

    AXWriteConfig(@"targetUUID", uuid);
    AXWriteConfig(@"deviceName", name);
    [self refresh];
    [self toast:name.length ? [NSString stringWithFormat:@"已选 %@，回状态栏看看", name]
                            : @"已选这台设备"];
}

- (void)clearTarget:(PSSpecifier *)specifier {
    AXWriteConfig(@"targetUUID", nil);
    AXWriteConfig(@"deviceName", nil);
    [self refresh];
    [self toast:@"已清除直连目标"];
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
    [out appendFormat:@"# BLE Logger %lu 条（直=直连扫描 注=注入 hook）\n", (unsigned long)frames.count];
    for (NSDictionary *f in frames) {
        if (![f isKindOfClass:[NSDictionary class]]) continue;
        NSString *tag = [AXString(f[@"src"]) isEqualToString:@"app"] ? @"注" : @"直";
        [out appendFormat:@"%@ %@(%@) %@ %@\n",
            AXString(f[@"t"]) ?: @"",
            AXString(f[@"dir"]) ?: @"",
            tag,
            AXString(f[@"chr"]) ?: @"?",
            AXSpaceHex(AXString(f[@"hex"]))];
    }

    [UIPasteboard generalPasteboard].string = out;
    [self toast:[NSString stringWithFormat:@"已复制 %lu 条", (unsigned long)frames.count]];
}

- (void)clearFrames:(PSSpecifier *)specifier {
    // 三个候选目录都清一遍，否则下一次读又会把 /var/tmp 或旧位置里的
    // 老数据捞回来，看起来像"清不掉"。
    for (NSString *dir in @[AXSDataDir(), AXS_DIR_MAIN, AXS_DIR_TMP, AXS_DIR_LEGACY]) {
        [@{} writeToFile:[dir stringByAppendingPathComponent:@"capture.plist"] atomically:YES];
        [@{} writeToFile:[dir stringByAppendingPathComponent:@"app.plist"] atomically:YES];
    }
    self.appDataCache = nil;
    self.lastCount = 0;

    [self refresh];
    [self toast:@"已清空"];
}

@end
