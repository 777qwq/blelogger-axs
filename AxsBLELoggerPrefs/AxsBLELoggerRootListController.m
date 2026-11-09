// 设置面板：只读写 plist，不碰蓝牙、不枚举已安装 App。
//
// 1.2.1 点进来就崩的两个点，这里都已经不存在：
// 1. -specifiers 里调 LSApplicationWorkspace 的 allInstalledApplications，
//    iOS 16 上这个方法已经没了，performSelector 直接 unrecognized selector。
//    新方案不注入 App，也就不需要 App 白名单，这段整个删掉。
// 2. 悬浮窗那套 UIApplication/窗口层级的代码也不在面板里，面板只有 PSSpecifier。
//
// 所有跨进程数据都是「SpringBoard 写 plist → 面板读 plist」，面板不持有蓝牙对象，
// 所以面板崩了也不会影响抓包，反之亦然。

#import "AxsBLELoggerRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kConfigPath   = @"/var/mobile/Library/Preferences/com.qwq.blelogger.plist";
static NSString *const kDataPath     = @"/var/mobile/Library/Preferences/com.qwq.blelogger.capture.plist";
static NSString *const kPrefsChanged = @"com.qwq.blelogger.preferences-changed";
static const NSUInteger kShowFrames  = 15;
static const NSUInteger kShowDevices = 8;
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
        // 让已经跑起来的 SpringBoard 立刻重读配置，不用 respring
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)kPrefsChanged, NULL, NULL, 1);
    }
    return ok;
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

- (NSDictionary *)config { return AXRead(kConfigPath); }
- (NSDictionary *)capture { return AXRead(kDataPath); }

- (NSString *)deviceName { return AXString(self.config[@"deviceName"]) ?: @""; }
- (NSString *)targetUUID {
    NSString *u = AXString(self.config[@"targetUUID"]);
    // 只显示前 8 位，完整值在复制内容里
    if (u.length > 8) return [u substringToIndex:8];
    return u ?: @"";
}

- (NSArray *)frames {
    NSArray *f = self.capture[@"frames"];
    return [f isKindOfClass:[NSArray class]] ? f : @[];
}

- (NSArray *)devices {
    NSArray *d = self.capture[@"devices"];
    return [d isKindOfClass:[NSArray class]] ? d : @[];
}

- (NSString *)stateText {
    return AXString(self.capture[@"state"]) ?: @"未启动";
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
    [self reloadSpecifiers];
}

#pragma mark - 列表

