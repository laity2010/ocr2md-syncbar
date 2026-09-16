#import "ConflictManager.h"

@interface OCR2MDConflictManager ()
@property(nonatomic,strong) NSURL *conflictURL;
@property(nonatomic,copy) OCR2MDSyncTrigger syncHandler;
@property(nonatomic,strong) NSDictionary *document;
@property(nonatomic,strong) NSArray<NSDictionary *> *conflicts;
@property(nonatomic,copy) NSString *leftRoot;
@property(nonatomic,copy) NSString *rightRoot;
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSTableView *table;
@property(nonatomic,strong) NSTextField *summaryLabel;
@property(nonatomic,strong) NSTextField *detailLabel;
@property(nonatomic,strong) NSButton *openLeftButton;
@property(nonatomic,strong) NSButton *openRightButton;
@property(nonatomic,strong) NSButton *resolveLeftButton;
@property(nonatomic,strong) NSButton *resolveRightButton;
@end

@implementation OCR2MDConflictManager

- (instancetype)initWithConflictURL:(NSURL *)conflictURL syncHandler:(OCR2MDSyncTrigger)syncHandler {
    self = [super init];
    if (self) {
        _conflictURL = conflictURL;
        _syncHandler = [syncHandler copy];
        _conflicts = @[];
    }
    return self;
}

- (NSString *)labelForRoot:(NSString *)root {
    if ([root containsString:@"iCloud~md~obsidian"]) return @"iCloud";
    if ([root containsString:@"/GoogleDrive-"]) return @"Google Drive";
    if ([root containsString:@"/OneDrive-"]) return @"OneDrive";
    NSString *name = root.lastPathComponent;
    return name.length ? name : @"左/右副本";
}

- (void)loadDocument {
    NSData *data = [NSData dataWithContentsOfURL:self.conflictURL];
    NSDictionary *doc = nil;
    if (data.length) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]]) doc = obj;
    }
    self.document = doc ?: @{};
    self.leftRoot = [self.document[@"left_root"] isKindOfClass:[NSString class]] ? self.document[@"left_root"] : @"";
    self.rightRoot = [self.document[@"right_root"] isKindOfClass:[NSString class]] ? self.document[@"right_root"] : @"";
    NSArray *items = [self.document[@"conflicts"] isKindOfClass:[NSArray class]] ? self.document[@"conflicts"] : @[];
    NSMutableArray *clean = [NSMutableArray array];
    for (id item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *path = [item[@"path"] isKindOfClass:[NSString class]] ? item[@"path"] : @"";
        if (path.length) [clean addObject:item];
    }
    self.conflicts = clean;
    [self.table reloadData];
    if (self.conflicts.count) {
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }
    [self refreshControls];
}

- (void)showWindow {
    if (!self.window) [self buildWindow];
    [self loadDocument];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [sender orderOut:nil];
    return NO;
}

- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 480)
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"Unison 冲突管理";
    self.window.minSize = NSMakeSize(760, 420);
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    [self.window center];

    NSView *content = self.window.contentView;
    NSTextField *title = [NSTextField wrappingLabelWithString:@"同步已冻结，Unison 没有自动覆盖任何一边。选择冲突文件后，先检查双方版本，再决定以哪一边为准。可按 Shift 或 ⌘ 多选并批量应用同一裁决；处理前会自动保存双方副本。"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:title];

    self.summaryLabel = [NSTextField labelWithString:@""];
    self.summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryLabel.textColor = [NSColor secondaryLabelColor];
    [content addSubview:self.summaryLabel];

    self.table = [[NSTableView alloc] init];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    column.title = @"冲突文件";
    column.width = 760;
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.table addTableColumn:column];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.allowsMultipleSelection = YES;
    self.table.rowHeight = 28;

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = self.table;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    [content addSubview:scroll];

    self.detailLabel = [NSTextField wrappingLabelWithString:@""];
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.textColor = [NSColor secondaryLabelColor];
    self.detailLabel.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    [content addSubview:self.detailLabel];

    self.openLeftButton = [self button:@"打开左侧" action:@selector(openLeft:)];
    self.openRightButton = [self button:@"打开右侧" action:@selector(openRight:)];
    self.resolveLeftButton = [self button:@"以左侧为准…" action:@selector(resolveLeft:)];
    self.resolveRightButton = [self button:@"以右侧为准…" action:@selector(resolveRight:)];
    NSButton *reloadButton = [self button:@"重新读取" action:@selector(reload:)];

    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.openLeftButton, self.openRightButton, self.resolveLeftButton, self.resolveRightButton, reloadButton]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 8;
    buttons.alignment = NSLayoutAttributeCenterY;
    [content addSubview:buttons];

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18],
        [title.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
        [title.topAnchor constraintEqualToAnchor:content.topAnchor constant:18],
        [self.summaryLabel.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.summaryLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [scroll.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.summaryLabel.bottomAnchor constant:8],
        [scroll.bottomAnchor constraintEqualToAnchor:self.detailLabel.topAnchor constant:-10],
        [self.detailLabel.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.detailLabel.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [buttons.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [buttons.topAnchor constraintEqualToAnchor:self.detailLabel.bottomAnchor constant:10],
        [buttons.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
    ]];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)self.conflicts.count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSTextField *field = [tableView makeViewWithIdentifier:@"pathCell" owner:self];
    if (!field) {
        field = [NSTextField labelWithString:@""];
        field.identifier = @"pathCell";
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    NSString *path = self.conflicts[(NSUInteger)row][@"path"] ?: @"";
    field.stringValue = path;
    field.toolTip = path;
    return field;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification { [self refreshControls]; }

- (NSArray<NSDictionary *> *)selectedConflicts {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    [self.table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < self.conflicts.count) [items addObject:self.conflicts[idx]];
    }];
    return items;
}

- (NSDictionary *)selectedConflict {
    NSArray<NSDictionary *> *items = [self selectedConflicts];
    return items.count == 1 ? items.firstObject : nil;
}

- (NSString *)fileInfoForRoot:(NSString *)root relative:(NSString *)relative {
    NSString *path = [self safeFullPathForRoot:root relative:relative];
    if (!path.length) return @"路径无效";
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attrs) return @"文件不存在";
    unsigned long long size = [attrs fileSize];
    NSDate *modified = attrs[NSFileModificationDate];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale currentLocale];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *when = modified ? [fmt stringFromDate:modified] : @"未知时间";
    return [NSString stringWithFormat:@"%@ · %llu 字节", when, size];
}

- (void)refreshControls {
    NSString *left = [self labelForRoot:self.leftRoot];
    NSString *right = [self labelForRoot:self.rightRoot];
    NSArray<NSDictionary *> *selected = [self selectedConflicts];
    NSUInteger selectedCount = selected.count;
    BOOL hasAny = selectedCount > 0;
    BOOL hasSingle = selectedCount == 1;

    if (!self.conflicts.count) {
        self.summaryLabel.stringValue = @"当前没有可管理的冲突记录";
    } else if (selectedCount > 1) {
        self.summaryLabel.stringValue = [NSString stringWithFormat:@"当前 %lu 个冲突 · 已选择 %lu 项 · %@ ↔ %@",
            (unsigned long)self.conflicts.count, (unsigned long)selectedCount, left, right];
    } else {
        self.summaryLabel.stringValue = [NSString stringWithFormat:@"当前 %lu 个冲突 · %@ ↔ %@",
            (unsigned long)self.conflicts.count, left, right];
    }

    self.openLeftButton.title = [NSString stringWithFormat:@"打开 %@", left];
    self.openRightButton.title = [NSString stringWithFormat:@"打开 %@", right];
    self.resolveLeftButton.title = selectedCount > 1
        ? [NSString stringWithFormat:@"以 %@ 为准（%lu 项）…", left, (unsigned long)selectedCount]
        : [NSString stringWithFormat:@"以 %@ 为准…", left];
    self.resolveRightButton.title = selectedCount > 1
        ? [NSString stringWithFormat:@"以 %@ 为准（%lu 项）…", right, (unsigned long)selectedCount]
        : [NSString stringWithFormat:@"以 %@ 为准…", right];

    // “打开”只针对单个文件；批量裁决按钮对任意非空选择可用。
    self.openLeftButton.enabled = hasSingle;
    self.openRightButton.enabled = hasSingle;
    self.resolveLeftButton.enabled = hasAny;
    self.resolveRightButton.enabled = hasAny;

    if (hasSingle) {
        NSDictionary *item = selected.firstObject;
        NSString *path = item[@"path"] ?: @"";
        self.detailLabel.stringValue = [NSString stringWithFormat:@"%@\n%@：%@\n    %@\n%@：%@\n    %@",
           path, left, self.leftRoot, [self fileInfoForRoot:self.leftRoot relative:path],
           right, self.rightRoot, [self fileInfoForRoot:self.rightRoot relative:path]];
    } else if (selectedCount > 1) {
        self.detailLabel.stringValue = [NSString stringWithFormat:@"已选择 %lu 项。批量裁决会先校验全部项目、统一备份双方版本，再逐项应用同一方向；最后只重新运行一次 Unison。",
            (unsigned long)selectedCount];
    } else {
        self.detailLabel.stringValue = @"若状态栏仍显示冲突但这里为空，可点“重新读取”；仍为空时请打开同步日志。";
    }
}

