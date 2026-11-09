#pragma once
#include <Foundation/Foundation.h>

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

@interface CBUUID : NSObject
@property (readonly) NSString *UUIDString;
+ (instancetype)UUIDWithString:(NSString *)s;
@end

@class CBPeripheral, CBService, CBCharacteristic;

@interface CBCharacteristic : NSObject
@property (readonly) CBUUID *UUID;
@property (readonly) CBService *service;
@property (readonly) CBCharacteristicProperties properties;
@property (readonly) NSData *value;
@end

@interface CBService : NSObject
@property (readonly) CBUUID *UUID;
@property (readonly) NSArray *characteristics;
@property (readonly) CBPeripheral *peripheral;
@end

@interface CBPeripheral : NSObject
@property (readonly) NSString *name;
@property (readonly) NSUUID *identifier;
@property (readonly) NSArray *services;
- (void)writeValue:(NSData *)data forCharacteristic:(CBCharacteristic *)c type:(CBCharacteristicWriteType)t;
- (void)setNotifyValue:(BOOL)e forCharacteristic:(CBCharacteristic *)c;
@end

@protocol CBPeripheralDelegate <NSObject>
@optional
- (void)peripheral:(CBPeripheral *)p didUpdateValueForCharacteristic:(CBCharacteristic *)c error:(id)e;
- (void)peripheral:(CBPeripheral *)p didWriteValueForCharacteristic:(CBCharacteristic *)c error:(id)e;
@end

@interface CBCentralManager : NSObject
- (instancetype)initWithDelegate:(id)d queue:(id)q;
@end
