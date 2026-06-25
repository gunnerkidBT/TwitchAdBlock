#import "TWABSettingsVC.h"
#import "Config.h"
#import "SettingsKeys.h"
#import "NSURLSession+TwitchAdBlock.h"

extern NSBundle *tweakBundle;
extern NSUserDefaults *tweakDefaults;
// Emotes.x — clears the emote registry and re-fetches global sets.
extern void twab_reloadEmotes(void);
// Tweak.x — [{ @"name": NSString, @"present": @(BOOL) }, ...] for the
// hooked Twitch classes, recorded at launch.
extern NSArray<NSDictionary *> *twab_classDiagnostics(void);

#define LOC(x, d) (tweakBundle ? [tweakBundle localizedStringForKey:x value:d table:nil] : (d))

// Read-only screen listing which hooked Twitch/TwitchKit/Apollo classes
// resolved in the running binary. ✓ = hook active; ✗ = Twitch renamed or
// removed the class and that feature is silently inactive until updated.
@interface TWABDiagnosticsVC : UITableViewController
@end

@implementation TWABDiagnosticsVC {
    NSArray<NSDictionary *> *_items;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"settings.diag.title", @"Diagnostics");
    _items = twab_classDiagnostics() ?: @[];
    // Only show "Done" when we're the root of a presented nav controller
    // (settings had no nav, so showDiagnostics wrapped + presented us). When
    // pushed onto an existing nav stack, the back button handles dismissal —
    // adding Done there would tear down the whole settings flow.
    BOOL isPresentedRoot = self.navigationController.viewControllers.firstObject == self &&
                           self.navigationController.presentingViewController != nil;
    if (isPresentedRoot) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                          target:self
                                                          action:@selector(twabDone)];
    }
}
- (void)twabDone { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 1; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)_items.count;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:@"diag"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                             reuseIdentifier:@"diag"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSDictionary *item = _items[ip.row];
    BOOL present = [item[@"present"] boolValue];
    NSString *status = present ? LOC(@"settings.diag.ok", @"✓ OK")
                               : LOC(@"settings.diag.missing", @"✗ missing");
    UIColor *color = present ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    if ([cell respondsToSelector:@selector(defaultContentConfiguration)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        UIListContentConfiguration *cfg = [cell defaultContentConfiguration];
        cfg.text = item[@"name"];
        cfg.textProperties.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        cfg.secondaryText = status;
        cfg.secondaryTextProperties.color = color;
        [cell setContentConfiguration:cfg];
#pragma clang diagnostic pop
    } else {
        cell.textLabel.text = item[@"name"];
        cell.textLabel.font = [UIFont systemFontOfSize:11];
        cell.detailTextLabel.text = status;
        cell.detailTextLabel.textColor = color;
    }
    return cell;
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return LOC(@"settings.diag.header", @"Hooked Twitch classes (this build)");
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return LOC(@"settings.diag.footer",
        @"✓ = the class resolved and its hook is active. ✗ = Twitch renamed or "
        @"removed it, so that feature is inactive until the hook is updated.");
}
@end

@interface TWABSettingsVC () <UIDocumentPickerDelegate>
@property (nonatomic, assign) BOOL adblockEnabled;
@property (nonatomic, assign) BOOL proxyEnabled;
@property (nonatomic, assign) BOOL customProxyEnabled;
@property (nonatomic, assign) BOOL emotesEnabled;
@property (nonatomic, assign) TWABProxyStatus proxyStatus;
// Ordered list of custom proxies, mirroring TWABKeyAdBlockProxy (stored
// as a newline-joined string). Each entry is one proxy address; the
// order is the fallback order used by twab_effectiveProxyAddresses().
@property (nonatomic, strong) NSMutableArray<NSString *> *proxies;
@end

@implementation TWABSettingsVC

+ (instancetype)settingsVC {
    // UITableViewStyleInsetGrouped (value 2) is iOS 13+; suppress availability warning
    // because @available is unusable in sideloaded dylibs (___isOSVersionAtLeast resolves to nil).
    UITableViewStyle style = UITableViewStyleGrouped;
    if ([NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){13,0,0}]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        style = UITableViewStyleInsetGrouped;
#pragma clang diagnostic pop
    }
    return [[self alloc] initWithStyle:style];
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithStyle:style])) {
        _adblockEnabled     = [tweakDefaults boolForKey:TWABKeyAdBlockEnabled];
        _proxyEnabled       = [tweakDefaults boolForKey:TWABKeyAdBlockProxyEnabled];
        _customProxyEnabled = [tweakDefaults boolForKey:TWABKeyAdBlockCustomProxyEnabled];
        _emotesEnabled      = [tweakDefaults boolForKey:TWABKeyEmotesEnabled];
        _proxyStatus        = TWABProxyStatusUnknown;
        [self loadProxiesFromDefaults];
    }
    return self;
}

