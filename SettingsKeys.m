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

NSString *twab_effectiveProxyAddress(void) {
    return [tweakDefaults boolForKey:TWABKeyAdBlockCustomProxyEnabled]
        ? [tweakDefaults stringForKey:TWABKeyAdBlockProxy]
        : PROXY_ADDR;
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
