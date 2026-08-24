#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <CommonCrypto/CommonDigest.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>
#import <WebKit/WebKit.h>

static NSString *const Site = @"https://copy-direct.example.com/?app=mac";
static NSString *const UpdateManifest = @"https://copy-direct.example.com/api/update/mac";
static NSInteger const WebKitPolicyChangeError = 102;
static NSString *const PendingUploadsKey = @"CopySync.pendingUploads";
static NSString *const IgnoreNextCopyKey = @"ignoreNextCopy";
static NSString *const ShowFooterKey = @"showFooter";
static NSString *const ClipboardHistoryKey = @"clipboardHistory";
static NSString *const DefaultTargetKey = @"defaultTarget";
static NSString *const SyncWebKey = @"syncTargetToWeb";
static NSString *const HistoryShortcutKey = @"historyShortcut";
static NSString *const HistoryPinnedKey = @"historyPinned";
static NSString *const HistoryVisibleKey = @"historyVisible";
static NSString *const ReceivedDeliveryPathsKey = @"receivedDeliveryPaths";
static NSPasteboardType const CopySyncPasteboardType = @"com.example.copysync";
static const int64_t PasteSignature = 0x434F5059;

@class CopySyncApp;
static CopySyncApp *CopySyncDelegate;

@interface CopySyncSidebarButton : NSButton
@end

@implementation CopySyncSidebarButton
- (BOOL)accessibilityPerformPress {
    [self performClick:nil];
    return YES;
}
@end

@interface CopySyncFlippedStackView : NSStackView
@end

@implementation CopySyncFlippedStackView
- (BOOL)isFlipped { return YES; }
@end

@interface CopySyncApp : NSObject <NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate>
@property (strong) NSWindow *window;
@property (strong) NSPanel *historyPanel;
@property (strong) NSStackView *historyStack;
@property (strong) NSScrollView *historyScroll;
@property (strong) NSButton *historyPinButton;
@property (strong) WKWebView *webView;
@property (assign) BOOL webRecoveryScheduled;
@property (assign) BOOL webRecoveryInProgress;
@property (strong) NSTextField *footerLabel;
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMenu *statusMenu;
@property (strong) NSMenuItem *statusMenuItem;
@property (strong) NSMenuItem *historyCountMenuItem;
@property (strong) NSMenuItem *screenshotUsageMenuItem;
@property (strong) NSMenuItem *cacheUsageMenuItem;
@property (strong) NSMenuItem *launchAtLoginMenuItem;
@property (strong) NSMenuItem *showFooterMenuItem;
@property (strong) NSMutableArray<NSDictionary *> *clipboardHistory;
@property (strong) NSMutableSet<NSString *> *inFlightHistoryIDs;
@property (strong) NSMutableSet<NSString *> *incomingDeliveryIDs;
@property (strong) NSMutableDictionary<NSString *, NSString *> *historyActionStates;
@property (strong) NSMutableDictionary<NSString *, NSString *> *receivedDeliveryPaths;
@property (strong) NSMapTable<WKDownload *, NSURL *> *webDownloadDestinations;
@property (strong) NSRunningApplication *previousApplication;
@property (strong) NSMutableArray<NSButton *> *sidebarButtons;
@property (copy) NSString *macSection;
@property (assign) NSInteger pasteboardChangeCount;
@property (assign) EventHotKeyRef windowHotKey;
@property (assign) EventHotKeyRef screenshotHotKey;
@property (assign) EventHotKeyRef historyHotKey;
@property (assign) EventHandlerRef windowHotKeyHandler;
@property (strong) NSTask *captureTask;
- (void)openWindow:(id)sender;
- (void)toggleMainWindow:(id)sender;
- (void)toggleHistoryPanel:(id)sender;
- (void)captureRegion:(id)sender;
- (void)showHistoryPanel:(id)sender;
- (void)pollWebClipboardRequest;
- (void)sendCommandVToApplication:(NSRunningApplication *)application;
- (void)requestScreenCapturePermission:(id)sender;
@end

static OSStatus windowHotKeyCallback(EventHandlerCallRef nextHandler, EventRef event, void *userInfo) {
    CopySyncApp *app = (__bridge CopySyncApp *)userInfo;
    EventHotKeyID hotKeyID = {};
    GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hotKeyID), NULL, &hotKeyID);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (hotKeyID.id == 2) [app captureRegion:nil];
        else if (hotKeyID.id == 3) [app toggleHistoryPanel:nil];
        else [app toggleMainWindow:nil];
    });
    return noErr;
}

@implementation CopySyncApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(workspaceApplicationActivated:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound) completionHandler:^(__unused BOOL granted, __unused NSError *error) {}];
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    [configuration.userContentController addScriptMessageHandler:self name:@"copySync"];
    self.webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
    self.webView.underPageBackgroundColor = NSColor.clearColor;
    self.webView.UIDelegate = self;
    self.webView.navigationDelegate = self;
    NSURLRequest *siteRequest = [NSURLRequest requestWithURL:[NSURL URLWithString:Site] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    [self.webView loadRequest:siteRequest];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1060, 760)
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"CopySync";
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    self.window.backgroundColor = [NSColor colorWithSRGBRed:.98 green:.976 blue:.969 alpha:1];
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.footerLabel = [NSTextField labelWithString:@"本地历史已开启 · 复制不自动上传 · ⌘J 截图 · ⌘, 历史悬浮贴"];
    self.footerLabel.alignment = NSTextAlignmentCenter;
    self.footerLabel.textColor = NSColor.secondaryLabelColor;
    self.footerLabel.font = [NSFont systemFontOfSize:12];
    NSStackView *content = [NSStackView stackViewWithViews:@[self.webView, self.footerLabel]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.spacing = 0;
    content.distribution = NSStackViewDistributionFill;
    [self.footerLabel.heightAnchor constraintEqualToConstant:28].active = YES;
    if ([NSUserDefaults.standardUserDefaults objectForKey:ShowFooterKey] == nil) [NSUserDefaults.standardUserDefaults setBool:YES forKey:ShowFooterKey];
    self.footerLabel.hidden = ![NSUserDefaults.standardUserDefaults boolForKey:ShowFooterKey];
    NSView *sidebar = [self buildSidebar];
    NSStackView *shell = [NSStackView stackViewWithViews:@[sidebar, content]];
    shell.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    shell.spacing = 0;
    shell.distribution = NSStackViewDistributionFill;
    [sidebar.widthAnchor constraintEqualToConstant:210].active = YES;
    self.window.contentView = shell;
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self buildHistoryPanel];

    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    NSImage *statusIcon = [NSImage imageWithSystemSymbolName:@"clipboard" accessibilityDescription:@"CopySync 剪贴板历史"];
    statusIcon.template = YES;
    self.statusItem.button.image = statusIcon;
    self.statusItem.button.title = @"";
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    self.statusMenu = [NSMenu new];
    self.historyCountMenuItem = [[NSMenuItem alloc] initWithTitle:@"本地历史 0 / 10" action:nil keyEquivalent:@""];
    self.screenshotUsageMenuItem = [[NSMenuItem alloc] initWithTitle:@"历史截图 0 张 · 0 B" action:nil keyEquivalent:@""];
    self.cacheUsageMenuItem = [[NSMenuItem alloc] initWithTitle:@"临时文件缓存 0 B" action:nil keyEquivalent:@""];
    [self.statusMenu addItem:self.historyCountMenuItem];
    [self.statusMenu addItem:self.screenshotUsageMenuItem];
    [self.statusMenu addItem:self.cacheUsageMenuItem];
    [self.statusMenu addItem:[NSMenuItem separatorItem]];
    [self.statusMenu addItemWithTitle:@"打开历史（⌘,）" action:@selector(showHistoryPanel:) keyEquivalent:@""];
    [self.statusMenu addItemWithTitle:@"打开跨设备传输（⌘.）" action:@selector(openWindow:) keyEquivalent:@""];
    [self.statusMenu addItemWithTitle:@"打开临时文件夹" action:@selector(openCacheFolder:) keyEquivalent:@""];
    [self.statusMenu addItemWithTitle:@"打开接收文件夹" action:@selector(openReceivedFolder:) keyEquivalent:@""];
    [self.statusMenu addItemWithTitle:@"清空历史记录…" action:@selector(clearHistory:) keyEquivalent:@""];
    [self.statusMenu addItemWithTitle:@"清理临时缓存…" action:@selector(clearCache:) keyEquivalent:@""];
    [self.statusMenu addItem:[NSMenuItem separatorItem]];
    [self.statusMenu addItemWithTitle:@"区域截图到历史（⌘J）" action:@selector(captureRegion:) keyEquivalent:@""];
    [self.statusMenu addItemWithTitle:@"屏幕录制权限…" action:@selector(requestScreenCapturePermission:) keyEquivalent:@""];
    [self.statusMenu addItemWithTitle:@"检查更新…" action:@selector(checkForUpdates:) keyEquivalent:@""];
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"状态：等待复制" action:nil keyEquivalent:@""];
    [self.statusMenu addItem:self.statusMenuItem];
    [self.statusMenu addItemWithTitle:@"忽略下一次复制" action:@selector(ignoreNextCopy:) keyEquivalent:@""];
    self.showFooterMenuItem = [[NSMenuItem alloc] initWithTitle:@"显示底部状态栏" action:@selector(toggleFooter:) keyEquivalent:@""];
    [self.statusMenu addItem:self.showFooterMenuItem];
    [self.statusMenu addItemWithTitle:@"偏好设置…" action:@selector(showPreferences:) keyEquivalent:@""];
    self.launchAtLoginMenuItem = [[NSMenuItem alloc] initWithTitle:@"登录时启动" action:@selector(toggleLaunchAtLogin:) keyEquivalent:@""];
    [self.statusMenu addItem:self.launchAtLoginMenuItem];
    [self.statusMenu addItemWithTitle:@"请求粘贴权限" action:@selector(requestPastePermission:) keyEquivalent:@""];
    [self.statusMenu addItem:[NSMenuItem separatorItem]];
    [self.statusMenu addItemWithTitle:@"退出" action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *appMenuItem = [NSMenuItem new];
    NSMenu *appMenu = [NSMenu new];
    NSMenuItem *historyItem = [[NSMenuItem alloc] initWithTitle:@"剪贴板历史" action:@selector(showHistoryPanel:) keyEquivalent:@","];
    historyItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [appMenu addItem:historyItem];
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *preferencesItem = [[NSMenuItem alloc] initWithTitle:@"偏好设置…" action:@selector(showPreferences:) keyEquivalent:@""];
    [appMenu addItem:preferencesItem];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"退出 CopySync" action:@selector(terminate:) keyEquivalent:@"q"];
    appMenuItem.submenu = appMenu;
    [mainMenu addItem:appMenuItem];
    NSApp.mainMenu = mainMenu;

    [NSUserDefaults.standardUserDefaults removeObjectForKey:PendingUploadsKey];
    [self ensureCacheFolders];
    self.inFlightHistoryIDs = [NSMutableSet new];
    self.incomingDeliveryIDs = [NSMutableSet new];
    self.historyActionStates = [NSMutableDictionary new];
    self.receivedDeliveryPaths = [[NSUserDefaults.standardUserDefaults dictionaryForKey:ReceivedDeliveryPathsKey] mutableCopy] ?: [NSMutableDictionary new];
    self.webDownloadDestinations = [NSMapTable weakToStrongObjectsMapTable];
    NSArray *savedHistory = [NSUserDefaults.standardUserDefaults arrayForKey:ClipboardHistoryKey];
    self.clipboardHistory = [NSMutableArray new];
    for (id entry in savedHistory ?: @[]) {
        if ([entry isKindOfClass:NSString.class] && [entry length]) {
            [self.clipboardHistory addObject:@{@"id":NSUUID.UUID.UUIDString, @"kind":@"text", @"text":entry, @"created":@(NSDate.date.timeIntervalSince1970)}];
        } else if ([entry isKindOfClass:NSDictionary.class] && [entry[@"id"] length] && [entry[@"kind"] length]) {
            [self.clipboardHistory addObject:entry];
        }
    }
    while (self.clipboardHistory.count > 10) [self.clipboardHistory removeLastObject];
    [self saveHistory];
    if ([NSUserDefaults.standardUserDefaults objectForKey:DefaultTargetKey] == nil) [NSUserDefaults.standardUserDefaults setObject:@"all" forKey:DefaultTargetKey];
    if ([NSUserDefaults.standardUserDefaults objectForKey:SyncWebKey] == nil) [NSUserDefaults.standardUserDefaults setBool:YES forKey:SyncWebKey];
    NSString *savedShortcut = [NSUserDefaults.standardUserDefaults stringForKey:HistoryShortcutKey];
    if (!savedShortcut || [savedShortcut isEqual:@"control"] || [savedShortcut isEqual:@"controlComma"]) [NSUserDefaults.standardUserDefaults setObject:@"commandComma" forKey:HistoryShortcutKey];
    [self refreshHistoryPanel];
    self.pasteboardChangeCount = NSPasteboard.generalPasteboard.changeCount;
    [NSTimer scheduledTimerWithTimeInterval:0.45 repeats:YES block:^(__unused NSTimer *timer) { [self watchPasteboard]; [self pollWebClipboardRequest]; }];
    [self updatePreferenceMenus];
    [self installWindowHotKey];
    [self updateLaunchAtLoginMenu];
    if ([NSUserDefaults.standardUserDefaults boolForKey:HistoryPinnedKey] && [NSUserDefaults.standardUserDefaults boolForKey:HistoryVisibleKey])
        dispatch_async(dispatch_get_main_queue(), ^{ [self showHistoryPanel:@YES]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self checkForUpdatesInteractive:NO]; });
}