- (NSMutableArray *)specifiers {
    NSMutableArray *items = [NSMutableArray array];

    // ---- 概览 ----
    PSSpecifier *intro = [PSSpecifier groupSpecifierWithName:@"BLE Logger"];
    [intro setProperty:@"插件在 SpringBoard 里自己当中心设备：扫描、连接、订阅全部 Notify 特征，"
                       @"把设备推上来的帧记下来。不注入任何 App，设备没有配套 App 也能用。"
                forKey:@"footerText"];
    [items addObject:intro];

    PSSpecifier *enabled = [PSSpecifier preferenceSpecifierNamed:@"启用抓包"
                                                          target:self
                                                             set:@selector(setEnabled:specifier:)
                                                             get:@selector(getEnabled:)
                                                          detail:nil
                                                            cell:PSSwitchCell
                                                            edit:nil];
    [items addObject:enabled];

    PSSpecifier *status = [PSSpecifier preferenceSpecifierNamed:@"运行状态"
                                                         target:nil set:nil get:nil detail:nil
                                                           cell:PSTitleValueCell edit:nil];
    [status setProperty:self.stateText forKey:@"value"];
    [items addObject:status];

    // ---- 目标设备 ----
    NSString *name = self.deviceName;
    NSString *uuid = self.targetUUID;
    NSString *targetDesc = @"未选择（只扫描，不连接）";
    if (name.length && uuid.length) {
        targetDesc = [NSString stringWithFormat:@"%@  ·  %@…", name, uuid];
    } else if (name.length) {
        targetDesc = name;
    } else if (uuid.length) {
        targetDesc = [NSString stringWithFormat:@"%@…", uuid];
    }

    PSSpecifier *devGroup = [PSSpecifier groupSpecifierWithName:@"目标设备"];
    [devGroup setProperty:[NSString stringWithFormat:@"当前：%@\n点下面的设备直接设为目标；设备没名字时也能按 UUID 认。",
                           targetDesc]
                   forKey:@"footerText"];
    [items addObject:devGroup];

    NSArray *devices = self.devices;
    if (devices.count == 0) {
        PSSpecifier *none = [PSSpecifier preferenceSpecifierNamed:@"还没扫到设备"
                                                           target:nil set:nil get:nil detail:nil
                                                             cell:PSTitleValueCell edit:nil];
        [none setProperty:@"确认蓝牙已开、开关已打开" forKey:@"value"];
        [items addObject:none];
    } else {
        NSUInteger shown = 0;
        for (NSDictionary *d in devices) {
            if (shown >= kShowDevices) break;
            NSString *dname = AXString(d[@"name"]);
            NSString *duuid = AXString(d[@"uuid"]);
            if (duuid.length == 0) continue;

            NSString *label = dname.length
                ? [NSString stringWithFormat:@"%@（%@）", dname,
                   duuid.length > 8 ? [duuid substringToIndex:8] : duuid]
                : [NSString stringWithFormat:@"未命名（%@）",
                   duuid.length > 8 ? [duuid substringToIndex:8] : duuid];

            PSSpecifier *row = AXButtonRow(label, self, @selector(pickDevice:));
            [row setProperty:d forKey:@"axs_device"];
            [items addObject:row];
            shown++;
        }
    }

    PSSpecifier *manual = AXButtonRow(@"手动输入设备名", self, @selector(editDeviceName:));
    [items addObject:manual];

    if (name.length || uuid.length) {
        PSSpecifier *clear = AXButtonRow(@"清除目标（只扫描）", self, @selector(clearTarget:));
        [items addObject:clear];
    }

    // ---- 最近值（按特征去重）----
    NSArray *frames = self.frames;
    NSMutableArray *chrOrder = [NSMutableArray array];
    NSMutableDictionary *latest = [NSMutableDictionary dictionary];
    for (NSInteger i = (NSInteger)frames.count - 1; i >= 0; i--) {
        NSDictionary *f = frames[i];
        NSString *chr = AXString(f[@"chr"]);
        if (chr.length == 0) continue;
        if (!latest[chr]) {
            latest[chr] = f;
            [chrOrder addObject:chr];       // 倒序扫，第一次遇到即最新
        }
    }

    if (chrOrder.count) {
        PSSpecifier *latestGroup = [PSSpecifier groupSpecifierWithName:@"最近值（按特征）"];
        [latestGroup setProperty:@"同一特征只留最后一帧，完整日志在下面。点按复制这一帧。"
                          forKey:@"footerText"];
        [items addObject:latestGroup];

        NSUInteger shown = 0;
        for (NSString *chr in chrOrder) {
            if (shown >= kShowLatest) break;
            NSDictionary *f = latest[chr];
            NSString *shortChr = chr.length > 8 ? [chr substringToIndex:8] : chr;
            NSString *hex = AXString(f[@"hex"]) ?: @"";
            NSString *label = [NSString stringWithFormat:@"%@  %@", shortChr, hex];
            PSSpecifier *row = AXButtonRow(label, self, @selector(copyFrame:));
            [row setProperty:f forKey:@"axs_frame"];
            [items addObject:row];
            shown++;
        }
    }

    // ---- 日志 ----
    PSSpecifier *frameGroup = [PSSpecifier groupSpecifierWithName:
        [NSString stringWithFormat:@"最近帧（共 %lu 条，点按复制）", (unsigned long)frames.count]];
    [frameGroup setProperty:@"时间 + 方向 + HEX。设备推上来的帧方向是「收」。"
                    forKey:@"footerText"];
    [items addObject:frameGroup];

    if (frames.count == 0) {
        PSSpecifier *empty = [PSSpecifier preferenceSpecifierNamed:@"还没有帧"
                                                            target:nil set:nil get:nil detail:nil
                                                              cell:PSTitleValueCell edit:nil];
        [empty setProperty:@"连上之后按一下设备上的按钮" forKey:@"value"];
        [items addObject:empty];
    } else {
        NSUInteger start = frames.count > kShowFrames ? frames.count - kShowFrames : 0;
        for (NSUInteger i = frames.count; i > start; i--) {
            NSDictionary *f = frames[i - 1];
            NSString *label = [NSString stringWithFormat:@"%@ %@  %@",
                               AXString(f[@"t"]) ?: @"", AXString(f[@"dir"]) ?: @"",
                               AXString(f[@"hex"]) ?: @""];
            PSSpecifier *row = AXButtonRow(label, self, @selector(copyFrame:));
            [row setProperty:f forKey:@"axs_frame"];
            [items addObject:row];
        }
    }

    PSSpecifier *actions = [PSSpecifier groupSpecifierWithName:@""];
    [items addObject:actions];

    PSSpecifier *copyAll = AXButtonRow(@"复制全部日志", self, @selector(copyAll:));
    [items addObject:copyAll];

    PSSpecifier *clear = AXButtonRow(@"清空日志", self, @selector(clearFrames:));
    [items addObject:clear];

    return items;
}

