#pragma once

#import <UIKit/UIKit.h>

// 抓包入口：由 Hooks/AxsBLELoggerMain.xm 的 %ctor 调用。
// 内部会先判 bundle 与面板白名单，不合格直接返回。
void AxsBLELoggerStart(void);