- (void)workspaceApplicationActivated:(NSNotification *)notification {
    NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
    if (application && ![application.bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier]) self.previousApplication = application;
}

- (NSView *)buildSidebar {
    NSVisualEffectView *sidebar = [NSVisualEffectView new];
    sidebar.material = NSVisualEffectMaterialSidebar;
    sidebar.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    NSButton *inbox = [CopySyncSidebarButton buttonWithTitle:@"收件箱" target:self action:@selector(showMacInbox:)];
    NSButton *records = [CopySyncSidebarButton buttonWithTitle:@"传输历史" target:self action:@selector(showMacRecords:)];
    NSButton *drive = [CopySyncSidebarButton buttonWithTitle:@"临时网盘" target:self action:@selector(showMacDrive:)];
    NSButton *openWeb = [CopySyncSidebarButton buttonWithTitle:@"打开网页版" target:self action:@selector(openWebVersion:)];
    NSButton *settings = [CopySyncSidebarButton buttonWithTitle:@"设置" target:self action:@selector(showPreferences:)];
    NSArray *symbols = @[@"tray.and.arrow.down", @"clock", @"icloud", @"arrow.up.right", @"gearshape"];
    NSImageSymbolConfiguration *symbolStyle = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular];
    NSUInteger symbolIndex = 0;
    self.sidebarButtons = [NSMutableArray new];
    for (NSButton *button in @[inbox, records, drive, openWeb, settings]) {
        button.bordered = NO;
        button.alignment = NSTextAlignmentLeft;
        button.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        button.image = [[NSImage imageWithSystemSymbolName:symbols[symbolIndex++] accessibilityDescription:nil] imageWithSymbolConfiguration:symbolStyle];
        button.imagePosition = NSImageLeading;
        button.imageHugsTitle = YES;
        button.contentTintColor = [NSColor colorWithSRGBRed:.24 green:.27 blue:.25 alpha:1];
        button.wantsLayer = YES;
        button.layer.cornerRadius = 9;
        [button.heightAnchor constraintEqualToConstant:34].active = YES;
        [self.sidebarButtons addObject:button];
    }
    NSView *spacer = [NSView new];
    NSStackView *stack = [NSStackView stackViewWithViews:@[inbox, records, drive, openWeb, spacer, settings]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 4;
    stack.edgeInsets = NSEdgeInsetsZero;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [sidebar addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor constant:14], [stack.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor constant:-14],
        [stack.topAnchor constraintEqualToAnchor:sidebar.topAnchor constant:16], [stack.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor constant:-16],
        [inbox.widthAnchor constraintEqualToAnchor:stack.widthAnchor], [records.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [drive.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [openWeb.widthAnchor constraintEqualToAnchor:stack.widthAnchor], [settings.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    [self updateSidebarSelection];
    return sidebar;
}

- (void)updateSidebarSelection {
    NSString *active = self.macSection ?: @"inbox";
    NSArray *sections = @[@"inbox", @"records", @"drive"];
    for (NSUInteger index = 0; index < self.sidebarButtons.count; index++) {
        NSButton *button = self.sidebarButtons[index];
        BOOL selected = index < sections.count && [sections[index] isEqual:active];
        button.layer.backgroundColor = selected ? [NSColor colorWithSRGBRed:.043 green:.36 blue:.24 alpha:1].CGColor : NSColor.clearColor.CGColor;
        button.contentTintColor = selected ? NSColor.whiteColor : [NSColor colorWithSRGBRed:.24 green:.27 blue:.25 alpha:1];
    }
}

- (void)selectMacSection:(NSString *)section {
    self.macSection = section;
    [self openWindow:nil];
    [self.webView evaluateJavaScript:[NSString stringWithFormat:@"window.showMacSection && window.showMacSection('%@')", section] completionHandler:nil];
    [self updateSidebarSelection];
}

- (void)showMacInbox:(id)sender { [self selectMacSection:@"inbox"]; }
- (void)showMacRecords:(id)sender { [self selectMacSection:@"records"]; }
- (void)showMacDrive:(id)sender { [self selectMacSection:@"drive"]; }
- (void)openWebVersion:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://copy-direct.example.com/"]];
}

- (NSURL *)cacheRootURL {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [NSURL fileURLWithPath:[documents stringByAppendingPathComponent:@"CopySync 临时文件"] isDirectory:YES];
}

- (NSURL *)historyImagesURL { return [[self cacheRootURL] URLByAppendingPathComponent:@"历史截图" isDirectory:YES]; }
- (NSURL *)receivedFilesURL {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [NSURL fileURLWithPath:[documents stringByAppendingPathComponent:@"CopySync"] isDirectory:YES];
}
- (NSURL *)legacyReceivedFilesURL { return [[self cacheRootURL] URLByAppendingPathComponent:@"接收文件" isDirectory:YES]; }
- (NSURL *)legacyStandaloneReceivedFilesURL {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [NSURL fileURLWithPath:[documents stringByAppendingPathComponent:@"CopySync 接收文件"] isDirectory:YES];
}
- (NSURL *)outgoingFilesURL { return [[self cacheRootURL] URLByAppendingPathComponent:@"待发送" isDirectory:YES]; }

- (void)ensureCacheFolders {
    for (NSURL *url in @[[self cacheRootURL], [self historyImagesURL], [self receivedFilesURL], [self outgoingFilesURL]])
        [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSURL *legacy in @[[self legacyReceivedFilesURL], [self legacyStandaloneReceivedFilesURL]]) {
        NSArray<NSURL *> *oldFiles = [NSFileManager.defaultManager contentsOfDirectoryAtURL:legacy includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        for (NSURL *oldFile in oldFiles ?: @[]) {
            NSURL *destination = [self uniqueReceivedURLForName:oldFile.lastPathComponent];
            [NSFileManager.defaultManager moveItemAtURL:oldFile toURL:destination error:nil];
        }
    }
}

- (NSString *)sha256ForData:(NSData *)data {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *value = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [value appendFormat:@"%02x", digest[i]];
    return value;
}

- (void)saveHistory {
    [NSUserDefaults.standardUserDefaults setObject:self.clipboardHistory ?: @[] forKey:ClipboardHistoryKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    [self updateStorageMenu];
}

- (void)deleteFileForHistoryItem:(NSDictionary *)item {
    if ([item[@"kind"] isEqual:@"image"] && [item[@"path"] length])
        [NSFileManager.defaultManager removeItemAtPath:item[@"path"] error:nil];
}

- (void)pruneHistory {
    while (self.clipboardHistory.count > 10) {
        NSInteger removable = self.clipboardHistory.count - 1;
        while (removable >= 0 && [self.inFlightHistoryIDs containsObject:self.clipboardHistory[removable][@"id"]]) removable--;
        if (removable < 0) break;
        NSDictionary *old = self.clipboardHistory[removable];
        [self deleteFileForHistoryItem:old];
        [self.clipboardHistory removeObjectAtIndex:removable];
    }
}

- (void)addTextToHistory:(NSString *)text {
    if (!text.length) return;
    NSString *fingerprint = [self sha256ForData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    NSUInteger duplicate = [self.clipboardHistory indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) { return [item[@"fingerprint"] isEqual:fingerprint]; }];
    if (duplicate != NSNotFound) [self.clipboardHistory removeObjectAtIndex:duplicate];
    [self.clipboardHistory insertObject:@{@"id":NSUUID.UUID.UUIDString, @"kind":@"text", @"text":text, @"fingerprint":fingerprint, @"created":@(NSDate.date.timeIntervalSince1970)} atIndex:0];
    [self pruneHistory];
    [self saveHistory];
    [self refreshHistoryPanel];
}

- (void)addImageDataToHistory:(NSData *)png title:(NSString *)title {
    if (!png.length) return;
    [self ensureCacheFolders];
    NSString *fingerprint = [self sha256ForData:png];
    NSUInteger duplicate = [self.clipboardHistory indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) { return [item[@"fingerprint"] isEqual:fingerprint]; }];
    if (duplicate != NSNotFound) {
        NSDictionary *existing = self.clipboardHistory[duplicate];
        [self.clipboardHistory removeObjectAtIndex:duplicate];
        NSMutableDictionary *updated = [existing mutableCopy];
        updated[@"created"] = @(NSDate.date.timeIntervalSince1970);
        [self.clipboardHistory insertObject:updated atIndex:0];
    } else {
        NSString *identifier = NSUUID.UUID.UUIDString;
        NSURL *url = [[self historyImagesURL] URLByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"png"]];
        if (![png writeToURL:url options:NSDataWritingAtomic error:nil]) { [self setStatusOK:NO message:@"无法保存本地图片历史"]; return; }
        [self.clipboardHistory insertObject:@{@"id":identifier, @"kind":@"image", @"text":title ?: @"图片", @"path":url.path, @"fingerprint":fingerprint, @"created":@(NSDate.date.timeIntervalSince1970)} atIndex:0];
    }
    [self pruneHistory];
    [self saveHistory];
    [self refreshHistoryPanel];
}

- (NSData *)pngDataFromPasteboard:(NSPasteboard *)pasteboard {
    NSData *png = [pasteboard dataForType:NSPasteboardTypePNG];
    if (png.length) return png;
    NSData *tiff = [pasteboard dataForType:NSPasteboardTypeTIFF];
    if (!tiff.length) return nil;
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

- (NSDictionary *)historyItemWithID:(NSString *)identifier {
    for (NSDictionary *item in self.clipboardHistory) if ([item[@"id"] isEqual:identifier]) return item;
    return nil;
}

- (BOOL)writeHistoryItemToPasteboard:(NSDictionary *)item {
    if (!item) return NO;
    NSPasteboardItem *pasteItem = [NSPasteboardItem new];
    if ([item[@"kind"] isEqual:@"image"]) {
        NSData *data = [NSData dataWithContentsOfFile:item[@"path"] ?: @""];
        if (!data.length) {
            [self setStatusOK:NO message:@"历史图片文件已不存在"];
            return NO;
        }
        [pasteItem setData:data forType:NSPasteboardTypePNG];
    } else {
        [pasteItem setString:item[@"text"] ?: @"" forType:NSPasteboardTypeString];
    }
    [pasteItem setString:@"" forType:CopySyncPasteboardType];
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    BOOL copied = [pasteboard writeObjects:@[pasteItem]];
    self.pasteboardChangeCount = pasteboard.changeCount;
    if (!copied) [self setStatusOK:NO message:@"复制失败"];
    return copied;
}

- (void)copyHistoryItem:(NSButton *)sender {
    NSString *identifier = sender.identifier;
    NSDictionary *item = [self historyItemWithID:identifier];
    if (![self writeHistoryItemToPasteboard:item]) return;
    self.historyActionStates[identifier] = @"copySuccess";
    [self refreshHistoryPanel];
    [self setStatusOK:YES message:[item[@"kind"] isEqual:@"image"] ? @"截图已复制" : @"文本已复制"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([self.historyActionStates[identifier] isEqual:@"copySuccess"]) {
            [self.historyActionStates removeObjectForKey:identifier];
            [self refreshHistoryPanel];
        }
    });
}

- (void)historyAction:(NSButton *)sender {
    NSString *identifier = sender.identifier;
    NSDictionary *item = [self historyItemWithID:identifier];
    if (!item || [self.inFlightHistoryIDs containsObject:identifier]) return;
    BOOL cloud = sender.tag == 1;
    [self.inFlightHistoryIDs addObject:identifier];
    [self refreshHistoryPanel];
    NSString *target = cloud ? @"web" : @"android";
    NSString *visible = cloud ? @"1" : @"0";
    NSString *script;
    if ([item[@"kind"] isEqual:@"image"]) {
        NSData *data = [NSData dataWithContentsOfFile:item[@"path"] ?: @""];
        if (!data.length) {
            [self.inFlightHistoryIDs removeObject:identifier];
            [self refreshHistoryPanel];
            [self setStatusOK:NO message:@"历史图片文件已不存在"];
            return;
        }
        NSString *base64 = [data base64EncodedStringWithOptions:0];
        NSString *name = [item[@"path"] lastPathComponent] ?: @"CopySync.png";
        script = [NSString stringWithFormat:@"(async()=>{try{const id=%@[0],action=%@[0],raw=atob(%@[0]),bytes=new Uint8Array(raw.length);for(let i=0;i<raw.length;i++)bytes[i]=raw.charCodeAt(i);const body=new FormData();body.append('files',new Blob([bytes],{type:'image/png'}),%@[0]);body.set('source_device','mac');body.set('target_device',%@[0]);body.set('web_visible',%@);const r=await fetch('/api/upload',{method:'POST',body});if(!r.ok)throw new Error('请求失败 '+r.status);if(action==='cloud'&&typeof loadItems==='function')await loadItems();window.webkit.messageHandlers.copySync.postMessage({type:'historyAction',ok:true,id,action});}catch(e){window.webkit.messageHandlers.copySync.postMessage({type:'historyAction',ok:false,id:%@[0],action:%@[0],error:String(e&&e.message||e)});}})();", [self jsonArray:identifier], [self jsonArray:cloud ? @"cloud" : @"plane"], [self jsonArray:base64], [self jsonArray:name], [self jsonArray:target], visible, [self jsonArray:identifier], [self jsonArray:cloud ? @"cloud" : @"plane"]];
    } else {
        script = [NSString stringWithFormat:@"(async()=>{try{const id=%@[0],action=%@[0],body=new FormData();body.set('text',%@[0]);body.set('source_device','mac');body.set('target_device',%@[0]);body.set('web_visible',%@);const r=await fetch('/api/text',{method:'POST',body});if(!r.ok)throw new Error('请求失败 '+r.status);if(action==='cloud'&&typeof loadItems==='function')await loadItems();window.webkit.messageHandlers.copySync.postMessage({type:'historyAction',ok:true,id,action});}catch(e){window.webkit.messageHandlers.copySync.postMessage({type:'historyAction',ok:false,id:%@[0],action:%@[0],error:String(e&&e.message||e)});}})();", [self jsonArray:identifier], [self jsonArray:cloud ? @"cloud" : @"plane"], [self jsonArray:item[@"text"] ?: @""], [self jsonArray:target], visible, [self jsonArray:identifier], [self jsonArray:cloud ? @"cloud" : @"plane"]];
    }
    [self.webView evaluateJavaScript:script completionHandler:^(__unused id result, NSError *error) {
        if (!error) return;
        [self.inFlightHistoryIDs removeObject:identifier];
        [self refreshHistoryPanel];
        [self setStatusOK:NO message:@"网络页面尚未就绪"];
    }];
}

- (void)deleteHistoryItem:(NSMenuItem *)sender {
    NSString *identifier = sender.representedObject;
    if ([self.inFlightHistoryIDs containsObject:identifier]) { [self setStatusOK:NO message:@"该项目正在传输，暂不能删除"]; return; }
    NSUInteger index = [self.clipboardHistory indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) { return [item[@"id"] isEqual:identifier]; }];
    if (index == NSNotFound) return;
    [self deleteFileForHistoryItem:self.clipboardHistory[index]];
    [self.clipboardHistory removeObjectAtIndex:index];
    [self saveHistory];
    [self refreshHistoryPanel];
}

- (unsigned long long)sizeOfDirectory:(NSURL *)directory excludingHistory:(BOOL)excludeHistory {
    unsigned long long total = 0;
    NSDirectoryEnumerator *files = [NSFileManager.defaultManager enumeratorAtURL:directory includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLIsRegularFileKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
    for (NSURL *url in files) {
        if (excludeHistory && [url.path hasPrefix:[self historyImagesURL].path]) { [files skipDescendants]; continue; }
        NSNumber *regular = nil, *size = nil;
        [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (regular.boolValue) total += size.unsignedLongLongValue;
    }
    return total;
}

- (NSString *)formattedBytes:(unsigned long long)bytes {
    NSByteCountFormatter *formatter = [NSByteCountFormatter new];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    return [formatter stringFromByteCount:(long long)bytes];
}

- (void)updateStorageMenu {
    if (!self.historyCountMenuItem) return;
    NSUInteger screenshots = 0;
    for (NSDictionary *item in self.clipboardHistory) if ([item[@"kind"] isEqual:@"image"]) screenshots++;
    self.historyCountMenuItem.title = [NSString stringWithFormat:@"本地历史 %lu / 10", (unsigned long)self.clipboardHistory.count];
    self.screenshotUsageMenuItem.title = [NSString stringWithFormat:@"历史截图 %lu 张 · %@", (unsigned long)screenshots, [self formattedBytes:[self sizeOfDirectory:[self historyImagesURL] excludingHistory:NO]]];
    self.cacheUsageMenuItem.title = [NSString stringWithFormat:@"临时文件缓存 %@", [self formattedBytes:[self sizeOfDirectory:[self cacheRootURL] excludingHistory:YES]]];
}

- (void)statusItemClicked:(id)sender {
    if (NSApp.currentEvent.type == NSEventTypeRightMouseUp) {
        [self updateStorageMenu];
        self.statusItem.menu = self.statusMenu;
        [self.statusItem.button performClick:nil];
        self.statusItem.menu = nil;
    } else if (self.historyPanel.isVisible) {
        [self.historyPanel orderOut:nil];
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:HistoryVisibleKey];
    } else {
        [self showHistoryPanel:sender];
    }
}

- (void)openCacheFolder:(id)sender {
    [self ensureCacheFolders];
    [NSWorkspace.sharedWorkspace openURL:[self cacheRootURL]];
}

- (void)openReceivedFolder:(id)sender {
    [self ensureCacheFolders];
    [NSWorkspace.sharedWorkspace openURL:[self receivedFilesURL]];
}

- (void)revealReceivedDelivery:(NSString *)deliveryID name:(NSString *)name {
    [self ensureCacheFolders];
    NSString *savedPath = self.receivedDeliveryPaths[deliveryID ?: @""];
    NSURL *fileURL = savedPath.length ? [NSURL fileURLWithPath:savedPath] : nil;
    if (!fileURL || ![NSFileManager.defaultManager fileExistsAtPath:fileURL.path]) {
        NSString *safeName = name.lastPathComponent.length ? name.lastPathComponent : @"CopySync-file";
        NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[self receivedFilesURL] includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        fileURL = [files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *candidate, NSDictionary *bindings) {
            if ([candidate.lastPathComponent isEqual:safeName]) return YES;
            NSString *extension = safeName.pathExtension;
            NSString *base = safeName.stringByDeletingPathExtension;
            NSString *candidateBase = candidate.lastPathComponent.stringByDeletingPathExtension;
            return (!extension.length || [candidate.pathExtension isEqual:extension]) && [candidateBase hasPrefix:[base stringByAppendingString:@"-"]];
        }]].firstObject;
    }
    if (fileURL && [NSFileManager.defaultManager fileExistsAtPath:fileURL.path]) {
        if (deliveryID.length) {
            self.receivedDeliveryPaths[deliveryID] = fileURL.path;
            [NSUserDefaults.standardUserDefaults setObject:self.receivedDeliveryPaths forKey:ReceivedDeliveryPathsKey];
        }
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[fileURL]];
        [self setStatusOK:YES message:[NSString stringWithFormat:@"已在 Finder 中显示：%@", fileURL.lastPathComponent]];
    } else {
        [NSWorkspace.sharedWorkspace openURL:[self receivedFilesURL]];
        [self setStatusOK:NO message:@"文件仍在接收中，请稍后再点一次"];
    }
}

