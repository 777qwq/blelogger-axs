// 常驻 SpringBoard 的 BLE 抓包器。
//
// 和 1.2.x 的根本区别：不注入任何 App、不做 hook。
// 插件自己就是 Central，主动扫描 → 连上目标设备 → 订阅所有 Notify 特征，
// 把设备推上来的帧记下来。所以「设备没有配套 App」也能抓。
//
// 代价是看不到官方 App 发给设备的帧 —— 那是 hook 方案才有的能力，
// 两者不能同时要，这里按「无 App 设备」优先。
//
// 稳定性上的两条硬规矩：
// 1. 配置里没有 enabled 就当作关闭。装完不会自己跑，必须去面板打开一次，
//    避免「一装就 respring 循环、连设置都进不去」。
// 2. delegate 全部挂在主队列，devices 数组只在主队列改，不跨线程碰。

#import "AxsBLELoggerScanner.h"
#import "AxsBLELoggerStore.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString *const kPrefsChanged = @"com.qwq.blelogger.preferences-changed";

static void axs_scanner_prefs_changed(CFNotificationCenterRef center, void *observer,
                                      CFStringRef name, const void *object, CFDictionaryRef info);

@interface AxsBLELoggerScanner : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) CBPeripheral *target;
@property (nonatomic, copy)   NSString *targetName;   // 广播名（可能为空）
@property (nonatomic, copy)   NSString *targetUUID;   // peripheral.identifier，最可靠
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, strong) NSMutableArray *devices;
@property (nonatomic, assign) BOOL relinking;
@end

@implementation AxsBLELoggerScanner

+ (instancetype)shared {
    static AxsBLELoggerScanner *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[AxsBLELoggerScanner alloc] init]; });
    return s;
}

#pragma mark - 生命周期

- (void)start {
    AxsBLELoggerLoadFrames();
    NSArray *saved = AxsBLELoggerReadDevices();
    self.devices = [saved isKindOfClass:[NSArray class]] ? [saved mutableCopy] : [NSMutableArray array];

    [self reloadConfig];

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self,
        axs_scanner_prefs_changed,
        (__bridge CFStringRef)kPrefsChanged, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    // 关着就先不碰 CoreBluetooth，省电也少一个崩溃面。
    if (!self.enabled) {
        AxsBLELoggerSetState(@"未启用（在设置里打开）");
        return;
    }
    [self createCentralIfNeeded];
}

- (void)createCentralIfNeeded {
    if (self.central) return;
    self.central = [[CBCentralManager alloc]
        initWithDelegate:self
                   queue:dispatch_get_main_queue()
                 options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
}

static void axs_scanner_prefs_changed(CFNotificationCenterRef center, void *observer,
                                      CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsBLELoggerScanner *scanner = (__bridge AxsBLELoggerScanner *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [scanner reloadConfig];
        [scanner applyConfigChange];
    });
}

- (void)reloadConfig {
    NSDictionary *c = AxsBLELoggerReadConfig();

    // 没写过配置 = 关闭。宁可多一步「去设置里打开」，也不要装完就崩。
    id e = c[@"enabled"];
    self.enabled = [e isKindOfClass:[NSNumber class]] ? [e boolValue] : NO;

    id name = c[@"deviceName"];
    self.targetName = [name isKindOfClass:[NSString class]] ? name : @"";

    id uuid = c[@"targetUUID"];
    self.targetUUID = [uuid isKindOfClass:[NSString class]] ? uuid : @"";
}

- (void)applyConfigChange {
    if (!self.enabled) {
        [self stopEverything];
        AxsBLELoggerSetState(@"已关闭");
        return;
    }

    [self createCentralIfNeeded];

    // 目标变了：断开旧的，重新找
    if (self.target) {
        NSString *uuid = self.target.identifier.UUIDString;
        BOOL sameUUID = self.targetUUID.length == 0 ||
                        [self.targetUUID caseInsensitiveCompare:uuid] == NSOrderedSame;
        BOOL sameName = self.targetName.length == 0 ||
                        [(self.target.name ?: @"") isEqualToString:self.targetName];
        if (!(sameUUID && sameName)) {
            [self.central cancelPeripheralConnection:self.target];
            self.target = nil;
        }
    }

    if (self.central.state != CBManagerStatePoweredOn) return;
    if (!self.target) [self beginScan];
}

- (void)stopEverything {
    if (self.target) {
        [self.central cancelPeripheralConnection:self.target];
        self.target = nil;
    }
    if (self.central.isScanning) [self.central stopScan];
}

#pragma mark - 扫描

