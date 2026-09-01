#import <Cocoa/Cocoa.h>

typedef void (^OCR2MDSyncTrigger)(void);

@interface OCR2MDConflictManager : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
- (instancetype)initWithConflictURL:(NSURL *)conflictURL syncHandler:(OCR2MDSyncTrigger)syncHandler;
- (void)showWindow;
@end