// Load the multi-proxy list. Accepts both newlines and commas as
// separators so a single-proxy legacy stored value parses cleanly and
// pasted comma-separated lists from elsewhere just work.
- (void)loadProxiesFromDefaults {
    NSString *raw = [tweakDefaults stringForKey:TWABKeyAdBlockProxy] ?: @"";
    NSMutableCharacterSet *seps = [NSMutableCharacterSet
        characterSetWithCharactersInString:@","];
    [seps formUnionWithCharacterSet:[NSCharacterSet newlineCharacterSet]];
    NSArray *split = [raw componentsSeparatedByCharactersInSet:seps];
    NSMutableArray *clean = [NSMutableArray array];
    for (NSString *s in split) {
        NSString *t = [s stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [clean addObject:t];
    }
    self.proxies = clean;
}

// Persist as newline-joined string. Trim empty entries on save so the
// list stays clean even if a user clears a field without deleting the row.
- (void)saveProxiesToDefaults {
    NSMutableArray *trimmed = [NSMutableArray array];
    for (NSString *p in self.proxies) {
        NSString *t = [p stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [trimmed addObject:t];
    }
    [tweakDefaults setObject:[trimmed componentsJoinedByString:@"\n"]
                      forKey:TWABKeyAdBlockProxy];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"TwitchMods";
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    // Dragging the table dismisses the keyboard, which also fires
    // textFieldDidEndEditing — useful since plain taps on switches/cells
    // don't necessarily resign first responder.
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    // Non-zero estimate enables self-sizing for the subtitle toggle rows
    // (heightForRowAtIndexPath returns UITableViewAutomaticDimension for them).
    self.tableView.estimatedRowHeight = 60;
    if (self.proxyEnabled) [self refreshProxyStatus];
}

#pragma mark - UITableViewDataSource

// Section layout:
//   0: Ad Block toggle           (always shown)
//   1: Proxy + custom proxy      (only when ad block is on)
//   2: Emotes toggle + reload    (always shown)
//   3: Home: launch / stories / keep-live-feed
//   4: Tools: export / import / diagnostics
//   5: empty / version footer    (always shown — last section)

// Launch Screen options. tabIndex < 0 means "use Twitch's default" (both
// keys cleared). subTabIndex < 0 means "don't override sub-tab".
// Indices match the live VC hierarchy on Twitch 29.4.2 (verified via dump
// + user confirmation of tab labels):
//   tab 0 Home   sub 0 Following, sub 1 Live (default), sub 2 Clips
//   tab 1 Browse sub 0 Categories, sub 1 Live Channels
//   tab 3 Activity
//   tab 4 Profile
typedef struct {
    const char *title;
    NSInteger tabIndex;
    NSInteger subTabIndex;
} TWABLaunchOpt;
static const TWABLaunchOpt kLaunchOpts[] = {
    { "Default",                 -1, -1 },
    { "Home → Following",        0,  0 },
    { "Home → Live",             0,  1 },
    { "Home → Clips",            0,  2 },
    { "Browse → Categories",     1,  0 },
    { "Browse → Live Channels",  1,  1 },
    { "Activity",                3, -1 },
    { "Profile",                 4, -1 },
};
#define TWAB_LAUNCH_OPT_COUNT (sizeof(kLaunchOpts) / sizeof(kLaunchOpts[0]))

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 6;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 2;  // ad block toggle + hide "Go Ad-Free" button
        case 1:
            if (!self.adblockEnabled) return 0;
            if (!self.proxyEnabled) return 1;
            // proxy switch + custom switch + (custom-only: N proxy rows
            // + "Add proxy" row) + status
            return self.customProxyEnabled ? (3 + (NSInteger)self.proxies.count + 1) : 3;
        case 2: return 2;  // emotes toggle + reload-emotes action
        case 3: return 3;  // launch dropdown + hide-stories toggle + watch-limit toggle
        case 4: return 3;  // Tools: export, import, diagnostics
        case 5: return 0;  // version footer only
        default: return 0;
    }
}

// Category title above each section. Proxy header is suppressed when ad block
// is off (the section collapses to 0 rows, so a lone header would float).
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return LOC(@"settings.section.adblock", @"Ad Blocking");
        case 1: return self.adblockEnabled ? LOC(@"settings.section.proxy", @"Proxy") : nil;
        case 2: return LOC(@"settings.section.emotes", @"Emotes");
        case 3: return LOC(@"settings.section.home", @"Home & Playback");
        case 4: return LOC(@"settings.section.tools", @"Tools");
        default: return nil;  // section 5 = version footer only
    }
}

// Current launch-tab + sub-tab choice (-1 = absent).
- (NSInteger)currentLaunchTab {
    if (![tweakDefaults objectForKey:TWABKeyLaunchTab]) return -1;
    return [tweakDefaults integerForKey:TWABKeyLaunchTab];
}
- (NSInteger)currentLaunchSubTab {
    if (![tweakDefaults objectForKey:TWABKeyLaunchSubTab]) return -1;
    return [tweakDefaults integerForKey:TWABKeyLaunchSubTab];
}

// Row index of the proxy status row inside section 1 (when proxy is on).
// With custom proxy on: switches (2) + N proxy rows + add row (1) → status
// at index 2 + N + 1 = 3 + N. With custom off: switches (2) → status at 2.
- (NSInteger)statusRowIndex {
    return self.customProxyEnabled ? (3 + (NSInteger)self.proxies.count) : 2;
}