- (NSString *)safeFullPathForRoot:(NSString *)root relative:(NSString *)relative {
    if (!root.length || !relative.length || [relative hasPrefix:@"/"]) return nil;
    for (NSString *component in relative.pathComponents) if ([component isEqualToString:@".."]) return nil;
    NSString *rootStd = root.stringByStandardizingPath;
    NSString *full = [[rootStd stringByAppendingPathComponent:relative] stringByStandardizingPath];
    NSString *prefix = [rootStd stringByAppendingString:@"/"];
    return [full hasPrefix:prefix] ? full : nil;
}

- (void)showMessage:(NSString *)title info:(NSString *)info {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title ?: @"";
    alert.informativeText = info ?: @"";
    [alert addButtonWithTitle:@"好"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)openRoot:(NSString *)root {
    NSString *relative = [self selectedConflict][@"path"];
    NSString *path = [self safeFullPathForRoot:root relative:relative];
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self showMessage:@"文件不存在" info:path ?: relative];
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]];
}

- (void)openLeft:(id)sender { [self openRoot:self.leftRoot]; }
- (void)openRight:(id)sender { [self openRoot:self.rightRoot]; }
- (void)reload:(id)sender { [self loadDocument]; }

- (NSString *)timestampComponent {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyyMMdd-HHmmss-SSS";
    return [fmt stringFromDate:[NSDate date]];
}

- (BOOL)backupPath:(NSString *)path relative:(NSString *)relative under:(NSString *)backupRoot side:(NSString *)side error:(NSError **)error {
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
    NSString *dest = [[backupRoot stringByAppendingPathComponent:side] stringByAppendingPathComponent:relative];
    NSString *parent = dest.stringByDeletingLastPathComponent;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    return [[NSFileManager defaultManager] copyItemAtPath:path toPath:dest error:error];
}

