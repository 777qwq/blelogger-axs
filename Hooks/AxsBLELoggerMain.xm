#import <UIKit/UIKit.h>
#import "AxsBLELoggerPrivate.h"

// 本插件不 hook 固定类，入口是一个构造函数：
// AxsBLELoggerStart() 内部判断 bundle、读面板白名单，再装 CoreBluetooth 的 hook。
%ctor {
    @autoreleasepool {
        AxsBLELoggerStart();
    }
}
