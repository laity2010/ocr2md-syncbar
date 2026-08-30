#import <Cocoa/Cocoa.h>

@interface OCR2MDSyncStatusDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic,strong) NSStatusItem *statusItem;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSURL *syncRoot;
@property(nonatomic,strong) NSURL *stateURL;
@property(nonatomic,strong) NSURL *lockURL;
@property(nonatomic,strong) NSURL *runLogURL;
@property(nonatomic,strong) NSURL *unisonLogURL;
@end

@implementation OCR2MDSyncStatusDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSURL *home = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
    self.syncRoot = [home URLByAppendingPathComponent:@"Library/Application Support/ocr2md-sync" isDirectory:YES];
    self.stateURL = [self.syncRoot URLByAppendingPathComponent:@"unison-state.txt"];
    self.lockURL = [self.syncRoot URLByAppendingPathComponent:@".unison-sync.lock" isDirectory:YES];
    self.runLogURL = [home URLByAppendingPathComponent:@"Library/Logs/ocr2md-sync/unison-run.log"];
    self.unisonLogURL = [home URLByAppendingPathComponent:@"Library/Logs/ocr2md-sync/unison.log"];

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.imagePosition = NSImageOnly;
    self.statusItem.button.imageScaling = NSImageScaleProportionallyDown;
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    self.statusItem.menu = menu;

    [self refresh:nil];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
}

- (NSDictionary<NSString *, NSString *> *)readState {
    NSString *text = [NSString stringWithContentsOfURL:self.stateURL encoding:NSUTF8StringEncoding error:nil];
    if (!text) return @{};
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSRange r = [line rangeOfString:@"="];
        if (r.location == NSNotFound) continue;
        NSString *key = [line substringToIndex:r.location];
        NSString *value = [line substringFromIndex:r.location + 1];
        if (key.length) result[key] = value;
    }
    return result;
}

- (BOOL)isStale:(NSString *)value {
    if (!value.length) return YES;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSDate *date = [fmt dateFromString:value];
    if (!date) return YES;
    return -[date timeIntervalSinceNow] > 45.0;
}

- (NSDictionary<NSString *, NSString *> *)latestTransfer {
    NSData *data = [NSData dataWithContentsOfURL:self.runLogURL];
    if (!data.length) return @{};
    NSUInteger start = data.length > 262144 ? data.length - 262144 : 0;
    NSData *tail = [data subdataWithRange:NSMakeRange(start, data.length - start)];
    NSString *text = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
    if (!text) return @{};
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSRegularExpression *normal = [NSRegularExpression regularExpressionWithPattern:@"(<----|---->)\\s+(?:changed|new file|deleted)\\s+(.+?)\\s*$" options:0 error:nil];
    NSRegularExpression *conflict = [NSRegularExpression regularExpressionWithPattern:@"(?:changed|new file|deleted)\\s+<-\\?->\\s+(?:changed|new file|deleted)\\s+(.+?)\\s*$" options:0 error:nil];
    for (NSString *line in [lines reverseObjectEnumerator]) {
        NSTextCheckingResult *cm = [conflict firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (cm && cm.numberOfRanges >= 2) {
            NSString *path = [line substringWithRange:[cm rangeAtIndex:1]];
            return @{ @"direction": @"冲突", @"path": [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] };
        }
        NSTextCheckingResult *m = [normal firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (!m || m.numberOfRanges < 3) continue;
        NSString *marker = [line substringWithRange:[m rangeAtIndex:1]];
        NSString *path = [line substringWithRange:[m rangeAtIndex:2]];
        NSString *direction = [marker isEqualToString:@"<----"] ? @"Google Drive → iCloud" : @"iCloud → Google Drive";
        return @{ @"direction": direction, @"path": [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] };
    }
    return @{};
}

- (NSString *)healthForState:(NSDictionary *)state {
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.lockURL.path]) return @"syncing";
    NSString *status = state[@"status"] ?: @"";
    if ([status isEqualToString:@"conflict_or_skipped"]) return @"conflict";
    if ([status isEqualToString:@"error"]) return @"error";
    if ([status isEqualToString:@"ok"] && ![self isStale:state[@"last_end"] ?: @""]) return @"ok";
    return @"stale";
}

