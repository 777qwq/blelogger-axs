#pragma once
#include <Foundation/Foundation.h>

// 只覆盖本工程用到的 CoreBluetooth 表面，Linux 本地编译用。
// 真机构建走 Xcode SDK 的系统头文件。

typedef NSInteger CBCharacteristicWriteType;
enum {
    CBCharacteristicWriteWithResponse    = 0,
    CBCharacteristicWriteWithoutResponse = 1,
};

typedef NSUInteger CBCharacteristicProperties;
enum {
    CBCharacteristicPropertyBroadcast            = 0x01,
    CBCharacteristicPropertyRead                 = 0x02,
    CBCharacteristicPropertyWriteWithoutResponse = 0x04,
    CBCharacteristicPropertyWrite                = 0x08,
    CBCharacteristicPropertyNotify               = 0x10,
    CBCharacteristicPropertyIndicate             = 0x20,
};

typedef NSInteger CBManagerState;
enum {
    CBManagerStateUnknown      = 0,
    CBManagerStateResetting    = 1,
    CBManagerStateUnsupported  = 2,
    CBManagerStateUnauthorized = 3,
    CBManagerStatePoweredOff   = 4,
    CBManagerStatePoweredOn    = 5,
};

extern NSString *const CBCentralManagerOptionShowPowerAlertKey;
extern NSString *const CBCentralManagerScanOptionAllowDuplicatesKey;
extern NSString *const CBAdvertisementDataLocalNameKey;

@class CBPeripheral, CBService, CBCharacteristic;

@interface CBUUID : NSObject
@property (readonly) NSString *UUIDString;
+ (instancetype)UUIDWithString:(NSString *)s;
@end

@interface CBCharacteristic : NSObject
@property (readonly) CBUUID *UUID;
@property (readonly) CBService *service;
@property (readonly) CBCharacteristicProperties properties;
@property (readonly) NSData *value;
@property (readonly) BOOL isNotifying;
@end

@interface CBService : NSObject
@property (readonly) CBUUID *UUID;
@property (readonly) NSArray *characteristics;
@property (readonly) CBPeripheral *peripheral;
@end

@protocol CBPeripheralDelegate;

@interface CBPeripheral : NSObject
@property (readonly) NSString *name;
@property (readonly) NSUUID *identifier;
@property (readonly) NSArray *services;
@property (readonly) CBManagerState state;
@property (nonatomic, strong) id<CBPeripheralDelegate> delegate;
- (void)discoverServices:(NSArray *)services;
- (void)discoverCharacteristics:(NSArray *)chars forService:(CBService *)service;
- (void)writeValue:(NSData *)data forCharacteristic:(CBCharacteristic *)c type:(CBCharacteristicWriteType)t;
- (void)setNotifyValue:(BOOL)e forCharacteristic:(CBCharacteristic *)c;
@end

@protocol CBPeripheralDelegate <NSObject>
@optional
- (void)peripheral:(CBPeripheral *)p didDiscoverServices:(id)e;
- (void)peripheral:(CBPeripheral *)p didDiscoverCharacteristicsForService:(CBService *)s error:(id)e;
- (void)peripheral:(CBPeripheral *)p didUpdateValueForCharacteristic:(CBCharacteristic *)c error:(id)e;
- (void)peripheral:(CBPeripheral *)p didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)c error:(id)e;
- (void)peripheral:(CBPeripheral *)p didWriteValueForCharacteristic:(CBCharacteristic *)c error:(id)e;
@end

@protocol CBCentralManagerDelegate;

@interface CBCentralManager : NSObject
- (instancetype)initWithDelegate:(id<CBCentralManagerDelegate>)d
                           queue:(dispatch_queue_t)q
                         options:(NSDictionary *)options;
@property (readonly) CBManagerState state;
@property (readonly) BOOL isScanning;
- (void)scanForPeripheralsWithServices:(NSArray *)services options:(NSDictionary *)options;
- (void)stopScan;
- (void)connectPeripheral:(CBPeripheral *)p options:(NSDictionary *)options;
- (void)cancelPeripheralConnection:(CBPeripheral *)p;
@end

@protocol CBCentralManagerDelegate <NSObject>
@optional
- (void)centralManagerDidUpdateState:(CBCentralManager *)c;
- (void)centralManager:(CBCentralManager *)c
 didDiscoverPeripheral:(CBPeripheral *)p
     advertisementData:(NSDictionary *)d
                  RSSI:(NSNumber *)r;
- (void)centralManager:(CBCentralManager *)c didConnectPeripheral:(CBPeripheral *)p;
- (void)centralManager:(CBCentralManager *)c didFailToConnectPeripheral:(CBPeripheral *)p error:(id)e;
- (void)centralManager:(CBCentralManager *)c didDisconnectPeripheral:(CBPeripheral *)p error:(id)e;
@end
