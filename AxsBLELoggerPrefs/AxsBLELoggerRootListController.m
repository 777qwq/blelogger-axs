#import "AxsBLELoggerRootListController.h"
#import "AxsBLELoggerPreferences.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

// 只扫用户装的 App；系统 App 在别的目录里，这里天然拿不到。
static NSString *const kAxsBLELoggerAppRoot = @"/var/containers/Bundle/Application";

#pragma mark - App 枚举

// 首选 LSApplicationWorkspace：Settings 进程里 MobileCoreServices 已经加载，
// 走的是 launchservicesd 的 XPC，不受 App 沙盒的文件读取限制。
static NSMutableDictionary *AxsBLELoggerAppsViaWorkspace(void) {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) return map;

    id workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
    if (!workspace) return map;

    NSArray *proxies = [workspace performSelector:@selector(allInstalledApplications)];
    for (id proxy in proxies) {
        NSString *bundleId = [proxy performSelector:@selector(bundleIdentifier)];
        if (bundleId.length == 0 || [bundleId hasPrefix:@"com.apple."]) continue;

        if ([proxy respondsToSelector:@selector(applicationType)]) {
            NSString *type = [proxy performSelector:@selector(applicationType)];
            if (type && ![type isEqualToString:@"User"]) continue;
        }

        NSString *name = nil;
        if ([proxy respondsToSelector:@selector(localizedName)]) {
            name = [proxy performSelector:@selector(localizedName)];
        }
        if (name.length == 0) name = bundleId;

        map[name] = bundleId;
    }
    return map;
}

// 兜底：直接遍历 App 目录。workspace 不可用时才走这条。
static NSMutableDictionary *AxsBLELoggerAppsViaFilesystem(void) {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSFileManager *manager = [NSFileManager defaultManager];

    for (NSString *slot in [manager contentsOfDirectoryAtPath:kAxsBLELoggerAppRoot error:NULL]) {
        if ([slot hasPrefix:@"."]) continue;
        NSString *slotPath = [kAxsBLELoggerAppRoot stringByAppendingPathComponent:slot];

        for (NSString *item in [manager contentsOfDirectoryAtPath:slotPath error:NULL]) {
            if (![item hasSuffix:@".app"]) continue;

            NSString *appPath = [slotPath stringByAppendingPathComponent:item];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                                  [appPath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *bundleId = info[@"CFBundleIdentifier"];
            if (bundleId.length == 0 || [bundleId hasPrefix:@"com.apple."]) continue;

            NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
            if (name.length == 0) name = [item stringByDeletingPathExtension];

            map[name] = bundleId;
        }
    }
    return map;
}

static NSMutableDictionary *AxsBLELoggerInstalledApps(void) {
    NSMutableDictionary *map = AxsBLELoggerAppsViaWorkspace();
    if (map.count > 0) return map;
    return AxsBLELoggerAppsViaFilesystem();
}

#pragma mark - 面板

@interface AxsBLELoggerRootListController ()
@property (nonatomic, strong) PSSpecifier *appGroupSpecifier;
@end

@implementation AxsBLELoggerRootListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *items = [[self loadSpecifiersFromPlistName:@"AxsBLELoggerRoot"
                                                            target:self] mutableCopy];

        // Root.plist 的最后一项是「注入这些 App」的组头，
        // 后面追加的每一行都会落在这个组里。
        self.appGroupSpecifier = [items lastObject];

        NSDictionary *apps = AxsBLELoggerInstalledApps();
        NSArray *names = [[apps allKeys] sortedArrayUsingSelector:@selector(compare:)];

        for (NSString *name in names) {
            PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:name
                                                              target:self
                                                                 set:@selector(axs_blelogger_setApp:specifier:)
                                                                 get:@selector(axs_blelogger_getApp:)
                                                              detail:nil
                                                                cell:PSSwitchCell
                                                                edit:nil];
            [row setProperty:apps[name] forKey:@"axs_bundle_id"];
            [items addObject:row];
        }

        _specifiers = items;
        [self axs_blelogger_refreshFooter];
    }
    return _specifiers;
}

- (void)axs_blelogger_refreshFooter {
    if (!self.appGroupSpecifier) return;

    NSArray *selected = axs_blelogger_readPreferences()[@"selected"];
    NSString *footer = selected.count == 0
        ? @"一个都不勾 = 注入全部第三方 App。勾选后只注入勾选的，需重启目标 App 生效。"
        : [NSString stringWithFormat:@"已选 %lu 个 App，只注入这些。改动需重启目标 App 生效。",
                                     (unsigned long)selected.count];

    [self.appGroupSpecifier setProperty:footer forKey:@"footerText"];
}

#pragma mark - 单个 App 的开关

- (id)axs_blelogger_getApp:(PSSpecifier *)specifier {
    NSString *bundleId = [specifier propertyForKey:@"axs_bundle_id"];
    if (bundleId.length == 0) return @NO;

    NSArray *selected = axs_blelogger_readPreferences()[@"selected"];
    BOOL on = [selected isKindOfClass:[NSArray class]] && [selected containsObject:bundleId];
    return @(on);
}

- (void)axs_blelogger_setApp:(id)value specifier:(PSSpecifier *)specifier {
    NSString *bundleId = [specifier propertyForKey:@"axs_bundle_id"];
    if (bundleId.length == 0) return;

    NSArray *current = axs_blelogger_readPreferences()[@"selected"];
    NSMutableArray *selected = [current isKindOfClass:[NSArray class]]
        ? [current mutableCopy] : [NSMutableArray array];

    if ([value boolValue]) {
        if (![selected containsObject:bundleId]) [selected addObject:bundleId];
    } else {
        [selected removeObject:bundleId];
    }

    NSError *error = nil;
    if (!axs_blelogger_writePreference(@"selected", selected, &error)) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"设置未保存"
                             message:error.localizedDescription ?: @"请检查配置文件路径和写入权限。"
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        [self reloadSpecifiers];
        return;
    }

    [self axs_blelogger_refreshFooter];
}

@end