// Returns the proxy index for a section-1 row if it's a proxy edit row,
// or -1 if it's not (could be a switch, the add row, or the status row).
- (NSInteger)proxyIndexForRow:(NSInteger)row {
    if (!self.customProxyEnabled) return -1;
    if (row < 2 || row >= 2 + (NSInteger)self.proxies.count) return -1;
    return row - 2;
}

// Section-1 row index of the "Add proxy" tap target. Comes right after
// the last proxy row.
- (NSInteger)addProxyRowIndex {
    return 2 + (NSInteger)self.proxies.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            if (indexPath.row == 0)
                return [self switchCellWithTitle:LOC(@"settings.adblock.title", @"Ad Block")
                                        subtitle:LOC(@"settings.adblock.desc",
                                                     @"Block video, display, and feed ads.")
                                             on:_adblockEnabled
                                         action:@selector(adblockSwitchChanged:)
                                     identifier:@"AdBlockSwitch"];
            return [self switchCellWithTitle:LOC(@"settings.hideadfree.title",
                                                 @"Hide “Go Ad-Free” Button")
                                    subtitle:LOC(@"settings.hideadfree.desc",
                                                 @"Remove the Turbo upsell banner on the Following tab.")
                                         on:[tweakDefaults boolForKey:TWABKeyHideAdFreeButton]
                                     action:@selector(hideAdFreeSwitchChanged:)
                                 identifier:@"HideAdFreeSwitch"];
        case 1: {
            NSInteger row = indexPath.row;
            if (row == 0)
                return [self switchCellWithTitle:LOC(@"settings.proxy.title", @"Ad Block Proxy")
                                        subtitle:LOC(@"settings.proxy.desc",
                                                     @"Route stream playlists through an ad-free-country proxy.")
                                             on:_proxyEnabled
                                         action:@selector(proxySwitchChanged:)
                                     identifier:@"ProxySwitch"];
            if (row == 1)
                return [self switchCellWithTitle:LOC(@"settings.custom_proxy.title", @"Custom Proxy")
                                        subtitle:LOC(@"settings.custom_proxy.desc",
                                                     @"Use your own proxy servers instead of the default.")
                                             on:_customProxyEnabled
                                         action:@selector(customProxySwitchChanged:)
                                     identifier:@"CustomProxySwitch"];
            if (!self.customProxyEnabled) return [self proxyStatusCell];
            NSInteger proxyIdx = [self proxyIndexForRow:row];
            if (proxyIdx >= 0) return [self proxyRowCellForIndex:proxyIdx];
            if (row == [self addProxyRowIndex]) return [self addProxyCell];
            return [self proxyStatusCell];
        }
        case 2:
            if (indexPath.row == 0)
                return [self switchCellWithTitle:LOC(@"settings.emotes.title", @"3rd-Party Emotes")
                                        subtitle:LOC(@"settings.emotes.desc",
                                                     @"Show 7TV, BetterTTV & FrankerFaceZ emotes in chat.")
                                             on:_emotesEnabled
                                         action:@selector(emotesSwitchChanged:)
                                     identifier:@"EmotesSwitch"];
            return [self actionCellWithTitle:LOC(@"settings.emotes.reload", @"Reload Emotes")
                                    subtitle:LOC(@"settings.emotes.reload.desc",
                                                 @"Clear the cache and re-fetch all emote sets.")
                                 destructive:NO disclosure:NO identifier:@"ReloadEmotesCell"];
        case 3:
            if (indexPath.row == 0) return [self launchScreenDropdownCell];
            if (indexPath.row == 1)
                return [self switchCellWithTitle:LOC(@"settings.hidestories.title",
                                                     @"Hide Twitch Stories")
                                        subtitle:LOC(@"settings.hidestories.desc",
                                                     @"Remove the Stories strip from the Home tab.")
                                             on:[tweakDefaults boolForKey:TWABKeyHideStories]
                                         action:@selector(hideStoriesSwitchChanged:)
                                     identifier:@"HideStoriesSwitch"];
            return [self switchCellWithTitle:LOC(@"settings.watchlimit.title",
                                                 @"Keep Live Feed Playing")
                                    subtitle:LOC(@"settings.watchlimit.desc",
                                                 @"Stop the Live feed cutting a stream off with the Watch/Follow overlay.")
                                         on:[tweakDefaults boolForKey:TWABKeyDisableWatchLimit]
                                     action:@selector(disableWatchLimitSwitchChanged:)
                                 identifier:@"DisableWatchLimitSwitch"];
        case 4:
            if (indexPath.row == 0)
                return [self actionCellWithTitle:LOC(@"settings.tools.export", @"Export Settings")
                                        subtitle:LOC(@"settings.tools.export.desc",
                                                     @"Share your toggles and proxy list as JSON.")
                                     destructive:NO disclosure:NO identifier:@"ExportCell"];
            if (indexPath.row == 1)
                return [self actionCellWithTitle:LOC(@"settings.tools.import", @"Import Settings")
                                        subtitle:LOC(@"settings.tools.import.desc",
                                                     @"Select a previously exported JSON file.")
                                     destructive:NO disclosure:NO identifier:@"ImportCell"];
            return [self actionCellWithTitle:LOC(@"settings.tools.diag", @"Diagnostics")
                                    subtitle:LOC(@"settings.tools.diag.desc",
                                                 @"Check which Twitch hooks resolved on this version.")
                                 destructive:NO disclosure:YES identifier:@"DiagCell"];
        default: break;
    }
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                 reuseIdentifier:@"empty"];
}

