#import "TWABProxyPool.h"
#import "TWABProxyAuthDelegate.h"
#import "NSURLSession+TwitchAdBlock.h"
#import "SettingsKeys.h"
#import <os/log.h>
#import <float.h>

extern NSUserDefaults *tweakDefaults;

static NSString *const kTWABProxySeedKey = @"TWProxySeed";

static const NSTimeInterval kCheckInterval = 180;   // background re-check
static const NSTimeInterval kCheckTimeout  = 8;
static const double kUnknownLatency        = 0.4;   // before the first check

@interface TWABProxyState : NSObject
@property (nonatomic, strong) NSNumber *up;          // nil = not checked yet
@property (nonatomic, assign) double latency;        // seconds, last good check
@property (nonatomic, assign) NSUInteger failures;   // consecutive request failures
@property (nonatomic, strong) NSDate *benchedUntil;
@end
@implementation TWABProxyState
@end

static dispatch_queue_t twab_poolQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("twab.proxypool", DISPATCH_QUEUE_SERIAL); });
    return q;
}

// Only touched on twab_poolQueue.
static NSMutableDictionary<NSString *, TWABProxyState *> *twab_states;
static NSString *twab_current;

static TWABProxyState *twab_stateFor(NSString *address) {
    if (!twab_states) twab_states = [NSMutableDictionary dictionary];
    TWABProxyState *s = twab_states[address];
    if (!s) twab_states[address] = s = [TWABProxyState new];
    return s;
}

static BOOL twab_isBenched(TWABProxyState *s) {
    return s.benchedUntil && s.benchedUntil.timeIntervalSinceNow > 0;
}

// This install's fixed spot in [0, 1), so users are spread over the proxies.
static double twab_seed(void) {
    static double seed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seed = [tweakDefaults doubleForKey:kTWABProxySeedKey];
        if (seed <= 0 || seed >= 1) {
            seed = (arc4random_uniform(UINT32_MAX - 1) + 1) / (double)UINT32_MAX;
            [tweakDefaults setDouble:seed forKey:kTWABProxySeedKey];
        }
    });
    return seed;
}

static NSUInteger twab_indexOf(NSArray<NSString *> *addresses, NSString *address) {
    NSUInteger i = [addresses indexOfObject:address];
    return i == NSNotFound ? 0 : i + 1;
}

