#import "TWABSettingsVC.h"
#import "Config.h"
#import "SettingsKeys.h"
#import "ChannelPoints.h"
#import "NSURLSession+TwitchAdBlock.h"
#import "TWABProxyPool.h"

// Tweak.x: re-applies declutter switches to what is on screen now.
extern void twab_applySettingsLive(void);

// ─── "Applies the next time you open a stream" notes ───────────────────────
// Settings that can't take effect on a stream that's already open show an
// orange note while a change is waiting, and it clears when the next stream
// opens. Tracked per switch: its defaults key, and whether turning it ON
// applies live (Hide Channel Bar, Leaderboard), so only turning it off waits.
extern NSUserDefaults *tweakDefaults;
static NSDictionary<NSString *, NSArray *> *twab_pendingTracked(void) {
    static NSDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = @{
            @"AdBlockSwitch"                 : @[TWABKeyAdBlockEnabled, @NO],
            @"ProxySwitch"                   : @[TWABKeyAdBlockProxyEnabled, @NO],
            @"CustomProxySwitch"             : @[TWABKeyAdBlockCustomProxyEnabled, @NO],
            @"EmotesSwitch"                  : @[TWABKeyEmotesEnabled, @NO],
            @"HideChannelBarSwitch"          : @[TWABKeyHideChannelBar, @YES],
            @"HideLeaderboardSwitch"         : @[TWABKeyHideLeaderboard, @YES],
            @"HideCommunityHighlightsSwitch" : @[TWABKeyHideCommunityHighlights, @NO],
            @"HidePinnedMessagesSwitch"      : @[TWABKeyHidePinnedMessages, @NO],
            @"HideHypeTrainsSwitch"          : @[TWABKeyHideHypeTrains, @NO],
            @"HidePredictionsSwitch"         : @[TWABKeyHidePredictions, @NO],
            @"HidePollsSwitch"               : @[TWABKeyHidePolls, @NO],
            @"HideSubGoalSwitch"             : @[TWABKeyHideSubGoal, @NO],
            @"HideDropsSwitch"               : @[TWABKeyHideDrops, @NO],
            @"StreamRewindSwitch"            : @[TWABKeyStreamRewind, @NO],
        };
    });
    return d;
}

// The value each tracked setting has on screen now (main thread only).
static NSMutableDictionary<NSString *, NSNumber *> *twab_appliedValues;

static void twab_snapshotAppliedIfNeeded(void) {
    if (!twab_appliedValues) twab_appliedValues = [NSMutableDictionary dictionary];
    for (NSArray *t in twab_pendingTracked().allValues) {
        NSString *key = t[0];
        if (!twab_appliedValues[key]) twab_appliedValues[key] = @([tweakDefaults boolForKey:key]);
    }
}

static BOOL twab_isPending(NSString *identifier) {
    NSArray *t = twab_pendingTracked()[identifier];
    if (!t || !twab_appliedValues) return NO;
    NSNumber *applied = twab_appliedValues[t[0]];
    return applied && applied.boolValue != [tweakDefaults boolForKey:t[0]];
}

// Called from Tweak.x when a stream screen opens: everything waiting is now
// in effect.
void twab_settingsStreamOpened(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!twab_appliedValues) return;
        for (NSArray *t in twab_pendingTracked().allValues)
            twab_appliedValues[t[0]] = @([tweakDefaults boolForKey:t[0]]);
    });
}

extern NSBundle *tweakBundle;
extern NSUserDefaults *tweakDefaults;
// Emotes.x — clears the emote registry and re-fetches global sets.
extern void twab_reloadEmotes(void);

#define LOC(x, d) (tweakBundle ? [tweakBundle localizedStringForKey:x value:d table:nil] : (d))

@interface TWABSettingsVC () <UIDocumentPickerDelegate>
@property (nonatomic, assign) BOOL adblockEnabled;
@property (nonatomic, assign) BOOL proxyEnabled;
@property (nonatomic, assign) BOOL customProxyEnabled;
@property (nonatomic, assign) BOOL emotesEnabled;
@property (nonatomic, assign) TWABProxyStatus proxyStatus;
// From the last check: how many proxies answered, out of how many.
@property (nonatomic, assign) NSUInteger proxyOnlineCount;
@property (nonatomic, assign) NSUInteger proxyTotalCount;
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
        twab_snapshotAppliedIfNeeded();
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
    self.tableView.estimatedSectionFooterHeight = 44;
    if (self.proxyEnabled) [self refreshProxyStatus];
}

#pragma mark - UITableViewDataSource

// Section layout:
//   0: Ad Blocking: ad block + block tracking
//   1: Proxy (only when ad block is on): proxy, custom proxy, servers, skip list
//   2: Chat: auto-claim, emotes, keep deleted, sizes, reload emotes
//   3: Home & Playback: launch screen, keep live feed playing, stream rewind
//   4: Declutter: Stream
//   5: Declutter: Chat (Community Highlights sub-options while it's on)
//   6: Declutter: Feeds & Tabs
//   7: Tools: export / import
//   8: version footer (no rows)

// Launch Screen options. tabIndex < 0 means "use Twitch's default" (both
// keys cleared). subTabIndex < 0 means "don't override sub-tab".
// Indices match the live VC hierarchy on Twitch 29.4.2 (verified via dump
// + user confirmation of tab labels):
//   tab 0 Home   sub 0 Following, sub 1 Live (default), sub 2 Clips
//   tab 1 Browse sub 0 Categories, sub 1 Live Channels
//   tab 3 Activity
//   tab 4 Profile
// group: the menu section an option sits in ("Home", "Browse"; "" = an
// untitled section; "*" = the Default section). name: its label in the menu.
// symbol: its SF Symbol.
typedef struct {
    const char *title;
    const char *group;
    const char *name;
    const char *symbol;
    NSInteger tabIndex;
    NSInteger subTabIndex;
} TWABLaunchOpt;
static const TWABLaunchOpt kLaunchOpts[] = {
    { "Default",                "*",      "Twitch Default", "iphone",                        -1, -1 },
    { "Home → Following",       "Home",   "Following",      "heart",                          0,  0 },
    { "Home → Live",            "Home",   "Live",           "dot.radiowaves.left.and.right",  0,  1 },
    { "Home → Clips",           "Home",   "Clips",          "film",                           0,  2 },
    { "Browse → Categories",    "Browse", "Categories",     "square.grid.2x2",                1,  0 },
    { "Browse → Live Channels", "Browse", "Live Channels",  "play.tv",                        1,  1 },
    { "Activity",               "",       "Activity",       "bell",                           3, -1 },
    { "Profile",                "",       "Profile",        "person.crop.circle",             4, -1 },
};
#define TWAB_LAUNCH_OPT_COUNT (sizeof(kLaunchOpts) / sizeof(kLaunchOpts[0]))

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 9;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 2;  // ad block toggle + block tracking
        case 1:
            if (!self.adblockEnabled) return 0;
            if (!self.proxyEnabled) return 1;
            // proxy switch + custom switch + (custom-only: N proxy rows
            // + "Add proxy" row) + status + whitelist
            return self.customProxyEnabled ? (3 + (NSInteger)self.proxies.count + 2) : 4;
        case 2: return [self chatRowCount];
        case 3: return 3;  // launch dropdown + watch-limit + stream rewind
        case 4:
        case 5:
        case 6: return (NSInteger)[self declutterRowsForSection:section].count;
        case 7: return 2;  // Tools: export, import
        case 8: return 0;  // version footer only
        default: return 0;
    }
}