- (void)resolveFromRoot:(NSString *)sourceRoot toRoot:(NSString *)destRoot sourceLabel:(NSString *)sourceLabel destLabel:(NSString *)destLabel {
    NSArray<NSDictionary *> *selected = [self selectedConflicts];
    if (!selected.count) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *plans = [NSMutableArray arrayWithCapacity:selected.count];

    // 第一阶段只校验，不改任何文件。批量里只要有一项不安全，就整批拒绝。
    for (NSDictionary *item in selected) {
        NSString *relative = [item[@"path"] isKindOfClass:[NSString class]] ? item[@"path"] : @"";
        NSString *source = [self safeFullPathForRoot:sourceRoot relative:relative];
        NSString *dest = [self safeFullPathForRoot:destRoot relative:relative];
        if (!source.length || !dest.length) {
            [self showMessage:@"路径不安全，整批未处理" info:relative];
            return;
        }
        BOOL sourceIsDir = NO;
        if (![fm fileExistsAtPath:source isDirectory:&sourceIsDir] || sourceIsDir) {
            [self showMessage:@"批量中包含暂不能自动裁决的项目，整批未处理"
                          info:[NSString stringWithFormat:@"当前版本只自动处理双方都存在的文件内容冲突。删除冲突或目录冲突会继续冻结。\n\n%@", relative]];
            return;
        }
        BOOL destIsDir = NO;
        if ([fm fileExistsAtPath:dest isDirectory:&destIsDir] && destIsDir) {
            [self showMessage:@"批量中包含目录目标，整批未处理" info:relative];
            return;
        }
        [plans addObject:@{ @"relative": relative, @"source": source, @"dest": dest }];
    }

    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.alertStyle = NSAlertStyleWarning;
    confirm.messageText = plans.count > 1
        ? [NSString stringWithFormat:@"将 %lu 项都以 %@ 版本为准？", (unsigned long)plans.count, sourceLabel]
        : [NSString stringWithFormat:@"以 %@ 版本为准？", sourceLabel];
    confirm.informativeText = plans.count > 1
        ? [NSString stringWithFormat:@"所选 %lu 项中，%@ 的当前内容都会被 %@ 覆盖。覆盖前会先把全部双方版本保存到同一份 conflict-backups；全部处理后只重新运行一次 Unison。",
            (unsigned long)plans.count, destLabel, sourceLabel]
        : [NSString stringWithFormat:@"%@ 的当前内容会被 %@ 覆盖。覆盖前会把双方版本保存到独立的 conflict-backups。\n\n%@",
            destLabel, sourceLabel, plans.firstObject[@"relative"]];
    [confirm addButtonWithTitle:@"取消"];
    [confirm addButtonWithTitle:plans.count > 1 ? @"确认批量处理" : @"确认处理"];
    [NSApp activateIgnoringOtherApps:YES];
    if ([confirm runModal] != NSAlertSecondButtonReturn) return;

    NSString *backupRoot = [[[self.conflictURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"conflict-backups" isDirectory:YES].path stringByAppendingPathComponent:[self timestampComponent]];
    NSError *error = nil;

    // 第二阶段先把整批双方版本完整备份。备份失败时一个目标文件都不覆盖。
    for (NSDictionary *plan in plans) {
        NSString *relative = plan[@"relative"];
        if (![self backupPath:plan[@"source"] relative:relative under:backupRoot side:@"chosen" error:&error] ||
            ![self backupPath:plan[@"dest"] relative:relative under:backupRoot side:@"replaced" error:&error]) {
            [self showMessage:@"批量备份失败，未执行任何覆盖" info:error.localizedDescription ?: backupRoot];
            return;
        }
    }

    // 第三阶段从刚保存的 chosen 快照读取，保证整批使用确认时的源版本。
    NSUInteger completed = 0;
    for (NSDictionary *plan in plans) {
        NSString *relative = plan[@"relative"];
        NSString *snapshot = [[backupRoot stringByAppendingPathComponent:@"chosen"] stringByAppendingPathComponent:relative];
        NSData *data = [NSData dataWithContentsOfFile:snapshot options:NSDataReadingMappedIfSafe error:&error];
        if (!data) {
            [self showMessage:@"读取批量备份失败"
                          info:[NSString stringWithFormat:@"已完成 %lu / %lu 项。其余项目未继续处理。\n\n%@",
                                (unsigned long)completed, (unsigned long)plans.count, error.localizedDescription ?: snapshot]];
            return;
        }

        NSString *dest = plan[@"dest"];
        NSString *parent = dest.stringByDeletingLastPathComponent;
        if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:&error]) {
            [self showMessage:@"无法创建目标目录"
                          info:[NSString stringWithFormat:@"已完成 %lu / %lu 项。\n\n%@",
                                (unsigned long)completed, (unsigned long)plans.count, error.localizedDescription ?: parent]];
            return;
        }

        if ([fm fileExistsAtPath:dest]) {
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:dest];
            if (!handle) {
                [self showMessage:@"无法写入目标文件"
                              info:[NSString stringWithFormat:@"已完成 %lu / %lu 项。\n\n%@",
                                    (unsigned long)completed, (unsigned long)plans.count, dest]];
                return;
            }
            @try {
                [handle truncateFileAtOffset:0];
                [handle writeData:data];
                [handle closeFile];
            } @catch (NSException *exception) {
                @try { [handle closeFile]; } @catch (__unused NSException *ignored) {}
                [self showMessage:@"写入目标文件失败"
                              info:[NSString stringWithFormat:@"已完成 %lu / %lu 项。\n\n%@",
                                    (unsigned long)completed, (unsigned long)plans.count, exception.reason ?: dest]];
                return;
            }
        } else if (![fm createFileAtPath:dest contents:data attributes:nil]) {
            [self showMessage:@"创建目标文件失败"
                          info:[NSString stringWithFormat:@"已完成 %lu / %lu 项。\n\n%@",
                                (unsigned long)completed, (unsigned long)plans.count, dest]];
            return;
        }
        completed++;
    }

    self.detailLabel.stringValue = plans.count > 1
        ? [NSString stringWithFormat:@"已将 %lu 项统一以 %@ 为准；双方原版本已备份。正在重新运行一次 Unison…\n备份：%@",
            (unsigned long)plans.count, sourceLabel, backupRoot]
        : [NSString stringWithFormat:@"已以 %@ 为准；双方原版本已备份。正在重新运行 Unison…\n备份：%@", sourceLabel, backupRoot];

    if (self.syncHandler) self.syncHandler();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self loadDocument];
    });
}

- (void)resolveLeft:(id)sender {
    [self resolveFromRoot:self.leftRoot toRoot:self.rightRoot sourceLabel:[self labelForRoot:self.leftRoot] destLabel:[self labelForRoot:self.rightRoot]];
}

- (void)resolveRight:(id)sender {
    [self resolveFromRoot:self.rightRoot toRoot:self.leftRoot sourceLabel:[self labelForRoot:self.rightRoot] destLabel:[self labelForRoot:self.leftRoot]];
}

@end
