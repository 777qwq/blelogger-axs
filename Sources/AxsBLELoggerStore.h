#pragma once

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>

// 配置（面板写、SpringBoard 读）
NSString *AxsBLELoggerConfigPath(void);
NSDictionary *AxsBLELoggerReadConfig(void);
BOOL AxsBLELoggerWriteConfigKey(NSString *key, id value);

// 抓包数据（SpringBoard 写、面板读）
// frames: [{ t, dir, svc, chr, hex }]  最多 300 条，先进先出
NSArray *AxsBLELoggerReadFrames(void);
void AxsBLELoggerLoadFrames(void);
void AxsBLELoggerAppendFrame(NSString *dir, NSString *svc, NSString *chr, NSString *hex);
void AxsBLELoggerClearFrames(void);

// 附近设备: [{ name, uuid, rssi }]  最多 20 条
NSArray *AxsBLELoggerReadDevices(void);
void AxsBLELoggerSetDevices(NSArray *devices);

// 运行状态一句话
NSString *AxsBLELoggerReadState(void);
void AxsBLELoggerSetState(NSString *state);

// 工具
NSString *AxsBLELoggerHex(NSData *data);
NSString *AxsBLELoggerUUIDString(CBUUID *uuid);
