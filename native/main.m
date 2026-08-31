#import <Cocoa/Cocoa.h>
#import "SyncGroupManager.h"

@interface OCR2MDSyncStatusDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic,strong) NSStatusItem *statusItem;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSTimer *animationTimer;
@property(nonatomic,assign) CGFloat animationAngle;
@property(nonatomic,copy) NSString *currentHealth;
@property(nonatomic,strong) NSImage *syncingBaseImage;
@property(nonatomic,assign) BOOL menuOpen;
@property(nonatomic,assign) NSTimeInterval demoSequenceStartedAt;
@property(nonatomic,strong) NSURL *syncRoot;
@property(nonatomic,strong) NSURL *stateURL;
@property(nonatomic,strong) NSURL *lockURL;
@property(nonatomic,strong) NSURL *runLogURL;
@property(nonatomic,strong) NSURL *unisonLogURL;
@property(nonatomic,strong) NSURL *previewURL;
@property(nonatomic,strong) NSURL *groupsURL;
@property(nonatomic,strong) OCR2MDSyncGroupManager *syncGroupManager;
@end

@implementation OCR2MDSyncStatusDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSURL *home = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
    self.syncRoot = [home URLByAppendingPathComponent:@"Library/Application Support/ocr2md-sync" isDirectory:YES];
    self.stateURL = [self.syncRoot URLByAppendingPathComponent:@"unison-state.txt"];
    self.lockURL = [self.syncRoot URLByAppendingPathComponent:@".unison-sync.lock" isDirectory:YES];
    self.runLogURL = [home URLByAppendingPathComponent:@"Library/Logs/ocr2md-sync/unison-run.log"];
    self.unisonLogURL = [home URLByAppendingPathComponent:@"Library/Logs/ocr2md-sync/unison.log"];
    self.previewURL = [self.syncRoot URLByAppendingPathComponent:@"syncstatus-preview.txt"];
    self.groupsURL = [self.syncRoot URLByAppendingPathComponent:@"sync-groups.json"];
    NSURL *legacyProfileURL = [home URLByAppendingPathComponent:@"Library/Application Support/Unison/ocr2md.prf"];
    self.syncGroupManager = [[OCR2MDSyncGroupManager alloc] initWithConfigURL:self.groupsURL legacyProfileURL:legacyProfileURL];

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
    NSString *phase = state[@"phase"] ?: @"";
    if ([phase isEqualToString:@"syncing"]) return @"syncing";
    if ([phase isEqualToString:@"polling"]) return @"polling";
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.lockURL.path]) return @"polling";
    NSString *status = state[@"status"] ?: @"";
    if ([status isEqualToString:@"conflict_or_skipped"]) return @"conflict";
    if ([status isEqualToString:@"error"]) return @"error";
    if ([status isEqualToString:@"ok"] && ![self isStale:state[@"last_end"] ?: @""]) return @"idle";
    return @"stale";
}

- (NSDictionary *)appearanceForHealth:(NSString *)health {
    if ([health isEqualToString:@"idle"] || [health isEqualToString:@"ok"]) {
        return @{ @"symbol": @"checkmark.circle.fill", @"label": @"空闲", @"color": [NSColor colorWithCalibratedWhite:0.48 alpha:1.0] };
    }
    if ([health isEqualToString:@"polling"]) {
        return @{ @"symbol": @"arrow.triangle.2.circlepath", @"label": @"正在轮询", @"color": [NSColor blackColor] };
    }
    if ([health isEqualToString:@"syncing"]) {
        return @{ @"symbol": @"arrow.triangle.2.circlepath", @"label": @"正在同步", @"color": [NSColor colorWithCalibratedRed:0.00 green:0.46 blue:1.00 alpha:1.0] };
    }
    if ([health isEqualToString:@"conflict"]) return @{ @"symbol": @"exclamationmark.triangle.fill", @"label": @"有冲突", @"color": [NSColor colorWithCalibratedRed:1.00 green:0.42 blue:0.00 alpha:1.0] };
    if ([health isEqualToString:@"error"]) return @{ @"symbol": @"xmark.octagon.fill", @"label": @"同步错误", @"color": [NSColor colorWithCalibratedRed:0.95 green:0.05 blue:0.08 alpha:1.0] };
    return @{ @"symbol": @"questionmark.circle.fill", @"label": @"等待同步", @"color": [NSColor colorWithCalibratedWhite:0.42 alpha:1.0] };
}

- (NSImage *)symbolImage:(NSString *)symbol color:(NSColor *)color {
    NSImage *image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    NSImageSymbolConfiguration *weightConfig = [NSImageSymbolConfiguration configurationWithPointSize:15.0 weight:NSFontWeightSemibold scale:NSImageSymbolScaleMedium];
    NSImageSymbolConfiguration *colorConfig = [NSImageSymbolConfiguration configurationWithPaletteColors:@[color]];
    NSImageSymbolConfiguration *symbolConfig = [weightConfig configurationByApplyingConfiguration:colorConfig];
    NSImage *coloredImage = [image imageWithSymbolConfiguration:symbolConfig];
    coloredImage.template = NO;
    return coloredImage;
}