- (void)clearHistory:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"清空全部本地历史？";
    alert.informativeText = @"文本记录和历史截图都会删除，正在传输的项目除外。";
    [alert addButtonWithTitle:@"清空"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    for (NSDictionary *item in self.clipboardHistory.copy) {
        if ([self.inFlightHistoryIDs containsObject:item[@"id"]]) continue;
        [self deleteFileForHistoryItem:item];
        [self.clipboardHistory removeObject:item];
    }
    [self saveHistory];
    [self refreshHistoryPanel];
    [self setStatusOK:YES message:@"本地历史已清空"];
}

- (void)clearCache:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"清理临时文件缓存？";
    alert.informativeText = @"只清理待发送缓存，不删除历史截图和已接收文件。";
    [alert addButtonWithTitle:@"清理"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    for (NSURL *directory in @[[self outgoingFilesURL]]) {
        [NSFileManager.defaultManager removeItemAtURL:directory error:nil];
        [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    [self updateStorageMenu];
    [self setStatusOK:YES message:@"临时缓存已清理"];
}

- (void)buildHistoryPanel {
    self.historyPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 320, 240)
                                                   styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView)
                                                     backing:NSBackingStoreBuffered defer:NO];
    self.historyPanel.titleVisibility = NSWindowTitleHidden;
    self.historyPanel.title = @"最近复制";
    self.historyPanel.titlebarAppearsTransparent = YES;
    self.historyPanel.floatingPanel = YES;
    self.historyPanel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    self.historyPanel.backgroundColor = NSColor.clearColor;
    self.historyPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.historyPanel.releasedWhenClosed = NO;
    self.historyPanel.delegate = self;
    self.historyPanel.minSize = NSMakeSize(240, 150);
    self.historyPanel.maxSize = NSMakeSize(620, 1200);
    BOOL restoredFrame = [self.historyPanel setFrameUsingName:@"CopySyncHistoryPanel"];
    [self.historyPanel setFrameAutosaveName:@"CopySyncHistoryPanel"];
    if (!restoredFrame) [self.historyPanel center];

    NSVisualEffectView *glass = [[NSVisualEffectView alloc] initWithFrame:self.historyPanel.contentView.bounds];
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    glass.material = NSVisualEffectMaterialPopover;
    glass.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    glass.state = NSVisualEffectStateActive;
    glass.wantsLayer = YES;
    glass.layer.cornerRadius = 14;
    glass.layer.masksToBounds = YES;

    NSView *headerSpacer = [NSView new];
    [headerSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.historyPinButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"pin.fill" accessibilityDescription:@"固定悬浮贴"] target:self action:@selector(toggleHistoryPin:)];
    self.historyPinButton.bordered = NO;
    self.historyPinButton.imagePosition = NSImageOnly;
    NSStackView *header = [NSStackView stackViewWithViews:@[headerSpacer, self.historyPinButton]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    self.historyStack = [CopySyncFlippedStackView new];
    self.historyStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.historyStack.alignment = NSLayoutAttributeLeading;
    self.historyStack.spacing = 7;
    self.historyStack.edgeInsets = NSEdgeInsetsMake(2, 2, 8, 2);
    self.historyStack.translatesAutoresizingMaskIntoConstraints = YES;
    self.historyStack.frame = NSMakeRect(0, 0, 280, 1);
    self.historyStack.autoresizingMask = NSViewWidthSizable;
    NSScrollView *scroll = [NSScrollView new];
    self.historyScroll = scroll;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.documentView = self.historyStack;
    NSStackView *root = [NSStackView stackViewWithViews:@[header, scroll]];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.spacing = 10;
    root.edgeInsets = NSEdgeInsetsMake(18, 14, 12, 14);
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [glass addSubview:root];
    [NSLayoutConstraint activateConstraints:@[
        [root.leadingAnchor constraintEqualToAnchor:glass.leadingAnchor], [root.trailingAnchor constraintEqualToAnchor:glass.trailingAnchor],
        [root.topAnchor constraintEqualToAnchor:glass.topAnchor], [root.bottomAnchor constraintEqualToAnchor:glass.bottomAnchor],
        [scroll.widthAnchor constraintEqualToAnchor:root.widthAnchor]
    ]];
    self.historyPanel.contentView = glass;
    if ([NSUserDefaults.standardUserDefaults objectForKey:HistoryPinnedKey] == nil) [NSUserDefaults.standardUserDefaults setBool:YES forKey:HistoryPinnedKey];
    [self updateHistoryPin];
}