// Category title above each section. Proxy header is suppressed when ad block
// is off (the section collapses to 0 rows, so a lone header would float).
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return LOC(@"settings.section.adblock", @"Ad Blocking");
        case 1: return self.adblockEnabled ? LOC(@"settings.section.proxy", @"Proxy") : nil;
        case 2: return LOC(@"settings.section.chat", @"Chat");
        case 3: return LOC(@"settings.section.home", @"Home & Playback");
        case 4: return LOC(@"settings.section.declutter.stream", @"Declutter: Stream");
        case 5: return LOC(@"settings.section.declutter.chat", @"Declutter: Chat");
        case 6: return LOC(@"settings.section.declutter.feeds", @"Declutter: Feeds & Tabs");
        case 7: return LOC(@"settings.section.tools", @"Tools");
        default: return nil;  // section 8 = version footer only
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
            if (indexPath.row == 1)
                return [self switchCellWithTitle:LOC(@"settings.blocktracking.title", @"Block Tracking")
                                        subtitle:LOC(@"settings.blocktracking.desc",
                                                     @"Stop Twitch's usage tracking, crash reports and ad measurement from being sent.")
                                             on:[tweakDefaults boolForKey:TWABKeyBlockTracking]
                                         action:@selector(blockTrackingSwitchChanged:)
                                     identifier:@"BlockTrackingSwitch"];
            return [self switchCellWithTitle:LOC(@"settings.adblock.title", @"Ad Block")
                                    subtitle:LOC(@"settings.adblock.desc",
                                                 @"Block video, display, and feed ads.")
                                         on:_adblockEnabled
                                     action:@selector(adblockSwitchChanged:)
                                 identifier:@"AdBlockSwitch"];
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
            if (!self.customProxyEnabled) {
                if (row == 2) return [self proxyStatusCell];
                return [self proxyWhitelistCell];
            }
            NSInteger proxyIdx = [self proxyIndexForRow:row];
            if (proxyIdx >= 0) return [self proxyMenuRowCellForIndex:proxyIdx inPlace:nil];
            if (row == [self addProxyRowIndex]) return [self addProxyCell];
            if (row == [self statusRowIndex]) return [self proxyStatusCell];
            return [self proxyWhitelistCell];
        }
        case 2:
            if (indexPath.row == 0)
                return [self switchCellWithTitle:LOC(@"settings.autoclaimpoints.title",
                                                     @"Auto-Claim Bonus Points")
                                        subtitle:LOC(@"settings.autoclaimpoints.desc",
                                                     @"Automatically claim the bonus channel points chest when it appears.")
                                             on:[tweakDefaults boolForKey:TWABKeyAutoClaimPoints]
                                         action:@selector(autoClaimPointsSwitchChanged:)
                                     identifier:@"AutoClaimPointsSwitch"];
            if (indexPath.row == 1)
                return [self switchCellWithTitle:LOC(@"settings.emotes.title", @"3rd-Party Emotes")
                                        subtitle:LOC(@"settings.emotes.desc",
                                                     @"Show 7TV, BetterTTV & FrankerFaceZ emotes in chat.")
                                             on:_emotesEnabled
                                         action:@selector(emotesSwitchChanged:)
                                     identifier:@"EmotesSwitch"];
            if (indexPath.row == 2)
                return [self switchCellWithTitle:LOC(@"settings.keepdeleted.title",
                                                     @"Keep Deleted Messages")
                                        subtitle:LOC(@"settings.keepdeleted.desc",
                                                     @"Keep messages moderators delete, and messages from timed-out or banned users, with a note saying what happened.")
                                             on:[tweakDefaults boolForKey:TWABKeyKeepDeletedMessages]
                                         action:@selector(keepDeletedSwitchChanged:)
                                     identifier:@"KeepDeletedSwitch"];
            if (indexPath.row == 3) return [self emoteSizeCell];
            if (indexPath.row == 4) return [self textSizeCell];
            return [self actionCellWithTitle:LOC(@"settings.emotes.reload", @"Reload Emotes")
                                    subtitle:LOC(@"settings.emotes.reload.desc",
                                                 @"Clear the cache and re-fetch all emote sets.")
                                 destructive:NO disclosure:NO identifier:@"ReloadEmotesCell"];
        case 3:
            if (indexPath.row == 0) return [self launchScreenDropdownCell];
            if (indexPath.row == 2)
                return [self switchCellWithTitle:LOC(@"settings.streamrewind.title", @"Stream Rewind (Experimental)")
                                        subtitle:LOC(@"settings.streamrewind.desc2",
                                                     @"An unreleased Twitch feature: rewind live streams right in the player, double-tap to skip, and jump back to live. Works on channels that save past broadcasts. Twitch hasn't finished it yet, so expect the odd bug.")
                                             on:[tweakDefaults boolForKey:TWABKeyStreamRewind]
                                         action:@selector(streamRewindSwitchChanged:)
                                     identifier:@"StreamRewindSwitch"];
            return [self switchCellWithTitle:LOC(@"settings.watchlimit.title",
                                                 @"Keep Live Feed Playing")
                                    subtitle:LOC(@"settings.watchlimit.desc",
                                                 @"Stop the Live feed cutting a stream off with the Watch/Follow overlay.")
                                         on:[tweakDefaults boolForKey:TWABKeyDisableWatchLimit]
                                     action:@selector(disableWatchLimitSwitchChanged:)
                                 identifier:@"DisableWatchLimitSwitch"];
        case 4:
        case 5:
        case 6:
            return [self declutterCellNamed:[self declutterRowsForSection:indexPath.section][indexPath.row]];
        case 7:
            if (indexPath.row == 0)
                return [self actionCellWithTitle:LOC(@"settings.tools.export", @"Export Settings")
                                        subtitle:LOC(@"settings.tools.export.desc",
                                                     @"Share your toggles and proxy list as JSON.")
                                     destructive:NO disclosure:NO identifier:@"ExportCell"];
            return [self actionCellWithTitle:LOC(@"settings.tools.import", @"Import Settings")
                                    subtitle:LOC(@"settings.tools.import.desc",
                                                 @"Select a previously exported JSON file.")
                                 destructive:NO disclosure:NO identifier:@"ImportCell"];
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

static const NSInteger kTWABMenuOverlayTag = 0x74776d31;

// What the row shows on the right: "Home · Live", "Activity", "Twitch Default".
static NSString *twab_launchOptLabel(NSUInteger i) {
    const TWABLaunchOpt *o = &kLaunchOpts[i];
    NSString *name = [NSString stringWithUTF8String:o->name];
    if (o->group[0] == '\0' || o->group[0] == '*') return name;
    return [NSString stringWithFormat:@"%s · %@", o->group, name];
}

// The row's value plus an up/down chevron, like iOS Settings' pop-up rows
// (or another symbol, e.g. "ellipsis.circle" for a row of actions).
static NSAttributedString *twab_menuValueTextWithSymbol(NSString *value, NSString *symbol);
static NSAttributedString *twab_menuValueTextWithSymbol(NSString *value, NSString *symbol) {
    UIColor *color = [UIColor secondaryLabelColor];
    BOOL actions = [symbol hasPrefix:@"ellipsis"];
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc]
        initWithString:value.length ? [value stringByAppendingString:@" "] : @""
            attributes:@{ NSFontAttributeName : [UIFont systemFontOfSize:15],
                          NSForegroundColorAttributeName : color }];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:actions ? 17 : ([symbol isEqualToString:@"chevron.right"] ? 12 : 11)
                                                        weight:actions ? UIImageSymbolWeightRegular
                                                                       : UIImageSymbolWeightSemibold];
    UIImage *chevron = [[UIImage systemImageNamed:symbol withConfiguration:cfg]
        imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (chevron) {
        NSTextAttachment *att = [NSTextAttachment new];
        att.image = chevron;
        att.bounds = CGRectMake(0, actions ? -3 : -1, chevron.size.width, chevron.size.height);
        [s appendAttributedString:[NSAttributedString attributedStringWithAttachment:att]];
    }
    return s;
}

// Turns a row into a pop-up menu row: the value and an up/down chevron sit on
// the right, and (iOS 14+) a clear button over the whole row opens `menu`
// right at the row. Returns NO on iOS 13, where the row keeps its
// tap-to-open sheet (didSelectRow).
- (BOOL)twab_setMenu:(id)menu value:(NSString *)value onCell:(UITableViewCell *)cell {
    return [self twab_setMenu:menu value:value symbol:@"chevron.up.chevron.down" onCell:cell];
}

- (BOOL)twab_setMenu:(id)menu value:(NSString *)value symbol:(NSString *)symbol onCell:(UITableViewCell *)cell {
    UILabel *label = [cell.accessoryView isKindOfClass:UILabel.class] ? (UILabel *)cell.accessoryView : nil;
    if (!label) {
        label = [UILabel new];
        label.userInteractionEnabled = NO;
        cell.accessoryView = label;
    }
    label.attributedText = twab_menuValueTextWithSymbol(value, symbol);
    [label sizeToFit];
    // respondsToSelector: rather than @available (crashes when sideloaded).
    if (!menu || ![UIButton instancesRespondToSelector:@selector(setShowsMenuAsPrimaryAction:)]) return NO;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
    UIButton *overlay = (UIButton *)[cell viewWithTag:kTWABMenuOverlayTag];
    if (!overlay) {
        overlay = [UIButton buttonWithType:UIButtonTypeCustom];
        overlay.tag = kTWABMenuOverlayTag;
        overlay.frame = cell.bounds;
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        overlay.showsMenuAsPrimaryAction = YES;
        if ([overlay respondsToSelector:@selector(setPreferredMenuElementOrder:)])
            overlay.preferredMenuElementOrder = UIContextMenuConfigurationElementOrderFixed;
        [cell addSubview:overlay];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    overlay.menu = menu;
    overlay.accessibilityValue = value;
    [cell bringSubviewToFront:overlay];
#pragma clang diagnostic pop
    return YES;
}

// The look every row shares: the title, and under it a grey 12pt description
// (or a coloured status line when `color` is given).
- (void)twab_styleCell:(UITableViewCell *)cell title:(NSString *)title
              subtitle:(id)subtitle color:(UIColor *)color titleColor:(UIColor *)titleColor {
    if ([cell respondsToSelector:@selector(defaultContentConfiguration)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        UIListContentConfiguration *cfg = [cell defaultContentConfiguration];
        cfg.text = title;
        if (titleColor) cfg.textProperties.color = titleColor;
        if ([subtitle isKindOfClass:NSAttributedString.class]) cfg.secondaryAttributedText = subtitle;
        else cfg.secondaryText = subtitle;
        cfg.secondaryTextProperties.color = color ?: [UIColor secondaryLabelColor];
        cfg.secondaryTextProperties.font = color ? [UIFont systemFontOfSize:12 weight:UIFontWeightMedium]
                                                 : [UIFont systemFontOfSize:12];
        cfg.textToSecondaryTextVerticalPadding = 2;
        [cell setContentConfiguration:cfg];
#pragma clang diagnostic pop
    } else {
        cell.textLabel.text = title;
        if (titleColor) cell.textLabel.textColor = titleColor;
        if ([subtitle isKindOfClass:NSAttributedString.class]) cell.detailTextLabel.attributedText = subtitle;
        else cell.detailTextLabel.text = subtitle;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = color ?: [UIColor grayColor];
    }
}

// A row that opens an editor or another screen: value and › on the right.
- (void)twab_setDisclosureValue:(NSString *)value onCell:(UITableViewCell *)cell {
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    [self twab_setMenu:nil value:value symbol:@"chevron.right" onCell:cell];
}

// Sets a menu action's grey second line (iOS 15+).
static void twab_setMenuSubtitle(id action, NSString *subtitle) {
    if (subtitle.length && [action respondsToSelector:NSSelectorFromString(@"setSubtitle:")])
        [action setValue:subtitle forKey:@"subtitle"];
}

- (void)applyLaunchOpt:(NSUInteger)i {
    if (i >= TWAB_LAUNCH_OPT_COUNT) return;
    NSInteger tab = kLaunchOpts[i].tabIndex;
    NSInteger sub = kLaunchOpts[i].subTabIndex;
    if (tab < 0) [tweakDefaults removeObjectForKey:TWABKeyLaunchTab];
    else         [tweakDefaults setInteger:tab forKey:TWABKeyLaunchTab];
    if (sub < 0) [tweakDefaults removeObjectForKey:TWABKeyLaunchSubTab];
    else         [tweakDefaults setInteger:sub forKey:TWABKeyLaunchSubTab];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:0 inSection:3]]
                          withRowAnimation:UITableViewRowAnimationNone];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
