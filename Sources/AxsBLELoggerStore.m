// 跨进程共享数据：SpringBoard 写，设置面板读。
//
// 配置文件与抓包数据分开，是因为写频率差三个数量级：
// 配置一天改几次，帧一秒可能来十几条。混在一个 plist 里会让面板
// 每次刷新都重读一遍配置，也让 SpringBoard 的高频写盘放大。
//
// 写盘全部走原子写（writeToFile:atomically:），Settings 读到的
// 要么是旧版要么是新版，不会是半截文件。

#import "AxsBLELoggerStore.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>

static NSString *const kConfigPath = @"/var/mobile/Library/Preferences/com.qwq.blelogger.plist";
static NSString *const kDataPath   = @"/var/mobile/Library/Preferences/com.qwq.blelogger.capture.plist";
static const NSUInteger kMaxFrames   = 300;
static const NSUInteger kMaxDevices  = 20;

static NSMutableArray *g_frames  = nil;
static BOOL            g_loaded   = NO;
static BOOL            g_dirty    = NO;
static BOOL            g_flushing = NO;
static NSLock         *g_lock     = nil;

static void axs_store_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_lock = [[NSLock alloc] init];
    });
}

NSString *AxsBLELoggerConfigPath(void) {
    // /var/mobile 在 rootful / rootless / roothide 三种环境里都是数据卷真实路径，
    // 不做 jbroot 前缀转换：转换的是越狱资源，不是用户偏好。
    return kConfigPath;
}

NSDictionary *AxsBLELoggerReadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

BOOL AxsBLELoggerWriteConfigKey(NSString *key, id value) {
    if (key.length == 0) return NO;

    NSMutableDictionary *d = [AxsBLELoggerReadConfig() mutableCopy];
    if (value) {
        d[key] = value;
    } else {
        [d removeObjectForKey:key];
    }

    BOOL ok = [d writeToFile:kConfigPath atomically:YES];
    if (ok) {
        // 让已注入的 SpringBoard 立刻重新读配置
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFSTR("com.qwq.blelogger.preferences-changed"), NULL, NULL, 1);
    }
    return ok;
}

#pragma mark - 帧数据

static NSMutableDictionary *axs_store_read_data(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kDataPath];
    return [d isKindOfClass:[NSDictionary class]] ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

static void axs_store_write_data(NSDictionary *data) {
    [data writeToFile:kDataPath atomically:YES];
}

// 0.5 秒合并写一次。按键连击时一秒能来十几条，逐条落盘没必要。
static void axs_store_schedule_flush(void) {
    @synchronized (g_lock) {
        if (g_flushing) return;
        g_flushing = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *copy = nil;
        @synchronized (g_lock) {
            g_flushing = NO;
            if (!g_dirty) return;
            g_dirty = NO;
            copy = [g_frames copy];
        }
        NSMutableDictionary *data = axs_store_read_data();
        data[@"frames"] = copy ?: @[];
        axs_store_write_data(data);
    });
}

void AxsBLELoggerLoadFrames(void) {
    axs_store_init();
    @synchronized (g_lock) {
        if (g_loaded) return;
        NSDictionary *d = axs_store_read_data();
        NSArray *frames = d[@"frames"];
        g_frames = [frames isKindOfClass:[NSArray class]] ? [frames mutableCopy] : [NSMutableArray array];
        g_loaded = YES;
    }
}

NSArray *AxsBLELoggerReadFrames(void) {
    axs_store_init();
    @synchronized (g_lock) {
        if (!g_loaded) {
            NSDictionary *d = axs_store_read_data();
            NSArray *frames = d[@"frames"];
            g_frames = [frames isKindOfClass:[NSArray class]] ? [frames mutableCopy] : [NSMutableArray array];
            g_loaded = YES;
        }
        return [g_frames copy];
    }
}

void AxsBLELoggerAppendFrame(NSString *dir, NSString *svc, NSString *chr, NSString *hex) {
    axs_store_init();
    @synchronized (g_lock) {
        if (!g_loaded) {
            NSDictionary *d = axs_store_read_data();
            NSArray *frames = d[@"frames"];
            g_frames = [frames isKindOfClass:[NSArray class]] ? [frames mutableCopy] : [NSMutableArray array];
            g_loaded = YES;
        }

        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";

        [g_frames addObject:@{
            @"t":   [df stringFromDate:[NSDate date]],
            @"dir": dir ?: @"?",
            @"svc": svc ?: @"?",
            @"chr": chr ?: @"?",
            @"hex": hex ?: @"",
        }];

        while (g_frames.count > kMaxFrames) {
            [g_frames removeObjectAtIndex:0];
        }
        g_dirty = YES;
    }
    axs_store_schedule_flush();
}

void AxsBLELoggerClearFrames(void) {
    axs_store_init();
    @synchronized (g_lock) {
        g_frames = [NSMutableArray array];
        g_loaded = YES;
        g_dirty = YES;
    }
    axs_store_schedule_flush();
}

#pragma mark - 设备列表

NSArray *AxsBLELoggerReadDevices(void) {
    NSArray *d = axs_store_read_data()[@"devices"];
    return [d isKindOfClass:[NSArray class]] ? d : @[];
}

void AxsBLELoggerSetDevices(NSArray *devices) {
    NSMutableDictionary *data = axs_store_read_data();
    data[@"devices"] = devices ?: @[];
    axs_store_write_data(data);
}

#pragma mark - 状态

NSString *AxsBLELoggerReadState(void) {
    NSString *s = axs_store_read_data()[@"state"];
    return [s isKindOfClass:[NSString class]] ? s : @"未启动";
}

void AxsBLELoggerSetState(NSString *state) {
    NSMutableDictionary *data = axs_store_read_data();
    data[@"state"] = state ?: @"";
    axs_store_write_data(data);
}

#pragma mark - 工具

NSString *AxsBLELoggerHex(NSData *data) {
    if (!data || data.length == 0) return @"";
    const unsigned char *b = (const unsigned char *)data.bytes;
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < data.length; i++) {
        [s appendFormat:@"%02X", b[i]];
    }
    return s;
}

// CBUUID.UUIDString 对 16/32 位只返回短形式，补成完整 128 位便于对照
NSString *AxsBLELoggerUUIDString(CBUUID *uuid) {
    if (!uuid) return @"?";
    NSString *s = uuid.UUIDString;
    if (s.length == 4) return [NSString stringWithFormat:@"0000%@-0000-1000-8000-00805F9B34FB", s];
    if (s.length == 8) return [NSString stringWithFormat:@"%@-0000-1000-8000-00805F9B34FB", s];
    return s;
}
