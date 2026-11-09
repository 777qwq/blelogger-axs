// BLELogger — 注入目标 App，hook CoreBluetooth，抓 BLE 读写并显示悬浮球
//
// 设计要点：
//   1. 只 hook 三个点：CBPeripheral 的 writeValue / setDelegate / CBCentralManager init
//   2. 日志写 /var/mobile/Library/Preferences/ble-capture.log，每次冷启动开一条新会话
//   3. 悬浮球在 App 首次创建 CBCentralManager 时出现，不用蓝牙的 App 不受影响
//   4. 点任一条记录即复制 "ble:设备|服务|特征|HEX" 到剪贴板
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <dispatch/dispatch.h>
#import "AxsBLELoggerConfig.h"

// ---------------- 全局状态 ----------------

static NSString *const kLogPath = @"/var/mobile/Library/Preferences/ble-capture.log";

static NSMutableArray *g_records  = nil;
static BOOL            g_logOK    = NO;
static BOOL            g_hudShown = NO;
static BOOL            g_session   = NO;
static NSString       *g_bundleId  = nil;

static void (*g_origWrite)(id, SEL, NSData *, CBCharacteristic *, CBCharacteristicWriteType) = NULL;
static void (*g_origSetDelegate)(id, SEL, id) = NULL;
static void (*g_origDidUpdate)(id, SEL, CBPeripheral *, CBCharacteristic *, id) = NULL;
static id   (*g_origCMInit)(id, SEL, id, id) = NULL;
static BOOL g_delegateHooked = NO;

// ---------------- 工具函数 ----------------

static NSString *BLHex(NSData *d) {
    if (!d) return @"";
    const unsigned char *b = (const unsigned char *)[d bytes];
    NSUInteger n = [d length];
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < n; i++) {
        [s appendFormat:@"%02X", b[i]];
    }
    return s;
}

// CBUUID.UUIDString 对 16/32 位 UUID 只返回短形式，补成完整 128 位
static NSString *BLUUID(CBUUID *u) {
    if (!u) return @"?";
    NSString *s = [u UUIDString];
    NSUInteger n = [s length];
    if (n == 4) {
        return [NSString stringWithFormat:@"0000%@-0000-1000-8000-00805F9B34FB", s];
    }
    if (n == 8) {
        return [NSString stringWithFormat:@"%@-0000-1000-8000-00805F9B34FB", s];
    }
    return s;
}

static NSString *BLNow(void) {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"HH:mm:ss"];
    return [df stringFromDate:[NSDate date]];
}

static NSString *BLNowFull(void) {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
    return [df stringFromDate:[NSDate date]];
}

// ---------------- 日志文件 ----------------

static void BLLogOpen(void) {
    @synchronized([NSObject class]) {
        [[NSFileManager defaultManager] removeItemAtPath:kLogPath error:NULL];
        NSString *head = [NSString stringWithFormat:@"=== session %@  app=%@ ===\n",
                          BLNowFull(), (g_bundleId ? g_bundleId : @"?")];
        g_logOK = [head writeToFile:kLogPath atomically:NO
                           encoding:NSUTF8StringEncoding error:NULL];
    }
}

// 日志只在「这个 App 第一次真正用蓝牙」时开新会话，
// 避免用户切到别的 App 时把正在抓的内容清掉。
static void BLEnsureSession(void) {
    if (g_session) return;
    g_session = YES;
    BLLogOpen();
}

static void BLLogAppend(NSString *text) {
    if (!g_logOK) return;
    @synchronized([NSObject class]) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        if (!fh) return;
        [fh seekToEndOfFile];
        [fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
        [fh synchronizeFile];
        [fh closeFile];
    }
}

// ---------------- 悬浮球 ----------------

@interface AxsBLELoggerWindow : UIWindow
@end

@implementation AxsBLELoggerWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(id)e {
    UIView *v = [super hitTest:p withEvent:e];
    return (v == self) ? nil : v;   // 点空白处穿透给下层 App
}
@end

@interface AxsBLELoggerHUD : NSObject
@property (strong) AxsBLELoggerWindow *win;
@property (strong) UIButton *dot;
@property (strong) UIView *panel;
@property (strong) UIView *card;
@property (strong) UIScrollView *scroll;
@property (strong) NSMutableArray *rows;
@end

@implementation AxsBLELoggerHUD

+ (instancetype)shared {
    static AxsBLELoggerHUD *o = nil;
    if (!o) o = [[AxsBLELoggerHUD alloc] init];
    return o;
}

- (instancetype)init {
    if ((self = [super init])) {
        _rows = [NSMutableArray array];
    }
    return self;
}

- (UILabel *)mkLabel:(NSString *)text font:(UIFont *)font color:(UIColor *)color frame:(CGRect)f lines:(NSInteger)n {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.text = text;
    l.font = font;
    l.textColor = color;
    l.numberOfLines = n;
    l.textAlignment = NSTextAlignmentLeft;
    return l;
}