// Native pull-down menu (iOS 14+): Default, then Home and Browse sections
// with headers, then Activity / Profile; the current choice gets the system
// checkmark.
- (UIMenu *)launchScreenMenu {
    NSUInteger current = [self currentLaunchOptIndex];
    NSMutableArray<UIMenuElement *> *sections = [NSMutableArray array];
    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    const char *group = NULL;
    __weak typeof(self) weakSelf = self;
    for (NSUInteger i = 0; i <= TWAB_LAUNCH_OPT_COUNT; i++) {
        BOOL flush = i == TWAB_LAUNCH_OPT_COUNT || (group && strcmp(group, kLaunchOpts[i].group) != 0);
        if (flush && items.count) {
            NSString *header = (group[0] == '\0' || group[0] == '*') ? @"" : [NSString stringWithUTF8String:group];
            [sections addObject:[UIMenu menuWithTitle:header image:nil identifier:nil
                                              options:UIMenuOptionsDisplayInline children:items]];
            items = [NSMutableArray array];
        }
        if (i == TWAB_LAUNCH_OPT_COUNT) break;
        group = kLaunchOpts[i].group;
        UIAction *a = [UIAction actionWithTitle:[NSString stringWithUTF8String:kLaunchOpts[i].name]
                                          image:[UIImage systemImageNamed:[NSString stringWithUTF8String:kLaunchOpts[i].symbol]]
                                     identifier:nil
                                        handler:^(__kindof UIAction *_) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf applyLaunchOpt:i]; });
        }];
        a.state = i == current ? UIMenuElementStateOn : UIMenuElementStateOff;
        [items addObject:a];
    }
    return [UIMenu menuWithTitle:@"" children:sections];
}

- (UITableViewCell *)launchScreenDropdownCell {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"LaunchDropdown"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"LaunchDropdown"];
    }
    NSString *title = LOC(@"settings.launch.title", @"Launch Screen");
    NSString *subtitle = LOC(@"settings.launch.desc", @"The tab Twitch opens on.");
    if ([cell respondsToSelector:@selector(defaultContentConfiguration)]) {
        UIListContentConfiguration *cfg = [cell defaultContentConfiguration];
        cfg.text = title;
        cfg.secondaryText = subtitle;
        cfg.secondaryTextProperties.color = [UIColor secondaryLabelColor];
        cfg.secondaryTextProperties.font = [UIFont systemFontOfSize:12];
        cfg.textToSecondaryTextVerticalPadding = 2;
        [cell setContentConfiguration:cfg];
    } else {
        cell.textLabel.text = title;
        cell.detailTextLabel.text = subtitle;
        cell.detailTextLabel.textColor = [UIColor grayColor];
    }
    BOOL nativeMenu = [UIButton instancesRespondToSelector:@selector(setShowsMenuAsPrimaryAction:)];
    [self twab_setMenu:(nativeMenu ? [self launchScreenMenu] : nil)
                 value:twab_launchOptLabel([self currentLaunchOptIndex])
                onCell:cell];
    return cell;
}
#pragma clang diagnostic pop

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && self.adblockEnabled && self.proxyEnabled &&
        indexPath.row == [self statusRowIndex] + 1) {
        [self presentWhitelistEditor];
        return;
    }
    if (indexPath.section == 1 && self.adblockEnabled && self.proxyEnabled &&
        !self.customProxyEnabled && indexPath.row == [self statusRowIndex]) {
        [self presentDefaultProxyPicker:[tableView cellForRowAtIndexPath:indexPath]];
        return;
    }
    if (indexPath.section == 1 && self.adblockEnabled && self.proxyEnabled &&
        self.customProxyEnabled && indexPath.row == [self addProxyRowIndex]) {
        [self presentProxyEditorForIndex:-1];
        return;
    }
    if (indexPath.section == 1 && self.customProxyEnabled && [self proxyIndexForRow:indexPath.row] >= 0) {
        [self presentProxyEditorForIndex:[self proxyIndexForRow:indexPath.row]];
        return;
    }
    if (indexPath.section == 2 &&
        ![UIButton instancesRespondToSelector:@selector(setShowsMenuAsPrimaryAction:)]) {
        if (indexPath.row == 3) { [self stepScaleForKey:TWABKeyChatEmoteScale]; return; }
        if (indexPath.row == 4) { [self stepScaleForKey:TWABKeyChatTextScale]; return; }
    }
    if (indexPath.section == 2 && indexPath.row == [self chatRowCount] - 1) {
        [self reloadEmotesTapped:[tableView cellForRowAtIndexPath:indexPath]];
        return;
    }
    if (indexPath.section == 3 && indexPath.row == 0) {
        [self presentLaunchScreenPicker:[tableView cellForRowAtIndexPath:indexPath]];
        return;
    }
    if (indexPath.section == 7) {
        if (indexPath.row == 0)
            [self exportSettings:[tableView cellForRowAtIndexPath:indexPath]];
        else
            [self importSettings];
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
        if (twab_pendingTracked()[identifier])
            [sw addTarget:self action:@selector(trackedSwitchToggled:)
                forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    }
    // A change that can't apply to the open stream gets an orange note.
    NSAttributedString *pendingSubtitle = nil;
    if (twab_isPending(identifier)) {
        NSMutableAttributedString *s = [[NSMutableAttributedString alloc]
            initWithString:subtitle ?: @""
                attributes:@{ NSFontAttributeName : [UIFont systemFontOfSize:12],
                              NSForegroundColorAttributeName : [UIColor secondaryLabelColor] }];
        NSString *note = LOC(@"settings.pending.stream", @"Applies the next time you open a stream");
        [s appendAttributedString:[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@%@", s.length ? @"\n" : @"", note]
                attributes:@{ NSFontAttributeName : [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold],
                              NSForegroundColorAttributeName : [UIColor systemOrangeColor] }]];
        pendingSubtitle = s;
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
        if (pendingSubtitle) cfg.secondaryAttributedText = pendingSubtitle;
        [cell setContentConfiguration:cfg];
#pragma clang diagnostic pop
    } else {
        cell.textLabel.text = title;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = [UIColor grayColor];
        if (pendingSubtitle) cell.detailTextLabel.attributedText = pendingSubtitle;
        else cell.detailTextLabel.text = subtitle;
    }
    sw.on = on;
    return cell;
}

// Runs after a tracked switch's own handler: turning on a setting that
// applies live (channel bar, leaderboard) counts as applied; then the row is
// redrawn to show or clear its note.
- (void)trackedSwitchToggled:(UISwitch *)sw {
    NSArray *t = twab_pendingTracked()[sw.accessibilityIdentifier];
    if (!t) return;
    if (sw.on && [t[1] boolValue]) twab_appliedValues[t[0]] = @YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        UITableView *tv = weakSelf.tableView;
        UIView *v = sw;
        while (v && ![v isKindOfClass:UITableViewCell.class]) v = v.superview;
        NSIndexPath *ip = v ? [tv indexPathForCell:(UITableViewCell *)v] : nil;
        if (ip) [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    });
}

