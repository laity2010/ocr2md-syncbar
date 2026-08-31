#import "SyncGroupManager.h"
#import "ExclusionEditor.h"

@interface OCR2MDSyncGroupManager () <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate>
@property(nonatomic,strong) NSURL *configURL;
@property(nonatomic,strong) NSURL *legacyProfileURL;
@property(nonatomic,strong) NSMutableArray<NSMutableDictionary *> *groups;
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSTableView *groupsTable;
@property(nonatomic,strong) NSTableView *directoriesTable;
@property(nonatomic,strong) NSTextField *groupNameField;
@property(nonatomic,strong) NSButton *groupEnabledButton;
@property(nonatomic,strong) NSTextField *summaryLabel;
@property(nonatomic,strong) NSButton *removeGroupButton;
@property(nonatomic,strong) NSButton *addDirectoryButton;
@property(nonatomic,strong) NSButton *removeDirectoryButton;
@property(nonatomic,strong) NSButton *changeDirectoryButton;
@property(nonatomic,strong) NSMutableDictionary<NSString *, NSString *> *fileCounts;
@property(nonatomic,strong) NSMutableSet<NSString *> *fileCountLoading;
@property(nonatomic,strong) OCR2MDExclusionEditor *exclusionEditor;
@end

@implementation OCR2MDSyncGroupManager

- (instancetype)initWithConfigURL:(NSURL *)configURL legacyProfileURL:(NSURL *)legacyProfileURL {
    self = [super init];
    if (self) {
        _configURL = configURL;
        _legacyProfileURL = legacyProfileURL;
        _fileCounts = [NSMutableDictionary dictionary];
        _fileCountLoading = [NSMutableSet set];
        [self loadConfig];
    }
    return self;
}

- (NSMutableDictionary *)newDirectoryWithPath:(NSString *)path {
    return [@{
        @"id": [NSUUID UUID].UUIDString,
        @"path": path ?: @"",
        @"excludes": [NSMutableArray array]
    } mutableCopy];
}

- (NSMutableDictionary *)newGroupNamed:(NSString *)name {
    return [@{
        @"id": [NSUUID UUID].UUIDString,
        @"name": name ?: @"新同步组",
        @"enabled": @YES,
        @"directories": [NSMutableArray array]
    } mutableCopy];
}

- (NSArray<NSString *> *)rootsFromLegacyProfile {
    NSString *text = [NSString stringWithContentsOfURL:self.legacyProfileURL encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return @[];
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![line hasPrefix:@"root = "]) continue;
        NSString *root = [[line substringFromIndex:7] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (root.length) [roots addObject:root];
        if (roots.count == 2) break;
    }
    return roots;
}

- (void)migrateGroupToDirectoryModel:(NSMutableDictionary *)group {
    id existing = group[@"directories"];
    if ([existing isKindOfClass:[NSArray class]]) {
        if (![existing isKindOfClass:[NSMutableArray class]]) group[@"directories"] = [(NSArray *)existing mutableCopy];
        NSMutableArray *directories = group[@"directories"];
        for (NSUInteger i = 0; i < directories.count; i++) {
            id rawDirectory = directories[i];
            NSMutableDictionary *directory = [rawDirectory isKindOfClass:[NSMutableDictionary class]] ? rawDirectory : [rawDirectory mutableCopy];
            if (!directory) continue;
            directories[i] = directory;
            id excludes = directory[@"excludes"];
            if (![excludes isKindOfClass:[NSArray class]]) directory[@"excludes"] = [NSMutableArray array];
            else if (![excludes isKindOfClass:[NSMutableArray class]]) directory[@"excludes"] = [(NSArray *)excludes mutableCopy];
        }
        return;
    }

    NSMutableArray *directories = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    id pairs = group[@"pairs"];
    if ([pairs isKindOfClass:[NSArray class]]) {
        for (NSDictionary *pair in (NSArray *)pairs) {
            for (NSString *key in @[@"source", @"target"]) {
                NSString *path = [pair[key] isKindOfClass:[NSString class]] ? pair[key] : @"";
                if (!path.length || [seen containsObject:path]) continue;
                [seen addObject:path];
                [directories addObject:[self newDirectoryWithPath:path]];
            }
        }
    }
    group[@"directories"] = directories;
    [group removeObjectForKey:@"pairs"];
}

