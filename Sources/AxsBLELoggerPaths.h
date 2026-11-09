#pragma once

#import <Foundation/Foundation.h>

static inline NSString *axs_blelogger_preferencesPath(void) {
    // /var/mobile 是数据卷上的真实路径，Rootful / Rootless / Roothide 三种环境都一样。
    // 这里不做 jbroot()/ROOT_PATH_NS 转换：转换的是越狱前缀下的安装资源，不是用户偏好。
    return @"/var/mobile/Library/Preferences/com.qwq.blelogger.plist";
}
