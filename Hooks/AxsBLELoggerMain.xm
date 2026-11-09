#import <UIKit/UIKit.h>
#import "AxsBLELoggerScanner.h"

// 一个 dylib，两个分支，按宿主进程分流：
//
//   SpringBoard  → 直连模式：插件自己当 Central，抓设备推上来的帧
//   第三方 App    → 注入模式：hook CoreBluetooth，抓 App 发出去的帧
//
// 必须全注入（Filter 留空），因为注入哪个 App 是用户运行时选的，
// 没法在安装包里的 Filter 里静态写死。真正的开关在 AxsBLELoggerHookStart
// 里读白名单，没勾的 App 加载完立即 return。
void AxsBLELoggerHookStart(void);

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if ([bid isEqualToString:@"com.apple.springboard"]) {
            AxsBLELoggerScannerStart();
        } else {
            AxsBLELoggerHookStart();
        }
    }
}
