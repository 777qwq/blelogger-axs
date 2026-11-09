#pragma once
#include <objc/objc.h>

typedef void *dispatch_queue_t;
typedef long dispatch_once_t;
typedef void (^dispatch_block_t)(void);

#define DISPATCH_QUEUE_SERIAL 0

extern dispatch_queue_t dispatch_get_main_queue(void);
extern dispatch_queue_t dispatch_queue_create(const char *label, void *attr);
extern void dispatch_async(dispatch_queue_t queue, dispatch_block_t block);
extern void dispatch_once(dispatch_once_t *predicate, dispatch_block_t block);