- (void)toggleHistoryPin:(id)sender {
    BOOL pinned = ![NSUserDefaults.standardUserDefaults boolForKey:HistoryPinnedKey];
    [NSUserDefaults.standardUserDefaults setBool:pinned forKey:HistoryPinnedKey];
    [self updateHistoryPin];
}

- (void)updateHistoryPin {
    BOOL pinned = [NSUserDefaults.standardUserDefaults boolForKey:HistoryPinnedKey];
    self.historyPanel.hidesOnDeactivate = !pinned;
    self.historyPanel.level = pinned ? NSFloatingWindowLevel : NSNormalWindowLevel;
    NSImage *pinImage = [NSImage imageWithSystemSymbolName:pinned ? @"pin.fill" : @"pin" accessibilityDescription:pinned ? @"取消固定悬浮贴" : @"固定悬浮贴"];
    if (pinned) {
        NSImage *baseImage = pinImage;
        pinImage = [NSImage imageWithSize:baseImage.size flipped:NO drawingHandler:^BOOL(NSRect destination) {
            [NSGraphicsContext saveGraphicsState];
            NSAffineTransform *transform = [NSAffineTransform transform];
            [transform translateXBy:NSMidX(destination) yBy:NSMidY(destination)];
            [transform rotateByDegrees:-35];
            [transform translateXBy:-NSMidX(destination) yBy:-NSMidY(destination)];
            [transform concat];
            [baseImage drawInRect:destination];
            [NSGraphicsContext restoreGraphicsState];
            return YES;
        }];
    }
    self.historyPinButton.image = pinImage;
    self.historyPinButton.toolTip = pinned ? @"已固定：切换应用后仍显示" : @"未固定：切换应用后自动隐藏";
    if (pinned && self.historyPanel.isVisible) [self.historyPanel orderFront:nil];
}