// Returns the index into kLaunchOpts that matches the currently-saved
// tab/subTab combo. Falls back to row 0 ("Default") if no match.
- (NSUInteger)currentLaunchOptIndex {
    NSInteger tab = [self currentLaunchTab];
    NSInteger sub = [self currentLaunchSubTab];
    for (NSUInteger i = 0; i < TWAB_LAUNCH_OPT_COUNT; i++) {
        if (kLaunchOpts[i].tabIndex == tab && kLaunchOpts[i].subTabIndex == sub) {
            return i;
        }
    }
    return 0;
}

- (UITableViewCell *)launchScreenDropdownCell {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"LaunchDropdown"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:@"LaunchDropdown"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSString *title = LOC(@"settings.launch.title", @"Launch Screen");
    NSString *detail = [NSString stringWithUTF8String:
        kLaunchOpts[[self currentLaunchOptIndex]].title];
    if ([cell respondsToSelector:@selector(defaultContentConfiguration)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        UIListContentConfiguration *cfg = [cell defaultContentConfiguration];
        cfg.text = title;
        cfg.secondaryText = detail;
        [cell setContentConfiguration:cfg];
#pragma clang diagnostic pop
    } else {
        cell.textLabel.text = title;
        cell.detailTextLabel.text = detail;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && self.adblockEnabled && self.proxyEnabled &&
        self.customProxyEnabled && indexPath.row == [self addProxyRowIndex]) {
        [self.proxies addObject:@""];
        [self saveProxiesToDefaults];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                      withRowAnimation:UITableViewRowAnimationAutomatic];
        return;
    }
    if (indexPath.section == 2 && indexPath.row == 1) {
        [self reloadEmotesTapped:[tableView cellForRowAtIndexPath:indexPath]];
        return;
    }
    if (indexPath.section == 3 && indexPath.row == 0) {
        [self presentLaunchScreenPicker:[tableView cellForRowAtIndexPath:indexPath]];
        return;
    }
    if (indexPath.section == 4) {
        if (indexPath.row == 0)
            [self exportSettings:[tableView cellForRowAtIndexPath:indexPath]];
        else if (indexPath.row == 1)
            [self importSettings];
        else
            [self showDiagnostics];
    }
}

// Swipe-to-delete for proxy rows. Section 1 + the row maps to a proxy
// index via proxyIndexForRow:.
- (BOOL)tableView:(UITableView *)tableView
    canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1 || !self.customProxyEnabled) return NO;
    return [self proxyIndexForRow:indexPath.row] >= 0;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSInteger idx = [self proxyIndexForRow:indexPath.row];
    if (idx < 0 || idx >= (NSInteger)self.proxies.count) return;
    [self.proxies removeObjectAtIndex:idx];
    [self saveProxiesToDefaults];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
    if (self.proxyEnabled) [self refreshProxyStatus];
}

