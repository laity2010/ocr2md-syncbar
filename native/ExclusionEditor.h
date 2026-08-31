#import <Cocoa/Cocoa.h>

@interface OCR2MDExclusionEditor : NSObject
- (instancetype)initWithRootPath:(NSString *)rootPath
                           items:(NSArray<NSString *> *)items
                     saveHandler:(void (^)(NSArray<NSString *> *items))saveHandler;
- (void)runModal;
@end
