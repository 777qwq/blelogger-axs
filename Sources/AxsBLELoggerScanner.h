#pragma once

#import <Foundation/Foundation.h>

// 由 Hooks/AxsBLELoggerMain.xm 的 %ctor 调用，只在 SpringBoard 里生效。
void AxsBLELoggerScannerStart(void);
