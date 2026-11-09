#pragma once

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "AxsBLELoggerPaths.h"

static NSString * const AxsBLELoggerPreferencesDomain = @"com.qwq.blelogger";
static NSString * const AxsBLELoggerPreferencesChanged = @"com.qwq.blelogger.preferences-changed";

// Tweak 侧只读。面板是唯一写入方，这里不做默认值持久化。
static inline NSDictionary *axs_blelogger_readPreferences(void) {
    NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:axs_blelogger_preferencesPath()];
    return [values isKindOfClass:[NSDictionary class]] ? values : [NSMutableDictionary dictionary];
}

// 原子写入后发 Darwin 通知，已注入的进程能立刻拿到新配置。
static inline BOOL axs_blelogger_writePreference(NSString *key, id value, NSError **error) {
    if (key.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:AxsBLELoggerPreferencesDomain code:1 userInfo:nil];
        }
        return NO;
    }

    NSMutableDictionary *values = [axs_blelogger_readPreferences() mutableCopy];
    if (value) {
        [values setObject:value forKey:key];
    } else {
        [values removeObjectForKey:key];
    }

    if (![values writeToFile:axs_blelogger_preferencesPath() atomically:YES]) {
        if (error) {
            *error = [NSError errorWithDomain:AxsBLELoggerPreferencesDomain code:2 userInfo:nil];
        }
        return NO;
    }

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)AxsBLELoggerPreferencesChanged, NULL, NULL, 1);
    return YES;
}