- (void)refreshHistoryPanel {
    for (NSView *view in self.historyStack.arrangedSubviews.copy) [self.historyStack removeArrangedSubview:view], [view removeFromSuperview];
    if (!self.clipboardHistory.count) {
        NSTextField *empty = [NSTextField labelWithString:@"复制文本、图片或使用 ⌘J 截图后会出现在这里"];
        empty.textColor = NSColor.secondaryLabelColor;
        empty.font = [NSFont systemFontOfSize:12];
        [self.historyStack addArrangedSubview:empty];
        [self updateHistoryDocumentFrame];
        return;
    }
    [self.clipboardHistory enumerateObjectsUsingBlock:^(NSDictionary *item, NSUInteger index, __unused BOOL *stop) {
        BOOL imageItem = [item[@"kind"] isEqual:@"image"];
        NSString *text = item[@"text"] ?: @"";
        NSString *oneLine = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
        if (oneLine.length > 70) oneLine = [[oneLine substringToIndex:70] stringByAppendingString:@"…"];
        NSView *row = [NSView new];
        row.wantsLayer = YES;
        row.layer.cornerRadius = 9;
        row.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:.45].CGColor;
        NSButton *content = [NSButton buttonWithTitle:[NSString stringWithFormat:@"%lu   %@", (unsigned long)index + 1, imageItem ? (text.length ? text : @"截图") : oneLine] target:self action:@selector(useHistoryItem:)];
        content.tag = index;
        content.bordered = NO;
        content.alignment = NSTextAlignmentLeft;
        content.lineBreakMode = NSLineBreakByTruncatingTail;
        content.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        content.contentTintColor = NSColor.labelColor;
        if (imageItem) {
            NSImage *thumbnail = [[NSImage alloc] initWithContentsOfFile:item[@"path"] ?: @""];
            thumbnail.size = NSMakeSize(38, 38);
            content.image = thumbnail;
            content.imagePosition = NSImageLeading;
            content.imageScaling = NSImageScaleProportionallyUpOrDown;
        }
        NSMenu *context = [NSMenu new];
        NSMenuItem *remove = [[NSMenuItem alloc] initWithTitle:@"删除此条" action:@selector(deleteHistoryItem:) keyEquivalent:@""];
        remove.target = self;
        remove.representedObject = item[@"id"];
        [context addItem:remove];
        content.menu = context;

        BOOL busy = [self.inFlightHistoryIDs containsObject:item[@"id"]];
        NSString *state = self.historyActionStates[item[@"id"]];
        NSButton *cloud = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:[state isEqual:@"cloudSuccess"] ? @"checkmark.circle.fill" : @"icloud.and.arrow.up" accessibilityDescription:@"上传临时网盘"] target:self action:@selector(historyAction:)];
        cloud.tag = 1;
        cloud.identifier = item[@"id"];
        cloud.bezelStyle = NSBezelStyleInline;
        cloud.toolTip = busy ? @"处理中…" : @"上传临时网盘";
        cloud.enabled = !busy;
        cloud.contentTintColor = [state isEqual:@"cloudSuccess"] ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
        NSButton *plane = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:[state isEqual:@"planeSuccess"] ? @"checkmark.circle.fill" : @"paperplane.fill" accessibilityDescription:@"发送到 Android"] target:self action:@selector(historyAction:)];
        plane.tag = 2;
        plane.identifier = item[@"id"];
        plane.bezelStyle = NSBezelStyleInline;
        plane.toolTip = busy ? @"处理中…" : @"发送到 Android";
        plane.enabled = !busy;
        plane.contentTintColor = [state isEqual:@"planeSuccess"] ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
        NSButton *copy = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:[state isEqual:@"copySuccess"] ? @"checkmark.circle.fill" : @"doc.on.doc" accessibilityDescription:@"复制到剪贴板"] target:self action:@selector(copyHistoryItem:)];
        copy.identifier = item[@"id"];
        copy.bezelStyle = NSBezelStyleInline;
        copy.toolTip = @"复制到系统剪贴板";
        copy.contentTintColor = [state isEqual:@"copySuccess"] ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
        for (NSButton *button in @[cloud, plane, copy]) {
            button.translatesAutoresizingMaskIntoConstraints = NO;
            [button.widthAnchor constraintEqualToConstant:28].active = YES;
            [button.heightAnchor constraintEqualToConstant:28].active = YES;
        }
        NSStackView *actions = [NSStackView stackViewWithViews:@[cloud, plane, copy]];
        actions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        actions.spacing = 3;
        actions.alignment = NSLayoutAttributeCenterY;
        NSView *trailingSpacer = [NSView new];
        [trailingSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        NSStackView *line = [NSStackView stackViewWithViews:@[content, trailingSpacer, actions]];
        line.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        line.alignment = NSLayoutAttributeCenterY;
        line.spacing = 4;
        line.edgeInsets = NSEdgeInsetsMake(4, 7, 4, 5);
        line.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:line];
        [NSLayoutConstraint activateConstraints:@[
            [line.leadingAnchor constraintEqualToAnchor:row.leadingAnchor], [line.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
            [line.topAnchor constraintEqualToAnchor:row.topAnchor], [line.bottomAnchor constraintEqualToAnchor:row.bottomAnchor]
        ]];
        [content setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self.historyStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.historyStack.widthAnchor].active = YES;
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:imageItem ? 54 : 42].active = YES;
    }];
    [self updateHistoryDocumentFrame];
    [self updateStorageMenu];
}

- (void)updateHistoryDocumentFrame {
    NSRect frame = self.historyStack.frame;
    frame.origin = NSZeroPoint;
    frame.size.width = MAX(self.historyScroll.contentSize.width, 200);
    self.historyStack.frame = frame;
    [self.historyStack layoutSubtreeIfNeeded];
    CGFloat height = self.historyStack.edgeInsets.top + self.historyStack.edgeInsets.bottom;
    NSUInteger count = self.historyStack.arrangedSubviews.count;
    for (NSView *view in self.historyStack.arrangedSubviews) height += MAX(MAX(view.frame.size.height, view.fittingSize.height), 24);
    if (count > 1) height += self.historyStack.spacing * (count - 1);
    frame.size.height = MAX(height, self.historyScroll.contentSize.height);
    self.historyStack.frame = frame;
}

- (void)windowDidResize:(NSNotification *)notification {
    if (notification.object == self.historyPanel) [self updateHistoryDocumentFrame];
}

- (void)showHistoryPanel:(id)sender {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (![front.bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier]) self.previousApplication = front;
    [self refreshHistoryPanel];
    [self.historyPanel makeKeyAndOrderFront:nil];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:HistoryVisibleKey];
}

- (void)useHistoryItem:(NSButton *)sender {
    if (sender.tag < 0 || sender.tag >= (NSInteger)self.clipboardHistory.count) return;
    NSDictionary *item = self.clipboardHistory[sender.tag];
    if (![self writeHistoryItemToPasteboard:item]) return;
    BOOL pinned = [NSUserDefaults.standardUserDefaults boolForKey:HistoryPinnedKey];
    if (!pinned) {
        [self.historyPanel orderOut:nil];
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:HistoryVisibleKey];
    }
    NSRunningApplication *targetApplication = self.previousApplication;
    if (!targetApplication) {
        [self setStatusOK:NO message:@"内容已复制；请先打开要粘贴的窗口后再点历史"];
        return;
    }
    [self pasteHistoryIntoApplication:targetApplication attempt:0];
}

- (void)openWindow:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)toggleMainWindow:(id)sender {
    if (self.window.isVisible) {
        [self.window orderOut:nil];
    } else {
        [self openWindow:nil];
    }
}

- (void)toggleHistoryPanel:(id)sender {
    if (self.historyPanel.isVisible) {
        if ([NSUserDefaults.standardUserDefaults boolForKey:HistoryPinnedKey]) return;
        [self.historyPanel orderOut:nil];
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:HistoryVisibleKey];
    } else {
        [self showHistoryPanel:sender];
    }
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [sender orderOut:nil];
    if (sender == self.historyPanel) [NSUserDefaults.standardUserDefaults setBool:NO forKey:HistoryVisibleKey];
    return NO;
}

- (void)captureRegion:(id)sender {
    if (self.captureTask.running) return;
    if (!CGPreflightScreenCaptureAccess()) {
        [self requestScreenCapturePermission:sender];
        return;
    }
    NSInteger before = NSPasteboard.generalPasteboard.changeCount;
    self.captureTask = [NSTask new];
    self.captureTask.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
    self.captureTask.arguments = @[@"-i", @"-c", @"-x"];
    __weak typeof(self) weakSelf = self;
    self.captureTask.terminationHandler = ^(__unused NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            self.captureTask = nil;
            NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
            NSData *png = pasteboard.changeCount == before ? nil : [pasteboard dataForType:NSPasteboardTypePNG];
            if (!png.length) { [self setStatusOK:YES message:@"已取消区域截图"]; return; }
            self.pasteboardChangeCount = pasteboard.changeCount;
            [self addImageDataToHistory:png title:@"区域截图"];
            [self setStatusOK:YES message:@"截图已保存到本地历史"];
        });
    };
    NSError *error = nil;
    if (![self.captureTask launchAndReturnError:&error]) {
        self.captureTask = nil;
        [self setStatusOK:NO message:error.localizedDescription ?: @"无法启动区域截图"];
    } else {
        self.statusMenuItem.title = @"状态：请框选截图区域";
    }
}

- (void)openPrivacyPane:(NSString *)anchor {
    NSString *value = [NSString stringWithFormat:@"x-apple.systempreferences:com.apple.preference.security?%@", anchor];
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:value]];
}

- (void)requestScreenCapturePermission:(id)sender {
    if (CGPreflightScreenCaptureAccess()) {
        [self setStatusOK:YES message:@"屏幕录制权限已开启"];
        return;
    }
    BOOL granted = CGRequestScreenCaptureAccess();
    if (granted) {
        [self setStatusOK:YES message:@"屏幕录制权限已开启，请再次使用 ⌘J"];
        return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"需要屏幕录制权限才能截图";
    alert.informativeText = @"如果「屏幕录制」列表里已有 CopySync 但勾选后仍无效（多见于更新后旧授权失效），请选中 CopySync 点「−」删除，再点「＋」重新添加本应用并勾选，然后重启 CopySync。";
    [alert addButtonWithTitle:@"打开系统设置"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] == NSAlertFirstButtonReturn) [self openPrivacyPane:@"Privacy_ScreenCapture"];
    [self setStatusOK:NO message:@"允许屏幕录制并重启 CopySync 后即可截图"];
}

- (void)requestPastePermission:(id)sender {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    BOOL eventAccess = CGRequestPostEventAccess();
    if (eventAccess) {
        [self setStatusOK:YES message:@"辅助功能权限已开启，可以点击历史直接粘贴"];
    } else {
        [self setStatusOK:NO message:@"请在系统设置的辅助功能中允许 CopySync，然后重新打开应用"];
        [self openPrivacyPane:@"Privacy_Accessibility"];
    }
}

- (void)checkForUpdates:(id)sender {
    [self checkForUpdatesInteractive:YES];
}

- (void)checkForUpdatesInteractive:(BOOL)interactive {
    if (interactive) [self setStatusOK:YES message:@"正在检查更新"];
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:UpdateManifest] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *latest = [manifest[@"version"] isKindOfClass:NSString.class] ? manifest[@"version"] : nil;
        NSString *current = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0";
        BOOL newer = latest.length && [latest compare:current options:NSNumericSearch] == NSOrderedDescending;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !manifest) {
                if (interactive) [self setStatusOK:NO message:@"检查更新失败"];
                return;
            }
            if (!newer) {
                if (interactive) [self setStatusOK:YES message:@"已经是最新版"];
                return;
            }
            [NSApp activateIgnoringOtherApps:YES];
            [self.window makeKeyAndOrderFront:nil];
            NSAlert *alert = [NSAlert new];
            alert.messageText = [NSString stringWithFormat:@"发现 CopySync %@", latest];
            alert.informativeText = manifest[@"notes"] ?: @"下载后将自动更新并重新打开。";
            [alert addButtonWithTitle:@"立即更新"];
            [alert addButtonWithTitle:@"稍后"];
            [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
                if (result == NSAlertFirstButtonReturn) [self downloadMacUpdate:manifest];
            }];
        });
    }];
    [task resume];
}

- (NSString *)sha256ForURL:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *value = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [value appendFormat:@"%02x", digest[i]];
    return value;
}

- (void)downloadMacUpdate:(NSDictionary *)manifest {
    NSURL *url = [NSURL URLWithString:manifest[@"url"] ?: @""];
    NSString *expected = [manifest[@"sha256"] lowercaseString];
    if (!url || !expected.length) { [self setStatusOK:NO message:@"更新清单无效"]; return; }
    [self setStatusOK:YES message:@"正在下载更新"];
    NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSURL *zip = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"CopySync-update-%@.zip", NSUUID.UUID.UUIDString]]];
        BOOL copied = location && [NSFileManager.defaultManager copyItemAtURL:location toURL:zip error:nil];
        if (error || !copied || ![[self sha256ForURL:zip] isEqualToString:expected]) {
            [NSFileManager.defaultManager removeItemAtURL:zip error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ [self setStatusOK:NO message:@"更新下载或校验失败"]; });
            return;
        }
        [self installMacUpdate:zip];
    }];
    [task resume];
}