- (NSImage *)rotatedImage:(NSImage *)source angle:(CGFloat)degrees {
    NSSize size = NSMakeSize(18.0, 18.0);
    NSImage *result = [[NSImage alloc] initWithSize:size];
    [result lockFocus];
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:size.width / 2.0 yBy:size.height / 2.0];
    [transform rotateByDegrees:degrees];
    [transform translateXBy:-size.width / 2.0 yBy:-size.height / 2.0];
    [transform concat];
    [source drawInRect:NSMakeRect(1.0, 1.0, 16.0, 16.0)
              fromRect:NSZeroRect
             operation:NSCompositingOperationSourceOver
              fraction:1.0
        respectFlipped:YES
                 hints:nil];
    [result unlockFocus];
    result.template = NO;
    return result;
}

- (void)animationTick:(NSTimer *)timer {
    if (![self.currentHealth isEqualToString:@"syncing"] || !self.syncingBaseImage) return;
    self.animationAngle = fmod(self.animationAngle + 30.0, 360.0);
    self.statusItem.button.image = [self rotatedImage:self.syncingBaseImage angle:self.animationAngle];
}

- (void)stopSyncAnimation {
    [self.animationTimer invalidate];
    self.animationTimer = nil;
    self.syncingBaseImage = nil;
    self.animationAngle = 0.0;
}

- (NSInteger)configuredDirectoryCountForGroupNamed:(NSString *)groupName {
    NSData *data = [NSData dataWithContentsOfURL:self.groupsURL];
    if (!data.length) return 0;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) return 0;
    NSArray *groups = ((NSDictionary *)object)[@"groups"];
    if (![groups isKindOfClass:[NSArray class]]) return 0;

    NSDictionary *fallback = nil;
    for (NSDictionary *group in groups) {
        if (![group isKindOfClass:[NSDictionary class]] || ![group[@"enabled"] boolValue]) continue;
        if (!fallback) fallback = group;
        NSString *name = [group[@"name"] isKindOfClass:[NSString class]] ? group[@"name"] : @"";
        if (groupName.length && [name isEqualToString:groupName]) {
            NSArray *directories = [group[@"directories"] isKindOfClass:[NSArray class]] ? group[@"directories"] : @[];
            return (NSInteger)directories.count;
        }
    }
    NSArray *directories = [fallback[@"directories"] isKindOfClass:[NSArray class]] ? fallback[@"directories"] : @[];
    return (NSInteger)directories.count;
}

- (NSString *)syncProgressTextForState:(NSDictionary *)state demoHealth:(NSString *)demoHealth {
    if (![self.currentHealth isEqualToString:@"syncing"] && ![demoHealth isEqualToString:@"syncing"]) return @"";

    NSInteger current = [state[@"progress_current"] integerValue];
    NSInteger total = [state[@"progress_total"] integerValue];

    if ([demoHealth isEqualToString:@"syncing"]) {
        total = [self configuredDirectoryCountForGroupNamed:nil];
        if (total <= 0) total = 3;
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - self.demoSequenceStartedAt;
        NSTimeInterval syncElapsed = elapsed - 6.0; // idle 3s + polling 3s
        if (syncElapsed < 0) syncElapsed = 0;
        current = MIN(total, MAX(1, (NSInteger)floor((syncElapsed / 3.0) * total) + 1));
    }

    if (total <= 0 || current <= 0) return @"";
    if (current > total) current = total;
    return [NSString stringWithFormat:@"%ld/%ld", (long)current, (long)total];
}

- (void)applyProgressText:(NSString *)progress health:(NSString *)health {
    BOOL syncing = [health isEqualToString:@"syncing"];
    self.statusItem.button.title = syncing ? (progress ?: @"") : @"";
    self.statusItem.button.imagePosition = (syncing && progress.length) ? NSImageLeft : NSImageOnly;
    if (syncing && progress.length) {
        self.statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightMedium];
    }
}

- (void)applyIconForHealth:(NSString *)health appearance:(NSDictionary *)appearance {
    BOOL wasSyncing = [self.currentHealth isEqualToString:@"syncing"];
    self.currentHealth = health;
    self.statusItem.button.contentTintColor = nil;

    if ([health isEqualToString:@"syncing"]) {
        if (!wasSyncing || !self.animationTimer) {
            [self stopSyncAnimation];
            self.currentHealth = @"syncing";
            self.syncingBaseImage = [self symbolImage:appearance[@"symbol"] color:appearance[@"color"]];
            self.animationAngle = 0.0;
            self.statusItem.button.image = [self rotatedImage:self.syncingBaseImage angle:0.0];
            self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:0.10 target:self selector:@selector(animationTick:) userInfo:nil repeats:YES];
        }
    } else {
        [self stopSyncAnimation];
        self.currentHealth = health;
        self.statusItem.button.image = [self symbolImage:appearance[@"symbol"] color:appearance[@"color"]];
    }
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"ocr2md：%@", appearance[@"label"]];
}

