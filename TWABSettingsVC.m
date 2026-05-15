#import "TWABSettingsVC.h"
#import "Config.h"

extern NSBundle *tweakBundle;
extern NSUserDefaults *tweakDefaults;

#define LOC(x, d) (tweakBundle ? [tweakBundle localizedStringForKey:x value:d table:nil] : (d))

@interface TWABSettingsVC ()
@property (nonatomic, assign) BOOL adblockEnabled;
@property (nonatomic, assign) BOOL proxyEnabled;
@property (nonatomic, assign) BOOL customProxyEnabled;
@property (nonatomic, assign) BOOL emotesEnabled;
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
        _adblockEnabled     = [tweakDefaults boolForKey:@"TWAdBlockEnabled"];
        _proxyEnabled       = [tweakDefaults boolForKey:@"TWAdBlockProxyEnabled"];
        _customProxyEnabled = [tweakDefaults boolForKey:@"TWAdBlockCustomProxyEnabled"];
        _emotesEnabled      = [tweakDefaults boolForKey:@"TWEmotesEnabled"];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"TwitchAdBlock";
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
}

#pragma mark - UITableViewDataSource

// Section layout:
//   0: Ad Block toggle           (always shown)
//   1: Proxy + custom proxy      (only when ad block is on)
//   2: Emotes toggle             (always shown)
//   3: empty / version footer    (always shown — last section)
// When ad block is OFF, section 1 collapses to 0 rows so the visual flow is
// AdBlock → Emotes → version. With ad block ON the user sees the full set.
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;
        case 1:
            if (!self.adblockEnabled) return 0;
            return self.proxyEnabled ? (self.customProxyEnabled ? 3 : 2) : 1;
        case 2: return 1;
        case 3: return 0;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case 0:
            return [self switchCellWithTitle:LOC(@"settings.adblock.title", @"Ad Block")
                                         on:_adblockEnabled
                                     action:@selector(adblockSwitchChanged:)
                                 identifier:@"AdBlockSwitch"];
        case 1:
            switch (indexPath.row) {
                case 0:
                    return [self switchCellWithTitle:LOC(@"settings.proxy.title", @"Ad Block Proxy")
                                                 on:_proxyEnabled
                                             action:@selector(proxySwitchChanged:)
                                         identifier:@"ProxySwitch"];
                case 1:
                    return [self switchCellWithTitle:LOC(@"settings.custom_proxy.title", @"Custom Proxy")
                                                 on:_customProxyEnabled
                                             action:@selector(customProxySwitchChanged:)
                                         identifier:@"CustomProxySwitch"];
                case 2:
                    return [self proxyAddressCell];
                default: break;
            }
            break;
        case 2:
            return [self switchCellWithTitle:LOC(@"settings.emotes.title", @"3rd-Party Emotes")
                                         on:_emotesEnabled
                                     action:@selector(emotesSwitchChanged:)
                                 identifier:@"EmotesSwitch"];
        default: break;
    }
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                 reuseIdentifier:@"empty"];
}

- (UITableViewCell *)switchCellWithTitle:(NSString *)title
                                      on:(BOOL)on
                                  action:(SEL)action
                              identifier:(NSString *)identifier {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:identifier];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
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
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = on;
    sw.accessibilityIdentifier = identifier;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (UITableViewCell *)proxyAddressCell {
    UITableViewCell *cell = [[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"ProxyAddressCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UITextField *tf = [[UITextField alloc] init];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    tf.placeholder = @"user:pass@host:port";
    tf.text = [tweakDefaults stringForKey:@"TWAdBlockProxy"];
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.keyboardType = UIKeyboardTypeURL;
    tf.returnKeyType = UIReturnKeyDone;
    tf.delegate = self;
    [cell.contentView addSubview:tf];
    [NSLayoutConstraint activateConstraints:@[
        [tf.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [tf.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [tf.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [tf.heightAnchor constraintEqualToConstant:44],
    ]];
    return cell;
}

#pragma mark - UITableViewDelegate (footers)

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    if (section == 3) {
        UILabel *ver = [[UILabel alloc] init];
        ver.text = @"TwitchAdBlock v" PACKAGE_VERSION;
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
        text = LOC(@"settings.proxy.footer",
                   @"Proxy specific requests through a proxy server based in an ad-free country");
    } else if (section == 2)
        text = LOC(@"settings.emotes.footer",
                   @"Render 7TV, BetterTTV, and FrankerFaceZ emotes inline in chat");
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
    [tweakDefaults setBool:sw.on forKey:@"TWAdBlockEnabled"];
    self.adblockEnabled = sw.on;
    // Section 1 holds the proxy rows — its visibility tracks the ad-block toggle.
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
                  withRowAnimation:UITableViewRowAnimationFade];
    [tweakDefaults synchronize];
}

- (void)emotesSwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:@"TWEmotesEnabled"];
    self.emotesEnabled = sw.on;
    [tweakDefaults synchronize];
}

- (void)proxySwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:@"TWAdBlockProxyEnabled"];
    self.proxyEnabled = sw.on;
    NSMutableArray *paths = [NSMutableArray arrayWithObject:
        [NSIndexPath indexPathForRow:1 inSection:1]];
    if (self.customProxyEnabled)
        [paths addObject:[NSIndexPath indexPathForRow:2 inSection:1]];
    if (sw.on)
        [self.tableView insertRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
    else
        [self.tableView deleteRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
    [tweakDefaults synchronize];
}

- (void)customProxySwitchChanged:(UISwitch *)sw {
    [tweakDefaults setBool:sw.on forKey:@"TWAdBlockCustomProxyEnabled"];
    self.customProxyEnabled = sw.on;
    NSArray *paths = @[[NSIndexPath indexPathForRow:2 inSection:1]];
    if (sw.on)
        [self.tableView insertRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
    else
        [self.tableView deleteRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationFade];
    [tweakDefaults synchronize];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    [tweakDefaults setValue:textField.text forKey:@"TWAdBlockProxy"];
    [tweakDefaults synchronize];
}

@end
