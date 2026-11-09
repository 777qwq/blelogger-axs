#pragma once

#import <Foundation/Foundation.h>

@interface AxsBLELoggerConfig : NSObject
+ (instancetype)axs_blelogger_shared;
- (BOOL)axs_blelogger_isEnabled;
- (BOOL)axs_blelogger_shouldInjectBundle:(NSString *)bundleId;
- (id)axs_blelogger_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_blelogger_reload;
@end
