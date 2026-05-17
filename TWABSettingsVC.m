#import "TWABSettingsVC.h"
#import "Config.h"
#import "SettingsKeys.h"
#import "NSURLSession+TwitchAdBlock.h"

extern NSBundle *tweakBundle;
extern NSUserDefaults *tweakDefaults;

#define LOC(x, d) (tweakBundle ? [tweakBundle localizedStringForKey:x value:d table:nil] : (d))

@interface TWABSettingsVC ()
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
    if (self.proxyEnabled) [self refreshProxyStatus];
}

#pragma mark - UITableViewDataSource

// Section layout:
//   0: Ad Block toggle           (always shown)
//   1: Proxy + custom proxy      (only when ad block is on)
//   2: Emotes toggle             (always shown)
//   3: Launch Screen picker      (always shown — checkmark per option)
//   4: empty / version footer    (always shown — last section)

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
    return 5;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;
        case 1:
            if (!self.adblockEnabled) return 0;
            if (!self.proxyEnabled) return 1;
            // proxy switch + custom switch + (custom-only: N proxy rows
            // + "Add proxy" row) + status
            return self.customProxyEnabled ? (3 + (NSInteger)self.proxies.count + 1) : 3;
        case 2: return 1;
        case 3: return 2;  // launch dropdown + hide-stories toggle
        case 4: return 0;
        default: return 0;
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
            return [self switchCellWithTitle:LOC(@"settings.adblock.title", @"Ad Block")
                                         on:_adblockEnabled
                                     action:@selector(adblockSwitchChanged:)
                                 identifier:@"AdBlockSwitch"];
        case 1: {
            NSInteger row = indexPath.row;
            if (row == 0)
                return [self switchCellWithTitle:LOC(@"settings.proxy.title", @"Ad Block Proxy")
                                             on:_proxyEnabled
                                         action:@selector(proxySwitchChanged:)
                                     identifier:@"ProxySwitch"];
            if (row == 1)
                return [self switchCellWithTitle:LOC(@"settings.custom_proxy.title", @"Custom Proxy")
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
            return [self switchCellWithTitle:LOC(@"settings.emotes.title", @"3rd-Party Emotes")
                                         on:_emotesEnabled
                                     action:@selector(emotesSwitchChanged:)
                                 identifier:@"EmotesSwitch"];
        case 3:
            if (indexPath.row == 0) return [self launchScreenDropdownCell];
            return [self switchCellWithTitle:LOC(@"settings.hidestories.title",
                                                 @"Hide Twitch Stories")
                                         on:[tweakDefaults boolForKey:TWABKeyHideStories]
                                     action:@selector(hideStoriesSwitchChanged:)
                                 identifier:@"HideStoriesSwitch"];
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
    if (indexPath.section == 3 && indexPath.row == 0) {
        [self presentLaunchScreenPicker:[tableView cellForRowAtIndexPath:indexPath]];
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
                                      on:(BOOL)on
                                  action:(SEL)action
                              identifier:(NSString *)identifier {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    UISwitch *sw;
    if (cell) {
        sw = (UISwitch *)cell.accessoryView;
    } else {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
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
        [cell setContentConfiguration:cfg];
#pragma clang diagnostic pop
    } else {
        cell.textLabel.text = title;
    }
    sw.on = on;
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
    if (section == 4) {
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

    NSString *text = nil;
    if (section == 0)
        text = LOC(@"settings.adblock.footer", @"Choose whether or not you want to block ads");
    else if (section == 1) {
        if (!self.adblockEnabled) return nil;
        if (self.proxyEnabled && self.customProxyEnabled) {
            text = LOC(@"settings.proxy.footer.multi",
                       @"Proxies are tried in order. The first to respond 200 to /ping rewrites "
                       @"playlists (V2 / ttv-lol-pro format). Otherwise the first valid proxy "
                       @"tunnels them via HTTP CONNECT. Use ↑↓ to reorder, swipe a "
                       @"row to delete.");
        } else {
            text = LOC(@"settings.proxy.footer",
                       @"Proxy specific requests through a proxy server based in an ad-free country");
        }
    } else if (section == 2)
        text = LOC(@"settings.emotes.footer",
                   @"Render 7TV, BetterTTV, and FrankerFaceZ emotes inline in chat");
    else if (section == 3)
        text = LOC(@"settings.home.footer",
                   @"Choose which tab Twitch opens to, and optionally hide the Stories strip. Takes effect on next launch.");
    else
        return nil;

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
