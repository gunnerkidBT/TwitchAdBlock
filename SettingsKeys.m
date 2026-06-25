#import "SettingsKeys.h"
#import "Config.h"

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

// XOR-obfuscated default proxy address. Plaintext is reconstructed once at
// first call. Keeps the host/credentials out of the source AND out of
// `strings` against the dylib.
NSString *twab_defaultProxyAddress(void) {
    static const uint8_t key = 0xA5;
    static const uint8_t bytes[] = {
        0xf2, 0xd1, 0xe8, 0xe1, 0xee, 0xc3, 0x9f, 0x90, 0xf4, 0x95,
        0xed, 0x93, 0xf3, 0xe5, 0x94, 0x93, 0x9d, 0x8b, 0x9c, 0x95,
        0x8b, 0x94, 0x9c, 0x93, 0x8b, 0x94, 0x90, 0x93, 0x9f, 0x9d,
        0x95, 0x95, 0x95,
    };
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        size_t n = sizeof(bytes);
        char buf[n + 1];
        for (size_t i = 0; i < n; i++) buf[i] = bytes[i] ^ key;
        buf[n] = '\0';
        cached = [NSString stringWithUTF8String:buf];
    });
    return cached;
}
