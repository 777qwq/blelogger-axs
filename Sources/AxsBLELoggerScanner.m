// 常驻 SpringBoard 的 BLE 抓包器。
//
// 不注入任何 App、不做 hook。插件自己就是 Central，主动扫描 → 连上目标设备
// → 订阅所有 Notify 特征，把设备推上来的帧记下来。所以「设备没有配套 App」
// 或者「App 注入失败」时也能抓到东西。
//
// 代价：看不到官方 App 发给设备的帧。那是注入方案才有的能力。
// 两条路现在同时开，面板合并显示，互为兜底。
//
// 稳定性上的两条硬规矩：
// 1. 设备列表、连接状态全部在主队列改，不跨线程碰 CoreBluetooth。
// 2. 没指定目标设备时只扫描列列表，不自动连 —— 免得一装就乱连别人的设备。

#import "AxsBLELoggerScanner.h"
#import "AxsBLELoggerStore.h"
#import "AxsBLELoggerPaths.h"
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
@property (nonatomic, assign) BOOL subscribed;
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

    if (!self.enabled) {
        AxsBLELoggerSetState(@"直连扫描：已关闭");
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

    // 和面板保持一致：没写过配置就当作开。1.4.1 之前这里是默认关，
    // 结果「装完什么都没发生」比「装完开始扫描」更让人困惑。
    id e = c[@"enabled"];
    self.enabled = [e isKindOfClass:[NSNumber class]] ? [e boolValue] : YES;

    id name = c[@"deviceName"];
    self.targetName = [name isKindOfClass:[NSString class]] ? name : @"";

    id uuid = c[@"targetUUID"];
    self.targetUUID = [uuid isKindOfClass:[NSString class]] ? uuid : @"";
}

- (void)applyConfigChange {
    if (!self.enabled) {
        [self stopEverything];
        AxsBLELoggerSetState(@"直连扫描：已关闭");
        return;
    }

    [self createCentralIfNeeded];

    if (self.target) {
        NSString *uuid = self.target.identifier.UUIDString;
        BOOL sameUUID = self.targetUUID.length == 0 ||
                        [self.targetUUID caseInsensitiveCompare:uuid] == NSOrderedSame;
        BOOL sameName = self.targetName.length == 0 ||
                        [(self.target.name ?: @"") isEqualToString:self.targetName];
        if (!(sameUUID && sameName)) {
            [self.central cancelPeripheralConnection:self.target];
            self.target = nil;
            self.subscribed = NO;
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
    self.subscribed = NO;
}

#pragma mark - 扫描

- (void)beginScan {
    if (!self.central) return;
    if (self.central.state != CBManagerStatePoweredOn) return;
    if (self.central.isScanning) return;

    NSString *want = self.targetName.length ? self.targetName : self.targetUUID;
    AxsBLELoggerSetState(want.length
        ? [NSString stringWithFormat:@"扫描中…（目标 %@）", want]
        : @"扫描中…（未选设备，只列附近设备）");

    [self.central scanForPeripheralsWithServices:nil
                                          options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    switch (central.state) {
        case CBManagerStatePoweredOn:
            [self beginScan];
            break;
        case CBManagerStatePoweredOff:
            AxsBLELoggerSetState(@"直连扫描：蓝牙未开启");
            break;
        case CBManagerStateUnauthorized:
            AxsBLELoggerSetState(@"直连扫描：蓝牙权限被拒");
            break;
        case CBManagerStateUnsupported:
            AxsBLELoggerSetState(@"直连扫描：此设备不支持 BLE");
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

    NSDictionary *row = @{ @"name": name,
                           @"uuid": uuid,
                           @"rssi": RSSI ?: @0 };

    NSUInteger existing = NSNotFound;
    for (NSUInteger i = 0; i < self.devices.count; i++) {
        id u = self.devices[i][@"uuid"];
        if ([u isKindOfClass:[NSString class]] && [u isEqualToString:uuid]) { existing = i; break; }
    }

    BOOL changed = NO;
    if (existing != NSNotFound) {
        // 名字后到的情况很常见，更新一下
        NSString *oldName = self.devices[existing][@"name"];
        if (![oldName isEqualToString:name]) {
            [self.devices removeObjectAtIndex:existing];
            [self.devices insertObject:row atIndex:0];
            changed = YES;
        }
    } else {
        [self.devices insertObject:row atIndex:0];
        while (self.devices.count > 20) [self.devices removeLastObject];
        changed = YES;
    }
    if (changed) AxsBLELoggerSetDevices(self.devices);

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
            match = YES;
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
    self.subscribed = NO;
    if (!self.enabled) {
        AxsBLELoggerSetState(@"直连扫描：已关闭");
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

    NSUInteger total = 0, subscribed = 0;
    for (CBCharacteristic *ch in service.characteristics) {
        CBCharacteristicProperties p = ch.properties;
        if (p & (CBCharacteristicPropertyNotify | CBCharacteristicPropertyIndicate)) {
            total++;
            if (!ch.isNotifying) { [peripheral setNotifyValue:YES forCharacteristic:ch]; subscribed++; }
        }
    }

    if (total > 0) {
        self.subscribed = YES;
        NSString *name = peripheral.name ?: self.targetName;
        if (name.length == 0) name = peripheral.identifier.UUIDString;
        AxsBLELoggerSetState([NSString stringWithFormat:@"已连接 %@，订阅 %lu 个特征",
                              name, (unsigned long)total]);
        (void)subscribed;
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (error) return;
    NSData *value = characteristic.value;
    if (value.length == 0) return;

    // 只记 Notify / Indicate 的；读一次就完的值也会走这个回调，
    // 但那些是 App 主动读的，属于注入方案的范围。
    AxsBLELoggerAppendFrame(@"收",
                            AxsBLELoggerUUIDString(characteristic.service.UUID),
                            AxsBLELoggerUUIDString(characteristic.UUID),
                            AxsBLELoggerHex(value));
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (!error) return;
    AxsBLELoggerSetState([NSString stringWithFormat:@"订阅 %@ 失败：%@",
        AxsBLELoggerUUIDString(characteristic.UUID),
        error.localizedDescription ?: @"未知错误"]);
}

@end

#pragma mark - 入口

void AxsBLELoggerScannerStart(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        // 只认 SpringBoard。Filter 那层已经限死了，这里再挡一次。
        if (![bid isEqualToString:@"com.apple.springboard"]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            [[AxsBLELoggerScanner shared] start];
        });
    }
}