- (NSDictionary *)appearanceForHealth:(NSString *)health {
    if ([health isEqualToString:@"ok"]) return @{ @"symbol": @"checkmark.circle.fill", @"label": @"已同步" };
    if ([health isEqualToString:@"syncing"]) return @{ @"symbol": @"arrow.triangle.2.circlepath", @"label": @"正在同步" };
    if ([health isEqualToString:@"conflict"]) return @{ @"symbol": @"exclamationmark.triangle.fill", @"label": @"有冲突" };
    if ([health isEqualToString:@"error"]) return @{ @"symbol": @"xmark.octagon.fill", @"label": @"同步错误" };
    return @{ @"symbol": @"questionmark.circle.fill", @"label": @"等待同步" };
}

- (void)refresh:(id)sender {
    NSDictionary *state = [self readState];
    NSString *health = [self healthForState:state];
    NSDictionary *appearance = [self appearanceForHealth:health];
    NSDictionary *latest = [self latestTransfer];

    NSImage *image = [NSImage imageWithSystemSymbolName:appearance[@"symbol"] accessibilityDescription:appearance[@"label"]];
    image.template = YES;
    self.statusItem.button.image = image;
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"ocr2md：%@", appearance[@"label"]];

    NSMenu *menu = self.statusItem.menu;
    [menu removeAllItems];

    NSMenuItem *title = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"ocr2md · %@", appearance[@"label"]] action:nil keyEquivalent:@""];
    title.enabled = NO;
    [menu addItem:title];

    NSString *lastEnd = state[@"last_end"] ?: @"";
    NSMenuItem *last = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"上次巡检：%@", lastEnd.length ? lastEnd : @"尚无记录"] action:nil keyEquivalent:@""];
    last.enabled = NO;
    [menu addItem:last];

    NSString *direction = latest[@"direction"] ?: @"";
    NSString *path = latest[@"path"] ?: @"";
    if (direction.length) {
        NSString *detail = path.length ? [NSString stringWithFormat:@"%@ · %@", direction, path] : direction;
        NSMenuItem *recent = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"最近变更：%@", detail] action:nil keyEquivalent:@""];
        recent.enabled = NO;
        [menu addItem:recent];
    }

    if ([health isEqualToString:@"conflict"]) {
        NSMenuItem *warning = [[NSMenuItem alloc] initWithTitle:@"⚠️ 冲突已冻结，未自动覆盖" action:nil keyEquivalent:@""];
        warning.enabled = NO;
        [menu addItem:warning];
    } else if ([health isEqualToString:@"error"]) {
        NSMenuItem *err = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"退出码：%@", state[@"exit_code"] ?: @"?"] action:nil keyEquivalent:@""];
        err.enabled = NO;
        [menu addItem:err];
    }

    [menu addItem:[NSMenuItem separatorItem]];
    [self addAction:@"立即同步" selector:@selector(syncNow:) key:@"s" toMenu:menu];
    [self addAction:@"打开 ocr2md" selector:@selector(openVault:) key:@"o" toMenu:menu];
    [self addAction:@"打开同步日志" selector:@selector(openLog:) key:@"l" toMenu:menu];
    [menu addItem:[NSMenuItem separatorItem]];
    [self addAction:@"退出状态栏" selector:@selector(quit:) key:@"q" toMenu:menu];
}

- (void)addAction:(NSString *)title selector:(SEL)selector key:(NSString *)key toMenu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:selector keyEquivalent:key];
    item.target = self;
    [menu addItem:item];
}

- (void)menuWillOpen:(NSMenu *)menu { [self refresh:nil]; }

- (void)syncNow:(id)sender {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = @[@"kickstart", @"-k", [NSString stringWithFormat:@"gui/%d/com.ocr2md.unison-sync", getuid()]];
    [task launchAndReturnError:nil];
    [self refresh:nil];
}

- (void)openVault:(id)sender {
    NSURL *url = [NSURL URLWithString:@"obsidian://open?vault=ocr2md"];
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)openLog:(id)sender {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:self.unisonLogURL.path]) [[NSWorkspace sharedWorkspace] openURL:self.unisonLogURL];
    else if ([fm fileExistsAtPath:self.runLogURL.path]) [[NSWorkspace sharedWorkspace] openURL:self.runLogURL];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        OCR2MDSyncStatusDelegate *delegate = [[OCR2MDSyncStatusDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
        (void)delegate;
    }
    return 0;
}