// Slider row: title + value% on top, subtitle below, slider at the bottom.
// Built entirely with manual subviews — UIListContentConfiguration takes over
// the content view and hides anything else added to it.
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
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (disclosure) [self twab_setDisclosureValue:nil onCell:cell];
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
    // The built-in proxy can be chosen by country (tap the row).
    if (!self.customProxyEnabled) {
        NSString *chosen = [tweakDefaults stringForKey:TWABKeyPreferredProxy];
        title = [NSString stringWithFormat:@"%@: %@", title,
                 chosen.length ? chosen : LOC(@"settings.proxy.automatic", @"Automatic")];
    }
    cell.selectionStyle = self.customProxyEnabled ? UITableViewCellSelectionStyleNone
                                                  : UITableViewCellSelectionStyleDefault;
    cell.accessoryType = self.customProxyEnabled ? UITableViewCellAccessoryNone
                                                 : UITableViewCellAccessoryDisclosureIndicator;
    NSString *detail;
    UIColor *color;
    switch (self.proxyStatus) {
        case TWABProxyStatusOnline:
            detail = LOC(@"settings.proxy.status.online", @"● Online");
            if (self.proxyTotalCount > 1)
                detail = [NSString stringWithFormat:@"%@ (%lu/%lu)", detail,
                          (unsigned long)self.proxyOnlineCount, (unsigned long)self.proxyTotalCount];
            color  = self.proxyOnlineCount < self.proxyTotalCount ? [UIColor systemOrangeColor]
                                                                 : [UIColor systemGreenColor];
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
    if (!self.customProxyEnabled) return [self defaultProxyMenuCellWithStatus:detail color:color];
    // Custom: same layout as Default Proxy, status under the title.
    UITableViewCell *custom = [self.tableView dequeueReusableCellWithIdentifier:@"CustomProxyStatusCell"];
    if (!custom) {
        custom = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                        reuseIdentifier:@"CustomProxyStatusCell"];
        custom.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    if (!self.proxies.count) {
        detail = LOC(@"settings.proxy.custom.none2", @"No proxies added yet");
        color = [UIColor secondaryLabelColor];
    }
    [self twab_styleCell:custom title:LOC(@"settings.proxy.custom.status", @"Your Proxies")
                subtitle:detail color:color titleColor:nil];
    return custom;
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

// Set while reloadStatusRow refreshes the visible row in place, so a status
// update doesn't close the menu if it's open.
static UITableViewCell *twab_inPlaceProxyCell;

static BOOL twab_hasDeferredMenus(void) {
    return [NSClassFromString(@"UIDeferredMenuElement")
        respondsToSelector:NSSelectorFromString(@"elementWithUncachedProvider:")];
}

// "Default Proxy" with the live status under it and the choice on the right;
// tapping opens the country menu.
- (UITableViewCell *)defaultProxyMenuCellWithStatus:(NSString *)status color:(UIColor *)color {
    BOOL inPlace = twab_inPlaceProxyCell != nil;
    UITableViewCell *cell = twab_inPlaceProxyCell
        ?: [self.tableView dequeueReusableCellWithIdentifier:@"DefaultProxyMenuCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"DefaultProxyMenuCell"];
    }
    NSString *title = LOC(@"settings.proxy.pick.title", @"Default Proxy");
    if ([cell respondsToSelector:@selector(defaultContentConfiguration)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        UIListContentConfiguration *cfg = [cell defaultContentConfiguration];
        cfg.text = title;
        cfg.secondaryText = status;
        cfg.secondaryTextProperties.color = color;
        cfg.secondaryTextProperties.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        cfg.textToSecondaryTextVerticalPadding = 2;
        [cell setContentConfiguration:cfg];
#pragma clang diagnostic pop
    } else {
        cell.textLabel.text = title;
        cell.detailTextLabel.text = status;
        cell.detailTextLabel.textColor = color;
    }
    NSString *chosen = [tweakDefaults stringForKey:TWABKeyPreferredProxy];
    BOOL nativeMenu = [UIButton instancesRespondToSelector:@selector(setShowsMenuAsPrimaryAction:)];
    // In place with a live (built-on-open) menu: keep the menu as it is.
    BOOL keepMenu = inPlace && twab_hasDeferredMenus();
    [self twab_setMenu:(nativeMenu && !keepMenu ? [self defaultProxyMenu] : nil)
                 value:chosen.length ? chosen : LOC(@"settings.proxy.automatic", @"Automatic")
                onCell:cell];
    return cell;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
// Automatic first, then each country with its live speed (or Offline /
// backup note) as a grey second line. Built when the menu opens (iOS 15+),
// so the speeds are current.
- (NSArray<UIMenuElement *> *)defaultProxyMenuItems {
    NSArray<NSString *> *names = twab_defaultProxyNames();
    NSArray<NSString *> *addresses = twab_effectiveProxyAddresses();
    NSString *chosen = [tweakDefaults stringForKey:TWABKeyPreferredProxy] ?: @"";
    __weak typeof(self) weakSelf = self;
    void (^choose)(NSString *) = ^(NSString *name) {
        if (name.length) [tweakDefaults setObject:name forKey:TWABKeyPreferredProxy];
        else [tweakDefaults removeObjectForKey:TWABKeyPreferredProxy];
        twab_proxyPoolResetPick();
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf reloadStatusRow]; });
    };
    UIAction *automatic = [UIAction actionWithTitle:LOC(@"settings.proxy.automatic", @"Automatic")
                                              image:[UIImage systemImageNamed:@"sparkles"]
                                         identifier:nil
                                            handler:^(__kindof UIAction *_) { choose(nil); }];
    twab_setMenuSubtitle(automatic, LOC(@"settings.proxy.automatic.sub", @"Recommended · uses the best servers for you"));
    automatic.state = chosen.length ? UIMenuElementStateOff : UIMenuElementStateOn;

    NSMutableArray<UIMenuElement *> *countries = [NSMutableArray array];
    NSSet *backups = twab_backupOnlyProxyAddresses();
    for (NSUInteger i = 0; i < names.count && i < addresses.count; i++) {
        NSString *name = names[i];
        NSDictionary *info = twab_proxyPoolInfo(addresses[i]);
        NSString *state;
        NSString *symbol;
        if (!info[@"up"]) {
            state = LOC(@"settings.proxy.status.notchecked", @"Not checked yet");
            symbol = @"circle.dashed";
        } else if (![info[@"up"] boolValue] || [info[@"benched"] boolValue]) {
            state = LOC(@"settings.proxy.status.offline.plain", @"Offline");
            symbol = @"wifi.slash";
        } else {
            state = [NSString stringWithFormat:@"%.0f ms", [info[@"latencyMs"] doubleValue]];
            symbol = @"globe";
        }
        if ([backups containsObject:addresses[i]])
            state = [state stringByAppendingString:LOC(@"settings.proxy.backup720", @" · backup, up to 720p")];
        UIAction *a = [UIAction actionWithTitle:name
                                          image:[UIImage systemImageNamed:symbol]
                                     identifier:nil
                                        handler:^(__kindof UIAction *_) { choose(name); }];
        twab_setMenuSubtitle(a, state);
        // iOS 14 has no subtitles, so the state goes in the title there.
        if (![a respondsToSelector:NSSelectorFromString(@"setSubtitle:")])
            a.title = [NSString stringWithFormat:@"%@ · %@", name, state];
        a.state = [chosen isEqualToString:name] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [countries addObject:a];
    }
    NSMutableArray<UIMenuElement *> *out = [NSMutableArray array];
    [out addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil
                                 options:UIMenuOptionsDisplayInline children:@[automatic]]];
    if (countries.count)
        [out addObject:[UIMenu menuWithTitle:LOC(@"settings.proxy.pick.header",
                                                 @"If your pick goes down, another server takes over until it's back.")
                                       image:nil identifier:nil
                                     options:UIMenuOptionsDisplayInline children:countries]];
    return out;
}

- (UIMenu *)defaultProxyMenu {
    if (twab_hasDeferredMenus()) {
        __weak typeof(self) weakSelf = self;
        UIMenuElement *live = [UIDeferredMenuElement elementWithUncachedProvider:
            ^(void (^completion)(NSArray<UIMenuElement *> *)) {
                completion([weakSelf defaultProxyMenuItems] ?: @[]);
            }];
        return [UIMenu menuWithTitle:@"" children:@[live]];
    }
    return [UIMenu menuWithTitle:@"" children:[self defaultProxyMenuItems]];
}
#pragma clang diagnostic pop