- (void)buildWindow {
    CGRect b = [[UIScreen mainScreen] bounds];
    AxsBLELoggerWindow *w = nil;
    // iOS 13+ 的 window 必须挂在某个 UIWindowScene 上才稳定显示；
    // 拿不到 scene（极早期）就退回老的 initWithFrame。
    UIWindow *kw = [[UIApplication sharedApplication] keyWindow];
    UIWindowScene *sc = kw ? [kw windowScene] : nil;
    if (sc) {
        w = [[AxsBLELoggerWindow alloc] initWithWindowScene:sc];
        w.frame = b;
    } else {
        w = [[AxsBLELoggerWindow alloc] initWithFrame:b];
    }
    w.windowLevel = 2100;
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = [[UIViewController alloc] init];
    w.hidden = NO;

    UIView *host = w.rootViewController.view;
    host.backgroundColor = [UIColor clearColor];

    UIButton *dot = [UIButton buttonWithType:UIButtonTypeCustom];
    dot.frame = CGRectMake(b.size.width - 62, b.size.height * 0.35, 46, 46);
    dot.backgroundColor = [UIColor colorWithRed:0.10 green:0.55 blue:0.90 alpha:0.88];
    dot.layer.cornerRadius = 23.0;
    dot.layer.masksToBounds = YES;
    [dot setTitle:@"BLE" forState:UIControlStateNormal];
    [dot setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    dot.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [dot addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [dot addGestureRecognizer:pan];

    [host addSubview:dot];
    _dot = dot;
    _win = w;
    _panel = nil;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateChanged) return;
    CGPoint t = [g translationInView:_dot.superview];
    CGRect f = _dot.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    CGRect b = [[UIScreen mainScreen] bounds];
    if (f.origin.x < 8) f.origin.x = 8;
    if (f.origin.y < 60) f.origin.y = 60;
    if (f.origin.x > b.size.width - f.size.width - 8) f.origin.x = b.size.width - f.size.width - 8;
    if (f.origin.y > b.size.height - f.size.height - 40) f.origin.y = b.size.height - f.size.height - 40;
    _dot.frame = f;
    [g setTranslation:CGPointMake(0, 0) inView:_dot.superview];
}

- (void)togglePanel {
    if (_panel) {
        [_panel removeFromSuperview];
        _panel = nil;
        _card = nil;
        _scroll = nil;
        return;
    }
    [self buildPanel];
}

- (void)buildPanel {
    CGRect b = [[UIScreen mainScreen] bounds];
    UIView *host = _win.rootViewController.view;

    UIView *panel = [[UIView alloc] initWithFrame:b];
    panel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.72];
    [host addSubview:panel];
    _panel = panel;

    CGFloat cw = b.size.width - 32;
    CGFloat chh = b.size.height - 160;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 90, cw, chh)];
    card.backgroundColor = [UIColor systemBackgroundColor];
    card.layer.cornerRadius = 16.0;
    card.layer.masksToBounds = YES;
    [panel addSubview:card];
    _card = card;

    UILabel *title = [self mkLabel:@"BLE 抓包" font:[UIFont boldSystemFontOfSize:17]
                             color:[UIColor labelColor]
                             frame:CGRectMake(16, 12, 160, 22) lines:1];
    [card addSubview:title];

    UILabel *sub = [self mkLabel:@""
                           font:[UIFont systemFontOfSize:11]
                          color:[UIColor secondaryLabelColor]
                          frame:CGRectMake(16, 35, cw - 150, 16) lines:1];
    sub.tag = 9001;
    [card addSubview:sub];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(cw - 72, 8, 60, 30);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:14];
    [close addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(cw - 128, 8, 54, 30);
    [clear setTitle:@"清空" forState:UIControlStateNormal];
    clear.titleLabel.font = [UIFont systemFontOfSize:14];
    [clear setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    [clear addTarget:self action:@selector(clearAll) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:clear];

    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 58, cw, chh - 58)];
    sv.alwaysBounceVertical = YES;
    sv.showsVerticalScrollIndicator = YES;
    [card addSubview:sv];
    _scroll = sv;

    [self reloadRows];
}

