// 精简头：本地 Linux 编译用。真 SDK 里有完整的 dlfcn.h。
#pragma once

#define RTLD_LAZY   0x1
#define RTLD_NOW    0x2

void *dlopen(const char *path, int mode);
void *dlsym(void *handle, const char *symbol);
int dlclose(void *handle);
char *dlerror(void);
