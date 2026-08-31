#import <Cocoa/Cocoa.h>

@interface OCR2MDSyncGroupManager : NSObject
- (instancetype)initWithConfigURL:(NSURL *)configURL legacyProfileURL:(NSURL *)legacyProfileURL;
- (void)showWindow;
@end