- (void)reloadRows {
    NSUInteger i, n = [_rows count];
    for (i = 0; i < n; i++) {
        [[_rows objectAtIndex:i] removeFromSuperview];
    }
    [_rows removeAllObjects];
    if (!_scroll) return;

    CGFloat cw = _scroll.frame.size.width;
    CGFloat y = 0;
    n = [g_records count];

    for (i = 0; i < n; i++) {
        NSDictionary *r = (NSDictionary *)[g_records objectAtIndex:i];
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, cw, 54)];
        row.backgroundColor = (i % 2 == 0) ? [UIColor colorWithWhite:0.5 alpha:0.06] : [UIColor clearColor];
        row.tag = (NSInteger)i;

        NSString *dir = (NSString *)[r objectForKey:@"dir"];
        UIColor *dc = [dir isEqualToString:@"发"] ? [UIColor systemBlueColor] : [UIColor systemGreenColor];

        NSString *head = [NSString stringWithFormat:@"%@  %@  %@ / %@",
                          (NSString *)[r objectForKey:@"t"], dir,
                          (NSString *)[r objectForKey:@"svc"], (NSString *)[r objectForKey:@"chr"]];
        UILabel *l1 = [self mkLabel:head font:[UIFont systemFontOfSize:10] color:dc
                              frame:CGRectMake(12, 5, cw - 24, 14) lines:1];
        [row addSubview:l1];

        UILabel *l2 = [self mkLabel:(NSString *)[r objectForKey:@"hex"]
                               font:[UIFont monospacedSystemFontOfSize:13 weight:0]
                              color:[UIColor labelColor]
                              frame:CGRectMake(12, 21, cw - 24, 26) lines:1];
        l2.tag = 9100;
        [row addSubview:l2];

        UIButton *hit = [UIButton buttonWithType:UIButtonTypeCustom];
        hit.frame = CGRectMake(0, 0, cw, 54);
        hit.tag = (NSInteger)i;
        [hit addTarget:self action:@selector(copyRow:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:hit];

        [_scroll addSubview:row];
        [_rows addObject:row];
        y += 54;
    }
    _scroll.contentSize = CGSizeMake(cw, y);

    UILabel *sub = (UILabel *)[_card viewWithTag:9001];
    if (sub) {
        sub.text = g_logOK
            ? [NSString stringWithFormat:@"日志 %lu 条 · 点任一条复制", (unsigned long)n]
            : @"日志不可写，仅内存可见";
    }
    [_dot setTitle:(n ? [NSString stringWithFormat:@"BLE %lu", (unsigned long)n] : @"BLE")
          forState:UIControlStateNormal];
}

- (void)copyRow:(UIButton *)sender {
    NSInteger i = sender.tag;
    if (i < 0 || i >= (NSInteger)[g_records count]) return;
    NSDictionary *r = (NSDictionary *)[g_records objectAtIndex:(NSUInteger)i];

    NSString *line = [NSString stringWithFormat:@"ble:%@|%@|%@|%@",
                      (NSString *)[r objectForKey:@"dev"],
                      (NSString *)[r objectForKey:@"svc"],
                      (NSString *)[r objectForKey:@"chr"],
                      (NSString *)[r objectForKey:@"hex"]];
    [[UIPasteboard generalPasteboard] setString:line];

    UILabel *l2 = (UILabel *)[sender.superview viewWithTag:9100];
    if (l2) {
        l2.text = @"已复制 ✓";
        l2.textColor = [UIColor systemGreenColor];
        [self performSelector:@selector(restoreLabel:) withObject:l2 afterDelay:1.0];
    }
}

- (void)restoreLabel:(UILabel *)l {
    if (!l) return;
    NSInteger idx = l.superview.tag;
    if (idx >= 0 && idx < (NSInteger)[g_records count]) {
        NSDictionary *r = (NSDictionary *)[g_records objectAtIndex:(NSUInteger)idx];
        l.text = (NSString *)[r objectForKey:@"hex"];
    }
    l.textColor = [UIColor labelColor];
}

