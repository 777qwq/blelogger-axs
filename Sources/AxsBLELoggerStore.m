// 跨进程共享数据：SpringBoard / 目标 App 写，设置面板读。
//
// 配置文件与抓包数据分开，是因为写频率差三个数量级：
// 配置一天改几次，帧一秒可能来十几条。混在一个 plist 里会让面板
// 每次刷新都重读一遍配置，也让高频写盘放大。
//
// 写盘全部走原子写（writeToFile:atomically:），Settings 读到的
// 要么是旧版要么是新版，不会是半截文件。
//
// 路径本身见 AxsBLELoggerPaths.h —— 从 Preferences 搬到 Caches 的原因
// 在那里写了，核心是 cfprefsd 会盖掉直接写入的字节。

#import "AxsBLELoggerStore.h"
#import "AxsBLELoggerPaths.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>

#define kConfigPath AXSPath(@"config.plist")
#define kDataPath   AXSPath(@"capture.plist")
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
        // 1.4.x 的旧文件在 Preferences 里，第一次跑新版时搬到新目录。
        // 只在目标文件不存在时搬，不会覆盖已经抓到的新数据。
        AXSMigrateLegacyFiles();
    });
}

NSString *AxsBLELoggerConfigPath(void) {
    // /var/mobile 在 rootful / rootless / roothide 三种环境里都是数据卷真实路径，
    // 不做 jbroot 前缀转换：转换的是越狱资源，不是用户偏好。
    return kConfigPath;
}

NSDictionary *AxsBLELoggerReadConfig(void) {
    axs_store_init();
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    if ([d isKindOfClass:[NSDictionary class]] && d.count) return d;
    return @{};
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

#pragma mark - 注入式抓包（独立文件）

#define kAppDataPath AXSPath(@"app.plist")

// 注入的代码跑在第三方 App 的沙盒里，能写哪里由 AXSDataDir 在运行时探测：
// Caches → /var/tmp → 自己容器的 Documents。1.4.1 只探测两处而且写死
// 文件名，结果是「文件写成功了，面板读不到」—— 因为面板不知道它退到了
// 哪个 App 的容器里。现在探测统一在 Paths.h，面板那边会扫容器兜底。
NSString *AxsBLELoggerAppDataPath(void) {
    return kAppDataPath;
}

static NSMutableDictionary *axs_app_read_data(void);

// 诊断：哪些 App 被注入过。面板读这个列表就知道 hook 到底有没有进目标进程。
void AxsBLELoggerNoteInjected(NSString *bid) {
    if (bid.length == 0) return;
    axs_store_init();

    @synchronized (g_lock) {
        NSMutableDictionary *data = axs_app_read_data();
        NSArray *old = data[@"injected"];
        NSMutableArray *list = [old isKindOfClass:[NSArray class]] ? [old mutableCopy] : [NSMutableArray array];

        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";

        BOOL seen = NO;
        for (NSDictionary *e in list) {
            if ([e isKindOfClass:[NSDictionary class]] && [e[@"bid"] isEqualToString:bid]) { seen = YES; break; }
        }
        if (!seen) {
            [list addObject:@{ @"bid": bid, @"t": [df stringFromDate:[NSDate date]] }];
            while (list.count > 20) [list removeObjectAtIndex:0];
        }

        data[@"injected"] = list;
        data[@"path"] = AxsBLELoggerAppDataPath();
        [data writeToFile:AxsBLELoggerAppDataPath() atomically:YES];
    }
}

static NSMutableArray *g_appFrames = nil;
static BOOL g_appLoaded = NO;
static BOOL g_appDirty = NO;
static BOOL g_appFlushing = NO;

static NSMutableDictionary *axs_app_read_data(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:AxsBLELoggerAppDataPath()];
    return [d isKindOfClass:[NSDictionary class]] ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

static void axs_app_load_locked(void) {
    if (g_appLoaded) return;
    NSArray *frames = axs_app_read_data()[@"frames"];
    g_appFrames = [frames isKindOfClass:[NSArray class]] ? [frames mutableCopy] : [NSMutableArray array];
    g_appLoaded = YES;
}

static void axs_app_schedule_flush(void) {
    @synchronized (g_lock) {
        if (g_appFlushing) return;
        g_appFlushing = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *copy = nil;
        @synchronized (g_lock) {
            g_appFlushing = NO;
            if (!g_appDirty) return;
            g_appDirty = NO;
            copy = [g_appFrames copy];
        }
        // 多个 App 进程同时抓包时，各自内存里都有一份历史。直接整份覆盖
        // 会把别的进程刚写的帧抹掉，所以写之前先并上盘上已有的，按内容去重。
        NSMutableDictionary *data = axs_app_read_data();
        NSArray *disk = data[@"frames"];
        NSMutableArray *merged = [NSMutableArray array];
        // mini Foundation 里没有 NSMutableSet，拿字典当集合用
        NSMutableDictionary *seen = [NSMutableDictionary dictionary];

        for (NSArray *list in @[([disk isKindOfClass:[NSArray class]] ? disk : @[]), (copy ?: @[])]) {
            for (NSDictionary *f in list) {
                if (![f isKindOfClass:[NSDictionary class]]) continue;
                NSString *key = [NSString stringWithFormat:@"%@|%@|%@|%@|%@",
                                 f[@"t"] ?: @"", f[@"dir"] ?: @"",
                                 f[@"chr"] ?: @"", f[@"hex"] ?: @"", f[@"src"] ?: @""];
                if (seen[key]) continue;
                seen[key] = @YES;
                [merged addObject:f];
            }
        }

        [merged sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
            return [(x[@"t"] ?: @"") compare:(y[@"t"] ?: @"")];
        }];
        while (merged.count > kMaxFrames) [merged removeObjectAtIndex:0];

        data[@"frames"] = merged;
        [data writeToFile:AxsBLELoggerAppDataPath() atomically:YES];
    });
}

void AxsBLELoggerAppendAppFrame(NSString *dir, NSString *svc, NSString *chr, NSString *hex) {
    axs_store_init();
    @synchronized (g_lock) {
        axs_app_load_locked();

        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";

        [g_appFrames addObject:@{
            @"t":   [df stringFromDate:[NSDate date]],
            @"dir": dir ?: @"?",
            @"svc": svc ?: @"?",
            @"chr": chr ?: @"?",
            @"hex": hex ?: @"",
            @"src": @"app",
        }];
        while (g_appFrames.count > kMaxFrames) [g_appFrames removeObjectAtIndex:0];
        g_appDirty = YES;
    }
    axs_app_schedule_flush();
}

NSArray *AxsBLELoggerReadAppFrames(void) {
    axs_store_init();
    @synchronized (g_lock) {
        axs_app_load_locked();
        return [g_appFrames copy];
    }
}

void AxsBLELoggerClearAppFrames(void) {
    axs_store_init();
    @synchronized (g_lock) {
        g_appFrames = [NSMutableArray array];
        g_appLoaded = YES;
        g_appDirty = YES;
    }
    axs_app_schedule_flush();
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