- (NSString *)demoSequenceHealth {
    if (self.demoSequenceStartedAt <= 0) return nil;
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - self.demoSequenceStartedAt;
    const NSTimeInterval secondsPerState = 3.0;
    NSArray<NSString *> *states = @[@"idle", @"polling", @"syncing", @"conflict", @"error"];
    NSInteger slot = (NSInteger)floor(elapsed / secondsPerState);
    if (slot < 0 || slot >= (NSInteger)states.count) {
        self.demoSequenceStartedAt = 0;
        return nil;
    }
    return states[(NSUInteger)slot];
}

- (NSString *)previewHealthFromText:(NSString *)preview {
    if ([preview isEqualToString:@"ok"]) return @"idle";
    if ([preview isEqualToString:@"idle"] || [preview isEqualToString:@"polling"] || [preview isEqualToString:@"syncing"] || [preview isEqualToString:@"conflict"] || [preview isEqualToString:@"error"] || [preview isEqualToString:@"stale"]) return preview;
    return nil;
}

- (void)refresh:(id)sender {
    NSDictionary *state = [self readState];
    NSString *health = [self healthForState:state];
    NSString *preview = [NSString stringWithContentsOfURL:self.previewURL encoding:NSUTF8StringEncoding error:nil];
    preview = [preview stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *previewHealth = [self previewHealthFromText:preview];
    if (previewHealth.length) health = previewHealth;
    NSString *demoHealth = [self demoSequenceHealth];
    if (demoHealth.length) health = demoHealth;
    NSDictionary *appearance = [self appearanceForHealth:health];
    NSDictionary *latest = [self latestTransfer];

    [self applyIconForHealth:health appearance:appearance];
    NSString *progressText = [self syncProgressTextForState:state demoHealth:demoHealth];
    [self applyProgressText:progressText health:health];

    if (self.menuOpen) return;
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
    [self addAction:@"管理同步目录组…" selector:@selector(openSyncGroups:) key:@"g" toMenu:menu];

    NSMenuItem *engineering = [[NSMenuItem alloc] initWithTitle:@"工程开发" action:nil keyEquivalent:@""];
    NSMenu *engineeringMenu = [[NSMenu alloc] initWithTitle:@"工程开发"];
    NSMenuItem *showStates = [[NSMenuItem alloc] initWithTitle:@"显示每种状态图标" action:@selector(showEveryStatusIcon:) keyEquivalent:@""];
    showStates.target = self;
    [engineeringMenu addItem:showStates];
    engineering.submenu = engineeringMenu;
    [menu addItem:engineering];

    [menu addItem:[NSMenuItem separatorItem]];
    [self addAction:@"退出状态栏" selector:@selector(quit:) key:@"q" toMenu:menu];
}

- (void)addAction:(NSString *)title selector:(SEL)selector key:(NSString *)key toMenu:(NSMenu *)menu {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:selector keyEquivalent:key];
    item.target = self;
    [menu addItem:item];
}

- (void)menuWillOpen:(NSMenu *)menu {
    self.menuOpen = NO;
    [self refresh:nil];
    self.menuOpen = YES;
}

- (void)menuDidClose:(NSMenu *)menu {
    self.menuOpen = NO;
    [self refresh:nil];
}

- (void)syncNow:(id)sender {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    task.arguments = @[@"kickstart", @"-k", [NSString stringWithFormat:@"gui/%d/com.ocr2md.unison-sync", getuid()]];
    [task launchAndReturnError:nil];

    // Do not rebuild NSMenu while AppKit is still dispatching this menu item's action.
    // Rebuilding the live menu here can invalidate objects still owned by the menu
    // tracking session and lead to EXC_BAD_ACCESS on the next menu interaction.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self refresh:nil];
    });
}

- (void)showEveryStatusIcon:(id)sender {
    self.demoSequenceStartedAt = [[NSDate date] timeIntervalSince1970];
    // Let the menu tracking session finish first; refresh will then advance the one-shot sequence.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self refresh:nil];
    });
}

- (void)openVault:(id)sender {
    NSURL *url = [NSURL URLWithString:@"obsidian://open?vault=ocr2md"];
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)openSyncGroups:(id)sender {
    // Let the status-menu tracking session finish before presenting another window.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.syncGroupManager showWindow];
    });
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