- (void)presentLaunchScreenPicker:(UIView *)anchor {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:LOC(@"settings.launch.title", @"Launch Screen")
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger current = [self currentLaunchOptIndex];
    for (NSUInteger i = 0; i < TWAB_LAUNCH_OPT_COUNT; i++) {
        NSString *title = [NSString stringWithUTF8String:kLaunchOpts[i].title];
        if (i == current) title = [@"✓  " stringByAppendingString:title];
        NSInteger tab = kLaunchOpts[i].tabIndex;
        NSInteger sub = kLaunchOpts[i].subTabIndex;
        __weak typeof(self) weakSelf = self;
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) {
            if (tab < 0) [tweakDefaults removeObjectForKey:TWABKeyLaunchTab];
            else         [tweakDefaults setInteger:tab forKey:TWABKeyLaunchTab];
            if (sub < 0) [tweakDefaults removeObjectForKey:TWABKeyLaunchSubTab];
            else         [tweakDefaults setInteger:sub forKey:TWABKeyLaunchSubTab];
            [weakSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:3]
                              withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"settings.launch.cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    // iPad popover anchor — required when presentation style is action sheet.
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

// Tag for finding the proxy text field on a reused cell. Arbitrary but distinct.
static const NSInteger kProxyTextFieldTag = 0xABCD;

- (UITableViewCell *)switchCellWithTitle:(NSString *)title
                                subtitle:(NSString *)subtitle
                                      on:(BOOL)on
                                  action:(SEL)action
                              identifier:(NSString *)identifier {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    UISwitch *sw;
    if (cell) {
        sw = (UISwitch *)cell.accessoryView;
    } else {
        // Subtitle style so each mod carries a short gray description on the
        // line under its title (replacing the old per-section footers).
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        sw = [[UISwitch alloc] init];
        sw.accessibilityIdentifier = identifier;
        [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }
    // iOS 14+ ignores textLabel in favour of content configurations.
    // Use respondsToSelector: so we avoid @available (which crashes in sideloaded dylibs).
    if ([cell respondsToSelector:@selector(defaultContentConfiguration)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        UIListContentConfiguration *cfg = [cell defaultContentConfiguration];
        cfg.text = title;
        cfg.secondaryText = subtitle;
        cfg.secondaryTextProperties.color = [UIColor secondaryLabelColor];
        cfg.secondaryTextProperties.font = [UIFont systemFontOfSize:12];
        cfg.textToSecondaryTextVerticalPadding = 2;
        [cell setContentConfiguration:cfg];
#pragma clang diagnostic pop
    } else {
        cell.textLabel.text = title;
        cell.detailTextLabel.text = subtitle;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor grayColor];
    }
    sw.on = on;
    return cell;
}

// Tappable action row (no switch) with a tinted/red title + gray subtitle.
- (UITableViewCell *)actionCellWithTitle:(NSString *)title
                                subtitle:(NSString *)subtitle
                             destructive:(BOOL)destructive
                              disclosure:(BOOL)disclosure
                              identifier:(NSString *)identifier {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:identifier];
    }
    cell.accessoryType = disclosure ? UITableViewCellAccessoryDisclosureIndicator
                                    : UITableViewCellAccessoryNone;
    cell.accessibilityIdentifier = identifier;
    UIColor *titleColor = destructive ? [UIColor systemRedColor]
                                      : (self.view.tintColor ?: [UIColor systemBlueColor]);
    if ([cell respondsToSelector:@selector(defaultContentConfiguration)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        UIListContentConfiguration *cfg = [cell defaultContentConfiguration];
        cfg.text = title;
        cfg.textProperties.color = titleColor;
        cfg.secondaryText = subtitle;
        cfg.secondaryTextProperties.color = [UIColor secondaryLabelColor];
        cfg.secondaryTextProperties.font = [UIFont systemFontOfSize:12];
        cfg.textToSecondaryTextVerticalPadding = 2;
        [cell setContentConfiguration:cfg];
#pragma clang diagnostic pop
    } else {
        cell.textLabel.text = title;
        cell.textLabel.textColor = titleColor;
        cell.detailTextLabel.text = subtitle;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor grayColor];
    }
    return cell;
}

- (UITableViewCell *)proxyStatusCell {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"ProxyStatusCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                      reuseIdentifier:@"ProxyStatusCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    NSString *title = self.customProxyEnabled
        ? LOC(@"settings.proxy.custom_status", @"Custom proxy")
        : LOC(@"settings.proxy.default_status", @"Default proxy");
    NSString *detail;
    UIColor *color;
    switch (self.proxyStatus) {
        case TWABProxyStatusOnline:
            detail = LOC(@"settings.proxy.status.online", @"● Online");
            color  = [UIColor systemGreenColor];
            break;
        case TWABProxyStatusOffline:
            detail = LOC(@"settings.proxy.status.offline", @"● Offline");
            color  = [UIColor systemRedColor];
            break;
        case TWABProxyStatusChecking:
            detail = LOC(@"settings.proxy.status.checking", @"Checking…");
            color  = [UIColor systemGrayColor];
            break;
        case TWABProxyStatusUnknown:
        default:
            detail = LOC(@"settings.proxy.status.unknown", @"—");
            color  = [UIColor systemGrayColor];
            break;
    }
    if ([cell respondsToSelector:@selector(defaultContentConfiguration)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        UIListContentConfiguration *cfg = [cell defaultContentConfiguration];
        cfg.text = title;
        cfg.secondaryText = detail;
        cfg.secondaryTextProperties.color = color;
        [cell setContentConfiguration:cfg];
#pragma clang diagnostic pop
    } else {
        cell.textLabel.text = title;
        cell.detailTextLabel.text = detail;
        cell.detailTextLabel.textColor = color;
    }
    return cell;
}

// Tags for finding the up/down buttons on a reused proxy row cell.
static const NSInteger kProxyUpButtonTag   = 0xAB01;
static const NSInteger kProxyDownButtonTag = 0xAB02;

- (UIButton *)makeArrowButtonNamed:(NSString *)symbolName
                               tag:(NSInteger)tag
                            action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.tag = tag;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    if ([UIImage respondsToSelector:@selector(systemImageNamed:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        UIImageSymbolConfiguration *sym = [UIImageSymbolConfiguration
            configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
        UIImage *img = [UIImage systemImageNamed:symbolName withConfiguration:sym];
        [btn setImage:img forState:UIControlStateNormal];
#pragma clang diagnostic pop
    } else {
        // Pre-iOS 13 fallback — ASCII arrow as title.
        NSString *fallback = [symbolName isEqualToString:@"chevron.up"] ? @"▲" : @"▼";
        [btn setTitle:fallback forState:UIControlStateNormal];
    }
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (UITableViewCell *)proxyRowCellForIndex:(NSInteger)idx {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"ProxyRowCell"];
    UIButton *up, *down;
    UITextField *tf;
    if (cell) {
        up   = (UIButton *)[cell.contentView viewWithTag:kProxyUpButtonTag];
        down = (UIButton *)[cell.contentView viewWithTag:kProxyDownButtonTag];
        tf   = (UITextField *)[cell.contentView viewWithTag:kProxyTextFieldTag];
    } else {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"ProxyRowCell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        up   = [self makeArrowButtonNamed:@"chevron.up"
                                      tag:kProxyUpButtonTag
                                   action:@selector(proxyUpTapped:)];
        down = [self makeArrowButtonNamed:@"chevron.down"
                                      tag:kProxyDownButtonTag
                                   action:@selector(proxyDownTapped:)];
        tf = [[UITextField alloc] init];
        tf.tag = kProxyTextFieldTag;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.placeholder = @"user:pass@host:port";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.keyboardType = UIKeyboardTypeURL;
        tf.returnKeyType = UIReturnKeyDone;
        tf.font = [UIFont systemFontOfSize:15];
        tf.delegate = self;
        [tf addTarget:self
                action:@selector(proxyFieldChanged:)
      forControlEvents:UIControlEventEditingChanged];
        [cell.contentView addSubview:up];
        [cell.contentView addSubview:down];
        [cell.contentView addSubview:tf];
        [NSLayoutConstraint activateConstraints:@[
            [up.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:12],
            [up.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [up.widthAnchor constraintEqualToConstant:30],
            [up.heightAnchor constraintEqualToConstant:30],
            [down.leadingAnchor constraintEqualToAnchor:up.trailingAnchor constant:2],
            [down.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [down.widthAnchor constraintEqualToConstant:30],
            [down.heightAnchor constraintEqualToConstant:30],
            [tf.leadingAnchor constraintEqualToAnchor:down.trailingAnchor constant:10],
            [tf.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
            [tf.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [tf.heightAnchor constraintEqualToConstant:40],
        ]];
    }
    tf.text = idx < (NSInteger)self.proxies.count ? self.proxies[idx] : @"";
    // Dim disabled arrows so it's visually clear when a row can't move
    // further in that direction.
    BOOL canUp   = (idx > 0);
    BOOL canDown = (idx < (NSInteger)self.proxies.count - 1);
    up.enabled   = canUp;   up.alpha   = canUp   ? 1.0 : 0.25;
    down.enabled = canDown; down.alpha = canDown ? 1.0 : 0.25;
    return cell;
}

- (UITableViewCell *)addProxyCell {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"AddProxyCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"AddProxyCell"];
    }
    NSString *title = LOC(@"settings.proxy.add", @"+ Add proxy");
    if ([cell respondsToSelector:@selector(defaultContentConfiguration)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        UIListContentConfiguration *cfg = [cell defaultContentConfiguration];
        cfg.text = title;
        cfg.textProperties.color = self.view.tintColor ?: UIColor.systemBlueColor;
        [cell setContentConfiguration:cfg];
#pragma clang diagnostic pop
    } else {
        cell.textLabel.text = title;
        cell.textLabel.textColor = self.view.tintColor ?: UIColor.systemBlueColor;
    }
    return cell;
}

// Walks from any subview up to its enclosing UITableViewCell. Returns nil
// if the view isn't in a cell yet (shouldn't happen in our cellForRow flow).
- (UITableViewCell *)cellForSubview:(UIView *)view {
    UIView *v = view;
    while (v && ![v isKindOfClass:[UITableViewCell class]]) v = v.superview;
    return (UITableViewCell *)v;
}

#pragma mark - Multi-proxy editing

- (void)proxyUpTapped:(UIButton *)btn {
    UITableViewCell *cell = [self cellForSubview:btn];
    NSIndexPath *path = [self.tableView indexPathForCell:cell];
    NSInteger idx = [self proxyIndexForRow:path.row];
    if (idx <= 0) return;
    [self.proxies exchangeObjectAtIndex:idx withObjectAtIndex:idx - 1];
    [self saveProxiesToDefaults];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationFade];
}

- (void)proxyDownTapped:(UIButton *)btn {
    UITableViewCell *cell = [self cellForSubview:btn];
    NSIndexPath *path = [self.tableView indexPathForCell:cell];
    NSInteger idx = [self proxyIndexForRow:path.row];
    if (idx < 0 || idx >= (NSInteger)self.proxies.count - 1) return;
    [self.proxies exchangeObjectAtIndex:idx withObjectAtIndex:idx + 1];
    [self saveProxiesToDefaults];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationFade];
}

- (void)proxyFieldChanged:(UITextField *)tf {
    UITableViewCell *cell = [self cellForSubview:tf];
    NSIndexPath *path = [self.tableView indexPathForCell:cell];
    NSInteger idx = [self proxyIndexForRow:path.row];
    if (idx < 0 || idx >= (NSInteger)self.proxies.count) return;
    self.proxies[idx] = tf.text ?: @"";
    [self saveProxiesToDefaults];
}

#pragma mark - UITableViewDelegate (footers)

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section == 5) {
        UILabel *ver = [[UILabel alloc] init];
        ver.text = @"TwitchMods v" PACKAGE_VERSION;
        ver.textAlignment = NSTextAlignmentCenter;
        ver.font = [UIFont systemFontOfSize:13];
        ver.textColor = [UIColor colorWithWhite:0.5 alpha:1];
        UIView *wrap = [[UIView alloc] init];
        [wrap addSubview:ver];
        ver.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [ver.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:16],
            [ver.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-16],
            [ver.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:8],
            [ver.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-8],
        ]];
        return wrap;
    }

    // Per-mod descriptions now live as subtitles under each switch, so most
    // section footers are gone. The only footer left is the multi-proxy
    // reorder/delete mechanics, which describe row interactions rather than a
    // single toggle and don't fit on one subtitle line.
    NSString *text = nil;
    if (section == 1 && self.adblockEnabled && self.proxyEnabled && self.customProxyEnabled) {
        text = LOC(@"settings.proxy.footer.multi",
                   @"Proxies are tried in order. The first to respond 200 to /ping rewrites "
                   @"playlists (V2 / ttv-lol-pro format). Otherwise the first valid proxy "
                   @"tunnels them via HTTP CONNECT. Use ↑↓ to reorder, swipe a "
                   @"row to delete.");
    } else {
        return nil;
    }

    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    UIView *wrap = [[UIView alloc] init];
    [wrap addSubview:label];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-16],
        [label.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:8],
        [label.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-8],
    ]];
    return wrap;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    // Collapse footers for sections that no longer have one (their
    // descriptions moved to per-row subtitles), otherwise grouped style
    // leaves an empty gap. Section 4 = version, section 1 = proxy mechanics.
    BOOL hasFooter = (section == 5) ||
        (section == 1 && self.adblockEnabled && self.proxyEnabled && self.customProxyEnabled);
    return hasFooter ? UITableViewAutomaticDimension : CGFLOAT_MIN;
}

