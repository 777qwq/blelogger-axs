#pragma once

// 存储位置。这里放 static inline，是因为设置面板（PreferenceBundle）和
// tweak 是两个独立的二进制，没有共用的 .m 可以链接。头文件里给实现，
// 两边 include 就都有一份，不产生跨二进制的符号依赖。
//
// 为什么从 /var/mobile/Library/Preferences 搬走：
//
// 1. 那个目录归 cfprefsd 管。我们用 writeToFile:atomically: 直接写字节，
//    cfprefsd 内存里还留着旧的一份，随时可能把我们的写入盖回去。表现就是
//    「开关明明打开了，读出来还是关的」「设置改完一会儿自己变回去」。
// 2. 权限是 mobile:mobile 755，注入到第三方 App 里的代码（跑在沙盒里）
//    写不进去，1.4.1 的「数据文件读不到」就是这个问题。
//
// 换到 Caches：cfprefsd 不管这里，postinst 把目录建成 777，
// SpringBoard、Preferences、注入进程三方都能写。

#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>

// 编译带 -nostdinc，getenv 要自己声明
extern char *getenv(const char *name);

#define AXS_DIR_MAIN   @"/var/mobile/Library/Caches/com.qwq.blelogger"
#define AXS_DIR_TMP    @"/var/tmp/com.qwq.blelogger"
#define AXS_DIR_LEGACY @"/var/mobile/Library/Preferences"

// 探针：往目录里写一个字节再删掉，确认这个位置真的能落盘。
//
// 不在这里 mkdir：编译带 -nostdinc，拿不到 sys/stat.h，mini Foundation
// 也没有 createDirectoryAtPath: 这一族。目录统一由 deb 的 postinst 建
// （Caches 和 /var/tmp 各一个，权限 0777），这里只负责判断能不能写。
static inline BOOL AXSMakeWritable(NSString *dir) {
    if (dir.length == 0) return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) return NO;

    NSString *probe = [dir stringByAppendingPathComponent:@".probe"];
    NSData *one = [NSData dataWithBytes:"1" length:1];
    if (![one writeToFile:probe atomically:YES]) return NO;

    [fm removeItemAtPath:probe error:NULL];
    return YES;
}

// 本进程实际使用的目录。三个候选按优先级试，第一个能写的留下。
//
// 注意：不同进程探测结果可能不同（SpringBoard 能写 Caches，沙盒里的 App
// 只能写自己容器）。读的一方不要假设只有一个位置 —— 用 AXSReadAnyFile。
static inline NSString *AXSDataDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (AXSMakeWritable(AXS_DIR_MAIN)) { dir = AXS_DIR_MAIN; return; }
        if (AXSMakeWritable(AXS_DIR_TMP))  { dir = AXS_DIR_TMP;  return; }

        const char *home = getenv("HOME");
        if (home) {
            NSString *docs = [[NSString stringWithUTF8String:home]
                              stringByAppendingPathComponent:@"Documents"];
            if (AXSMakeWritable(docs)) { dir = docs; return; }
        }
        // 全都不行就返回兜底路径，让后面的写失败暴露在状态里，
        // 而不是悄悄写到某个谁也读不到的地方
        dir = AXS_DIR_TMP;
    });
    return dir;
}

static inline NSString *AXSPath(NSString *name) {
    return [AXSDataDir() stringByAppendingPathComponent:name];
}

// 读文件时按「本进程目录 → Caches → /var/tmp → 旧版 Preferences 目录」依次找。
// 写的一方在 A、读的一方在 B 时，靠这个把数据捞回来。
static inline NSDictionary *AXSReadAnyFile(NSString *name, NSString **foundPath) {
    NSMutableArray *dirs = [NSMutableArray array];
    [dirs addObject:AXSDataDir()];
    for (NSString *d in @[AXS_DIR_MAIN, AXS_DIR_TMP, AXS_DIR_LEGACY]) {
        if (![dirs containsObject:d]) [dirs addObject:d];
    }

    for (NSString *d in dirs) {
        NSString *p = [d stringByAppendingPathComponent:name];
        NSDictionary *v = [NSDictionary dictionaryWithContentsOfFile:p];
        if ([v isKindOfClass:[NSDictionary class]] && v.count) {
            if (foundPath) *foundPath = p;
            return v;
        }
    }
    if (foundPath) *foundPath = nil;
    return @{};
}

// 1.4.x 的旧文件名叫 com.qwq.blelogger.xxx，第一次跑到新版时搬过来。
// 只在配置目标位置还没有文件时搬，不覆盖新数据。
static inline void AXSMigrateLegacyFiles(void) {
    NSArray *pairs = @[
        @[@"com.qwq.blelogger.plist",           @"config.plist"],
        @[@"com.qwq.blelogger.capture.plist",   @"capture.plist"],
        @[@"com.qwq.blelogger.app.plist",       @"app.plist"],
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = AXSDataDir();

    for (NSArray *p in pairs) {
        NSString *dst = [dir stringByAppendingPathComponent:p[1]];
        if ([fm fileExistsAtPath:dst]) continue;

        NSString *src = [AXS_DIR_LEGACY stringByAppendingPathComponent:p[0]];
        if (![fm fileExistsAtPath:src]) continue;

        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:src];
        if ([d isKindOfClass:[NSDictionary class]] && d.count) {
            [d writeToFile:dst atomically:YES];
        }
    }
}

// 给面板显示用：当前读写的是哪个目录
static inline NSString *AXSDataDirDescription(void) {
    NSString *d = AXSDataDir();
    if ([d isEqualToString:AXS_DIR_MAIN])   return @"Caches";
    if ([d isEqualToString:AXS_DIR_TMP])    return @"/var/tmp";
    return @"App 容器 Documents";
}
