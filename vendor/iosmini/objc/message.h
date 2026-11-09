#pragma once
#include <objc/objc.h>

// 所有 objc 消息都经由它，调用点自行强转成正确签名
extern void *objc_msgSend(void);
