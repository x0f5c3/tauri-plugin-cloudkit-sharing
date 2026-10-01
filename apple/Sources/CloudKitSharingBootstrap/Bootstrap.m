#import <Foundation/Foundation.h>
#import "Bootstrap.h"
extern void cloudkit_sharing_install_early(void);
// A referenced anchor ensures static linking retains the +load implementation.
void cloudkit_sharing_bootstrap_anchor(void) {}
@interface TauriCloudKitSharingBootstrap : NSObject
@end
@implementation TauriCloudKitSharingBootstrap
+ (void)load { cloudkit_sharing_install_early(); }
@end