NSString *twab_proxyPoolPick(NSArray<NSString *> *addresses) {
    if (!addresses.count) return nil;
    if (addresses.count == 1) {
        // Nothing to choose between. Still report a dead proxy as nil so the
        // caller can go direct rather than fail.
        __block BOOL down = NO;
        dispatch_sync(twab_poolQueue(), ^{
            TWABProxyState *s = twab_stateFor(addresses[0]);
            down = s.up && !s.up.boolValue;
        });
        return down ? nil : addresses[0];
    }
    double seed = twab_seed();
    NSString *preferred = twab_preferredProxyAddress();
    if (preferred && ![addresses containsObject:preferred]) preferred = nil;
    __block NSString *pick = nil;
    dispatch_sync(twab_poolQueue(), ^{
        // The user's chosen country while it works; otherwise fall through to
        // the automatic pick (and come back once it recovers).
        if (preferred) {
            TWABProxyState *s = twab_stateFor(preferred);
            if (!twab_isBenched(s) && (!s.up || s.up.boolValue)) {
                if (![twab_current isEqualToString:preferred])
                    os_log(OS_LOG_DEFAULT, "[TWAB-Pool] using chosen proxy #%lu",
                           (unsigned long)twab_indexOf(addresses, preferred));
                twab_current = preferred;
                pick = preferred;
                return;
            }
        }
        // Stay on the current proxy while it works.
        if (twab_current && [addresses containsObject:twab_current]) {
            TWABProxyState *s = twab_stateFor(twab_current);
            if (!twab_isBenched(s) && (!s.up || s.up.boolValue)) { pick = twab_current; return; }
        }

        NSMutableArray<NSString *> *candidates = [NSMutableArray array];
        for (NSString *a in addresses) {
            TWABProxyState *s = twab_stateFor(a);
            if (!twab_isBenched(s) && (!s.up || s.up.boolValue)) [candidates addObject:a];
        }
        if (!candidates.count) {
            // All benched: use the one whose bench ends first, as long as its
            // last check passed. If every check failed, go direct.
            NSString *soonest = nil;
            NSDate *soonestDate = nil;
            for (NSString *a in addresses) {
                TWABProxyState *s = twab_stateFor(a);
                if (s.up && !s.up.boolValue) continue;
                if (!soonestDate || [s.benchedUntil compare:soonestDate] == NSOrderedAscending) {
                    soonest = a;
                    soonestDate = s.benchedUntil;
                }
            }
            pick = soonest;
            os_log(OS_LOG_DEFAULT, "[TWAB-Pool] no healthy proxy, using #%lu",
                   (unsigned long)twab_indexOf(addresses, pick));
            return;
        }

        // Proxies of similar speed share users evenly; clearly slower ones
        // (beyond 1.5x the fastest and 100 ms more) only get used when the
        // faster ones are down. The install's seed picks within the group.
        double fastest = DBL_MAX;
        for (NSString *a in candidates) {
            TWABProxyState *s = twab_stateFor(a);
            double lat = (s.up && s.latency > 0) ? s.latency : kUnknownLatency;
            fastest = MIN(fastest, lat);
        }
        double cutoff = MAX(fastest * 1.5, fastest + 0.1);
        NSMutableArray<NSString *> *group = [NSMutableArray array];
        for (NSString *a in candidates) {
            TWABProxyState *s = twab_stateFor(a);
            double lat = (s.up && s.latency > 0) ? s.latency : kUnknownLatency;
            if (lat <= cutoff) [group addObject:a];
        }
        NSUInteger idx = MIN((NSUInteger)(seed * group.count), group.count - 1);
        pick = group[idx];
        twab_current = pick;
        os_log(OS_LOG_DEFAULT, "[TWAB-Pool] using proxy #%lu (%lu similar, %lu healthy of %lu)",
               (unsigned long)twab_indexOf(addresses, pick), (unsigned long)group.count,
               (unsigned long)candidates.count, (unsigned long)addresses.count);
    });
    return pick;
}

// Errors that mean the proxy itself is the problem, not the user's network
// or a cancelled request.
static BOOL twab_isProxyFailure(NSError *error) {
    if (!error) return NO;
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        switch (error.code) {
            case NSURLErrorTimedOut:
            case NSURLErrorCannotFindHost:
            case NSURLErrorCannotConnectToHost:
            case NSURLErrorNetworkConnectionLost:
            case NSURLErrorSecureConnectionFailed:
            case NSURLErrorBadServerResponse:
            case NSURLErrorUserAuthenticationRequired:
                return YES;
            case 310: case 311: case 312:   // CFNetwork proxy connect/auth failures
                return YES;
            default:
                return NO;
        }
    }
    if ([error.domain isEqualToString:@"kCFErrorDomainCFNetwork"]) {
        return error.code == 310 || error.code == 311 || error.code == 312;
    }
    return NO;
}

void twab_proxyPoolReportResult(NSString *address, NSError *error) {
    if (!address.length) return;
    if (error && !twab_isProxyFailure(error)) return;
    dispatch_async(twab_poolQueue(), ^{
        TWABProxyState *s = twab_stateFor(address);
        if (!error) {
            s.failures = 0;
            s.benchedUntil = nil;
            return;
        }
        s.failures++;
        // 30s, 60s, 120s ... up to 10 minutes while it keeps failing.
        NSTimeInterval bench = MIN(600.0, 30.0 * pow(2.0, (double)MIN(s.failures - 1, 5UL)));
        s.benchedUntil = [NSDate dateWithTimeIntervalSinceNow:bench];
        if ([twab_current isEqualToString:address]) twab_current = nil;
        os_log(OS_LOG_DEFAULT, "[TWAB-Pool] proxy failed (%{public}@ %ld), benched %.0fs",
               error.domain, (long)error.code, bench);
    });
}

typedef NS_ENUM(NSInteger, TWABCheckResult) { TWABCheckUp, TWABCheckDown, TWABCheckUnknown };

