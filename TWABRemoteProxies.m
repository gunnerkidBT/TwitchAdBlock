#import "TWABRemoteProxies.h"
#import "TWABProxyPool.h"
#import "SettingsKeys.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCrypto.h>
#import <os/log.h>
#if __has_include("Secrets.h")
#import "Secrets.h"   // key pieces + built-in list; generated, never committed
#define TWAB_HAVE_SECRETS 1
#endif

extern NSUserDefaults *tweakDefaults;

// proxies.json format (written by make_proxies.py):
//   { "v": 2, "proxies": [ { "name": "Portugal", "backup": false, "addr": "<encrypted>" } ] }
// "addr" is user:pass@host:port encrypted with AES-256-CBC, followed by an
// HMAC-SHA256 tag over IV + ciphertext, base64-encoded. The keys are rebuilt
// at runtime from pieces in Secrets.h, which is generated locally and kept
// out of the public repo. { "v": 2, "useBuiltin": true } drops the saved
// list and goes back to the one built into the app.
static NSString *const kListURL =
    @"https://raw.githubusercontent.com/gunnerkidBT/TwitchAdBlock/master/proxies.json";
static NSString *const kCacheKey   = @"TWRemoteProxies";
static NSString *const kUpdatedKey = @"TWRemoteProxiesUpdated";
static const NSTimeInterval kRefreshAfter = 6 * 3600;

static NSArray<NSDictionary *> *twab_entries;  // guarded by @synchronized(kCacheKey)

#ifdef TWAB_HAVE_SECRETS
// Must match keys() in make_proxies.py.
static void twab_deriveKeys(uint8_t enc[CC_SHA256_DIGEST_LENGTH], uint8_t mac[CC_SHA256_DIGEST_LENGTH]) {
    CC_SHA256_CTX c;
    CC_SHA256_Init(&c);
    CC_SHA256_Update(&c, "twab-enc", 8);
    CC_SHA256_Update(&c, twab_kp_a, sizeof(twab_kp_a));
    CC_SHA256_Update(&c, twab_kp_b, sizeof(twab_kp_b));
    CC_SHA256_Final(enc, &c);
    CC_SHA256_Init(&c);
    CC_SHA256_Update(&c, "twab-mac", 8);
    CC_SHA256_Update(&c, twab_kp_b, sizeof(twab_kp_b));
    CC_SHA256_Update(&c, twab_kp_c, sizeof(twab_kp_c));
    CC_SHA256_Final(mac, &c);
}
#endif

// Decrypts one address. The tag is checked (in constant time) before any
// decryption, so a tampered or foreign file is rejected.
static NSString *twab_decryptAddr(NSString *b64) {
#ifdef TWAB_HAVE_SECRETS
    NSData *raw = [[NSData alloc] initWithBase64EncodedString:b64 ?: @"" options:0];
    if (raw.length < 16 + kCCBlockSizeAES128 + CC_SHA256_DIGEST_LENGTH) return nil;
    const uint8_t *p = raw.bytes;
    size_t ctLen = raw.length - 16 - CC_SHA256_DIGEST_LENGTH;
    if (ctLen % kCCBlockSizeAES128) return nil;
    uint8_t enc[CC_SHA256_DIGEST_LENGTH], mac[CC_SHA256_DIGEST_LENGTH], tag[CC_SHA256_DIGEST_LENGTH];
    twab_deriveKeys(enc, mac);
    CCHmac(kCCHmacAlgSHA256, mac, sizeof(mac), p, 16 + ctLen, tag);
    uint8_t diff = 0;
    for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) diff |= tag[i] ^ p[16 + ctLen + i];
    NSString *out = nil;
    if (!diff) {
        NSMutableData *plain = [NSMutableData dataWithLength:ctLen];
        size_t moved = 0;
        if (CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, enc, kCCKeySizeAES256,
                    p, p + 16, ctLen, plain.mutableBytes, plain.length, &moved) == kCCSuccess) {
            plain.length = moved;
            out = [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding];
        }
    }
    memset(enc, 0, sizeof(enc));
    memset(mac, 0, sizeof(mac));
    return out;
#else
    return nil;  // built without Secrets.h: no default servers
#endif
}

typedef NS_ENUM(NSInteger, TWABListResult) { TWABListInvalid, TWABListValid, TWABListUseBuiltin };