- (void)loadConfig {
    BOOL needsSave = NO;
    NSData *data = [NSData dataWithContentsOfURL:self.configURL];
    if (data.length) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
        if ([obj isKindOfClass:[NSDictionary class]]) {
            id rawGroups = ((NSDictionary *)obj)[@"groups"];
            if ([rawGroups isKindOfClass:[NSArray class]]) {
                self.groups = [(NSArray *)rawGroups mutableCopy];
                for (NSUInteger i = 0; i < self.groups.count; i++) {
                    id rawGroup = self.groups[i];
                    if (![rawGroup isKindOfClass:[NSMutableDictionary class]]) {
                        rawGroup = [rawGroup mutableCopy];
                        self.groups[i] = rawGroup;
                    }
                    NSMutableDictionary *group = rawGroup;
                    if (!group[@"directories"]) needsSave = YES;
                    NSArray *beforeDirectories = [group[@"directories"] isKindOfClass:[NSArray class]] ? group[@"directories"] : @[];
                    for (NSDictionary *directory in beforeDirectories) {
                        if (![directory[@"excludes"] isKindOfClass:[NSArray class]]) needsSave = YES;
                    }
                    [self migrateGroupToDirectoryModel:group];
                }
                NSNumber *version = ((NSDictionary *)obj)[@"version"];
                if (version.integerValue != 2) needsSave = YES;
                if (needsSave) [self saveConfig];
                return;
            }
        }
    }

    self.groups = [NSMutableArray array];
    NSMutableDictionary *legacy = [self newGroupNamed:@"ocr2md"];
    NSArray<NSString *> *roots = [self rootsFromLegacyProfile];
    if (roots.count == 2) {
        NSMutableArray *directories = legacy[@"directories"];
        [directories addObject:[self newDirectoryWithPath:roots[0]]];
        [directories addObject:[self newDirectoryWithPath:roots[1]]];
        legacy[@"legacyProfile"] = @"ocr2md";
    }
    [self.groups addObject:legacy];
    [self saveConfig];
}

- (void)saveConfig {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtURL:[self.configURL URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *document = @{ @"version": @2, @"groups": self.groups ?: @[] };
    NSData *data = [NSJSONSerialization dataWithJSONObject:document options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys) error:nil];
    if (data.length) [data writeToURL:self.configURL atomically:YES];
}

