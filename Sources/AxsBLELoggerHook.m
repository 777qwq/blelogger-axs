// 注入式抓包：hook CoreBluetooth，记录目标 App 收发的每一帧。
//
// 思路来自 rc-speaker-tile 的 PWProbe.x（1.1 探针）：
// 只 hook CoreBluetooth 这个通用框架，跟设备品牌无关，散热器、耳机、
// 手环都能抓。区别是 PWProbe 只把日志写到文件，这里落进设置面板。
//
// 原版只 hook 了写入。设备主动推给 App 的帧走的是 delegate 回调，
// 补上这一半才能看到耳机按键事件这类上行数据。
//
// 不用 Logos：build-macos.sh 会把 .xm 的 %ctor 用 sed 换掉，纯 runtime
// 写在这里，Linux / macOS 两套工具链编译行为一致。

#import "AxsBLELoggerStore.h"
#import "AxsBLELoggerScanner.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static void (*g_origWrite)(id, SEL, NSData *, CBCharacteristic *, CBCharacteristicWriteType) = NULL;
static void (*g_origSetDelegate)(id, SEL, id) = NULL;

// delegate 的类不固定（每个 App 自己写），原实现要按类分别存，
// 不能像只抓一个 delegate 那样用全局单指针。
// 用定长 C 数组而不是 NSDictionary：存的 IMP 是函数指针，ARC 下转 id 很别扭，
// 而且这里就几十个类，数组查一遍比字典还快。
#define AXS_MAX_DELEGATE_CLASSES 64
static Class g_cls[AXS_MAX_DELEGATE_CLASSES];
static IMP   g_imp[AXS_MAX_DELEGATE_CLASSES];
static int   g_clsCount = 0;
static BOOL  g_installed = NO;

// 总开关只控制"记不记"，不控制"装不装"。
// 关掉开关也必须把 hook 装上并上报一次，否则面板分不清
// 「没注入」和「注入了但没抓到」—— 这两种故障的处理方式完全不同。
static BOOL  g_recordEnabled = YES;

#pragma mark - 记录

static void AxsRecordWrite(NSData *data, CBCharacteristic *ch, CBCharacteristicWriteType type) {
    if (!g_recordEnabled) return;
    if (!data.length || !ch) return;
    AxsBLELoggerAppendAppFrame(
        (type == CBCharacteristicWriteWithResponse) ? @"发(应答)" : @"发",
        AxsBLELoggerUUIDString(ch.service.UUID),
        AxsBLELoggerUUIDString(ch.UUID),
        AxsBLELoggerHex(data));
}

static void AxsRecordNotify(CBCharacteristic *ch) {
    if (!g_recordEnabled) return;
    NSData *v = ch.value;
    if (!v.length) return;
    AxsBLELoggerAppendAppFrame(
        @"收",
        AxsBLELoggerUUIDString(ch.service.UUID),
        AxsBLELoggerUUIDString(ch.UUID),
        AxsBLELoggerHex(v));
}

#pragma mark - hook 实现

static void AxsHookedWrite(id self, SEL _cmd, NSData *data, CBCharacteristic *ch, CBCharacteristicWriteType type) {
    @autoreleasepool {
        AxsRecordWrite(data, ch, type);
    }
    if (g_origWrite) g_origWrite(self, _cmd, data, ch, type);
}

static void AxsHookedDidUpdate(id self, SEL _cmd, CBPeripheral *p, CBCharacteristic *ch, id err) {
    @autoreleasepool {
        if (!err) AxsRecordNotify(ch);
    }
    // 找回这个 delegate 类自己的原实现，别把 App 的回调吃掉
    Class cls = object_getClass(self);
    for (int i = 0; i < g_clsCount; i++) {
        if (g_cls[i] == cls) {
            IMP orig = g_imp[i];
            if (orig) {
                ((void (*)(id, SEL, CBPeripheral *, CBCharacteristic *, id))orig)(self, _cmd, p, ch, err);
            }
            return;
        }
    }
}

