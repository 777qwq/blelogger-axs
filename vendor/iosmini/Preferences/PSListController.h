#pragma once
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>

@interface PSListController : UIViewController {
    NSMutableArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)specifier;
@end