- (void)logUIEvent:(NSString *)event {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], event ?: @""];
    NSURL *logURL = [[self.configURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"sync-groups-ui.log"];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logURL.path];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:logURL.path contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:logURL.path];
    }
    [handle seekToEndOfFile];
    [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

- (void)showWindow {
    [self logUIEvent:@"showWindow"];
    if (!self.window) [self buildWindow];
    [self.groupsTable reloadData];
    if (self.groups.count && self.groupsTable.selectedRow < 0) {
        [self.groupsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }
    [self refreshSelectionUI];
    [self refreshFileCounts];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
}

- (NSTextField *)label:(NSString *)text bold:(BOOL)bold {
    NSTextField *label = [NSTextField labelWithString:text];
    if (bold) label.font = [NSFont systemFontOfSize:[NSFont systemFontSize] weight:NSFontWeightSemibold];
    return label;
}

- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1120, 560)
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"Unison 同步目录组";
    self.window.minSize = NSMakeSize(920, 460);
    self.window.delegate = self;
    [self.window center];

    NSView *content = self.window.contentView;
    NSView *left = [[NSView alloc] init];
    NSView *right = [[NSView alloc] init];
    left.translatesAutoresizingMaskIntoConstraints = NO;
    right.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:left];
    [content addSubview:right];

    NSTextField *groupsTitle = [self label:@"同步目录组" bold:YES];
    groupsTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [left addSubview:groupsTitle];

    self.groupsTable = [[NSTableView alloc] init];
    NSTableColumn *groupColumn = [[NSTableColumn alloc] initWithIdentifier:@"group"];
    groupColumn.title = @"组";
    groupColumn.resizingMask = NSTableColumnAutoresizingMask;
    [self.groupsTable addTableColumn:groupColumn];
    self.groupsTable.headerView = nil;
    self.groupsTable.dataSource = self;
    self.groupsTable.delegate = self;
    self.groupsTable.rowHeight = 30;
    self.groupsTable.allowsMultipleSelection = NO;

    NSScrollView *groupsScroll = [[NSScrollView alloc] init];
    groupsScroll.translatesAutoresizingMaskIntoConstraints = NO;
    groupsScroll.documentView = self.groupsTable;
    groupsScroll.hasVerticalScroller = YES;
    groupsScroll.borderType = NSBezelBorder;
    [left addSubview:groupsScroll];

    NSButton *addGroupButton = [self button:@"＋" action:@selector(addGroup:)];
    self.removeGroupButton = [self button:@"－" action:@selector(removeGroup:)];
    addGroupButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.removeGroupButton.translatesAutoresizingMaskIntoConstraints = NO;
    [left addSubview:addGroupButton];
    [left addSubview:self.removeGroupButton];

    NSTextField *nameLabel = [self label:@"组名称" bold:NO];
    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.groupNameField = [[NSTextField alloc] init];
    self.groupNameField.translatesAutoresizingMaskIntoConstraints = NO;
    self.groupNameField.target = self;
    self.groupNameField.action = @selector(groupNameChanged:);
    self.groupNameField.delegate = self;

    self.groupEnabledButton = [NSButton checkboxWithTitle:@"启用此组" target:self action:@selector(groupEnabledChanged:)];
    self.groupEnabledButton.translatesAutoresizingMaskIntoConstraints = NO;
    [right addSubview:nameLabel];
    [right addSubview:self.groupNameField];
    [right addSubview:self.groupEnabledButton];

    NSTextField *directoriesTitle = [self label:@"组内目录（保持同步）" bold:YES];
    directoriesTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [right addSubview:directoriesTitle];

    self.directoriesTable = [[NSTableView alloc] init];
    NSTableColumn *directoryColumn = [[NSTableColumn alloc] initWithIdentifier:@"directory"];
    directoryColumn.title = @"目录";
    directoryColumn.width = 500;
    directoryColumn.minWidth = 260;
    directoryColumn.resizingMask = NSTableColumnAutoresizingMask;
    [self.directoriesTable addTableColumn:directoryColumn];

    NSTableColumn *fileCountColumn = [[NSTableColumn alloc] initWithIdentifier:@"fileCount"];
    fileCountColumn.title = @"文件数";
    fileCountColumn.width = 82;
    fileCountColumn.minWidth = 72;
    fileCountColumn.maxWidth = 110;
    [self.directoriesTable addTableColumn:fileCountColumn];

    NSTableColumn *syncTypeColumn = [[NSTableColumn alloc] initWithIdentifier:@"syncType"];
    syncTypeColumn.title = @"同步类型";
    syncTypeColumn.width = 92;
    syncTypeColumn.minWidth = 82;
    syncTypeColumn.maxWidth = 120;
    [self.directoriesTable addTableColumn:syncTypeColumn];

    NSTableColumn *excludeColumn = [[NSTableColumn alloc] initWithIdentifier:@"exclude"];
    excludeColumn.title = @"排除";
    excludeColumn.width = 112;
    excludeColumn.minWidth = 100;
    excludeColumn.maxWidth = 145;
    [self.directoriesTable addTableColumn:excludeColumn];
    self.directoriesTable.dataSource = self;
    self.directoriesTable.delegate = self;
    self.directoriesTable.rowHeight = 30;
    self.directoriesTable.allowsMultipleSelection = NO;

    NSScrollView *directoriesScroll = [[NSScrollView alloc] init];
    directoriesScroll.translatesAutoresizingMaskIntoConstraints = NO;
    directoriesScroll.documentView = self.directoriesTable;
    directoriesScroll.hasVerticalScroller = YES;
    directoriesScroll.hasHorizontalScroller = YES;
    directoriesScroll.borderType = NSBezelBorder;
    [right addSubview:directoriesScroll];

    self.addDirectoryButton = [self button:@"添加目录…" action:@selector(addDirectory:)];
    self.removeDirectoryButton = [self button:@"移出目录…" action:@selector(removeDirectory:)];
    self.changeDirectoryButton = [self button:@"更改目录…" action:@selector(changeDirectory:)];
    for (NSButton *button in @[self.addDirectoryButton, self.removeDirectoryButton, self.changeDirectoryButton]) {
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [right addSubview:button];
    }

    self.summaryLabel = [NSTextField labelWithString:@""];
    self.summaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.summaryLabel.textColor = [NSColor secondaryLabelColor];
    [right addSubview:self.summaryLabel];

    NSTextField *hint = [NSTextField wrappingLabelWithString:@"同一组中的目录自动保持一致。每个目录可设置自己的排除列表；配置保存后会在下一轮同步生效。系统级安全排除始终保留。"];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.textColor = [NSColor secondaryLabelColor];
    hint.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
    [right addSubview:hint];

    [NSLayoutConstraint activateConstraints:@[
        [left.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:16],
        [left.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [left.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
        [left.widthAnchor constraintEqualToConstant:220],

        [right.leadingAnchor constraintEqualToAnchor:left.trailingAnchor constant:18],
        [right.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-16],
        [right.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
        [right.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],

        [groupsTitle.leadingAnchor constraintEqualToAnchor:left.leadingAnchor],
        [groupsTitle.topAnchor constraintEqualToAnchor:left.topAnchor],
        [groupsScroll.leadingAnchor constraintEqualToAnchor:left.leadingAnchor],
        [groupsScroll.trailingAnchor constraintEqualToAnchor:left.trailingAnchor],
        [groupsScroll.topAnchor constraintEqualToAnchor:groupsTitle.bottomAnchor constant:8],
        [groupsScroll.bottomAnchor constraintEqualToAnchor:addGroupButton.topAnchor constant:-8],
        [addGroupButton.leadingAnchor constraintEqualToAnchor:left.leadingAnchor],
        [addGroupButton.bottomAnchor constraintEqualToAnchor:left.bottomAnchor],
        [addGroupButton.widthAnchor constraintEqualToConstant:44],
        [self.removeGroupButton.leadingAnchor constraintEqualToAnchor:addGroupButton.trailingAnchor constant:6],
        [self.removeGroupButton.bottomAnchor constraintEqualToAnchor:left.bottomAnchor],
        [self.removeGroupButton.widthAnchor constraintEqualToConstant:44],

        [nameLabel.leadingAnchor constraintEqualToAnchor:right.leadingAnchor],
        [nameLabel.centerYAnchor constraintEqualToAnchor:self.groupNameField.centerYAnchor],
        [nameLabel.widthAnchor constraintEqualToConstant:52],
        [self.groupNameField.leadingAnchor constraintEqualToAnchor:nameLabel.trailingAnchor constant:8],
        [self.groupNameField.topAnchor constraintEqualToAnchor:right.topAnchor],
        [self.groupEnabledButton.leadingAnchor constraintEqualToAnchor:self.groupNameField.trailingAnchor constant:12],
        [self.groupEnabledButton.trailingAnchor constraintEqualToAnchor:right.trailingAnchor],
        [self.groupEnabledButton.centerYAnchor constraintEqualToAnchor:self.groupNameField.centerYAnchor],
        [self.groupEnabledButton.widthAnchor constraintEqualToConstant:90],

        [directoriesTitle.leadingAnchor constraintEqualToAnchor:right.leadingAnchor],
        [directoriesTitle.topAnchor constraintEqualToAnchor:self.groupNameField.bottomAnchor constant:18],
        [directoriesScroll.leadingAnchor constraintEqualToAnchor:right.leadingAnchor],
        [directoriesScroll.trailingAnchor constraintEqualToAnchor:right.trailingAnchor],
        [directoriesScroll.topAnchor constraintEqualToAnchor:directoriesTitle.bottomAnchor constant:8],
        [directoriesScroll.bottomAnchor constraintEqualToAnchor:self.addDirectoryButton.topAnchor constant:-10],

        [self.addDirectoryButton.leadingAnchor constraintEqualToAnchor:right.leadingAnchor],
        [self.removeDirectoryButton.leadingAnchor constraintEqualToAnchor:self.addDirectoryButton.trailingAnchor constant:8],
        [self.removeDirectoryButton.centerYAnchor constraintEqualToAnchor:self.addDirectoryButton.centerYAnchor],
        [self.changeDirectoryButton.leadingAnchor constraintEqualToAnchor:self.removeDirectoryButton.trailingAnchor constant:8],
        [self.changeDirectoryButton.centerYAnchor constraintEqualToAnchor:self.addDirectoryButton.centerYAnchor],

        [self.summaryLabel.leadingAnchor constraintEqualToAnchor:right.leadingAnchor],
        [self.summaryLabel.trailingAnchor constraintEqualToAnchor:right.trailingAnchor],
        [self.summaryLabel.topAnchor constraintEqualToAnchor:self.addDirectoryButton.bottomAnchor constant:10],

        [hint.leadingAnchor constraintEqualToAnchor:right.leadingAnchor],
        [hint.trailingAnchor constraintEqualToAnchor:right.trailingAnchor],
        [hint.topAnchor constraintEqualToAnchor:self.summaryLabel.bottomAnchor constant:8],
        [hint.bottomAnchor constraintLessThanOrEqualToAnchor:right.bottomAnchor]
    ]];
}

- (void)refreshFileCounts {
    [self.fileCounts removeAllObjects];
    [self.fileCountLoading removeAllObjects];
    for (NSDictionary *directory in [self selectedDirectories]) {
        NSString *path = [directory[@"path"] isKindOfClass:[NSString class]] ? directory[@"path"] : @"";
        if (path.length) [self requestFileCountForPath:path];
    }
}

- (void)requestFileCountForPath:(NSString *)path {
    if (!path.length || self.fileCounts[path] || [self.fileCountLoading containsObject:path]) return;
    [self.fileCountLoading addObject:path];
    self.fileCounts[path] = @"…";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fm = [[NSFileManager alloc] init];
        NSURL *root = [NSURL fileURLWithPath:path isDirectory:YES];
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:root
                                    includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                       options:NSDirectoryEnumerationSkipsPackageDescendants
                                                  errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
        NSUInteger count = 0;
        for (NSURL *url in enumerator) {
            NSNumber *regular = nil;
            [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            if (regular.boolValue) count++;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.fileCountLoading removeObject:path];
            strongSelf.fileCounts[path] = [NSNumberFormatter localizedStringFromNumber:@(count) numberStyle:NSNumberFormatterDecimalStyle];
            [strongSelf.directoriesTable reloadData];
        });
    });
}