// One check: a real request to Twitch through the proxy, so a proxy that is
// up but refuses us (bad password, blocked) counts as down. No internet on
// the phone gives "unknown", so it doesn't mark proxies as dead.
static void twab_checkOne(NSString *address, void (^done)(TWABCheckResult result, double latency)) {
    NSDictionary *info = TWABParseProxyAddress(address);
    if (!info) { done(TWABCheckDown, 0); return; }

    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.connectionProxyDictionary = @{
        @"HTTPEnable"  : @YES, @"HTTPProxy"  : info[@"host"], @"HTTPPort"  : info[@"port"],
        @"HTTPSEnable" : @YES, @"HTTPSProxy" : info[@"host"], @"HTTPSPort" : info[@"port"],
    };
    cfg.timeoutIntervalForRequest = kCheckTimeout;
    cfg.timeoutIntervalForResource = kCheckTimeout;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    TWABProxyAuthDelegate *auth = [TWABProxyAuthDelegate new];
    auth.proxyUser = info[@"user"];
    auth.proxyPass = info[@"pass"];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:auth delegateQueue:nil];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gql.twitch.tv/"]];
    req.HTTPMethod = @"HEAD";
    NSDate *start = [NSDate date];
    [[session dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *resp, NSError *err) {
        double latency = -start.timeIntervalSinceNow;
        if (!err && [resp isKindOfClass:NSHTTPURLResponse.class]) done(TWABCheckUp, latency);
        else if (twab_isProxyFailure(err) || !err) done(TWABCheckDown, latency);
        else done(TWABCheckUnknown, latency);
    }] resume];
    [session finishTasksAndInvalidate];
}

void twab_proxyPoolCheckNow(NSArray<NSString *> *addresses,
                            void (^completion)(NSUInteger online, NSUInteger total)) {
    NSUInteger total = addresses.count;
    if (!total) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(0, 0); });
        return;
    }
    dispatch_group_t group = dispatch_group_create();
    __block NSUInteger online = 0;
    for (NSString *address in addresses) {
        dispatch_group_enter(group);
        twab_checkOne(address, ^(TWABCheckResult result, double latency) {
            dispatch_async(twab_poolQueue(), ^{
                TWABProxyState *s = twab_stateFor(address);
                if (result == TWABCheckUp) {
                    // Averaged over checks so one slow check doesn't move users.
                    s.latency = (s.up.boolValue && s.latency > 0) ? s.latency * 0.7 + latency * 0.3
                                                                   : latency;
                    s.up = @YES;
                    online++;
                    // A passing check ends a bench early.
                    s.benchedUntil = nil;
                    s.failures = 0;
                } else if (result == TWABCheckDown) {
                    s.up = @NO;
                    if ([twab_current isEqualToString:address]) twab_current = nil;
                    // Look again soon rather than waiting for the next round.
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        twab_proxyPoolCheckNow(@[ address ], nil);
                    });
                }
                os_log(OS_LOG_DEFAULT, "[TWAB-Pool] check #%lu result=%ld %.0fms",
                       (unsigned long)twab_indexOf(addresses, address), (long)result, latency * 1000);
                dispatch_group_leave(group);
            });
        });
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (completion) completion(online, total);
    });
}

void twab_proxyPoolResetPick(void) {
    dispatch_async(twab_poolQueue(), ^{ twab_current = nil; });
}

NSDictionary *twab_proxyPoolInfo(NSString *address) {
    if (!address.length) return @{};
    __block NSDictionary *info;
    dispatch_sync(twab_poolQueue(), ^{
        TWABProxyState *s = twab_stateFor(address);
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        if (s.up) d[@"up"] = s.up;
        if (s.up.boolValue && s.latency > 0) d[@"latencyMs"] = @(s.latency * 1000);
        d[@"benched"] = @(twab_isBenched(s));
        d[@"current"] = @([twab_current isEqualToString:address]);
        info = d;
    });
    return info;
}

static BOOL twab_poolWanted(void) {
    return [tweakDefaults boolForKey:TWABKeyAdBlockEnabled] &&
           [tweakDefaults boolForKey:TWABKeyAdBlockProxyEnabled];
}

void twab_proxyPoolStart(void) {
    static dispatch_source_t timer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW,
                                  (uint64_t)(kCheckInterval * NSEC_PER_SEC),
                                  (uint64_t)(10 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            if (!twab_poolWanted()) return;
            NSArray<NSString *> *addresses = twab_effectiveProxyAddresses();
            if (addresses.count) twab_proxyPoolCheckNow(addresses, nil);
        });
        dispatch_resume(timer);
    });
}