// Pick the built-in proxy by country, or Automatic (iOS 13 fallback). A choice is a
// preference: if that proxy is down, the app still uses another one.
- (void)presentDefaultProxyPicker:(UIView *)anchor {
    NSArray<NSString *> *names = twab_defaultProxyNames();
    NSArray<NSString *> *addresses = twab_effectiveProxyAddresses();
    NSString *chosen = [tweakDefaults stringForKey:TWABKeyPreferredProxy] ?: @"";
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:LOC(@"settings.proxy.pick.title", @"Default Proxy")
                         message:LOC(@"settings.proxy.pick.desc",
                                     @"Automatic spreads streams over the servers that work best "
                                     @"for you. If you pick a country and it goes down, the app "
                                     @"switches to another one until it's back.")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    void (^choose)(NSString *) = ^(NSString *name) {
        if (name.length) [tweakDefaults setObject:name forKey:TWABKeyPreferredProxy];
        else [tweakDefaults removeObjectForKey:TWABKeyPreferredProxy];
        twab_proxyPoolResetPick();
        [weakSelf reloadStatusRow];
    };
    NSString *autoTitle = LOC(@"settings.proxy.automatic.recommended", @"Automatic (recommended)");
    if (!chosen.length) autoTitle = [@"✓  " stringByAppendingString:autoTitle];
    [sheet addAction:[UIAlertAction actionWithTitle:autoTitle style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) { choose(nil); }]];
    for (NSUInteger i = 0; i < names.count && i < addresses.count; i++) {
        NSString *name = names[i];
        NSDictionary *info = twab_proxyPoolInfo(addresses[i]);
        NSString *state;
        if (!info[@"up"]) state = LOC(@"settings.proxy.status.notchecked", @"Not checked yet");
        else if (![info[@"up"] boolValue] || [info[@"benched"] boolValue])
            state = LOC(@"settings.proxy.status.offline.plain", @"Offline");
        else state = [NSString stringWithFormat:@"%.0f ms", [info[@"latencyMs"] doubleValue]];
        NSString *title = [NSString stringWithFormat:@"%@ · %@", name, state];
        if ([twab_backupOnlyProxyAddresses() containsObject:addresses[i]])
            title = [title stringByAppendingString:LOC(@"settings.proxy.backup720", @" · backup, up to 720p")];
        if ([chosen isEqualToString:name]) title = [@"✓  " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *_) { choose(name); }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:LOC(@"settings.launch.cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = anchor;
    sheet.popoverPresentationController.sourceRect = anchor.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (UITableViewCell *)proxyWhitelistCell {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:@"ProxyWhitelistCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"ProxyWhitelistCell"];
    }
    NSMutableArray<NSString *> *channels = [NSMutableArray array];
    for (NSString *c in [[tweakDefaults stringForKey:TWABKeyProxyWhitelist] ?: @"" componentsSeparatedByString:@","]) {
        NSString *t = [c stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [channels addObject:t];
    }
    NSString *subtitle = channels.count
        ? [channels componentsJoinedByString:@", "]
        : LOC(@"settings.whitelist.desc", @"Channels that always play without the proxy.");
    [self twab_styleCell:cell title:LOC(@"settings.whitelist.title", @"Skip Proxy for Channels")
                subtitle:subtitle color:nil titleColor:nil];
    if ([cell respondsToSelector:@selector(defaultContentConfiguration)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        UIListContentConfiguration *cfg = (UIListContentConfiguration *)cell.contentConfiguration;
        cfg.secondaryTextProperties.numberOfLines = 2;
        cfg.secondaryTextProperties.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell setContentConfiguration:cfg];
#pragma clang diagnostic pop
    }
    NSString *value = channels.count == 0 ? LOC(@"settings.whitelist.none", @"None")
                    : channels.count == 1 ? @"1 channel"
                                          : [NSString stringWithFormat:@"%lu channels", (unsigned long)channels.count];
    [self twab_setDisclosureValue:value onCell:cell];
    return cell;
}

// One custom proxy: its place in the order as a numbered badge, the server
// (password left out) and its live speed or Offline under it. Tapping opens
// Edit / Move Up / Move Down / Delete. inPlace: refresh a visible row without
// rebuilding it (status updates), keeping its menu as it is.
- (UITableViewCell *)proxyMenuRowCellForIndex:(NSInteger)idx inPlace:(UITableViewCell *)existing {
    UITableViewCell *cell = existing ?: [self.tableView dequeueReusableCellWithIdentifier:@"ProxyMenuRowCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"ProxyMenuRowCell"];
    }
    NSString *raw = idx < (NSInteger)self.proxies.count ? self.proxies[idx] : @"";
    NSURL *url = twab_normalizedProxyURL(raw);
    NSString *server = raw;
    if (url.host.length)
        server = url.port ? [NSString stringWithFormat:@"%@:%@", url.host, url.port] : url.host;

    NSDictionary *info = twab_proxyPoolInfo(raw);
    NSString *state;
    UIColor *stateColor;
    if (!url) {
        state = LOC(@"settings.proxy.invalid", @"Not a valid address");
        stateColor = [UIColor systemRedColor];
    } else if (!info[@"up"]) {
        state = LOC(@"settings.proxy.status.notchecked", @"Not checked yet");
        stateColor = [UIColor secondaryLabelColor];
    } else if (![info[@"up"] boolValue] || [info[@"benched"] boolValue]) {
        state = LOC(@"settings.proxy.status.offline", @"● Offline");
        stateColor = [UIColor systemRedColor];
    } else {
        state = [NSString stringWithFormat:@"● %.0f ms", [info[@"latencyMs"] doubleValue]];
        stateColor = [UIColor systemGreenColor];
    }

    NSString *place = [NSString stringWithFormat:LOC(@"settings.proxy.number", @"Proxy %ld"), (long)idx + 1];
    NSMutableAttributedString *sub = [[NSMutableAttributedString alloc] initWithString:state
        attributes:@{ NSFontAttributeName : [UIFont systemFontOfSize:12 weight:UIFontWeightMedium],
                      NSForegroundColorAttributeName : stateColor }];
    [sub appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"  ·  %@", place]
            attributes:@{ NSFontAttributeName : [UIFont systemFontOfSize:12],
                          NSForegroundColorAttributeName : [UIColor secondaryLabelColor] }]];
    [self twab_styleCell:cell title:server subtitle:sub color:nil titleColor:nil];
    if ([cell respondsToSelector:@selector(defaultContentConfiguration)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        UIListContentConfiguration *cfg = (UIListContentConfiguration *)cell.contentConfiguration;
        cfg.textProperties.numberOfLines = 1;
        cfg.textProperties.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [cell setContentConfiguration:cfg];
#pragma clang diagnostic pop
    }
    BOOL nativeMenu = [UIButton instancesRespondToSelector:@selector(setShowsMenuAsPrimaryAction:)];
    [self twab_setMenu:(nativeMenu && !existing ? [self proxyRowMenuForIndex:idx] : nil)
                 value:nil symbol:@"ellipsis.circle" onCell:cell];
    if (!nativeMenu) [self twab_setDisclosureValue:nil onCell:cell];
    return cell;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
- (UIMenu *)proxyRowMenuForIndex:(NSInteger)idx {
    __weak typeof(self) weakSelf = self;
    UIAction *edit = [UIAction actionWithTitle:LOC(@"settings.proxy.edit", @"Edit")
                                         image:[UIImage systemImageNamed:@"pencil"] identifier:nil
                                       handler:^(__kindof UIAction *_) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf presentProxyEditorForIndex:idx]; });
    }];
    UIAction *up = [UIAction actionWithTitle:LOC(@"settings.proxy.moveup", @"Move Up")
                                       image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil
                                     handler:^(__kindof UIAction *_) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf moveProxyAtIndex:idx by:-1]; });
    }];
    UIAction *down = [UIAction actionWithTitle:LOC(@"settings.proxy.movedown", @"Move Down")
                                         image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil
                                       handler:^(__kindof UIAction *_) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf moveProxyAtIndex:idx by:1]; });
    }];
    if (idx <= 0) up.attributes = UIMenuElementAttributesDisabled;
    if (idx >= (NSInteger)self.proxies.count - 1) down.attributes = UIMenuElementAttributesDisabled;
    UIAction *del = [UIAction actionWithTitle:LOC(@"settings.proxy.delete", @"Delete")
                                        image:[UIImage systemImageNamed:@"trash"] identifier:nil
                                      handler:^(__kindof UIAction *_) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf deleteProxyAtIndex:idx]; });
    }];
    del.attributes = UIMenuElementAttributesDestructive;
    UIMenu *order = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                  options:UIMenuOptionsDisplayInline children:@[up, down]];
    UIMenu *danger = [UIMenu menuWithTitle:@"" image:nil identifier:nil
                                   options:UIMenuOptionsDisplayInline children:@[del]];
    return [UIMenu menuWithTitle:@"" children:@[edit, order, danger]];
}
#pragma clang diagnostic pop

- (UITableViewCell *)addProxyCell {
    return [self actionCellWithTitle:LOC(@"settings.proxy.add.title", @"Add Proxy")
                            subtitle:LOC(@"settings.proxy.add.desc", @"An HTTP proxy in an ad-free country.")
                         destructive:NO disclosure:NO identifier:@"AddProxyCell"];
}

// Walks from any subview up to its enclosing UITableViewCell. Returns nil
// if the view isn't in a cell yet (shouldn't happen in our cellForRow flow).
- (UITableViewCell *)cellForSubview:(UIView *)view {
    UIView *v = view;
    while (v && ![v isKindOfClass:[UITableViewCell class]]) v = v.superview;
    return (UITableViewCell *)v;
}