- (NSArray<NSString *> *)excludesForDirectory:(NSDictionary *)directory {
    id excludes = directory[@"excludes"];
    return [excludes isKindOfClass:[NSArray class]] ? excludes : @[];
}

- (void)manageExclusionsFromButton:(NSButton *)sender {
    NSInteger row = sender.tag;
    NSMutableArray *directories = [self selectedDirectories];
    if (row < 0 || row >= (NSInteger)directories.count) return;
    [self.directoriesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    NSMutableDictionary *directory = directories[(NSUInteger)row];
    NSString *path = [directory[@"path"] isKindOfClass:[NSString class]] ? directory[@"path"] : @"";
    NSArray *items = [self excludesForDirectory:directory];
    __weak typeof(self) weakSelf = self;
    self.exclusionEditor = [[OCR2MDExclusionEditor alloc] initWithRootPath:path items:items saveHandler:^(NSArray<NSString *> *newItems) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        directory[@"excludes"] = [newItems mutableCopy];
        [strongSelf saveConfig];
        [strongSelf.directoriesTable reloadData];
        [strongSelf refreshSelectionUI];
    }];
    [self.exclusionEditor runModal];
    self.exclusionEditor = nil;
}

- (NSMutableDictionary *)selectedGroup {
    NSInteger row = self.groupsTable.selectedRow;
    if ((row < 0 || row >= (NSInteger)self.groups.count) && self.groups.count > 0) {
        row = 0;
        if (self.groupsTable) {
            [self.groupsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        }
    }
    if (row < 0 || row >= (NSInteger)self.groups.count) return nil;
    return self.groups[(NSUInteger)row];
}

- (NSMutableArray *)selectedDirectories {
    NSMutableDictionary *group = [self selectedGroup];
    id directories = group[@"directories"];
    return [directories isKindOfClass:[NSMutableArray class]] ? directories : nil;
}

- (NSMutableDictionary *)selectedDirectory {
    NSMutableArray *directories = [self selectedDirectories];
    NSInteger row = self.directoriesTable.selectedRow;
    if (row < 0 || row >= (NSInteger)directories.count) return nil;
    return directories[(NSUInteger)row];
}

- (void)updateDirectoryActionState {
    BOOL hasAnyDirectory = [self selectedDirectories].count > 0;
    self.removeDirectoryButton.enabled = hasAnyDirectory;
    self.changeDirectoryButton.enabled = hasAnyDirectory;
}

- (void)refreshSelectionUI {
    NSMutableDictionary *group = [self selectedGroup];
    BOOL hasGroup = group != nil;
    self.groupNameField.enabled = hasGroup;
    self.groupEnabledButton.enabled = hasGroup;
    self.removeGroupButton.enabled = hasGroup;
    self.addDirectoryButton.enabled = hasGroup;

    if (hasGroup) {
        self.groupNameField.stringValue = group[@"name"] ?: @"";
        self.groupEnabledButton.state = [group[@"enabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    } else {
        self.groupNameField.stringValue = @"";
        self.groupEnabledButton.state = NSControlStateValueOff;
    }

    [self updateDirectoryActionState];

    NSUInteger count = [self selectedDirectories].count;
    if (!hasGroup) {
        self.summaryLabel.stringValue = @"未选择同步组";
    } else if (count < 2) {
        self.summaryLabel.stringValue = [NSString stringWithFormat:@"%@ · %lu 个目录 · 至少需要 2 个目录", [group[@"enabled"] boolValue] ? @"已启用" : @"已停用", (unsigned long)count];
    } else {
        self.summaryLabel.stringValue = [NSString stringWithFormat:@"%@ · %lu 个目录 · 组内互相同步 · 自动保存", [group[@"enabled"] boolValue] ? @"已启用" : @"已停用", (unsigned long)count];
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.groupsTable) return (NSInteger)self.groups.count;
    if (tableView == self.directoriesTable) return (NSInteger)[self selectedDirectories].count;
    return 0;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView == self.groupsTable) {
        NSTextField *field = [tableView makeViewWithIdentifier:@"groupCell" owner:self];
        if (!field) {
            field = [NSTextField labelWithString:@""];
            field.identifier = @"groupCell";
            field.lineBreakMode = NSLineBreakByTruncatingMiddle;
        }
        NSDictionary *group = self.groups[(NSUInteger)row];
        BOOL enabled = [group[@"enabled"] boolValue];
        NSUInteger count = [group[@"directories"] isKindOfClass:[NSArray class]] ? [group[@"directories"] count] : 0;
        field.stringValue = [NSString stringWithFormat:@"%@%@  (%lu)", enabled ? @"● " : @"○ ", group[@"name"] ?: @"未命名", (unsigned long)count];
        field.textColor = enabled ? [NSColor labelColor] : [NSColor secondaryLabelColor];
        field.toolTip = field.stringValue;
        return field;
    }

    NSDictionary *directory = [self selectedDirectories][(NSUInteger)row];
    NSString *path = [directory[@"path"] isKindOfClass:[NSString class]] ? directory[@"path"] : @"";
    NSArray *excludes = [self excludesForDirectory:directory];
    NSString *identifier = tableColumn.identifier;

    if ([identifier isEqualToString:@"exclude"]) {
        NSButton *button = [tableView makeViewWithIdentifier:@"excludeButton" owner:self];
        if (!button) {
            button = [NSButton buttonWithTitle:@"管理…" target:self action:@selector(manageExclusionsFromButton:)];
            button.identifier = @"excludeButton";
            button.bezelStyle = NSBezelStyleRounded;
            button.controlSize = NSControlSizeSmall;
        }
        button.target = self;
        button.action = @selector(manageExclusionsFromButton:);
        button.tag = row;
        button.title = excludes.count ? [NSString stringWithFormat:@"管理… (%lu)", (unsigned long)excludes.count] : @"管理…";
        button.toolTip = excludes.count ? [NSString stringWithFormat:@"%lu 个自定义排除项", (unsigned long)excludes.count] : @"管理这个目录的排除列表";
        return button;
    }

    NSString *cellID = [NSString stringWithFormat:@"%@Cell", identifier ?: @"directory"];
    NSTextField *field = [tableView makeViewWithIdentifier:cellID owner:self];
    if (!field) {
        field = [NSTextField labelWithString:@""];
        field.identifier = cellID;
        field.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    field.textColor = [NSColor labelColor];
    if ([identifier isEqualToString:@"fileCount"]) {
        if (!self.fileCounts[path]) [self requestFileCountForPath:path];
        field.stringValue = self.fileCounts[path] ?: @"…";
        field.alignment = NSTextAlignmentRight;
        field.toolTip = @"目录中的实际文件数（异步统计）";
    } else if ([identifier isEqualToString:@"syncType"]) {
        field.stringValue = excludes.count ? @"有排除" : @"镜像";
        field.alignment = NSTextAlignmentCenter;
        field.toolTip = excludes.count ? @"此目录有自定义排除项" : @"此目录没有自定义排除项";
    } else {
        field.stringValue = path;
        field.alignment = NSTextAlignmentLeft;
        field.toolTip = path;
    }
    return field;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object == self.groupsTable) {
        [self.directoriesTable deselectAll:nil];
        [self.directoriesTable reloadData];
        [self refreshSelectionUI];
        [self refreshFileCounts];
    } else if (notification.object == self.directoriesTable) {
        // Do not reload the table here: reloadData clears the selection we just made.
        [self updateDirectoryActionState];
    }
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    if (obj.object == self.groupNameField) [self groupNameChanged:self.groupNameField];
}

- (void)groupNameChanged:(id)sender {
    NSMutableDictionary *group = [self selectedGroup];
    if (!group) return;
    NSString *name = [self.groupNameField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) name = @"未命名同步组";
    group[@"name"] = name;
    self.groupNameField.stringValue = name;
    [self saveConfig];
    [self.groupsTable reloadData];
    [self refreshSelectionUI];
}

- (void)groupEnabledChanged:(id)sender {
    NSMutableDictionary *group = [self selectedGroup];
    if (!group) return;
    group[@"enabled"] = @(self.groupEnabledButton.state == NSControlStateValueOn);
    [self saveConfig];
    [self.groupsTable reloadData];
    [self refreshSelectionUI];
}

- (void)addGroup:(id)sender {
    [self logUIEvent:@"addGroup action"];
    NSMutableDictionary *group = [self newGroupNamed:@"新同步组"];
    [self.groups addObject:group];
    [self saveConfig];
    [self.groupsTable reloadData];
    NSInteger row = (NSInteger)self.groups.count - 1;
    [self.groupsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [self refreshSelectionUI];
    [self.window makeFirstResponder:self.groupNameField];
    [self.groupNameField selectText:nil];
}

- (void)removeGroup:(id)sender {
    [self logUIEvent:@"removeGroup action"];
    NSInteger row = self.groupsTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.groups.count) return;
    NSString *name = self.groups[(NSUInteger)row][@"name"] ?: @"此同步组";
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"删除“%@”？", name];
    alert.informativeText = @"删除后，这个目录组会从下一轮自动同步中移除。各目录和其中的文件不会被删除。";
    [alert addButtonWithTitle:@"删除"];
    [alert addButtonWithTitle:@"取消"];
    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse response = [alert runModal];
    if (response != NSAlertFirstButtonReturn) return;
    [self.groups removeObjectAtIndex:(NSUInteger)row];
    [self saveConfig];
    [self.groupsTable reloadData];
    if (self.groups.count) {
        NSInteger next = MIN(row, (NSInteger)self.groups.count - 1);
        [self.groupsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)next] byExtendingSelection:NO];
    }
    [self refreshSelectionUI];
}