- (void)beginScan {
    if (!self.central) return;
    if (self.central.state != CBManagerStatePoweredOn) return;
    if (self.central.isScanning) return;

    NSString *want = self.targetName.length ? self.targetName : self.targetUUID;
    AxsBLELoggerSetState(want.length
        ? [NSString stringWithFormat:@"扫描中…（目标 %@）", want]
        : @"扫描中…（未选设备，只列表）");

    [self.central scanForPeripheralsWithServices:nil
                                          options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    switch (central.state) {
        case CBManagerStatePoweredOn:
            [self beginScan];
            break;
        case CBManagerStatePoweredOff:
            AxsBLELoggerSetState(@"蓝牙未开启");
            break;
        case CBManagerStateUnauthorized:
            AxsBLELoggerSetState(@"蓝牙权限被拒");
            break;
        case CBManagerStateUnsupported:
            AxsBLELoggerSetState(@"此设备不支持 BLE");
            break;
        default:
            break;
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary *)advertisementData
                  RSSI:(NSNumber *)RSSI {

    NSString *name = peripheral.name;
    if (name.length == 0) name = advertisementData[CBAdvertisementDataLocalNameKey];
    if (name.length == 0) name = @"";

    NSString *uuid = peripheral.identifier.UUIDString;
    if (uuid.length == 0) return;

    // 没名字的设备也留下：有些设备只在连上之后才报名字，
    // 而且用户可能就是靠 UUID 认它。
    NSDictionary *row = @{ @"name": name,
                           @"uuid": uuid,
                           @"rssi": RSSI ?: @0 };

    NSUInteger existing = NSNotFound;
    for (NSUInteger i = 0; i < self.devices.count; i++) {
        id u = self.devices[i][@"uuid"];
        if ([u isKindOfClass:[NSString class]] && [u isEqualToString:uuid]) { existing = i; break; }
    }

    if (existing != NSNotFound) {
        [self.devices removeObjectAtIndex:existing];
        [self.devices insertObject:row atIndex:0];
    } else {
        [self.devices insertObject:row atIndex:0];
        while (self.devices.count > 20) [self.devices removeLastObject];
        AxsBLELoggerSetDevices(self.devices);
    }

    if (!self.enabled || self.target || self.relinking) return;
    if (self.targetUUID.length == 0 && self.targetName.length == 0) return;

    BOOL match = NO;
    if (self.targetUUID.length > 0) {
        match = [self.targetUUID caseInsensitiveCompare:uuid] == NSOrderedSame;
    }
    if (!match && self.targetName.length > 0 && name.length > 0) {
        if ([name isEqualToString:self.targetName]) {
            match = YES;
        } else if (self.targetName.length >= 3 &&
                   [name localizedCaseInsensitiveContainsString:self.targetName]) {
            match = YES;   // 允许「iKF」匹配「iKF-Air Clip-APP」
        }
    }

    if (!match) return;

    self.target = peripheral;
    [central stopScan];
    AxsBLELoggerSetState([NSString stringWithFormat:@"连接中… %@", name.length ? name : uuid]);
    [central connectPeripheral:peripheral options:nil];
}

#pragma mark - 连接

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    peripheral.delegate = self;
    NSString *name = peripheral.name;
    if (name.length == 0) name = self.targetName;
    if (name.length == 0) name = peripheral.identifier.UUIDString;
    AxsBLELoggerSetState([NSString stringWithFormat:@"已连接 %@，发现服务…", name]);
    [peripheral discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    self.target = nil;
    AxsBLELoggerSetState(@"连接失败，5 秒后重试");
    [self scheduleRelink:5.0];
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    self.target = nil;
    if (!self.enabled) {
        AxsBLELoggerSetState(@"已关闭");
        return;
    }
    AxsBLELoggerSetState(@"已断开，3 秒后重连");
    [self scheduleRelink:3.0];
}

- (void)scheduleRelink:(NSTimeInterval)delay {
    if (self.relinking) return;
    self.relinking = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.relinking = NO;
        if (self.enabled && !self.target) [self beginScan];
    });
}

#pragma mark - 服务 / 特征

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error || peripheral.services.count == 0) {
        AxsBLELoggerSetState(@"未发现服务，可能需要重新连接");
        return;
    }
    for (CBService *service in peripheral.services) {
        [peripheral discoverCharacteristics:nil forService:service];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    if (error) return;

    NSUInteger subscribed = 0;
    for (CBCharacteristic *ch in service.characteristics) {
        CBCharacteristicProperties p = ch.properties;
        if (p & (CBCharacteristicPropertyNotify | CBCharacteristicPropertyIndicate)) {
            if (!ch.isNotifying) [peripheral setNotifyValue:YES forCharacteristic:ch];
            subscribed++;
        }
    }

    if (subscribed > 0) {
        NSString *name = peripheral.name ?: self.targetName;
        if (name.length == 0) name = peripheral.identifier.UUIDString;
        AxsBLELoggerSetState([NSString stringWithFormat:@"已连接 %@，订阅 %lu 个特征",
                              name, (unsigned long)subscribed]);
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) return;
    NSData *value = characteristic.value;
    if (value.length == 0) return;

    AxsBLELoggerAppendFrame(@"收",
                            AxsBLELoggerUUIDString(characteristic.service.UUID),
                            AxsBLELoggerUUIDString(characteristic.UUID),
                            AxsBLELoggerHex(value));
}

// 订阅本身也可能失败，记下来，否则用户只看到「一条帧都没有」。
- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (!error) return;
    NSString *name = peripheral.name ?: self.targetName;
    AxsBLELoggerSetState([NSString stringWithFormat:@"订阅 %@ 失败：%@",
        AxsBLELoggerUUIDString(characteristic.UUID),
        error.localizedDescription ?: @"未知错误"]);
    (void)name;
}

@end

#pragma mark - 入口

void AxsBLELoggerScannerStart(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        // 只认 SpringBoard。Filter 已经限死了，这层是防 Filter 被改回全注入。
        if (![bid isEqualToString:@"com.apple.springboard"]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            [[AxsBLELoggerScanner shared] start];
        });
    }
}