- (BOOL)runTask:(NSString *)executable arguments:(NSArray<NSString *> *)arguments {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    if (![task launchAndReturnError:nil]) return NO;
    [task waitUntilExit];
    return task.terminationStatus == 0;
}

- (NSString *)shellQuote:(NSString *)value {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

- (NSString *)appleScriptLiteral:(NSString *)value {
    return [NSString stringWithFormat:@"\"%@\"", [[value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
}

- (void)installMacUpdate:(NSURL *)zip {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *unpack = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"CopySync-unpack-%@", NSUUID.UUID.UUIDString]];
        [NSFileManager.defaultManager createDirectoryAtPath:unpack withIntermediateDirectories:YES attributes:nil error:nil];
        if (![self runTask:@"/usr/bin/ditto" arguments:@[@"-x", @"-k", zip.path, unpack]]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self setStatusOK:NO message:@"无法解压更新"]; });
            return;
        }
        NSString *source = [unpack stringByAppendingPathComponent:@"CopySync.app"];
        NSString *destination = NSBundle.mainBundle.bundlePath;
        if (![NSFileManager.defaultManager fileExistsAtPath:[source stringByAppendingPathComponent:@"Contents/MacOS/CopySync"]]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self setStatusOK:NO message:@"更新包不完整"]; });
            return;
        }
        NSString *helper = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"copysync-update-%@.sh", NSUUID.UUID.UUIDString]];
        NSString *script = @"#!/bin/sh\nset -eu\ndest=$1\nsrc=$2\nold=\"${dest}.update-old\"\nrm -rf \"$old\"\nmv \"$dest\" \"$old\"\nmv \"$src\" \"$dest\"\nrm -rf \"$old\"\n";
        [script writeToFile:helper atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0700} ofItemAtPath:helper error:nil];
        BOOL writable = [NSFileManager.defaultManager isWritableFileAtPath:destination.stringByDeletingLastPathComponent];
        BOOL installed;
        if (writable) {
            installed = [self runTask:helper arguments:@[destination, source]];
        } else {
            NSString *command = [NSString stringWithFormat:@"%@ %@ %@", [self shellQuote:helper], [self shellQuote:destination], [self shellQuote:source]];
            NSString *appleScript = [NSString stringWithFormat:@"do shell script %@ with administrator privileges", [self appleScriptLiteral:command]];
            installed = [self runTask:@"/usr/bin/osascript" arguments:@[@"-e", appleScript]];
        }
        if (!installed) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self setStatusOK:NO message:@"更新安装失败"]; });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setStatusOK:YES message:@"更新完成，正在重新打开"];
            NSTask *relaunch = [NSTask new];
            relaunch.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
            relaunch.arguments = @[@"-c", @"sleep 1; /usr/bin/open \"$1\"", @"CopySyncUpdater", destination];
            [relaunch launchAndReturnError:nil];
            [NSApp terminate:nil];
        });
    });
}

- (void)installWindowHotKey {
    EventTypeSpec eventType = {kEventClassKeyboard, kEventHotKeyPressed};
    OSStatus handlerStatus = InstallApplicationEventHandler(windowHotKeyCallback, 1, &eventType, (__bridge void *)self, &_windowHotKeyHandler);
    EventHotKeyID hotKeyID = {'CPSY', 1};
    OSStatus hotKeyStatus = RegisterEventHotKey(kVK_ANSI_Period, cmdKey, hotKeyID, GetApplicationEventTarget(), 0, &_windowHotKey);
    EventHotKeyID screenshotID = {'CPSY', 2};
    OSStatus screenshotStatus = RegisterEventHotKey(kVK_ANSI_J, cmdKey, screenshotID, GetApplicationEventTarget(), 0, &_screenshotHotKey);
    EventHotKeyID historyID = {'CPSY', 3};
    OSStatus historyStatus = RegisterEventHotKey(kVK_ANSI_Comma, cmdKey, historyID, GetApplicationEventTarget(), 0, &_historyHotKey);
    [NSUserDefaults.standardUserDefaults setInteger:handlerStatus forKey:@"CopySync.hotKeyHandlerStatus"];
    [NSUserDefaults.standardUserDefaults setInteger:hotKeyStatus forKey:@"CopySync.hotKeyStatus"];
    [NSUserDefaults.standardUserDefaults setInteger:screenshotStatus forKey:@"CopySync.screenshotHotKeyStatus"];
    [NSUserDefaults.standardUserDefaults setInteger:historyStatus forKey:@"historyHotKeyStatus"];
    [NSUserDefaults.standardUserDefaults synchronize];
    if (handlerStatus != noErr || hotKeyStatus != noErr || screenshotStatus != noErr || historyStatus != noErr)
        [self setStatusOK:NO message:[NSString stringWithFormat:@"全局快捷键注册失败（%d）", (int)historyStatus]];
}

- (void)installHistoryHotKey {
    if (self.historyHotKey) UnregisterEventHotKey(self.historyHotKey), self.historyHotKey = NULL;
    NSString *shortcut = [NSUserDefaults.standardUserDefaults stringForKey:HistoryShortcutKey] ?: @"commandComma";
    UInt32 key = [shortcut isEqual:@"commandComma"] ? kVK_ANSI_Comma : kVK_ANSI_V;
    UInt32 modifiers = [shortcut isEqual:@"option"] ? optionKey : [shortcut isEqual:@"commandShift"] ? cmdKey | shiftKey : cmdKey;
    EventHotKeyID historyID = {'CPSY', 3};
    OSStatus status = RegisterEventHotKey(key, modifiers, historyID, GetApplicationEventTarget(), 0, &_historyHotKey);
    [NSUserDefaults.standardUserDefaults setInteger:status forKey:@"historyHotKeyStatus"];
    [NSUserDefaults.standardUserDefaults synchronize];
    if (status != noErr) [self setStatusOK:NO message:@"历史快捷键注册失败"];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.windowHotKey) UnregisterEventHotKey(self.windowHotKey);
    if (self.screenshotHotKey) UnregisterEventHotKey(self.screenshotHotKey);
    if (self.historyHotKey) UnregisterEventHotKey(self.historyHotKey);
    if (self.windowHotKeyHandler) RemoveEventHandler(self.windowHotKeyHandler);
}

- (void)updateLaunchAtLoginMenu {
    self.launchAtLoginMenuItem.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleLaunchAtLogin:(id)sender {
    NSError *error = nil;
    SMAppService *service = SMAppService.mainAppService;
    BOOL success = service.status == SMAppServiceStatusEnabled ? [service unregisterAndReturnError:&error] : [service registerAndReturnError:&error];
    [self updateLaunchAtLoginMenu];
    [self setStatusOK:success message:success ? @"登录启动设置已更新" : error.localizedDescription];
}

- (void)updatePreferenceMenus {
    BOOL showFooter = [NSUserDefaults.standardUserDefaults boolForKey:ShowFooterKey];
    self.showFooterMenuItem.state = showFooter ? NSControlStateValueOn : NSControlStateValueOff;
    self.footerLabel.hidden = !showFooter;
    self.footerLabel.stringValue = @"本地历史已开启 · 复制不自动上传 · ⌘J 截图 · ⌘, 历史悬浮贴";
}

- (void)ignoreNextCopy:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:IgnoreNextCopyKey];
    self.statusMenuItem.title = @"状态：下一次复制将被忽略";
}

- (void)toggleFooter:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:![NSUserDefaults.standardUserDefaults boolForKey:ShowFooterKey] forKey:ShowFooterKey];
    [self updatePreferenceMenus];
}

- (void)showPreferences:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
    NSButton *footer = [NSButton checkboxWithTitle:@"显示底部状态栏" target:self action:@selector(toggleFooter:)];
    footer.state = [NSUserDefaults.standardUserDefaults boolForKey:ShowFooterKey] ? NSControlStateValueOn : NSControlStateValueOff;
    NSButton *ignoreNext = [NSButton buttonWithTitle:@"忽略下一次复制" target:self action:@selector(ignoreNextCopy:)];
    NSButton *openReceived = [NSButton buttonWithTitle:@"打开接收文件夹" target:self action:@selector(openReceivedFolder:)];
    NSString *screenTitle = CGPreflightScreenCaptureAccess() ? @"屏幕录制：已允许" : @"请求屏幕录制权限";
    NSButton *screenPermission = [NSButton buttonWithTitle:screenTitle target:self action:@selector(requestScreenCapturePermission:)];
    NSString *pasteTitle = CGPreflightPostEventAccess() ? @"直接粘贴：已允许" : @"请求直接粘贴权限";
    NSButton *pastePermission = [NSButton buttonWithTitle:pasteTitle target:self action:@selector(requestPastePermission:)];
    NSTextField *targetLabel = [NSTextField labelWithString:@"默认发送到"];
    NSPopUpButton *target = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [target addItemsWithTitles:@[@"全部设备", @"Android 手机"]];
    NSDictionary *targetIndexes = @{@"all":@0, @"android":@1};
    [target selectItemAtIndex:[targetIndexes[[NSUserDefaults.standardUserDefaults stringForKey:DefaultTargetKey] ?: @"all"] integerValue]];
    NSButton *syncWeb = [NSButton checkboxWithTitle:@"目标是否同步到网页" target:nil action:nil];
    syncWeb.state = [NSUserDefaults.standardUserDefaults boolForKey:SyncWebKey] ? NSControlStateValueOn : NSControlStateValueOff;
    NSTextField *shortcutLabel = [NSTextField labelWithString:@"历史悬浮贴快捷键"];
    NSPopUpButton *shortcut = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [shortcut addItemsWithTitles:@[@"⌘,", @"⌥V", @"⇧⌘V"]];
    NSDictionary *shortcutIndexes = @{@"commandComma":@0, @"option":@1, @"commandShift":@2};
    [shortcut selectItemAtIndex:[shortcutIndexes[[NSUserDefaults.standardUserDefaults stringForKey:HistoryShortcutKey] ?: @"commandComma"] integerValue]];
    NSTextField *localNote = [NSTextField wrappingLabelWithString:@"本地复制和截图只保存到历史；需要时点击云朵上传临时网盘，或点击小飞机发送到 Android。"];
    localNote.textColor = NSColor.secondaryLabelColor;
    NSStackView *settings = [NSStackView stackViewWithViews:@[targetLabel, target, syncWeb, shortcutLabel, shortcut, localNote, screenPermission, pastePermission, openReceived, footer, ignoreNext]];
    settings.orientation = NSUserInterfaceLayoutOrientationVertical;
    settings.alignment = NSLayoutAttributeLeading;
    settings.spacing = 10;
    settings.frame = NSMakeRect(0, 0, 390, 370);
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"CopySync 偏好设置";
    alert.informativeText = @"⌘V 始终保留为系统正常粘贴；历史快捷键可单独选择。";
    alert.accessoryView = settings;
    [alert addButtonWithTitle:@"完成"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(__unused NSModalResponse response) {
        NSArray *targets = @[@"all", @"android"];
        NSArray *shortcuts = @[@"commandComma", @"option", @"commandShift"];
        [NSUserDefaults.standardUserDefaults setObject:targets[target.indexOfSelectedItem] forKey:DefaultTargetKey];
        [NSUserDefaults.standardUserDefaults setBool:syncWeb.state == NSControlStateValueOn forKey:SyncWebKey];
        [NSUserDefaults.standardUserDefaults setObject:shortcuts[shortcut.indexOfSelectedItem] forKey:HistoryShortcutKey];
        [self installHistoryHotKey];
        [self setStatusOK:YES message:@"偏好设置已保存"];
    }];
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL result))completionHandler {
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    [alert addButtonWithTitle:@"确定"];
    [alert addButtonWithTitle:@"取消"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) { completionHandler(response == NSAlertFirstButtonReturn); }];
}