#pragma mark - Multi-proxy editing

- (void)moveProxyAtIndex:(NSInteger)idx by:(NSInteger)delta {
    NSInteger to = idx + delta;
    if (idx < 0 || to < 0 || idx >= (NSInteger)self.proxies.count || to >= (NSInteger)self.proxies.count) return;
    [self.proxies exchangeObjectAtIndex:idx withObjectAtIndex:to];
    [self saveProxiesToDefaults];
    [self.tableView performBatchUpdates:^{
        [self.tableView moveRowAtIndexPath:[NSIndexPath indexPathForRow:2 + idx inSection:1]
                               toIndexPath:[NSIndexPath indexPathForRow:2 + to inSection:1]];
    } completion:^(BOOL _) {
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                      withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (void)deleteProxyAtIndex:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.proxies.count) return;
    [self.proxies removeObjectAtIndex:idx];
    [self saveProxiesToDefaults];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
    [self refreshProxyStatus];
}

// Add (idx < 0) or edit one custom proxy in a small text box.
- (void)presentProxyEditorForIndex:(NSInteger)idx {
    [self presentProxyEditorForIndex:idx text:(idx >= 0 && idx < (NSInteger)self.proxies.count)
                                                  ? self.proxies[idx] : @""
                               error:nil];
}

- (void)presentProxyEditorForIndex:(NSInteger)idx text:(NSString *)text error:(NSString *)error {
    BOOL adding = idx < 0;
    NSString *message = error ?: LOC(@"settings.proxy.editor.desc",
        @"An HTTP proxy in an ad-free country, as host:port or user:pass@host:port.");
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:adding ? LOC(@"settings.proxy.add.title", @"Add Proxy")
                                        : LOC(@"settings.proxy.edit.title", @"Edit Proxy")
                         message:message
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = text;
        tf.placeholder = @"user:pass@host:port";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.spellCheckingType = UITextSpellCheckingTypeNo;
        tf.keyboardType = UIKeyboardTypeURL;
        tf.returnKeyType = UIReturnKeyDone;
    }];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"settings.launch.cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:adding ? LOC(@"settings.proxy.add.button", @"Add")
                                                           : LOC(@"settings.proxy.save", @"Save")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
        __strong typeof(weakSelf) self = weakSelf;
        NSString *value = [weakAlert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        NSURL *url = twab_normalizedProxyURL(value);
        if (!url || !url.port) {
            NSString *err = LOC(@"settings.proxy.editor.invalid",
                @"That doesn't look right. Use host:port or user:pass@host:port, e.g. user:pass@1.2.3.4:8000.");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentProxyEditorForIndex:idx text:value error:err];
            });
            return;
        }
        if (adding) [self.proxies addObject:value];
        else if (idx < (NSInteger)self.proxies.count) self.proxies[idx] = value;
        [self saveProxiesToDefaults];
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                      withRowAnimation:UITableViewRowAnimationAutomatic];
        [self refreshProxyStatus];
    }]];
    alert.preferredAction = alert.actions.lastObject;
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableViewDelegate (footers)

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section == 8) {
        UIView *wrap = [[UIView alloc] init];

        UIButton *kofi = [UIButton buttonWithType:UIButtonTypeSystem];
        [kofi setTitle:@"☕ Support the Developer" forState:UIControlStateNormal];
        kofi.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        [kofi setTitleColor:[UIColor colorWithRed:1.0 green:0.6 blue:0.2 alpha:1.0] forState:UIControlStateNormal];
        [kofi addTarget:self action:@selector(openKofi) forControlEvents:UIControlEventTouchUpInside];
        kofi.translatesAutoresizingMaskIntoConstraints = NO;

        UILabel *ver = [[UILabel alloc] init];
        ver.text = @"TwitchMods v" PACKAGE_VERSION;
        ver.textAlignment = NSTextAlignmentCenter;
        ver.font = [UIFont systemFontOfSize:13];
        ver.textColor = [UIColor colorWithWhite:0.5 alpha:1];
        ver.translatesAutoresizingMaskIntoConstraints = NO;

        [wrap addSubview:kofi];
        [wrap addSubview:ver];
        [NSLayoutConstraint activateConstraints:@[
            [kofi.topAnchor constraintEqualToAnchor:wrap.topAnchor constant:12],
            [kofi.centerXAnchor constraintEqualToAnchor:wrap.centerXAnchor],
            [ver.topAnchor constraintEqualToAnchor:kofi.bottomAnchor constant:6],
            [ver.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:16],
            [ver.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-16],
            [ver.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor constant:-8],
        ]];
        return wrap;
    }

    // Other footers are plain text (titleForFooterInSection), which iOS
    // wraps to any length.
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1 && self.adblockEnabled && self.proxyEnabled && self.customProxyEnabled)
        return LOC(@"settings.proxy.footer.multi2",
                   @"Streams are spread over the proxies that work, and move off one "
                   @"that goes down. Tap a proxy to edit, move or delete it.");
    if (section == 4)
        return LOC(@"settings.declutter.stream.footer",
                   @"These apply in the channel bar, or in the info panel (tap the video) "
                   @"when the channel bar is hidden.");
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    // Collapse footers for sections that no longer have one (their
    // descriptions moved to per-row subtitles), otherwise grouped style
    // leaves an empty gap. Section 8 = version, section 4 = where the stream
    // buttons go with the channel bar hidden, section 1 = proxy mechanics.
    BOOL hasFooter = (section == 8) || (section == 4) ||
        (section == 1 && self.adblockEnabled && self.proxyEnabled && self.customProxyEnabled);
    return hasFooter ? UITableViewAutomaticDimension : CGFLOAT_MIN;
}

// Every row sizes itself to its title and subtitle.
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    // The status and Skip Proxy rows use the standard content layout, so they
    // size to the text (a fixed 44pt cut off descenders at larger text sizes).
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

// Chat rows: auto-claim, 3rd-party emotes, keep deleted messages, emote
// size, text size, reload emotes (always last).
- (NSInteger)chatRowCount {
    return 6;
}

// Declutter rows, grouped by where each item shows up. Names map to cells in
// declutterCellNamed:. Community Highlights' sub-options appear under it
// while it's on.
- (NSArray<NSString *> *)declutterRowsForSection:(NSInteger)section {
    switch (section) {
        case 4: return @[@"channelbar", @"subscribe", @"extensions", @"leaderboard", @"clip"];
        case 5: {
            NSMutableArray *rows = [@[@"bits", @"picker", @"community"] mutableCopy];
            if ([tweakDefaults boolForKey:TWABKeyHideCommunityHighlights])
                [rows addObjectsFromArray:@[@"pinned", @"hypetrains", @"predictions", @"polls", @"subgoal", @"drops"]];
            return rows;
        }
        case 6: return @[@"adfree", @"stories", @"recaps", @"createtab"];
        default: return @[];
    }
}