- (void)chooseDirectoryWithMessage:(NSString *)message completion:(void (^)(NSString *path))completion {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = message;
    panel.message = message;
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = YES;
    panel.prompt = @"选择";
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
    NSModalResponse result = [panel runModal];
    if (result == NSModalResponseOK && panel.URL.path.length) completion(panel.URL.path);
}

- (BOOL)directoryPathAlreadyExists:(NSString *)path excludingIndex:(NSInteger)excludedIndex {
    NSArray *directories = [self selectedDirectories];
    for (NSInteger i = 0; i < (NSInteger)directories.count; i++) {
        if (i == excludedIndex) continue;
        NSString *existing = [directories[(NSUInteger)i][@"path"] isKindOfClass:[NSString class]] ? directories[(NSUInteger)i][@"path"] : @"";
        if ([existing isEqualToString:path]) return YES;
    }
    return NO;
}

- (void)showDuplicateDirectoryAlert:(NSString *)path {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"这个目录已经在组内";
    alert.informativeText = path ?: @"";
    [alert addButtonWithTitle:@"好"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)showNeedDirectorySelection {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"请先选择一个目录";
    alert.informativeText = @"先在上方目录列表中点选要更改或移出的目录。";
    [alert addButtonWithTitle:@"好"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)addDirectory:(id)sender {
    [self logUIEvent:@"addDirectory action"];
    NSMutableArray *directories = [self selectedDirectories];
    if (!directories) return;
    [self chooseDirectoryWithMessage:@"添加到这个同步组" completion:^(NSString *path) {
        if ([self directoryPathAlreadyExists:path excludingIndex:-1]) {
            [self showDuplicateDirectoryAlert:path];
            return;
        }
        [directories addObject:[self newDirectoryWithPath:path]];
        [self saveConfig];
        [self.directoriesTable reloadData];
        NSInteger row = (NSInteger)directories.count - 1;
        [self.directoriesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
        [self.groupsTable reloadData];
        [self refreshSelectionUI];
        [self requestFileCountForPath:path];
    }];
}

- (BOOL)isDangerousDirectoryToDelete:(NSString *)path {
    if (!path.length) return YES;
    NSString *standard = [path stringByStandardizingPath];
    NSString *home = [NSHomeDirectory() stringByStandardizingPath];
    NSArray<NSString *> *protectedPaths = @[@"/", @"/Users", @"/System", @"/Library", @"/Applications", @"/Volumes", home];
    for (NSString *protected in protectedPaths) {
        if ([standard isEqualToString:protected]) return YES;
    }
    return NO;
}

- (void)finishRemovingDirectoryAtRow:(NSInteger)row directories:(NSMutableArray *)directories {
    if (row < 0 || row >= (NSInteger)directories.count) return;
    [directories removeObjectAtIndex:(NSUInteger)row];
    [self saveConfig];
    [self.directoriesTable reloadData];
    [self.groupsTable reloadData];
    if (directories.count) {
        NSInteger next = MIN(row, (NSInteger)directories.count - 1);
        [self.directoriesTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)next] byExtendingSelection:NO];
    }
    [self refreshSelectionUI];
}

- (void)showDeleteFailedForPath:(NSString *)path error:(NSError *)error {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = @"目录删除失败";
    alert.informativeText = [NSString stringWithFormat:@"%@\n\n%@", path ?: @"", error.localizedDescription ?: @"未知错误"];
    [alert addButtonWithTitle:@"好"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)confirmAndDeleteDirectoryAtPath:(NSString *)path row:(NSInteger)row directories:(NSMutableArray *)directories {
    NSString *standard = [path stringByStandardizingPath];
    if ([self isDangerousDirectoryToDelete:standard]) {
        NSAlert *blocked = [[NSAlert alloc] init];
        blocked.alertStyle = NSAlertStyleCritical;
        blocked.messageText = @"拒绝删除这个目录";
        blocked.informativeText = [NSString stringWithFormat:@"为避免误删系统目录或用户主目录，不能从这里删除：\n%@", standard];
        [blocked addButtonWithTitle:@"好"];
        [NSApp activateIgnoringOtherApps:YES];
        [blocked runModal];
        return;
    }

    NSAlert *confirm = [[NSAlert alloc] init];
    confirm.alertStyle = NSAlertStyleCritical;
    confirm.messageText = @"确认删除整个目录？";
    confirm.informativeText = [NSString stringWithFormat:@"将把下面这个目录及其中全部文件移到废纸篓，然后从同步组移出。\n\n%@\n\n如果这是 iCloud、Google Drive 等云盘目录，这个删除也可能同步到云端。", standard];
    [confirm addButtonWithTitle:@"取消"];
    [confirm addButtonWithTitle:@"确认删除"];
    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse response = [confirm runModal];
    if (response != NSAlertSecondButtonReturn) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL exists = [fm fileExistsAtPath:standard];
    if (exists) {
        NSError *error = nil;
        NSURL *url = [NSURL fileURLWithPath:standard isDirectory:YES];
        NSURL *trashedURL = nil;
        if (![fm trashItemAtURL:url resultingItemURL:&trashedURL error:&error]) {
            [self showDeleteFailedForPath:standard error:error];
            return;
        }
    }
    [self finishRemovingDirectoryAtRow:row directories:directories];
}

- (void)removeDirectory:(id)sender {
    [self logUIEvent:@"removeDirectory action"];
    NSMutableArray *directories = [self selectedDirectories];
    NSInteger row = self.directoriesTable.selectedRow;
    if (!directories || row < 0 || row >= (NSInteger)directories.count) {
        [self showNeedDirectorySelection];
        return;
    }

    NSDictionary *directory = directories[(NSUInteger)row];
    NSString *path = [directory[@"path"] isKindOfClass:[NSString class]] ? directory[@"path"] : @"";

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"将目录移出同步组？";
    alert.informativeText = [NSString stringWithFormat:@"%@\n\n默认只取消同步关系，目录和其中所有文件都会原样保留。", path];
    [alert addButtonWithTitle:@"仅移出，保留文件"];
    [alert addButtonWithTitle:@"移出并删除目录"];
    [alert addButtonWithTitle:@"取消"];
    [NSApp activateIgnoringOtherApps:YES];
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        [self finishRemovingDirectoryAtRow:row directories:directories];
    } else if (response == NSAlertSecondButtonReturn) {
        [self confirmAndDeleteDirectoryAtPath:path row:row directories:directories];
    }
}

- (void)changeDirectory:(id)sender {
    [self logUIEvent:@"changeDirectory action"];
    NSMutableDictionary *directory = [self selectedDirectory];
    NSInteger row = self.directoriesTable.selectedRow;
    if (!directory || row < 0) {
        [self showNeedDirectorySelection];
        return;
    }
    NSString *oldPath = [directory[@"path"] isKindOfClass:[NSString class]] ? directory[@"path"] : @"";
    [self chooseDirectoryWithMessage:@"更改这个目录" completion:^(NSString *path) {
        if ([self directoryPathAlreadyExists:path excludingIndex:row]) {
            [self showDuplicateDirectoryAlert:path];
            return;
        }
        directory[@"path"] = path;
        [self.fileCounts removeObjectForKey:oldPath];
        [self.fileCounts removeObjectForKey:path];
        [self saveConfig];
        [self.directoriesTable reloadData];
        [self refreshSelectionUI];
        [self requestFileCountForPath:path];
    }];
}

@end
