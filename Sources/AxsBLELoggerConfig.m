#import "AxsBLELoggerConfig.h"
#import "AxsBLELoggerPreferences.h"
#import <dispatch/dispatch.h>

@interface AxsBLELoggerConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, assign) dispatch_queue_t reloadQueue;
@end

static void axs_blelogger_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsBLELoggerConfig *config = (__bridge AxsBLELoggerConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_blelogger_reload];
    });
}

@implementation AxsBLELoggerConfig

+ (instancetype)axs_blelogger_shared {
    static AxsBLELoggerConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.qwq.blelogger.preferences", DISPATCH_QUEUE_SERIAL);
        [self axs_blelogger_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_blelogger_preferencesDidChange,
            (__bridge CFStringRef)AxsBLELoggerPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_blelogger_reload]; });
    }
    return self;
}

- (void)axs_blelogger_reload {
    self.snapshot = axs_blelogger_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AxsBLELoggerPreferencesChanged object:self];
    });
}

- (id)axs_blelogger_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)axs_blelogger_isEnabled {
    id value = [self axs_blelogger_valueForKey:@"enabled" defaultValue:@(YES)];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

// 白名单：selected 为空 = 全部注入；非空 = 只注入列表内的。
- (BOOL)axs_blelogger_shouldInjectBundle:(NSString *)bundleId {
    if (![self axs_blelogger_isEnabled]) return NO;
    id selected = [self axs_blelogger_valueForKey:@"selected" defaultValue:nil];
    if (![selected isKindOfClass:[NSArray class]] || [selected count] == 0) return YES;
    return [selected containsObject:bundleId];
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