// Self-size every row to fit its subtitle EXCEPT the proxy editor / add /
// status rows (section 1, row >= 2): those use centered constraints that
// don't pin top/bottom, so self-sizing would collapse them. They keep a
// fixed height. Toggles, action rows, and the launch dropdown all self-size.
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1 && indexPath.row >= 2) return 44.0;
    return UITableViewAutomaticDimension;
}

#pragma mark - Switch actions

- (void)adblockSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyAdBlockEnabled];
    self.adblockEnabled = sw.on;
    // Section 1 holds the proxy rows — its visibility tracks the ad-block toggle.
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationFade];
}

- (void)emotesSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyEmotesEnabled];
    self.emotesEnabled = sw.on;
}

- (void)proxySwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyAdBlockProxyEnabled];
    self.proxyEnabled = sw.on;
    self.proxyStatus = TWABProxyStatusUnknown;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationFade];
    if (sw.on) [self refreshProxyStatus];
}

- (void)hideStoriesSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideStories];
}

- (void)disableWatchLimitSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyDisableWatchLimit];
}

- (void)hideAdFreeSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideAdFreeButton];
}

#pragma mark - Tools (reload / export / import / diagnostics)

// The subset of defaults keys that export/import round-trips. Proxy list,
// every toggle, and the launch tab/sub-tab. Deliberately excludes one-shot
// migration flags and anything device-specific.
static NSArray<NSString *> *twab_exportKeys(void) {
    return @[ TWABKeyAdBlockEnabled, TWABKeyAdBlockProxyEnabled,
              TWABKeyAdBlockCustomProxyEnabled, TWABKeyAdBlockProxy,
              TWABKeyEmotesEnabled, TWABKeyLaunchTab, TWABKeyLaunchSubTab,
              TWABKeyHideStories, TWABKeyDisableWatchLimit,
              TWABKeyHideAdFreeButton ];
}