- (void)scheduleWebViewRecovery:(NSError *)error {
    if (error && (([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) ||
                  ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == WebKitPolicyChangeError))) return;
    if (self.webRecoveryScheduled) return;
    self.webRecoveryScheduled = YES;
    [self setStatusOK:NO message:@"页面连接中断，正在恢复"];
    [self performSelector:@selector(recoverWebView) withObject:nil afterDelay:1.0];
}

- (void)recoverWebView {
    self.webRecoveryScheduled = NO;
    self.webRecoveryInProgress = YES;
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:Site]
                                             cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                         timeoutInterval:30];
    [self.webView loadRequest:request];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (webView == self.webView) [self scheduleWebViewRecovery:error];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (webView == self.webView) [self scheduleWebViewRecovery:error];
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    if (webView == self.webView) [self scheduleWebViewRecovery:nil];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    BOOL recovered = self.webRecoveryInProgress;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(recoverWebView) object:nil];
    self.webRecoveryScheduled = NO;
    self.webRecoveryInProgress = NO;
    if (recovered) [self setStatusOK:YES message:@"页面已恢复"];
    NSString *script = @"(function(){fetch('/api/devices/mac/heartbeat',{method:'POST'}).catch(()=>{});if(window.__copySyncMac)return;window.__copySyncMac=true;let checking=false;let check=async()=>{if(checking)return;checking=true;try{const r=await fetch('/api/transfers?device=mac',{cache:'no-store'}),d=await r.json();for(const t of d.transfers){window.webkit.messageHandlers.copySync.postMessage({type:'incoming',id:t.id,item_id:t.item_id,name:t.name||'新内容',kind:t.kind,mime:t.mime||'',size:t.size||0});if(t.kind==='text')await fetch('/api/deliveries/'+t.id+'/ack',{method:'POST',body:new URLSearchParams({status:'delivered'})})}}catch(e){}finally{checking=false}};let es=new EventSource('/api/events');es.addEventListener('items',check);es.onopen=check;check()})()";
    [webView evaluateJavaScript:script completionHandler:nil];
}

- (NSURL *)uniqueReceivedURLForName:(NSString *)name {
    NSString *safeName = name.lastPathComponent.length ? name.lastPathComponent : @"CopySync-file";
    NSURL *destination = [[self receivedFilesURL] URLByAppendingPathComponent:safeName];
    if (![NSFileManager.defaultManager fileExistsAtPath:destination.path]) return destination;
    NSString *extension = safeName.pathExtension;
    NSString *base = safeName.stringByDeletingPathExtension;
    NSString *suffix = [NSUUID.UUID.UUIDString substringToIndex:8];
    NSString *uniqueName = extension.length ? [NSString stringWithFormat:@"%@-%@.%@", base, suffix, extension] : [NSString stringWithFormat:@"%@-%@", base, suffix];
    return [[self receivedFilesURL] URLByAppendingPathComponent:uniqueName];
}

- (void)ackDelivery:(NSString *)deliveryID status:(NSString *)status cookieHeader:(NSString *)cookieHeader {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://copy-direct.example.com/api/deliveries/%@/ack", deliveryID]]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [[NSString stringWithFormat:@"status=%@", status] dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    if (cookieHeader.length) [request setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request] resume];
}

- (void)receiveIncomingFile:(NSDictionary *)delivery {
    NSString *deliveryID = delivery[@"id"] ?: @"";
    NSString *itemID = delivery[@"item_id"] ?: @"";
    if (!deliveryID.length || !itemID.length || [self.incomingDeliveryIDs containsObject:deliveryID]) return;
    [self.incomingDeliveryIDs addObject:deliveryID];
    [self.webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSString *cookieHeader = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies][@"Cookie"] ?: @"";
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://copy-direct.example.com/download/%@", itemID]]];
        if (cookieHeader.length) [request setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
        [[[NSURLSession sharedSession] downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            BOOL downloaded = !error && http.statusCode >= 200 && http.statusCode < 300 && location;
            NSURL *destination = nil;
            if (downloaded) {
                [self ensureCacheFolders];
                destination = [self uniqueReceivedURLForName:delivery[@"name"]];
                downloaded = [NSFileManager.defaultManager moveItemAtURL:location toURL:destination error:&error];
            }
            if (downloaded) [self ackDelivery:deliveryID status:@"downloaded" cookieHeader:cookieHeader];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.incomingDeliveryIDs removeObject:deliveryID];
                if (downloaded) {
                    NSString *name = destination.lastPathComponent ?: @"文件";
                    self.receivedDeliveryPaths[deliveryID] = destination.path;
                    [NSUserDefaults.standardUserDefaults setObject:self.receivedDeliveryPaths forKey:ReceivedDeliveryPathsKey];
                    [self setStatusOK:YES message:[NSString stringWithFormat:@"已接收：%@", name]];
                    UNMutableNotificationContent *notice = [UNMutableNotificationContent new];
                    notice.title = @"CopySync 文件已接收";
                    notice.body = name;
                    notice.sound = UNNotificationSound.defaultSound;
                    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:[UNNotificationRequest requestWithIdentifier:deliveryID content:notice trigger:nil] withCompletionHandler:nil];
                } else {
                    [self setStatusOK:NO message:[NSString stringWithFormat:@"接收失败，稍后重试：%@", error.localizedDescription ?: @"下载错误"]];
                }
                [self updateStorageMenu];
            });
        }] resume];
    }];
}

- (void)saveSentItemID:(NSString *)itemID name:(NSString *)name {
    if (!itemID.length) return;
    NSString *storageKey = [@"sent:" stringByAppendingString:itemID];
    NSString *savedPath = self.receivedDeliveryPaths[storageKey];
    if (savedPath.length && [NSFileManager.defaultManager fileExistsAtPath:savedPath]) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:savedPath]]];
        [self setStatusOK:YES message:[NSString stringWithFormat:@"已在 Finder 中显示：%@", savedPath.lastPathComponent]];
        return;
    }
    if ([self.incomingDeliveryIDs containsObject:storageKey]) {
        [self setStatusOK:YES message:@"文件正在保存到 CopySync"];
        return;
    }
    [self.incomingDeliveryIDs addObject:storageKey];
    [self.webView.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSString *cookieHeader = [NSHTTPCookie requestHeaderFieldsWithCookies:cookies][@"Cookie"] ?: @"";
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://copy-direct.example.com/download/%@", itemID]]];
        if (cookieHeader.length) [request setValue:cookieHeader forHTTPHeaderField:@"Cookie"];
        [[[NSURLSession sharedSession] downloadTaskWithRequest:request completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            BOOL downloaded = !error && http.statusCode >= 200 && http.statusCode < 300 && location;
            NSURL *destination = nil;
            if (downloaded) {
                [self ensureCacheFolders];
                destination = [self uniqueReceivedURLForName:name];
                downloaded = [NSFileManager.defaultManager moveItemAtURL:location toURL:destination error:&error];
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.incomingDeliveryIDs removeObject:storageKey];
                if (downloaded) {
                    self.receivedDeliveryPaths[storageKey] = destination.path;
                    [NSUserDefaults.standardUserDefaults setObject:self.receivedDeliveryPaths forKey:ReceivedDeliveryPathsKey];
                    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[destination]];
                    [self setStatusOK:YES message:[NSString stringWithFormat:@"已在 Finder 中显示：%@", destination.lastPathComponent]];
                } else {
                    [self setStatusOK:NO message:[NSString stringWithFormat:@"保存已发送文件失败：%@", error.localizedDescription ?: @"下载错误"]];
                }
            });
        }] resume];
    }];
}

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    [alert addButtonWithTitle:@"确定"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(__unused NSModalResponse response) { completionHandler(); }];
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *result))completionHandler {
    if ([prompt isEqualToString:@"copysync-copy"]) {
        NSString *downloadLink = [NSString stringWithFormat:@"https://copy-direct.example.com/download/%@", defaultText ?: @""];
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        [pasteboard clearContents];
        BOOL copied = [pasteboard writeObjects:@[downloadLink]];
        self.pasteboardChangeCount = pasteboard.changeCount;
        if (!copied) [self setStatusOK:NO message:@"复制下载链接失败"];
        completionHandler(copied ? @"ok" : @"");
        return;
    }
    completionHandler(defaultText ?: @"");
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    if ([url.scheme isEqualToString:@"copysync-copy"]) {
        NSString *itemID = url.lastPathComponent.stringByRemovingPercentEncoding ?: @"";
        NSString *downloadLink = [NSString stringWithFormat:@"https://copy-direct.example.com/download/%@", itemID];
        NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
        [pasteboard clearContents];
        BOOL copied = [pasteboard writeObjects:@[downloadLink]];
        self.pasteboardChangeCount = pasteboard.changeCount;
        if (!copied) [self setStatusOK:NO message:@"复制下载链接失败"];
        decisionHandler(WKNavigationActionPolicyCancel);
    } else if (navigationAction.shouldPerformDownload || [url.path hasPrefix:@"/download/"]) {
        decisionHandler(WKNavigationActionPolicyDownload);
    } else {
        decisionHandler(WKNavigationActionPolicyAllow);
    }
}