- (UITableViewCell *)declutterCellNamed:(NSString *)name {
    if ([name isEqualToString:@"channelbar"])
        return [self switchCellWithTitle:LOC(@"settings.hidechannelbar.title", @"Hide Channel Bar") subtitle:LOC(@"settings.hidechannelbar.desc", @"Remove the bar under the video so chat gets the space. Tap the video to see the channel info and buttons.") on:[tweakDefaults boolForKey:TWABKeyHideChannelBar] action:@selector(hideChannelBarSwitchChanged:) identifier:@"HideChannelBarSwitch"];
    if ([name isEqualToString:@"subscribe"])
        return [self switchCellWithTitle:LOC(@"settings.hidesubscribe.title", @"Hide Subscribe Buttons") subtitle:LOC(@"settings.hidesubscribe.desc", @"Remove Subscribe and Gift a Sub under the video.") on:[tweakDefaults boolForKey:TWABKeyHideSubscribe] action:@selector(hideSubscribeSwitchChanged:) identifier:@"HideSubscribeSwitch"];
    if ([name isEqualToString:@"extensions"])
        return [self switchCellWithTitle:LOC(@"settings.hideextensions.title", @"Hide Extensions Button") subtitle:LOC(@"settings.hideextensions.desc", @"Remove the button for channel extensions, like viewer maps.") on:[tweakDefaults boolForKey:TWABKeyHideExtensions] action:@selector(hideExtensionsSwitchChanged:) identifier:@"HideExtensionsSwitch"];
    if ([name isEqualToString:@"leaderboard"])
        return [self switchCellWithTitle:LOC(@"settings.hideleaderboard.title", @"Hide Leaderboard") subtitle:LOC(@"settings.hideleaderboard.desc", @"Remove the top gifters and cheerers strip under the video.") on:[tweakDefaults boolForKey:TWABKeyHideLeaderboard] action:@selector(hideLeaderboardSwitchChanged:) identifier:@"HideLeaderboardSwitch"];
    if ([name isEqualToString:@"clip"])
        return [self switchCellWithTitle:LOC(@"settings.hideclipbutton.title", @"Hide Clip Button") subtitle:LOC(@"settings.hideclipbutton.desc", @"Remove the clip button from the player controls.") on:[tweakDefaults boolForKey:TWABKeyHideClipButton] action:@selector(hideClipButtonSwitchChanged:) identifier:@"HideClipButtonSwitch"];
    if ([name isEqualToString:@"bits"])
        return [self switchCellWithTitle:LOC(@"settings.hidebits.title", @"Hide Bits Button") subtitle:LOC(@"settings.hidebits.desc", @"Remove the cheering button from the chat box.") on:[tweakDefaults boolForKey:TWABKeyHideBits] action:@selector(hideBitsSwitchChanged:) identifier:@"HideBitsSwitch"];
    if ([name isEqualToString:@"picker"])
        return [self switchCellWithTitle:LOC(@"settings.hidepickerbutton.title", @"Hide 7TV Bar") subtitle:LOC(@"settings.hidepickerbutton.desc", @"Remove the 7TV bar above the keyboard when you type in chat (a 7TV button in older chat). Press and hold Twitch's emote button to open the 7TV picker instead.") on:[tweakDefaults boolForKey:TWABKeyHidePickerButton] action:@selector(hidePickerButtonSwitchChanged:) identifier:@"HidePickerButtonSwitch"];
    if ([name isEqualToString:@"community"])
        return [self switchCellWithTitle:LOC(@"settings.hidecommunity.title", @"Hide Community Highlights") subtitle:LOC(@"settings.hidecommunity.desc", @"Remove community highlight banners above chat (pinned messages, hype trains, predictions, polls, sub goals, drops).") on:[tweakDefaults boolForKey:TWABKeyHideCommunityHighlights] action:@selector(hideCommunityHighlightsSwitchChanged:) identifier:@"HideCommunityHighlightsSwitch"];
    if ([name isEqualToString:@"pinned"])
        return [self switchCellWithTitle:LOC(@"settings.hidepinnedmessages.title", @"Pinned Messages") subtitle:LOC(@"settings.hidepinnedmessages.desc", @"Hide mod-pinned messages above chat.") on:[tweakDefaults boolForKey:TWABKeyHidePinnedMessages] action:@selector(hidePinnedMessagesSwitchChanged:) identifier:@"HidePinnedMessagesSwitch"];
    if ([name isEqualToString:@"hypetrains"])
        return [self switchCellWithTitle:LOC(@"settings.hidehypetrains.title", @"Hype Trains") subtitle:LOC(@"settings.hidehypetrains.desc", @"Hide hype train banners above chat.") on:[tweakDefaults boolForKey:TWABKeyHideHypeTrains] action:@selector(hideHypeTrainsSwitchChanged:) identifier:@"HideHypeTrainsSwitch"];
    if ([name isEqualToString:@"predictions"])
        return [self switchCellWithTitle:LOC(@"settings.hidepredictions.title", @"Predictions") subtitle:LOC(@"settings.hidepredictions.desc", @"Hide prediction banners above chat.") on:[tweakDefaults boolForKey:TWABKeyHidePredictions] action:@selector(hidePredictionsSwitchChanged:) identifier:@"HidePredictionsSwitch"];
    if ([name isEqualToString:@"polls"])
        return [self switchCellWithTitle:LOC(@"settings.hidepolls.title", @"Polls") subtitle:LOC(@"settings.hidepolls.desc", @"Hide poll banners above chat.") on:[tweakDefaults boolForKey:TWABKeyHidePolls] action:@selector(hidePollsSwitchChanged:) identifier:@"HidePollsSwitch"];
    if ([name isEqualToString:@"subgoal"])
        return [self switchCellWithTitle:LOC(@"settings.hidesubgoal.title", @"Sub Goal") subtitle:LOC(@"settings.hidesubgoal.desc", @"Hide the subscription goal progress bar above chat.") on:[tweakDefaults boolForKey:TWABKeyHideSubGoal] action:@selector(hideSubGoalSwitchChanged:) identifier:@"HideSubGoalSwitch"];
    if ([name isEqualToString:@"drops"])
        return [self switchCellWithTitle:LOC(@"settings.hidedrops.title", @"Drops") subtitle:LOC(@"settings.hidedrops.desc", @"Hide Twitch Drops campaign notifications above chat.") on:[tweakDefaults boolForKey:TWABKeyHideDrops] action:@selector(hideDropsSwitchChanged:) identifier:@"HideDropsSwitch"];
    if ([name isEqualToString:@"adfree"])
        return [self switchCellWithTitle:LOC(@"settings.hideadfree.title", @"Hide “Go Ad-Free” Button") subtitle:LOC(@"settings.hideadfree.desc", @"Remove the Turbo upsell button from the Following tab and your profile.") on:[tweakDefaults boolForKey:TWABKeyHideAdFreeButton] action:@selector(hideAdFreeSwitchChanged:) identifier:@"HideAdFreeSwitch"];
    if ([name isEqualToString:@"stories"])
        return [self switchCellWithTitle:LOC(@"settings.hidestories.title", @"Hide Twitch Stories") subtitle:LOC(@"settings.hidestories.desc", @"Remove the Stories strip from the Home tab.") on:[tweakDefaults boolForKey:TWABKeyHideStories] action:@selector(hideStoriesSwitchChanged:) identifier:@"HideStoriesSwitch"];
    if ([name isEqualToString:@"recaps"])
        return [self switchCellWithTitle:LOC(@"settings.hiderecapsbar.title", @"Hide “From Channels You Follow”") subtitle:LOC(@"settings.hiderecapsbar.desc", @"Remove the bar of clips and recaps from channels you follow above the live channels on the Live page.") on:[tweakDefaults boolForKey:TWABKeyHideRecapsBar] action:@selector(hideRecapsBarSwitchChanged:) identifier:@"HideRecapsBarSwitch"];
    if ([name isEqualToString:@"createtab"])
        return [self switchCellWithTitle:LOC(@"settings.hidecreatetab.title", @"Hide “+” (Create) Button") subtitle:LOC(@"settings.hidecreatetab.desc", @"Remove the Create button from the middle of the bottom tab bar.") on:[tweakDefaults boolForKey:TWABKeyHideCreateTab] action:@selector(hideCreateTabSwitchChanged:) identifier:@"HideCreateTabSwitch"];
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

- (void)keepDeletedSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyKeepDeletedMessages];
}

- (void)streamRewindSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyStreamRewind];
}

- (void)blockTrackingSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyBlockTracking];
}

- (void)hideCreateTabSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideCreateTab];
    twab_applySettingsLive();
}

- (void)hideLeaderboardSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideLeaderboard];
    twab_applySettingsLive();
}

- (void)hideSubscribeSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideSubscribe];
    twab_applySettingsLive();
}

- (void)hideChannelBarSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideChannelBar];
    twab_applySettingsLive();
}

- (void)hideExtensionsSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideExtensions];
    twab_applySettingsLive();
}

- (void)hideBitsSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideBits];
    twab_applySettingsLive();
}

- (void)hideSubGoalSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideSubGoal];
}

- (void)hideCommunityHighlightsSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideCommunityHighlights];
    if (sw.on) {
        // When first enabled, turn on all 4 sub-toggles by default
        if (![tweakDefaults objectForKey:TWABKeyHidePinnedMessages])
            [tweakDefaults setBool:YES forKey:TWABKeyHidePinnedMessages];
        if (![tweakDefaults objectForKey:TWABKeyHideHypeTrains])
            [tweakDefaults setBool:YES forKey:TWABKeyHideHypeTrains];
        if (![tweakDefaults objectForKey:TWABKeyHidePredictions])
            [tweakDefaults setBool:YES forKey:TWABKeyHidePredictions];
        if (![tweakDefaults objectForKey:TWABKeyHidePolls])
            [tweakDefaults setBool:YES forKey:TWABKeyHidePolls];
        if (![tweakDefaults objectForKey:TWABKeyHideSubGoal])
            [tweakDefaults setBool:YES forKey:TWABKeyHideSubGoal];
        if (![tweakDefaults objectForKey:TWABKeyHideDrops])
            [tweakDefaults setBool:YES forKey:TWABKeyHideDrops];
    }
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:5]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)hidePinnedMessagesSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHidePinnedMessages];
}

- (void)hideHypeTrainsSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideHypeTrains];
}

- (void)hidePredictionsSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHidePredictions];
}

- (void)hidePollsSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHidePolls];
}

- (void)hideDropsSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideDrops];
}

- (void)hideClipButtonSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideClipButton];
    twab_applySettingsLive();
}


- (void)hidePickerButtonSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHidePickerButton];
}

- (void)hideRecapsBarSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideRecapsBar];
}

- (void)hideStoriesSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideStories];
}

- (void)disableWatchLimitSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyDisableWatchLimit];
}

- (void)autoClaimPointsSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyAutoClaimPoints];
}

- (void)hideAdFreeSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:TWABKeyHideAdFreeButton];
}

static const char *kChatScaleTitles[] = { "Default", "Large", "Extra Large" };

