// 注入式抓包：hook CoreBluetooth，抓目标 App 发出的和收到的每一帧。
//
// 这是 1.3.0 删掉、现在补回来的一半能力。两种抓法解决的问题不同：
//
//   直连（Scanner，跑在 SpringBoard）  设备推上来的帧，不需要设备有 App
//   注入（本文件，跑在目标 App 里）    App 发出去的帧 + 设备回给 App 的帧
//
// 散热器这类「必须用 App 才发指令」的设备，只有注入才看得到发出去的包。
//
// 不用 Logos：build-macos.sh 会把 .xm 里的 %ctor 用 sed 换掉，纯 runtime
// 写在这里省一层转换，编译行为在 Linux / macOS 上一致。

#import "AxsBLELoggerStore.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static void (*g_origWrite)(id, SEL, NSData *, CBCharacteristic *, CBCharacteristicWriteType) = NULL;
static void (*g_origSetDelegate)(id, SEL, id) = NULL;
static void (*g_origDidUpdate)(id, SEL, CBPeripheral *, CBCharacteristic *, id) = NULL;

static BOOL g_delegateHooked = NO;
static BOOL g_installed = NO;

#pragma mark - 记录

static void AxsRecordWrite(NSData *data, CBCharacteristic *ch, CBCharacteristicWriteType type) {
    if (!data.length || !ch) return;
    AxsBLELoggerAppendAppFrame(
        (type == CBCharacteristicWriteWithResponse) ? @"发(应答)" : @"发",
        AxsBLELoggerUUIDString(ch.service.UUID),
        AxsBLELoggerUUIDString(ch.UUID),
        AxsBLELoggerHex(data));
}

static void AxsRecordNotify(CBPeripheral *p, CBCharacteristic *ch) {
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
        if (!err) AxsRecordNotify(p, ch);
    }
    if (g_origDidUpdate) g_origDidUpdate(self, _cmd, p, ch, err);
}

// App 通常在拿到 CBPeripheral 后调 setDelegate:。这里把 delegate 身上的
// didUpdateValue 换掉，才能看到设备主动推给 App 的帧。
static void AxsHookedSetDelegate(id self, SEL _cmd, id delegate) {
    if (delegate && !g_delegateHooked) {
        Class cls = object_getClass(delegate);
        Method m = class_getInstanceMethod(cls, @selector(peripheral:didUpdateValueForCharacteristic:error:));
        if (m) {
            g_origDidUpdate = (void (*)(id, SEL, CBPeripheral *, CBCharacteristic *, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)AxsHookedDidUpdate);
            g_delegateHooked = YES;
        }
    }
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

void AxsBLELoggerHookStart(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) return;

        // 系统进程一律不装 hook。SpringBoard 由 Scanner 负责（直连模式），
        // 其余系统进程装进去没意义，还会拖慢每一个 App。
        if ([bid hasPrefix:@"com.apple."]) return;

        // 白名单：只有面板里勾了的 App 才 hook。
        // 配置里没有 apps 数组 = 一个都不抓，避免装完就全量注入。
        id apps = AxsBLELoggerReadConfig()[@"apps"];
        if (![apps isKindOfClass:[NSArray class]] || ![apps containsObject:bid]) return;

        if (!NSClassFromString(@"CBPeripheral")) {
            dlopen("/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth", RTLD_NOW);
        }
        AxsHookInstall();
    }
}