- (void)webView:(WKWebView *)webView navigationAction:(WKNavigationAction *)navigationAction didBecomeDownload:(WKDownload *)download {
    download.delegate = self;
}

- (void)webView:(WKWebView *)webView navigationResponse:(WKNavigationResponse *)navigationResponse didBecomeDownload:(WKDownload *)download {
    download.delegate = self;
}

- (void)download:(WKDownload *)download decideDestinationUsingResponse:(NSURLResponse *)response suggestedFilename:(NSString *)suggestedFilename completionHandler:(void (^)(NSURL *destination))completionHandler {
    [self ensureCacheFolders];
    NSURL *destination = [self uniqueReceivedURLForName:suggestedFilename ?: @"CopySync-download"];
    [self.webDownloadDestinations setObject:destination forKey:download];
    completionHandler(destination);
}

- (void)downloadDidFinish:(WKDownload *)download {
    NSURL *destination = [self.webDownloadDestinations objectForKey:download];
    [self.webDownloadDestinations removeObjectForKey:download];
    if (destination) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[destination]];
    [self setStatusOK:YES message:destination ? [NSString stringWithFormat:@"已在 Finder 中显示：%@", destination.lastPathComponent] : @"下载完成"];
}

- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData {
    [self.webDownloadDestinations removeObjectForKey:download];
    [self setStatusOK:NO message:error.localizedDescription ?: @"下载失败"];
}

- (NSString *)jsonArray:(id)value {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[value ?: NSNull.null] options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)setStatusOK:(BOOL)ok message:(NSString *)message {
    self.statusMenuItem.title = [@"状态：" stringByAppendingString:message ?: @"未知错误"];
    self.footerLabel.stringValue = [NSString stringWithFormat:@"%@ %@", ok ? @"✓" : @"⚠︎", message ?: @"未知错误"];
}

- (void)pollWebClipboardRequest {
    NSString *script = @"(()=>{const url=window.__copyDownloadUrl||'';window.__copyDownloadUrl='';return url})()";
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (error || ![result isKindOfClass:NSString.class] || ![result length]) return;
        NSString *downloadLink = result;
        NSString *escapedLink = [[downloadLink stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        NSString *appleScript = [NSString stringWithFormat:@"set the clipboard to \"%@\"", escapedLink];
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
        task.arguments = @[@"-e", appleScript];
        NSPipe *errorPipe = [NSPipe pipe];
        task.standardError = errorPipe;
        task.terminationHandler = ^(NSTask *finished) {
            NSData *errorData = [errorPipe.fileHandleForReading readDataToEndOfFile];
            NSString *errorText = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.pasteboardChangeCount = NSPasteboard.generalPasteboard.changeCount;
                if (finished.terminationStatus != 0) [self setStatusOK:NO message:errorText.length ? errorText : [NSString stringWithFormat:@"复制失败（%d）", finished.terminationStatus]];
            });
        };
        NSError *launchError = nil;
        if (![task launchAndReturnError:&launchError]) {
            [self setStatusOK:NO message:launchError.localizedDescription ?: @"复制下载链接失败"];
        }
    }];
}

- (void)watchPasteboard {
    NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
    if (pasteboard.changeCount == self.pasteboardChangeCount) return;
    self.pasteboardChangeCount = pasteboard.changeCount;
    if ([pasteboard availableTypeFromArray:@[CopySyncPasteboardType]]) return;
    if ([NSUserDefaults.standardUserDefaults boolForKey:IgnoreNextCopyKey]) {
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:IgnoreNextCopyKey];
        [self setStatusOK:YES message:@"已忽略一次复制"];
        return;
    }
    NSData *png = [self pngDataFromPasteboard:pasteboard];
    if (png.length) {
        [self addImageDataToHistory:png title:@"复制的图片"];
        [self setStatusOK:YES message:@"图片已保存到本地历史"];
        return;
    }
    NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
    if (!text.length) return;
    [self addTextToHistory:text];
    [self setStatusOK:YES message:@"文本已保存到本地历史"];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : @{};
    NSString *type = body[@"type"];
    if ([type isEqual:@"historyAction"]) {
        NSString *identifier = body[@"id"] ?: @"";
        NSString *action = body[@"action"] ?: @"";
        [self.inFlightHistoryIDs removeObject:identifier];
        if ([body[@"ok"] boolValue]) {
            self.historyActionStates[identifier] = [action isEqual:@"cloud"] ? @"cloudSuccess" : @"planeSuccess";
            [self setStatusOK:YES message:[action isEqual:@"cloud"] ? @"已上传到临时网盘" : @"已发送到 Android（离线时等待上线接收）"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                [self.historyActionStates removeObjectForKey:identifier];
                [self refreshHistoryPanel];
            });
        } else {
            [self setStatusOK:NO message:body[@"error"] ?: @"操作失败"];
        }
        [self pruneHistory];
        [self saveHistory];
        [self refreshHistoryPanel];
    } else if ([type isEqual:@"latest"]) {
        NSString *text = body[@"text"];
        if ([body[@"ok"] boolValue] && text.length) {
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
            [NSPasteboard.generalPasteboard setString:@"" forType:CopySyncPasteboardType];
            self.pasteboardChangeCount = NSPasteboard.generalPasteboard.changeCount;
        }
        [self sendCommandV];
    } else if ([type isEqual:@"incoming"]) {
        if (![body[@"kind"] isEqual:@"text"]) {
            [self receiveIncomingFile:body];
            return;
        }
        UNMutableNotificationContent *notice = [UNMutableNotificationContent new];
        notice.title = @"CopySync 收到新内容";
        notice.body = body[@"name"] ?: @"来自其他设备";
        notice.sound = UNNotificationSound.defaultSound;
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:body[@"id"] ?: NSUUID.UUID.UUIDString content:notice trigger:nil];
        [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
        [self setStatusOK:YES message:[NSString stringWithFormat:@"收到：%@", body[@"name"] ?: @"新内容"]];
    } else if ([type isEqual:@"revealReceived"]) {
        [self revealReceivedDelivery:body[@"id"] name:body[@"name"]];
    } else if ([type isEqual:@"saveSent"]) {
        [self saveSentItemID:body[@"item_id"] name:body[@"name"]];
    } else if ([type isEqual:@"copyText"]) {
        id rawText = body[@"text"];
        NSString *copiedText = [rawText isKindOfClass:NSString.class] ? rawText : ([rawText respondsToSelector:@selector(description)] ? [rawText description] : @"");
        dispatch_async(dispatch_get_main_queue(), ^{
            NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
            [pasteboard clearContents];
            BOOL copied = [pasteboard writeObjects:@[copiedText ?: @""]];
            self.pasteboardChangeCount = pasteboard.changeCount;
            if (!copied) [self setStatusOK:NO message:@"复制下载链接失败"];
        });
    } else if ([type isEqual:@"readClipboard"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
            NSString *argument = @"null";
            if (text) {
                NSData *json = [NSJSONSerialization dataWithJSONObject:@[text] options:0 error:nil];
                NSString *payload = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
                if (payload.length >= 2) argument = [payload substringWithRange:NSMakeRange(1, payload.length - 2)];
            }
            NSString *script = [NSString stringWithFormat:@"window.__copysyncClipboardCallback && window.__copysyncClipboardCallback(%@)", argument];
            [self.webView evaluateJavaScript:script completionHandler:nil];
        });
    } else if ([type isEqual:@"openWeb"]) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://copy-direct.example.com/"]];
    }
}

- (void)webView:(WKWebView *)webView runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSArray<NSURL *> *URLs))completionHandler {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection;
    panel.canChooseDirectories = parameters.allowsDirectories;
    panel.canChooseFiles = YES;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        completionHandler(result == NSModalResponseOK ? panel.URLs : nil);
    }];
}

- (void)pasteLatestText {
    NSString *script = @"(async()=>{try{const r=await fetch('/api/items');if(!r.ok)throw new Error('读取失败 '+r.status);const {items}=await r.json(),item=items.filter(i=>i.kind==='text'&&i.text).sort((a,b)=>b.created_at-a.created_at)[0];if(!item)throw new Error('没有文本');window.webkit.messageHandlers.copySync.postMessage({type:'latest',ok:true,text:item.text});}catch(e){window.webkit.messageHandlers.copySync.postMessage({type:'latest',ok:false,error:String(e&&e.message||e)});}})();";
    [self.webView evaluateJavaScript:script completionHandler:^(__unused id result, NSError *error) { if (error) [self sendCommandV]; }];
}

- (void)sendCommandV {
    [self sendCommandVToApplication:nil];
}

- (void)sendCommandVToApplication:(NSRunningApplication *)application {
    if (!CGPreflightPostEventAccess()) {
        [self requestPastePermission:nil];
        [self setStatusOK:NO message:@"内容已复制；允许辅助功能后，再点击即可直接粘贴"];
        return;
    }
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    CGKeyCode keys[] = {kVK_Command, kVK_ANSI_V, kVK_ANSI_V, kVK_Command};
    bool downs[] = {true, true, false, false};
    for (NSUInteger index = 0; index < 4; index++) {
        CGEventRef event = CGEventCreateKeyboardEvent(source, keys[index], downs[index]);
        if (index < 3) CGEventSetFlags(event, kCGEventFlagMaskCommand);
        CGEventSetIntegerValueField(event, kCGEventSourceUserData, PasteSignature);
        CGEventPost(kCGSessionEventTap, event);
        CFRelease(event);
    }
    CFRelease(source);
    [self setStatusOK:YES message:[NSString stringWithFormat:@"已粘贴到 %@", application.localizedName ?: @"当前窗口"]];
}

- (void)pasteHistoryIntoApplication:(NSRunningApplication *)application attempt:(NSUInteger)attempt {
    if (!CGPreflightPostEventAccess()) {
        [self sendCommandVToApplication:application];
        return;
    }
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (application && front.processIdentifier != application.processIdentifier && attempt < 12) {
        [application activateWithOptions:NSApplicationActivateAllWindows];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [self pasteHistoryIntoApplication:application attempt:attempt + 1];
        });
        return;
    }
    [self sendCommandVToApplication:application];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        CopySyncDelegate = [CopySyncApp new];
        app.delegate = CopySyncDelegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}