// Emote Size / Chat Text Size: a menu row like Launch Screen.
- (UITableViewCell *)scaleMenuCellWithTitle:(NSString *)title subtitle:(NSString *)subtitle
                                        key:(NSString *)key identifier:(NSString *)identifier {
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    [self twab_styleCell:cell title:title subtitle:subtitle color:nil titleColor:nil];
    NSInteger current = [tweakDefaults integerForKey:key];
    if (current < 0 || current > 2) current = 0;
    id menu = nil;
    if ([UIButton instancesRespondToSelector:@selector(setShowsMenuAsPrimaryAction:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
        NSArray *symbols = @[@"textformat.size.smaller", @"textformat.size", @"textformat.size.larger"];
        NSMutableArray *items = [NSMutableArray array];
        __weak typeof(self) weakSelf = self;
        for (NSInteger i = 0; i < 3; i++) {
            UIAction *a = [UIAction actionWithTitle:[NSString stringWithUTF8String:kChatScaleTitles[i]]
                                              image:[UIImage systemImageNamed:symbols[i]]
                                         identifier:nil
                                            handler:^(__kindof UIAction *_) {
                [tweakDefaults setInteger:i forKey:key];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:2]
                                      withRowAnimation:UITableViewRowAnimationNone];
                });
            }];
            a.state = i == current ? UIMenuElementStateOn : UIMenuElementStateOff;
            [items addObject:a];
        }
        menu = [UIMenu menuWithTitle:@"" children:items];
#pragma clang diagnostic pop
    }
    [self twab_setMenu:menu value:[NSString stringWithUTF8String:kChatScaleTitles[current]] onCell:cell];
    return cell;
}

- (UITableViewCell *)emoteSizeCell {
    return [self scaleMenuCellWithTitle:LOC(@"settings.emotesize.title", @"Emote Size")
                               subtitle:LOC(@"settings.emotesize.desc", @"How big emotes are in chat.")
                                    key:TWABKeyChatEmoteScale identifier:@"EmoteSizeCell"];
}

- (UITableViewCell *)textSizeCell {
    return [self scaleMenuCellWithTitle:LOC(@"settings.textsize.title", @"Chat Text Size")
                               subtitle:LOC(@"settings.textsize.desc", @"How big chat messages are.")
                                    key:TWABKeyChatTextScale identifier:@"TextSizeCell"];
}

// iOS 13 (no menus): tapping the row steps to the next size.
- (void)stepScaleForKey:(NSString *)key {
    NSInteger next = ([tweakDefaults integerForKey:key] + 1) % 3;
    [tweakDefaults setInteger:next forKey:key];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:2]
                  withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Tools (reload / export / import)

// The subset of defaults keys that export/import round-trips. Proxy list,
// every toggle, and the launch tab/sub-tab. Deliberately excludes one-shot
// migration flags and anything device-specific.
static NSArray<NSString *> *twab_exportKeys(void) {
    return @[ TWABKeyAdBlockEnabled, TWABKeyAdBlockProxyEnabled,
              TWABKeyAdBlockCustomProxyEnabled, TWABKeyAdBlockProxy,
              TWABKeyEmotesEnabled, TWABKeyLaunchTab, TWABKeyLaunchSubTab,
              TWABKeyHideStories, TWABKeyDisableWatchLimit,
              TWABKeyHideAdFreeButton, TWABKeyHidePickerButton,
              TWABKeyKeepDeletedMessages,
              TWABKeyHideRecapsBar, TWABKeyHideCreateTab,
              TWABKeyHideLeaderboard, TWABKeyHideSubscribe, TWABKeyHideBits,
              TWABKeyHideChannelBar, TWABKeyHideExtensions,
              TWABKeyHideCommunityHighlights,
              TWABKeyHidePinnedMessages, TWABKeyHideHypeTrains,
              TWABKeyHidePredictions, TWABKeyHidePolls,
              TWABKeyHideSubGoal, TWABKeyHideDrops,
              TWABKeyHideClipButton, TWABKeyAutoClaimPoints,
              TWABKeyProxyWhitelist,
              TWABKeyChatEmoteScale,
              TWABKeyChatTextScale,
              TWABKeyPreferredProxy,
              TWABKeyBlockTracking,
              TWABKeyStreamRewind ];
}

- (void)openKofi {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://ko-fi.com/gunnerkidgt"]
                                       options:@{} completionHandler:nil];
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
    // Clear all known keys first so stale values from a prior install don't
    // persist and conflict with the imported state (matches a fresh install).
    NSArray *allKeys = twab_exportKeys();
    for (NSString *key in allKeys)
        [tweakDefaults removeObjectForKey:key];
    // Only apply keys we recognise — ignore anything else in the blob.
    NSSet *allowed = [NSSet setWithArray:allKeys];
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
    // Check every configured proxy (a real request to Twitch through each).
    // The result also feeds the pool that picks which proxy streams use.
    NSArray<NSString *> *addrs = twab_effectiveProxyAddresses();
    if (!addrs.count) {
        self.proxyStatus = TWABProxyStatusOffline;
        [self reloadStatusRow];
        return;
    }
    self.proxyStatus = TWABProxyStatusChecking;
    [self reloadStatusRow];
    __weak typeof(self) weakSelf = self;
    twab_proxyPoolCheckNow(addrs, ^(NSUInteger online, NSUInteger total) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.proxyOnlineCount = online;
        strongSelf.proxyTotalCount = total;
        strongSelf.proxyStatus = online ? TWABProxyStatusOnline : TWABProxyStatusOffline;
        [strongSelf reloadStatusRow];
    });
}

- (void)reloadStatusRow {
    if (!self.adblockEnabled || !self.proxyEnabled) return;
    NSIndexPath *path = [NSIndexPath indexPathForRow:[self statusRowIndex] inSection:1];
    UITableViewCell *visible = [self.tableView cellForRowAtIndexPath:path];
    if (!self.customProxyEnabled && [visible.reuseIdentifier isEqualToString:@"DefaultProxyMenuCell"]) {
        twab_inPlaceProxyCell = visible;
        [self proxyStatusCell];
        twab_inPlaceProxyCell = nil;
        return;
    }
    if (self.customProxyEnabled) {
        for (NSIndexPath *ip in self.tableView.indexPathsForVisibleRows) {
            if (ip.section != 1) continue;
            NSInteger idx = [self proxyIndexForRow:ip.row];
            UITableViewCell *c = [self.tableView cellForRowAtIndexPath:ip];
            if (idx >= 0 && [c.reuseIdentifier isEqualToString:@"ProxyMenuRowCell"])
                [self proxyMenuRowCellForIndex:idx inPlace:c];
        }
    }
    [self.tableView reloadRowsAtIndexPaths:@[path]
                          withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

// Turns whatever was typed ("@Name, twitch.tv/other  third") into clean,
// lower-case channel names, each once.
static NSArray<NSString *> *twab_cleanChannelList(NSString *raw) {
    NSMutableCharacterSet *seps = [NSMutableCharacterSet characterSetWithCharactersInString:@",;"];
    [seps formUnionWithCharacterSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableOrderedSet<NSString *> *out = [NSMutableOrderedSet orderedSet];
    for (NSString *part in [raw ?: @"" componentsSeparatedByCharactersInSet:seps]) {
        NSString *name = part.lowercaseString;
        NSRange tv = [name rangeOfString:@"twitch.tv/"];
        if (tv.location != NSNotFound) name = [name substringFromIndex:NSMaxRange(tv)];
        name = [[name componentsSeparatedByString:@"/"] firstObject] ?: @"";
        name = [[name componentsSeparatedByString:@"?"] firstObject] ?: @"";
        while ([name hasPrefix:@"@"]) name = [name substringFromIndex:1];
        if (name.length) [out addObject:name];
    }
    return out.array;
}

- (void)presentWhitelistEditor {
    NSArray *current = twab_cleanChannelList([tweakDefaults stringForKey:TWABKeyProxyWhitelist]);
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:LOC(@"settings.whitelist.title", @"Skip Proxy for Channels")
                         message:LOC(@"settings.whitelist.editor.desc",
                                     @"Channels that always play without the proxy, separated by commas. "
                                     @"Channels you're subscribed to already skip it.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [current componentsJoinedByString:@", "];
        tf.placeholder = @"channel1, channel2";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.spellCheckingType = UITextSpellCheckingTypeNo;
        tf.keyboardType = UIKeyboardTypeASCIICapable;
        tf.returnKeyType = UIReturnKeyDone;
    }];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"settings.launch.cancel", @"Cancel")
                                              style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:LOC(@"settings.proxy.save", @"Save")
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
        NSArray *names = twab_cleanChannelList(weakAlert.textFields.firstObject.text);
        if (names.count)
            [tweakDefaults setObject:[names componentsJoinedByString:@", "] forKey:TWABKeyProxyWhitelist];
        else
            [tweakDefaults removeObjectForKey:TWABKeyProxyWhitelist];
        [weakSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                          withRowAnimation:UITableViewRowAnimationNone];
    }]];
    alert.preferredAction = alert.actions.lastObject;
    [self presentViewController:alert animated:YES completion:nil];
}

@end
