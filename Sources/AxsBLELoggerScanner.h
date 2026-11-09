#pragma once

#import <Foundation/Foundation.h>

// 只在 SpringBoard 里调用。插件自己当 Central，扫描 → 连接 → 订阅 Notify，
// 把设备推上来的帧记进 capture.plist。
//
// 这条路的定位变了：1.4.0 把它删掉是因为「抓不到 App 发出去的帧」，
// 但现在的情况是注入压根进不去目标 App —— 抓不到 100% 和抓一半之间，
// 后者明显更有用。两条路同时开，谁有数据算谁的。
void AxsBLELoggerScannerStart(void);
