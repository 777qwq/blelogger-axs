#import <UIKit/UIKit.h>
#import "AxsBLELoggerScanner.h"

// 不再 hook 任何类。入口只做一件事：在 SpringBoard 里把 BLE 扫描器拉起来。
// 注入范围由 layout/.../AxsBLELogger.plist 的 Filter 限定为 com.apple.springboard。
%ctor {
    @autoreleasepool {
        AxsBLELoggerScannerStart();
    }
}
