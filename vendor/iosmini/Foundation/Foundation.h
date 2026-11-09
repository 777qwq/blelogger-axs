#pragma once
#include <objc/objc.h>
#include <objc/runtime.h>
#include <objc/message.h>

typedef struct _NSRange { NSUInteger location; NSUInteger length; } NSRange;
static inline NSRange NSMakeRange(NSUInteger l, NSUInteger n) {
    NSRange r; r.location = l; r.length = n; return r;
}
#define NSNotFound ((NSUInteger)0x7fffffffffffffffUL)

typedef NSUInteger NSStringEncoding;
enum { NSUTF8StringEncoding = 4 };

typedef double NSTimeInterval;

@class NSString, NSArray, NSDictionary, NSData, NSDate;

@protocol NSObject
@end

extern void NSLog(NSString *fmt, ...);
extern Class NSClassFromString(NSString *name);

__attribute__((objc_root_class))
@interface NSObject {
    Class isa;
}
+ (instancetype)alloc;
+ (Class)class;
+ (BOOL)instancesRespondToSelector:(SEL)s;
- (instancetype)init;
- (Class)class;
- (BOOL)isKindOfClass:(Class)c;
- (BOOL)respondsToSelector:(SEL)s;
- (id)copy;
- (NSString *)description;
- (const char *)UTF8String;
- (void)performSelectorOnMainThread:(SEL)s withObject:(id)o waitUntilDone:(BOOL)w;
- (id)performSelector:(SEL)s withObject:(id)o afterDelay:(double)d;
- (id)performSelector:(SEL)s;
- (id)mutableCopy;
@end

typedef NSInteger NSComparisonResult;
enum { NSOrderedAscending = -1, NSOrderedSame = 0, NSOrderedDescending = 1 };

@interface NSError : NSObject
@property (readonly, copy) NSString *localizedDescription;
+ (instancetype)errorWithDomain:(NSString *)domain code:(NSInteger)code userInfo:(id)info;
@end

@interface NSString : NSObject
+ (instancetype)string;
+ (instancetype)stringWithUTF8String:(const char *)s;
+ (instancetype)stringWithFormat:(NSString *)fmt, ...;
+ (instancetype)stringWithString:(NSString *)s;
+ (instancetype)stringWithContentsOfFile:(NSString *)p encoding:(NSStringEncoding)e error:(id *)err;
- (NSUInteger)length;
- (unichar)characterAtIndex:(NSUInteger)i;
- (NSString *)substringFromIndex:(NSUInteger)i;
- (NSString *)substringToIndex:(NSUInteger)i;
- (BOOL)hasPrefix:(NSString *)s;
- (BOOL)hasSuffix:(NSString *)s;
- (BOOL)isEqualToString:(NSString *)s;
- (BOOL)containsString:(NSString *)s;
- (NSString *)stringByAppendingString:(NSString *)s;
- (NSString *)stringByAppendingFormat:(NSString *)fmt, ...;
- (NSArray *)componentsSeparatedByString:(NSString *)sep;
- (NSString *)uppercaseString;
- (NSString *)lowercaseString;
- (NSString *)stringByReplacingOccurrencesOfString:(NSString *)a withString:(NSString *)b;
- (NSComparisonResult)compare:(NSString *)s;
- (NSString *)lastPathComponent;
- (NSString *)stringByDeletingPathExtension;
- (NSString *)stringByAppendingPathComponent:(NSString *)c;
- (NSData *)dataUsingEncoding:(NSStringEncoding)e;
- (BOOL)writeToFile:(NSString *)p atomically:(BOOL)a encoding:(NSStringEncoding)e error:(id *)err;
@end

@interface NSMutableString : NSString
+ (instancetype)string;
- (void)appendString:(NSString *)s;
- (void)appendFormat:(NSString *)fmt, ...;
@end

@interface NSData : NSObject
+ (instancetype)dataWithBytes:(const void *)b length:(NSUInteger)l;
+ (instancetype)dataWithContentsOfFile:(NSString *)p;
- (const void *)bytes;
- (NSUInteger)length;
- (BOOL)writeToFile:(NSString *)p atomically:(BOOL)a;
@end

