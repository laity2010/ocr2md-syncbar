#import "ExclusionEditor.h"

@interface OCR2MDExclusionEditor () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSTableView *table;
@property(nonatomic,strong) NSMutableArray<NSString *> *items;
@property(nonatomic,copy) NSString *rootPath;
@property(nonatomic,copy) void (^saveHandler)(NSArray<NSString *> *items);
@end

@implementation OCR2MDExclusionEditor

- (instancetype)initWithRootPath:(NSString *)rootPath items:(NSArray<NSString *> *)items saveHandler:(void (^)(NSArray<NSString *> *))saveHandler {
    self = [super init];
    if (self) {
        _rootPath = [rootPath copy] ?: @"";
        _items = items ? [items mutableCopy] : [NSMutableArray array];
        _saveHandler = [saveHandler copy];
    }
    return self;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)self.items.count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSTextField *field = [tableView makeViewWithIdentifier:@"excludeCell" owner:self];
    if (!field) {
        field = [NSTextField labelWithString:@""];
        field.identifier = @"excludeCell";
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    NSString *value = self.items[(NSUInteger)row];
    field.stringValue = value;
    field.toolTip = value;
    return field;
}

- (NSString *)relativePathForURL:(NSURL *)url {
    NSString *root = [self.rootPath stringByStandardizingPath];
    NSString *path = [url.path stringByStandardizingPath];
    if (!root.length || !path.length || [path isEqualToString:root]) return nil;
    NSString *prefix = [root stringByAppendingString:@"/"];
    if (![path hasPrefix:prefix]) return nil;
    NSString *relative = [path substringFromIndex:prefix.length];
    if (!relative.length || [relative isEqualToString:@"."] || [relative hasPrefix:@"../"] ||
        [relative containsString:@"\n"] || [relative containsString:@"\r"]) return nil;
    return relative;
}

- (void)showInvalidSelection:(NSString *)path {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"只能排除当前同步目录内部的项目";
    alert.informativeText = path ?: @"";
    [alert addButtonWithTitle:@"好"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (NSArray<NSString *> *)chooseItems:(NSString *)title multiple:(BOOL)multiple {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = title;
    panel.message = @"选择当前同步目录内部的文件或文件夹。排除不会删除文件，只会停止同步这个项目。";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = multiple;
    panel.canCreateDirectories = NO;
    panel.prompt = @"选择";
    if (self.rootPath.length) panel.directoryURL = [NSURL fileURLWithPath:self.rootPath isDirectory:YES];
    [NSApp activateIgnoringOtherApps:YES];
    if ([panel runModal] != NSModalResponseOK) return @[];

    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSURL *url in panel.URLs) {
        NSString *relative = [self relativePathForURL:url];
        if (!relative) {
            [self showInvalidSelection:url.path];
            continue;
        }
        [result addObject:relative];
    }
    return result;
}

- (void)saveAndReload {
    [self.items sortUsingSelector:@selector(localizedStandardCompare:)];
    if (self.saveHandler) self.saveHandler([self.items copy]);
    [self.table reloadData];
}

- (void)addItem:(id)sender {
    for (NSString *relative in [self chooseItems:@"添加排除项" multiple:YES]) {
        if (![self.items containsObject:relative]) [self.items addObject:relative];
    }
    [self saveAndReload];
}

- (void)removeItem:(id)sender {
    NSInteger row = self.table.selectedRow;
    if (row < 0 || row >= (NSInteger)self.items.count) return;
    [self.items removeObjectAtIndex:(NSUInteger)row];
    [self saveAndReload];
    if (self.items.count) {
        NSInteger next = MIN(row, (NSInteger)self.items.count - 1);
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)next] byExtendingSelection:NO];
    }
}

- (void)changeItem:(id)sender {
    NSInteger row = self.table.selectedRow;
    if (row < 0 || row >= (NSInteger)self.items.count) return;
    NSString *relative = [self chooseItems:@"更改排除项" multiple:NO].firstObject;
    if (!relative.length) return;
    NSUInteger duplicate = [self.items indexOfObject:relative];
    if (duplicate != NSNotFound && duplicate != (NSUInteger)row) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"这个排除项已经存在";
        alert.informativeText = relative;
        [alert addButtonWithTitle:@"好"];
        [NSApp activateIgnoringOtherApps:YES];
        [alert runModal];
        return;
    }
    self.items[(NSUInteger)row] = relative;
    [self saveAndReload];
}

- (void)done:(id)sender {
    [NSApp stopModalWithCode:NSModalResponseOK];
    [self.window orderOut:nil];
}

- (void)windowWillClose:(NSNotification *)notification {
    if (NSApp.modalWindow == self.window) [NSApp stopModalWithCode:NSModalResponseCancel];
}

- (void)runModal {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 430)
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"管理排除列表";
    self.window.minSize = NSMakeSize(560, 340);
    self.window.delegate = self;
    [self.window center];

    NSView *content = self.window.contentView;
    NSTextField *rootLabel = [NSTextField wrappingLabelWithString:[NSString stringWithFormat:@"同步目录：%@", self.rootPath ?: @""]];
    rootLabel.translatesAutoresizingMaskIntoConstraints = NO;
    rootLabel.textColor = [NSColor secondaryLabelColor];
    [content addSubview:rootLabel];

    NSTextField *hint = [NSTextField wrappingLabelWithString:@"列表使用相对路径。加入排除不会删除现有文件。系统级安全排除（如 .obsidian-*、config-sync）始终另外生效。"];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.textColor = [NSColor secondaryLabelColor];
    hint.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    [content addSubview:hint];

    self.table = [[NSTableView alloc] init];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"exclude"];
    column.title = @"排除的相对路径";
    column.resizingMask = NSTableColumnAutoresizingMask;
    [self.table addTableColumn:column];
    self.table.delegate = self;
    self.table.dataSource = self;
    self.table.rowHeight = 28;
    self.table.allowsMultipleSelection = NO;

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = self.table;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES;
    scroll.borderType = NSBezelBorder;
    [content addSubview:scroll];

    NSButton *add = [NSButton buttonWithTitle:@"添加…" target:self action:@selector(addItem:)];
    NSButton *remove = [NSButton buttonWithTitle:@"移除" target:self action:@selector(removeItem:)];
    NSButton *change = [NSButton buttonWithTitle:@"更改…" target:self action:@selector(changeItem:)];
    NSButton *done = [NSButton buttonWithTitle:@"完成" target:self action:@selector(done:)];
    for (NSButton *button in @[add, remove, change, done]) {
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.bezelStyle = NSBezelStyleRounded;
        [content addSubview:button];
    }

    [NSLayoutConstraint activateConstraints:@[
        [rootLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [rootLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [rootLabel.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [hint.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [hint.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [hint.topAnchor constraintEqualToAnchor:rootLabel.bottomAnchor constant:8],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [scroll.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:12],
        [scroll.bottomAnchor constraintEqualToAnchor:add.topAnchor constant:-12],
        [add.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [add.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
        [remove.leadingAnchor constraintEqualToAnchor:add.trailingAnchor constant:8],
        [remove.centerYAnchor constraintEqualToAnchor:add.centerYAnchor],
        [change.leadingAnchor constraintEqualToAnchor:remove.trailingAnchor constant:8],
        [change.centerYAnchor constraintEqualToAnchor:add.centerYAnchor],
        [done.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [done.centerYAnchor constraintEqualToAnchor:add.centerYAnchor]
    ]];

    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp runModalForWindow:self.window];
}

@end