static void AxsHookDelegateClass(Class cls) {
    if (!cls) return;

    @synchronized ([CBPeripheral class]) {
        for (int i = 0; i < g_clsCount; i++) {
            if (g_cls[i] == cls) return;   // 这个类已经换过了
        }

        Method m = class_getInstanceMethod(cls, @selector(peripheral:didUpdateValueForCharacteristic:error:));
        if (!m) return;   // 这个类没实现，可能走消息转发，抓不到就算了

        IMP orig = method_getImplementation(m);
        method_setImplementation(m, (IMP)AxsHookedDidUpdate);

        if (g_clsCount < AXS_MAX_DELEGATE_CLASSES) {
            g_cls[g_clsCount] = cls;
            g_imp[g_clsCount] = orig;
            g_clsCount++;
        }
    }
}

// App 拿到 CBPeripheral 后第一件事就是 setDelegate:。在这里把 delegate
// 身上的 didUpdateValue 换掉，才能看到设备主动推给 App 的帧。
static void AxsHookedSetDelegate(id self, SEL _cmd, id delegate) {
    if (delegate) AxsHookDelegateClass(object_getClass(delegate));
    if (g_origSetDelegate) g_origSetDelegate(self, _cmd, delegate);
}

#pragma mark - 安装

static void AxsHookInstall(void) {
    if (g_installed) return;

    Class peripheral = NSClassFromString(@"CBPeripheral");
    if (!peripheral) return;

    Method mw = class_getInstanceMethod(peripheral, @selector(writeValue:forCharacteristic:type:));
    if (mw) {
        g_origWrite = (void (*)(id, SEL, NSData *, CBCharacteristic *, CBCharacteristicWriteType))method_getImplementation(mw);
        method_setImplementation(mw, (IMP)AxsHookedWrite);
    }

    Method md = class_getInstanceMethod(peripheral, @selector(setDelegate:));
    if (md) {
        g_origSetDelegate = (void (*)(id, SEL, id))method_getImplementation(md);
        method_setImplementation(md, (IMP)AxsHookedSetDelegate);
    }

    g_installed = YES;
}

#pragma mark - 入口

// 面板改开关后立刻生效。原来只在注入那一刻读一次配置，用户在设置里
// 关掉开关，正在跑的 App 还在继续记 —— 得把 App 划掉重开才停，
// 看起来就像「开关没用」。
static void axs_hook_prefs_changed(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef info) {
    id enabled = AxsBLELoggerReadConfig()[@"enabled"];
    g_recordEnabled = enabled ? [enabled boolValue] : YES;
}

void AxsBLELoggerHookStart(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) return;

        // SpringBoard 不是「被注入的 App」，是插件自己的宿主：走直连扫描。
        // 这一条是 1.4.1「注入不了 + 零数据」的补丁 —— 目标 App 注不进去时，
        // 至少还有一条能出帧的路。
        if ([bid isEqualToString:@"com.apple.springboard"]) {
            AxsBLELoggerScannerStart();
            return;
        }

        // 其他系统进程一律不装：抓的是第三方 App 的通信，塞进 backboardd
        // 这些进程只会拖慢系统，也没有要抓的东西。
        if ([bid hasPrefix:@"com.apple."]) return;

        // 配置里没写 enabled 这个键（刚装好）时默认记录
        id enabled = AxsBLELoggerReadConfig()[@"enabled"];
        g_recordEnabled = enabled ? [enabled boolValue] : YES;

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, axs_hook_prefs_changed,
            CFSTR("com.qwq.blelogger.preferences-changed"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        if (!NSClassFromString(@"CBPeripheral")) {
            dlopen("/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth", RTLD_NOW);
        }
        if (!NSClassFromString(@"CBPeripheral")) return;   // 这台设备没有 BLE

        AxsHookInstall();
        AxsBLELoggerSetState([NSString stringWithFormat:@"已注入 %@", bid]);
        AxsBLELoggerNoteInjected(bid);
    }
}