#pragma mark - 开关

- (id)getEnabled:(PSSpecifier *)specifier {
    id v = self.config[@"enabled"];
    return [v isKindOfClass:[NSNumber class]] ? v : @NO;
}

- (void)setEnabled:(id)value specifier:(PSSpecifier *)specifier {
    AXWriteConfig(@"enabled", @([value boolValue]));
    // SpringBoard 那边 1 秒左右才会写回新状态，稍后再刷一次列表
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf reloadSpecifiers];
    });
}

#pragma mark - 点选兜底

// PSSpecifier 的 action ivar 谁都能写，但如果哪天苹果改了布局，
// AXSetCellAction 会写失败。这时按钮不会自己派发，由这里接手。
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (g_axsCellActionWritable) {
        // 正常情况：PSButtonCell 自己已经把 action 发出去了，不再重复执行
        return;
    }

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

#pragma mark - 选设备

- (void)pickDevice:(PSSpecifier *)specifier {
    NSDictionary *d = [specifier propertyForKey:@"axs_device"];
    if (![d isKindOfClass:[NSDictionary class]]) return;

    NSString *uuid = AXString(d[@"uuid"]);
    NSString *name = AXString(d[@"name"]);
    if (uuid.length == 0) return;

    AXWriteConfig(@"targetUUID", uuid);
    AXWriteConfig(@"deviceName", name.length ? name : nil);
    if (!AXString(self.config[@"enabled"])) {
        AXWriteConfig(@"enabled", @YES);        // 选了设备顺手把开关打开
    }
    [self reloadSpecifiers];

    UIAlertController *toast = [UIAlertController alertControllerWithTitle:nil
                                                                   message:@"已设为目标，正在连接"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:toast animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [toast dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

- (void)editDeviceName:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"目标设备名"
                         message:@"填广播里的名字，支持部分匹配（填 iKF 就能匹配 iKF-Air Clip-APP）。留空 = 只扫描不连接。"
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = self.deviceName;
        tf.placeholder = @"例如 iKF-Air Clip-APP";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        UITextField *field = (UITextField *)alert.textFields.firstObject;
        NSString *name = field.text ?: @"";
        name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        AXWriteConfig(@"deviceName", name.length ? name : nil);
        AXWriteConfig(@"targetUUID", nil);      // 手输了名字就按名字匹配
        [weakSelf reloadSpecifiers];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearTarget:(PSSpecifier *)specifier {
    AXWriteConfig(@"deviceName", nil);
    AXWriteConfig(@"targetUUID", nil);
    [self reloadSpecifiers];
}

#pragma mark - 复制 / 清空

- (void)toast:(NSString *)text {
    UIAlertController *toast = [UIAlertController alertControllerWithTitle:nil
                                                                   message:text
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:toast animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [toast dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

- (void)copyFrame:(PSSpecifier *)specifier {
    NSDictionary *f = [specifier propertyForKey:@"axs_frame"];
    if (![f isKindOfClass:[NSDictionary class]]) return;

    NSString *text = [NSString stringWithFormat:@"%@ %@ %@ %@",
                      AXString(f[@"t"]) ?: @"", AXString(f[@"dir"]) ?: @"",
                      AXString(f[@"chr"]) ?: @"", AXString(f[@"hex"]) ?: @""];
    [UIPasteboard generalPasteboard].string = text;
    [self toast:@"已复制"];
}

- (void)copyAll:(PSSpecifier *)specifier {
    NSArray *frames = self.frames;
    NSMutableString *out = [NSMutableString string];
    for (NSDictionary *f in frames) {
        [out appendFormat:@"%@ %@ %@ %@\n",
            AXString(f[@"t"]) ?: @"", AXString(f[@"dir"]) ?: @"",
            AXString(f[@"chr"]) ?: @"", AXString(f[@"hex"]) ?: @""];
    }
    if (out.length == 0) [out appendString:@"（空）"];
    [UIPasteboard generalPasteboard].string = out;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"已复制"
                         message:[NSString stringWithFormat:@"%lu 条", (unsigned long)frames.count]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearFrames:(PSSpecifier *)specifier {
    NSMutableDictionary *d = [AXRead(kDataPath) mutableCopy];
    if (!d) d = [NSMutableDictionary dictionary];
    d[@"frames"] = @[];
    [d writeToFile:kDataPath atomically:YES];

    self.lastCount = 0;
    [self reloadSpecifiers];
}

@end