@interface NSArray : NSObject
+ (instancetype)array;
+ (instancetype)arrayWithObjects:(id)first, ...;
- (NSUInteger)count;
- (id)objectAtIndex:(NSUInteger)i;
- (id)firstObject;
- (id)lastObject;
- (BOOL)containsObject:(id)o;
- (id)objectAtIndexedSubscript:(NSUInteger)i;
- (NSUInteger)countByEnumeratingWithState:(void *)state objects:(id *)buffer count:(NSUInteger)len;
- (NSString *)componentsJoinedByString:(NSString *)sep;
- (NSArray *)sortedArrayUsingSelector:(SEL)s;
- (id)copy;
@end

@interface NSNumber : NSObject
+ (NSNumber *)numberWithBool:(BOOL)v;
+ (NSNumber *)numberWithInt:(int)v;
- (BOOL)boolValue;
- (int)intValue;
@end

@interface NSMutableArray : NSArray
+ (instancetype)array;
- (void)addObject:(id)o;
- (void)removeObject:(id)o;
- (void)removeAllObjects;
- (void)removeObjectAtIndex:(NSUInteger)i;
@end

@interface NSDictionary : NSObject
+ (instancetype)dictionaryWithObjects:(NSArray *)objs forKeys:(NSArray *)keys;
+ (id)dictionaryWithContentsOfFile:(NSString *)path;
- (id)objectForKey:(id)k;
- (id)objectForKeyedSubscript:(id)k;
- (NSUInteger)count;
- (NSArray *)allKeys;
- (BOOL)writeToFile:(NSString *)path atomically:(BOOL)flag;
- (id)copy;
@end

@interface NSMutableDictionary : NSDictionary
+ (instancetype)dictionary;
+ (id)dictionaryWithContentsOfFile:(NSString *)path;
- (void)setObject:(id)o forKey:(id)k;
- (void)setObject:(id)o forKeyedSubscript:(id)k;
- (void)removeObjectForKey:(id)k;
- (void)removeAllObjects;
@end

@interface NSUUID : NSObject
- (NSString *)UUIDString;
@end

@interface NSDate : NSObject
+ (instancetype)date;
@end

@interface NSDateFormatter : NSObject
- (instancetype)init;
- (void)setDateFormat:(NSString *)f;
- (NSString *)stringFromDate:(NSDate *)d;
@end

@interface NSFileManager : NSObject
+ (NSFileManager *)defaultManager;
- (BOOL)fileExistsAtPath:(NSString *)p;
- (NSArray *)contentsOfDirectoryAtPath:(NSString *)p error:(id *)e;
- (BOOL)createFileAtPath:(NSString *)p contents:(NSData *)c attributes:(id)a;
- (BOOL)removeItemAtPath:(NSString *)p error:(id *)e;
- (NSData *)contentsAtPath:(NSString *)p;
@end

@interface NSFileHandle : NSObject
+ (instancetype)fileHandleForWritingAtPath:(NSString *)p;
- (void)seekToEndOfFile;
- (void)writeData:(NSData *)d;
- (void)synchronizeFile;
- (void)closeFile;
@end

@interface NSBundle : NSObject
+ (NSBundle *)mainBundle;
+ (NSBundle *)bundleWithPath:(NSString *)p;
- (NSString *)bundleIdentifier;
- (BOOL)load;
@end


@interface NSNotificationCenter : NSObject
+ (NSNotificationCenter *)defaultCenter;
- (void)postNotificationName:(NSString *)name object:(id)object;
@end

@interface NSUserDefaults : NSObject
+ (NSUserDefaults *)standardUserDefaults;
- (BOOL)boolForKey:(NSString *)k;
- (void)setBool:(BOOL)v forKey:(NSString *)k;
- (id)objectForKey:(NSString *)k;
- (BOOL)synchronize;
@end

NSString *NSStringFromClass(Class c);

extern void *dlopen(const char *path, int mode);
extern void *dlsym(void *handle, const char *sym);
#define RTLD_LAZY 0x1
#define RTLD_NOW  0x2