- (void)reloadEmotesTapped:(UIView *)anchor {
    twab_reloadEmotes();
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:LOC(@"settings.emotes.reload", @"Reload Emotes")
                         message:LOC(@"settings.emotes.reload.done",
                                     @"Emote cache cleared. Global sets are re-fetching; "
                                     @"channel emotes reload as new chat messages arrive.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:LOC(@"settings.ok", @"OK")
                                          style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSString *)exportJSONString {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *key in twab_exportKeys()) {
        id val = [tweakDefaults objectForKey:key];
        if (val) values[key] = val;
    }
    NSDictionary *wrapped = @{ @"twitchmods_settings": @1, @"values": values };
    NSData *d = [NSJSONSerialization dataWithJSONObject:wrapped
                                               options:NSJSONWritingPrettyPrinted
                                                 error:nil];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

// Default export filename — used as the suggested name in the share sheet /
// "Save to Files". Date-stamped so multiple backups don't overwrite.
- (NSString *)exportFileName {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd";
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [NSString stringWithFormat:@"TwitchMods-Settings-%@.json",
            [fmt stringFromDate:[NSDate date]]];
}

- (void)exportSettings:(UIView *)anchor {
    NSString *json = [self exportJSONString];
    // Share a real file URL (not a raw string) so the export carries a proper
    // default filename through the share sheet and "Save to Files".
    NSURL *fileURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:[self exportFileName]];
    NSError *writeErr = nil;
    [json writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];
    NSArray *items = writeErr ? @[ json ] : @[ fileURL ];  // string fallback if write fails
    UIActivityViewController *av = [[UIActivityViewController alloc]
        initWithActivityItems:items applicationActivities:nil];
    // iPad popover anchor — required for action-style presentations.
    av.popoverPresentationController.sourceView = anchor;
    av.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:av animated:YES completion:nil];
}

