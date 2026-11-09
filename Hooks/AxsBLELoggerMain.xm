#import <Foundation/Foundation.h>

// 只走注入模式：hook 目标 App 里的 CoreBluetooth，抓它收发的每一帧，
// 帧落进共享 plist，设置面板负责显示。
//
// 不做设备直连（1.3.x 那套 SpringBoard 扫描）—— 那套只能看到设备推上来
// 的帧，看不到 App 发出去的，散热器这类"必须靠 App 发指令"的设备就抓瞎。
void AxsBLELoggerHookStart(void);

%ctor {
    @autoreleasepool {
        AxsBLELoggerHookStart();
    }
}