// Checks a downloaded/saved list. Every entry must decode to a usable proxy
// address, or the whole list is rejected.
static TWABListResult twab_parseList(NSData *json, NSArray<NSDictionary *> **outEntries) {
    if (!json.length) return TWABListInvalid;
    id obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![obj isKindOfClass:NSDictionary.class] || ![obj[@"v"] isEqual:@2]) return TWABListInvalid;
    if ([obj[@"useBuiltin"] boolValue]) return TWABListUseBuiltin;
    NSArray *list = obj[@"proxies"];
    if (![list isKindOfClass:NSArray.class] || !list.count) return TWABListInvalid;
    NSMutableArray *entries = [NSMutableArray array];
    for (NSDictionary *p in list) {
        if (![p isKindOfClass:NSDictionary.class]) return TWABListInvalid;
        NSString *name = p[@"name"];
        NSString *addr = twab_decryptAddr(p[@"addr"]);
        if (![name isKindOfClass:NSString.class] || !name.length || [addr containsString:@","] ||
            !twab_normalizedProxyURL(addr))
            return TWABListInvalid;
        [entries addObject:@{ @"name" : name, @"addr" : addr, @"backup" : @([p[@"backup"] boolValue]) }];
    }
    if (outEntries) *outEntries = entries;
    return TWABListValid;
}

NSArray<NSDictionary *> *twab_builtinProxyEntries(void) {
    static NSArray *builtin;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
#ifdef TWAB_HAVE_SECRETS
        NSArray *entries = nil;
        NSData *json = [@TWAB_BUILTIN_LIST dataUsingEncoding:NSUTF8StringEncoding];
        if (twab_parseList(json, &entries) == TWABListValid) builtin = entries;
        else os_log_error(OS_LOG_DEFAULT, "[TWAB-Remote] built-in server list didn't decode");
#endif
        if (!builtin) builtin = @[];
    });
    return builtin;
}

NSArray<NSDictionary *> *twab_remoteProxyEntries(void) {
    @synchronized (kCacheKey) { return twab_entries; }
}

NSDate *twab_remoteProxiesUpdated(void) {
    id d = [tweakDefaults objectForKey:kUpdatedKey];
    return [d isKindOfClass:NSDate.class] ? d : nil;
}

static void twab_fetchList(void) {
    if (![tweakDefaults boolForKey:TWABKeyAdBlockEnabled] ||
        ![tweakDefaults boolForKey:TWABKeyAdBlockProxyEnabled]) return;
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.timeoutIntervalForRequest = 10;
    cfg.timeoutIntervalForResource = 20;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    [[session dataTaskWithURL:[NSURL URLWithString:kListURL]
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        if (err || status != 200) {
            os_log(OS_LOG_DEFAULT, "[TWAB-Remote] server list not fetched (status %ld, %{public}@)",
                   (long)status, err.localizedDescription ?: @"no error");
            return;
        }
        NSArray *entries = nil;
        TWABListResult result = twab_parseList(data, &entries);
        if (result == TWABListInvalid) {
            os_log(OS_LOG_DEFAULT, "[TWAB-Remote] server list invalid, keeping the current one");
            return;
        }
        BOOL changed = ![data isEqualToData:[tweakDefaults dataForKey:kCacheKey] ?: [NSData data]];
        [tweakDefaults setObject:[NSDate date] forKey:kUpdatedKey];
        if (result == TWABListUseBuiltin) {
            [tweakDefaults removeObjectForKey:kCacheKey];
            @synchronized (kCacheKey) { twab_entries = nil; }
        } else {
            [tweakDefaults setObject:data forKey:kCacheKey];
            @synchronized (kCacheKey) { twab_entries = entries; }
        }
        os_log(OS_LOG_DEFAULT, "[TWAB-Remote] server list %{public}@: %lu servers%{public}@",
               result == TWABListUseBuiltin ? @"says use built-in" : @"updated",
               (unsigned long)entries.count, changed ? @" (changed)" : @"");
        if (changed) {
            // New servers: choose again and check them now.
            twab_proxyPoolResetPick();
            twab_proxyPoolCheckNow(twab_effectiveProxyAddresses(), nil);
        }
    }] resume];
    [session finishTasksAndInvalidate];
}

void twab_remoteProxiesStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *entries = nil;
        if (twab_parseList([tweakDefaults dataForKey:kCacheKey], &entries) == TWABListValid) {
            @synchronized (kCacheKey) { twab_entries = entries; }
            os_log(OS_LOG_DEFAULT, "[TWAB-Remote] using saved server list (%lu servers)",
                   (unsigned long)entries.count);
        }
        twab_fetchList();
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillEnterForegroundNotification object:nil
                         queue:nil usingBlock:^(NSNotification *note) {
            NSDate *updated = twab_remoteProxiesUpdated();
            if (!updated || -updated.timeIntervalSinceNow > kRefreshAfter) twab_fetchList();
        }];
    });
}
