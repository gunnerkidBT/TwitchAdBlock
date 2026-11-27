#import "SettingsKeys.h"
#import "Config.h"
#import "TWABRemoteProxies.h"

extern NSUserDefaults *tweakDefaults;

NSString *const TWABKeyAdBlockEnabled            = @"TWAdBlockEnabled";
NSString *const TWABKeyAdBlockProxyEnabled       = @"TWAdBlockProxyEnabled";
NSString *const TWABKeyAdBlockCustomProxyEnabled = @"TWAdBlockCustomProxyEnabled";
NSString *const TWABKeyAdBlockProxy              = @"TWAdBlockProxy";
NSString *const TWABKeyEmotesEnabled             = @"TWEmotesEnabled";
NSString *const TWABKeyLaunchTab                 = @"TWLaunchTab";
NSString *const TWABKeyLaunchSubTab              = @"TWLaunchSubTab";
NSString *const TWABKeyHideStories               = @"TWHideStories";
NSString *const TWABKeyHideAdFreeButton          = @"TWHideAdFreeButton";
NSString *const TWABKeyDisableWatchLimit         = @"TWDisableWatchLimit";
NSString *const TWABKeyRecentEmotes              = @"TWRecentEmotes";
NSString *const TWABKeyHidePickerButton          = @"TWHidePickerButton";
NSString *const TWABKeyKeepDeletedMessages       = @"TWKeepDeletedMessages";
NSString *const TWABKeyHighlightDeletedNotes     = @"TWHighlightDeletedNotes";
NSString *const TWABKeyHideRecapsBar             = @"TWHideRecapsBar";
NSString *const TWABKeyFitWideEmotes             = @"TWFitWideEmotes";
NSString *const TWABKeyHideCreateTab             = @"TWHideCreateTab";
NSString *const TWABKeyHideLeaderboard           = @"TWHideLeaderboard";
NSString *const TWABKeyHideSubscribe             = @"TWHideSubscribe";
NSString *const TWABKeyHideBits                  = @"TWHideBits";
NSString *const TWABKeyHideChannelBar            = @"TWHideChannelBar";
NSString *const TWABKeyHideExtensions            = @"TWHideExtensions";
NSString *const TWABKeyHideSubGoal               = @"TWHideSubGoal";
NSString *const TWABKeyHideCommunityHighlights   = @"TWHideCommunityHighlights";
NSString *const TWABKeyHidePinnedMessages        = @"TWHidePinnedMessages";
NSString *const TWABKeyHideHypeTrains            = @"TWHideHypeTrains";
NSString *const TWABKeyHidePredictions           = @"TWHidePredictions";
NSString *const TWABKeyHidePolls                 = @"TWHidePolls";
NSString *const TWABKeyHideDrops                 = @"TWHideDrops";
NSString *const TWABKeyDismissPinnedSeconds      = @"TWDismissPinnedSeconds";
NSString *const TWABKeyHideClipButton            = @"TWHideClipButton";
NSString *const TWABKeyProxyWhitelist            = @"TWProxyWhitelist";
NSString *const TWABKeyChatEmoteScale            = @"TWChatEmoteScale";
NSString *const TWABKeyChatTextScale             = @"TWChatTextScale";
NSString *const TWABKeyPreferredProxy            = @"TWPreferredProxy";
NSString *const TWABKeyBlockTracking             = @"TWBlockTracking";

// The default servers: the list from the repo when there is a valid one,
// otherwise the one built into the app (Secrets.h). Each @{ name, addr, backup }.
static NSArray<NSDictionary *> *twab_defaultProxyEntries(void) {
    NSArray<NSDictionary *> *remote = twab_remoteProxyEntries();
    return remote.count ? remote : twab_builtinProxyEntries();
}

NSString *twab_defaultProxyAddress(void) {
    NSMutableArray *addrs = [NSMutableArray array];
    for (NSDictionary *e in twab_defaultProxyEntries()) [addrs addObject:e[@"addr"]];
    return [addrs componentsJoinedByString:@","];
}

