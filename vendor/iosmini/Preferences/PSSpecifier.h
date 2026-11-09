#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

enum {
    PSGroupCell  = 0,
    PSLinkCell   = 1,
    PSButtonCell = 13,
    PSSwitchCell = 6
};

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(NSInteger)cell
                                    edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@property (nonatomic, assign) SEL buttonAction;
@end