- (void)importSettings {
    // Document picker so the user selects the exported .json file instead of
    // pasting. initWithDocumentTypes:inMode: is deprecated on iOS 14+ but still
    // works everywhere back to iOS 11 — and avoids the UTType /
    // UniformTypeIdentifiers dependency plus @available (unusable in sideloaded
    // dylibs). Import mode hands us a temp copy we own, so no security scope.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc]
            initWithDocumentTypes:@[ @"public.json", @"public.text", @"public.data" ]
                             inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.delegate = self;
    if ([picker respondsToSelector:@selector(setAllowsMultipleSelection:)])
        picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) { [self presentImportResult:NO count:0]; return; }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *err = nil;
    NSString *text = [NSString stringWithContentsOfURL:url
                                              encoding:NSUTF8StringEncoding
                                                 error:&err];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!text.length) { [self presentImportResult:NO count:0]; return; }
    [self applyImportedJSON:text];
}

- (void)applyImportedJSON:(NSString *)text {
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    id values = [obj isKindOfClass:NSDictionary.class] ? ((NSDictionary *)obj)[@"values"] : nil;
    if (![values isKindOfClass:NSDictionary.class]) {
        [self presentImportResult:NO count:0];
        return;
    }
    // Only apply keys we recognise — ignore anything else in the blob.
    NSSet *allowed = [NSSet setWithArray:twab_exportKeys()];
    NSInteger n = 0;
    for (NSString *key in (NSDictionary *)values) {
        if (![allowed containsObject:key]) continue;
        [tweakDefaults setObject:((NSDictionary *)values)[key] forKey:key];
        n++;
    }
    // Re-sync cached state + proxy list so the UI reflects the import now.
    _adblockEnabled     = [tweakDefaults boolForKey:TWABKeyAdBlockEnabled];
    _proxyEnabled       = [tweakDefaults boolForKey:TWABKeyAdBlockProxyEnabled];
    _customProxyEnabled = [tweakDefaults boolForKey:TWABKeyAdBlockCustomProxyEnabled];
    _emotesEnabled      = [tweakDefaults boolForKey:TWABKeyEmotesEnabled];
    [self loadProxiesFromDefaults];
    [self.tableView reloadData];
    if (self.proxyEnabled) [self refreshProxyStatus];
    [self presentImportResult:YES count:n];
}

- (void)presentImportResult:(BOOL)ok count:(NSInteger)n {
    NSString *msg = ok
        ? [NSString stringWithFormat:LOC(@"settings.tools.import.ok",
              @"Imported %ld settings. Some changes take effect on next launch."), (long)n]
        : LOC(@"settings.tools.import.fail",
              @"Couldn't read that — make sure it's a full exported JSON blob.");
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:LOC(@"settings.tools.import", @"Import Settings")
                         message:msg
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:LOC(@"settings.ok", @"OK")
                                          style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showDiagnostics {
    TWABDiagnosticsVC *vc = [[TWABDiagnosticsVC alloc] initWithStyle:UITableViewStyleGrouped];
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc]
            initWithRootViewController:vc];
        [self presentViewController:nav animated:YES completion:nil];
    }
}

- (void)customProxySwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyAdBlockCustomProxyEnabled];
    self.customProxyEnabled = sw.on;
    self.proxyStatus = TWABProxyStatusUnknown;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationFade];
    [self refreshProxyStatus];
}

- (void)refreshProxyStatus {
    if (!self.proxyEnabled) return;
    NSString *addr;
    if (self.customProxyEnabled) {
        // Probe the first non-empty configured proxy. The actual
        // routing iterates the full list at request time; this status
        // indicator just gives a "is anything online?" smoke test.
        addr = nil;
        for (NSString *p in self.proxies) {
            NSString *t = [p stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]];
            if (t.length) { addr = t; break; }
        }
        if (!addr) {
            self.proxyStatus = TWABProxyStatusOffline;
            [self reloadStatusRow];
            return;
        }
    } else {
        addr = PROXY_ADDR;
    }
    self.proxyStatus = TWABProxyStatusChecking;
    [self reloadStatusRow];
    __weak typeof(self) weakSelf = self;
    twab_checkProxyStatus(addr, ^(TWABProxyStatus s) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.proxyStatus = s;
        [strongSelf reloadStatusRow];
    });
}

- (void)reloadStatusRow {
    if (!self.adblockEnabled || !self.proxyEnabled) return;
    NSIndexPath *path = [NSIndexPath indexPathForRow:[self statusRowIndex] inSection:1];
    [self.tableView reloadRowsAtIndexPaths:@[path]
                          withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

// The per-row text field handler (proxyFieldChanged:) writes the array
// back to defaults on every keystroke. The status probe is heavier; only
// run it when the user finishes editing.
- (void)textFieldDidEndEditing:(UITextField *)textField {
    UITableViewCell *cell = [self cellForSubview:textField];
    NSIndexPath *path = [self.tableView indexPathForCell:cell];
    NSInteger idx = [self proxyIndexForRow:path.row];
    if (idx >= 0 && idx < (NSInteger)self.proxies.count) {
        self.proxies[idx] = textField.text ?: @"";
        [self saveProxiesToDefaults];
    }
    if (self.proxyEnabled && self.customProxyEnabled) [self refreshProxyStatus];
}

@end
