#pragma once
typedef long long int64_t;
typedef unsigned long long uint64_t;
#include <objc/objc.h>

// 只声明工程里实际用到的 dispatch 接口，Linux 本地编译用。
// 真机构建走 Xcode SDK，用的是系统真头文件。

typedef void *dispatch_queue_t;
typedef void *dispatch_time_t;
typedef long dispatch_once_t;
typedef void (^dispatch_block_t)(void);

typedef enum {
    QOS_CLASS_USER_INTERACTIVE = 0x21,
    QOS_CLASS_USER_INITIATED    = 0x19,
    QOS_CLASS_DEFAULT           = 0x15,
    QOS_CLASS_UTILITY           = 0x11,
    QOS_CLASS_BACKGROUND        = 0x09,
} qos_class_t;

#define DISPATCH_QUEUE_SERIAL 0
#define DISPATCH_TIME_NOW 0ull
#define NSEC_PER_SEC 1000000000ull
#define NSEC_PER_MSEC 1000000ull

extern dispatch_queue_t dispatch_get_main_queue(void);
extern dispatch_queue_t dispatch_get_global_queue(long identifier, unsigned long flags);
extern dispatch_queue_t dispatch_queue_create(const char *label, void *attr);
extern void dispatch_async(dispatch_queue_t queue, dispatch_block_t block);
extern void dispatch_sync(dispatch_queue_t queue, dispatch_block_t block);
extern void dispatch_once(dispatch_once_t *predicate, dispatch_block_t block);
extern dispatch_time_t dispatch_time(dispatch_time_t when, int64_t delta);
extern void dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block);
