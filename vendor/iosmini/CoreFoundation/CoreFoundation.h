#pragma once
#include <objc/objc.h>

typedef const struct __CFString *CFStringRef;

#ifdef __OBJC__
extern CFStringRef __CFStringMakeConstantString(const char *c);
#define CFSTR(s) __CFStringMakeConstantString(s)
#endif
typedef const struct __CFDictionary *CFDictionaryRef;
typedef const struct __CFNotificationCenter *CFNotificationCenterRef;

typedef long CFNotificationSuspensionBehavior;
enum { CFNotificationSuspensionBehaviorDeliverImmediately = 4 };

typedef void (*CFNotificationCallback)(CFNotificationCenterRef center, void *observer,
                                       CFStringRef name, const void *object,
                                       CFDictionaryRef userInfo);

extern CFNotificationCenterRef CFNotificationCenterGetDarwinNotifyCenter(void);
extern void CFNotificationCenterAddObserver(CFNotificationCenterRef center, const void *observer,
                                           CFNotificationCallback callback, CFStringRef name,
                                           const void *object, CFNotificationSuspensionBehavior behavior);
extern void CFNotificationCenterRemoveEveryObserver(CFNotificationCenterRef center, const void *observer);
extern void CFNotificationCenterPostNotification(CFNotificationCenterRef center, CFStringRef name,
                                                 const void *object, CFDictionaryRef userInfo,
                                                 _Bool deliverImmediately);
