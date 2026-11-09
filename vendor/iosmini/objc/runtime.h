#pragma once
#include <objc/objc.h>

typedef struct objc_selector *SEL;
typedef struct objc_method *Method;
typedef struct objc_ivar *Ivar;
typedef long ptrdiff_t;
typedef struct objc_class *Class;
typedef struct objc_object *id;

Class objc_getClass(const char *name);
Class object_getClass(id obj);
Method class_getInstanceMethod(Class cls, SEL name);
Method class_getClassMethod(Class cls, SEL name);
Class class_getSuperclass(Class cls);
Ivar class_getInstanceVariable(Class cls, const char *name);
ptrdiff_t ivar_getOffset(Ivar iv);
IMP method_getImplementation(Method m);
IMP method_setImplementation(Method m, IMP imp);
const char *method_getTypeEncoding(Method m);
void method_exchangeImplementations(Method a, Method b);
SEL sel_registerName(const char *name);
SEL NSSelectorFromString(id name);
id NSStringFromSelector(SEL sel);
void objc_setAssociatedObject(id object, const void *key, id value, int policy);
id objc_getAssociatedObject(id object, const void *key);

#define OBJC_ASSOCIATION_RETAIN_NONATOMIC 1
