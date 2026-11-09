#pragma once
#import <UIKit/UIKit.h>
#import <Preferences/PSSpecifier.h>

@interface PSListController : UIViewController {
    NSMutableArray *_specifiers;
}
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
- (PSSpecifier *)specifierAtIndexPath:(NSIndexPath *)ip;
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;
- (void)reloadSpecifier:(PSSpecifier *)specifier;
@end