- (void)clearAll {
    [g_records removeAllObjects];
    if (g_logOK) {
        NSString *head = [NSString stringWithFormat:@"=== session %@ (cleared) ===\n", BLNowFull()];
        [head writeToFile:kLogPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    }
    [self reloadRows];
}

- (void)addRecord:(NSDictionary *)r {
    if (!g_records) g_records = [NSMutableArray array];
    [g_records addObject:r];
    if ([g_records count] > 200) [g_records removeObjectAtIndex:0];

    if (_panel) {
        [self reloadRows];
    } else if (_dot) {
        [_dot setTitle:[NSString stringWithFormat:@"BLE %lu", (unsigned long)[g_records count]]
              forState:UIControlStateNormal];
    }
}

@end

// ---------------- 记录入口 ----------------

static void BLAdd(NSString *dir, NSString *dev, NSString *svc, NSString *chr, NSString *hex, NSString *type) {
    if (!hex || [hex length] == 0) return;
    BLEnsureSession();

    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    [r setObject:BLNow() forKey:@"t"];
    [r setObject:dir forKey:@"dir"];
    [r setObject:(dev ? dev : @"?") forKey:@"dev"];
    [r setObject:svc forKey:@"svc"];
    [r setObject:chr forKey:@"chr"];
    [r setObject:hex forKey:@"hex"];
    [r setObject:type forKey:@"type"];

    NSString *line = [NSString stringWithFormat:
        @"[%@] %@ %@\n  service  %@\n  char     %@\n  type     %@\n  hex      %@\n\n",
        (NSString *)[r objectForKey:@"t"], dir, (NSString *)[r objectForKey:@"dev"],
        svc, chr, type, hex];
    BLLogAppend(line);

    dispatch_async(dispatch_get_main_queue(), ^{
        [[AxsBLELoggerHUD shared] addRecord:r];
    });
}

// ---------------- hook 实现 ----------------

static void BLWrite(id self, SEL _cmd, NSData *data, CBCharacteristic *ch, CBCharacteristicWriteType type) {
    @autoreleasepool {
        NSString *dev = [(CBPeripheral *)self name];
        NSString *svc = BLUUID([[ch service] UUID]);
        NSString *chr = BLUUID([ch UUID]);
        NSString *hex = BLHex(data);
        NSString *t = (type == CBCharacteristicWriteWithResponse) ? @"withResponse" : @"withoutResponse";
        BLAdd(@"发", dev, svc, chr, hex, t);
    }
    if (g_origWrite) g_origWrite(self, _cmd, data, ch, type);
}

static void BLDidUpdate(id self, SEL _cmd, CBPeripheral *p, CBCharacteristic *ch, id err) {
    @autoreleasepool {
        NSData *v = [ch value];
        if (v && [v length] > 0 && !err) {
            NSString *dev = [p name];
            NSString *svc = BLUUID([[ch service] UUID]);
            NSString *chr = BLUUID([ch UUID]);
            BLAdd(@"收", dev, svc, chr, BLHex(v), @"notify");
        }
    }
    if (g_origDidUpdate) g_origDidUpdate(self, _cmd, p, ch, err);
}

static void BLSetDelegate(id self, SEL _cmd, id delegate) {
    if (delegate && !g_delegateHooked) {
        Class cls = object_getClass(delegate);
        Method m = class_getInstanceMethod(cls, @selector(peripheral:didUpdateValueForCharacteristic:error:));
        if (m) {
            g_origDidUpdate = (void (*)(id, SEL, CBPeripheral *, CBCharacteristic *, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)BLDidUpdate);
            g_delegateHooked = YES;
        }
    }
    if (g_origSetDelegate) g_origSetDelegate(self, _cmd, delegate);
}

static id BLCentralInit(id self, SEL _cmd, id delegate, id queue) {
    id r = g_origCMInit ? g_origCMInit(self, _cmd, delegate, queue) : nil;
    BLEnsureSession();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_hudShown) {
            g_hudShown = YES;
            [[AxsBLELoggerHUD shared] buildWindow];
        }
    });
    return r;
}

// ---------------- 安装 ----------------

static void BLInstall(void) {
    Class peripheral = NSClassFromString(@"CBPeripheral");
    Class central    = NSClassFromString(@"CBCentralManager");

    if (peripheral) {
        Method mw = class_getInstanceMethod(peripheral, @selector(writeValue:forCharacteristic:type:));
        if (mw) {
            g_origWrite = (void (*)(id, SEL, NSData *, CBCharacteristic *, CBCharacteristicWriteType))method_getImplementation(mw);
            method_setImplementation(mw, (IMP)BLWrite);
        }
        Method md = class_getInstanceMethod(peripheral, @selector(setDelegate:));
        if (md) {
            g_origSetDelegate = (void (*)(id, SEL, id))method_getImplementation(md);
            method_setImplementation(md, (IMP)BLSetDelegate);
        }
    }
    if (central) {
        Method mi = class_getInstanceMethod(central, @selector(initWithDelegate:queue:));
        if (mi) {
            g_origCMInit = (id (*)(id, SEL, id, id))method_getImplementation(mi);
            method_setImplementation(mi, (IMP)BLCentralInit);
        }
    }
}

void AxsBLELoggerStart(void) {
    @autoreleasepool {
        // 只对第三方 App 生效：系统进程（SpringBoard / backboardd / daemon）一律退出，
        // 否则每个进程都会装一遍 hook，日志也会互相踩。
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid || [bid length] == 0) return;
        if ([bid hasPrefix:@"com.apple."]) return;

        // 设置面板的白名单。Filter 保持全注入（Settings 写不进 /var/jb），
        // 在这里做软过滤：配置缺失 = 全注入，别让插件看起来完全没反应。
        if (![[AxsBLELoggerConfig axs_blelogger_shared] axs_blelogger_shouldInjectBundle:bid]) {
            return;
        }

        g_bundleId = bid;
        g_records = [NSMutableArray array];

        if (!NSClassFromString(@"CBPeripheral")) {
            dlopen("/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth", RTLD_NOW);
        }
        BLInstall();
    }
}