// Same order as the addresses in twab_defaultProxyAddress().
NSArray<NSString *> *twab_defaultProxyNames(void) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSDictionary *e in twab_defaultProxyEntries()) [names addObject:e[@"name"]];
    return names;
}

NSSet<NSString *> *twab_backupOnlyProxyAddresses(void) {
    if ([tweakDefaults boolForKey:TWABKeyAdBlockCustomProxyEnabled]) return [NSSet set];
    NSMutableSet *set = [NSMutableSet set];
    for (NSDictionary *e in twab_defaultProxyEntries())
        if ([e[@"backup"] boolValue]) [set addObject:e[@"addr"]];
    return set;
}

NSString *twab_preferredProxyAddress(void) {
    if ([tweakDefaults boolForKey:TWABKeyAdBlockCustomProxyEnabled]) return nil;
    NSString *name = [tweakDefaults stringForKey:TWABKeyPreferredProxy];
    if (!name.length) return nil;
    NSUInteger idx = [twab_defaultProxyNames() indexOfObject:name];
    NSArray<NSString *> *addresses = twab_effectiveProxyAddresses();
    return idx < addresses.count ? addresses[idx] : nil;
}

NSString *twab_effectiveProxyAddress(void) {
    return [tweakDefaults boolForKey:TWABKeyAdBlockCustomProxyEnabled]
        ? [tweakDefaults stringForKey:TWABKeyAdBlockProxy]
        : PROXY_ADDR;
}

NSURL *twab_normalizedProxyURL(NSString *address) {
    if (!address.length) return nil;
    NSString *normalized = address;
    if (![normalized hasPrefix:@"http://"] && ![normalized hasPrefix:@"https://"]) {
        normalized = [@"http://" stringByAppendingString:normalized];
    }
    NSURL *url = [NSURL URLWithString:normalized];
    return (url.host.length && [url.scheme hasPrefix:@"http"]) ? url : nil;
}

NSArray<NSString *> *twab_effectiveProxyAddresses(void) {
    NSString *raw = twab_effectiveProxyAddress();
    if (!raw.length) return @[];
    NSMutableCharacterSet *seps = [NSMutableCharacterSet characterSetWithCharactersInString:@","];
    [seps formUnionWithCharacterSet:[NSCharacterSet newlineCharacterSet]];
    NSArray *parts = [raw componentsSeparatedByCharactersInSet:seps];
    NSMutableArray *cleaned = [NSMutableArray array];
    for (NSString *p in parts) {
        NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [cleaned addObject:t];
    }
    return cleaned;
}

BOOL twab_userIsAdExempt(NSString *queryString) {
    if (!queryString.length) return NO;
    NSURLComponents *comps = [NSURLComponents new];
    comps.percentEncodedQuery = queryString;
    NSString *tokenStr = nil;
    for (NSURLQueryItem *item in comps.queryItems) {
        if ([item.name isEqualToString:@"token"]) { tokenStr = item.value; break; }
    }
    if (!tokenStr.length) return NO;
    NSData *data = [tokenStr dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return NO;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *dict = obj;
    BOOL subscriber = [dict[@"subscriber"] respondsToSelector:@selector(boolValue)] &&
                      [dict[@"subscriber"] boolValue];
    BOOL turbo      = [dict[@"turbo"] respondsToSelector:@selector(boolValue)] &&
                      [dict[@"turbo"] boolValue];
    return subscriber || turbo;
}

BOOL twab_channelIsWhitelisted(NSURL *usherURL) {
    NSString *raw = [tweakDefaults stringForKey:TWABKeyProxyWhitelist];
    if (!raw.length) return NO;
    NSArray *comps = usherURL.pathComponents;
    // /api/channel/hls/<name>.m3u8 → pathComponents: ["/","api","channel","hls","<name>.m3u8"]
    if (comps.count < 5) return NO;
    NSString *channel = [comps[4] stringByDeletingPathExtension].lowercaseString;
    if (!channel.length) return NO;
    for (NSString *entry in [raw componentsSeparatedByString:@","]) {
        NSString *trimmed = [entry stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
        if (trimmed.length && [trimmed isEqualToString:channel]) return YES;
    }
    return NO;
}
