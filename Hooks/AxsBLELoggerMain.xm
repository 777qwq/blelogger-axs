#import <Foundation/Foundation.h>

// 两条路同时开：
//
// 1. SpringBoard 里 → 直连扫描。插件自己当 Central 连设备、订阅 Notify。
//    抓不到 App 发出去的帧，但不需要注入任何 App，设备没有配套 App 也能用。
// 2. 其他 App 里 → hook CoreBluetooth，收发双向都记。
//
// 1.4.0 只留第 2 条，理由是「扫描抓不到发送帧」。但实际装上去连注入都没成功，
// 结果是零数据。现在两条都开，面板合并显示 —— 谁先给出帧都算赢。
//
// 分工在 AxsBLELoggerHookStart 里按 bundle id 判断，不是两套配置。

void AxsBLELoggerHookStart(void);
void AxsBLELoggerScannerStart(void);

%ctor {
    @autoreleasepool {
        AxsBLELoggerHookStart();
    }
}
