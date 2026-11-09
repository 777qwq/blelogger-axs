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

// 注入式抓包的数据单独存一份。
// 两个进程（SpringBoard 和被抓的 App）各持一份内存副本，写同一个 plist
// 必然互相覆盖，所以物理上分开，面板读的时候合并。
NSArray *AxsBLELoggerReadAppFrames(void);
void AxsBLELoggerAppendAppFrame(NSString *dir, NSString *svc, NSString *chr, NSString *hex);
void AxsBLELoggerClearAppFrames(void);

// 附近设备: [{ name, uuid, rssi }]  最多 20 条
NSArray *AxsBLELoggerReadDevices(void);
void AxsBLELoggerSetDevices(NSArray *devices);

// 运行状态一句话
NSString *AxsBLELoggerReadState(void);
void AxsBLELoggerSetState(NSString *state);

// 工具
NSString *AxsBLELoggerHex(NSData *data);
NSString *AxsBLELoggerUUIDString(CBUUID *uuid);
