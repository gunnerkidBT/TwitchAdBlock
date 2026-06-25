#import "NSData+TwitchAdBlock.h"
#import "SettingsKeys.h"
#import <os/log.h>

extern NSUserDefaults *tweakDefaults;

// Known ad-related __typename values, split by how aggressively we can
// strip them. Two semantics:
//
//   arrayAdTypenames — safe to remove from array contexts only (matches
//     the original feedItems.edges filter behavior). Used for things like
//     FeedAd where the typename might also appear inside legitimate
//     objects as a typed metadata field that the renderer expects to
//     exist (e.g., a Stream or Clip with an ad-context field).
//
//   fieldAdTypenames — also safe to remove as dict fields (e.g., the
//     entire `data.offerPromotion` key gets dropped). Used for top-level
//     banner/prompt typenames that renderers handle gracefully when nil.
//     A field-strip subset is more aggressive — only add typenames here
//     that are CONFIRMED as standalone banners, not as nested metadata.
static NSSet *twab_arrayAdTypenames(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithObjects:
            @"FeedAd",                // Following-feed ad cards
            @"OfferPromotion",        // brand offers (McDonalds banner etc.)
            @"PromotionDisplay",      // wrapper around offer promotions
            @"BitsProductPromotion",  // "buy Bits" prompt
            @"HostReadAd",            // streamer-read sponsor ad node
            nil];
    });
    return s;
}

static NSSet *twab_fieldAdTypenames(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // FeedAd intentionally excluded — Live/Clips streams carry
        // FeedAd-typed metadata fields and removing them breaks rendering.
        s = [NSSet setWithObjects:
            @"OfferPromotion",
            @"PromotionDisplay",
            @"BitsProductPromotion",
            nil];
    });
    return s;
}

// Single-pass walk over a GraphQL response that BOTH (a) discovers new
// ad-surface typenames for diagnostics AND (b) strips known ad nodes.
// Replaces the prior two-pass implementation (twab_scanForAdTypenames +
// twab_stripAdNodes) which walked the same tree twice and allocated an
// intermediate `allValues` array per dict. Sets *dirty=YES if any node
// was removed so callers can skip a no-op re-serialize (Apollo cache
// normalization is sensitive to byte-level differences).
static void twab_logStrip(NSString *typename) {
    static int count = 0;
    if (count++ >= 50) return;  // cap so a busy response doesn't flood logs
    os_log(OS_LOG_DEFAULT, "[TWAB-Strip] removed typename=%{public}@", typename);
}

static void twab_logSuspect(NSString *typename, NSString *opName, BOOL filtered) {
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%@|%@", opName ?: @"?", typename];
    @synchronized (seen) {
        if ([seen containsObject:key]) return;
        [seen addObject:key];
    }
    os_log(OS_LOG_DEFAULT,
        "[TWAB-Ad] suspect typename=%{public}@ op=%{public}@ filtered=%d",
        typename, opName ?: @"?", filtered);
}

// Returns YES if the typename is a candidate for ad-surface diagnostic
// logging (contains Ad/Promot/Sponsor/Headliner substring).
static BOOL twab_isSuspectTypename(NSString *typename) {
    return [typename containsString:@"Ad"] ||
           [typename containsString:@"Promot"] ||
           [typename containsString:@"Sponsor"] ||
           [typename containsString:@"Headliner"] ||
           [typename containsString:@"Upsell"] ||
           [typename containsString:@"Recommendation"];
}

static void twab_processTree(id obj, NSSet *arraySet, NSSet *fieldSet,
                             NSString *opName, BOOL *dirty) {
    if ([obj isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *d = obj;
        // Log this dict's own typename if suspect (single pass — was a
        // separate scan walk previously).
        NSString *ownType = d[@"__typename"];
        if ([ownType isKindOfClass:NSString.class] && twab_isSuspectTypename(ownType)) {
            twab_logSuspect(ownType, opName, [arraySet containsObject:ownType]);
        }
        NSMutableArray *toRemove = nil;
        for (NSString *key in d) {
            id val = d[key];
            if ([val isKindOfClass:NSDictionary.class]) {
                NSString *t = ((NSDictionary *)val)[@"__typename"];
                if ([t isKindOfClass:NSString.class] && [fieldSet containsObject:t]) {
                    if (!toRemove) toRemove = [NSMutableArray array];
                    [toRemove addObject:key];
                    twab_logStrip(t);
                    continue;  // skip recursion into a doomed subtree
                }
            }
            twab_processTree(val, arraySet, fieldSet, opName, dirty);
        }
        if (toRemove.count > 0) {
            *dirty = YES;
            [d removeObjectsForKeys:toRemove];
        }
    } else if ([obj isKindOfClass:NSMutableArray.class]) {
        // For array elements we match two shapes:
        //   - direct ad: element's own __typename is in arraySet
        //   - edge-style ad: element has a `node` subfield whose
        //     __typename is in arraySet (matches the GraphQL
        //     Connection { edges { node } } pattern)
        NSMutableArray *a = obj;
        NSMutableIndexSet *toRemove = nil;
        for (NSUInteger i = 0; i < a.count; i++) {
            id val = a[i];
            BOOL matched = NO;
            if ([val isKindOfClass:NSDictionary.class]) {
                NSDictionary *dval = (NSDictionary *)val;
                NSString *t = dval[@"__typename"];
                if ([t isKindOfClass:NSString.class] && [arraySet containsObject:t]) {
                    twab_logStrip(t);
                    matched = YES;
                } else {
                    id node = dval[@"node"];
                    if ([node isKindOfClass:NSDictionary.class]) {
                        NSString *nt = ((NSDictionary *)node)[@"__typename"];
                        if ([nt isKindOfClass:NSString.class] && [arraySet containsObject:nt]) {
                            twab_logStrip(nt);
                            matched = YES;
                        }
                    }
                }
            }
            if (matched) {
                if (!toRemove) toRemove = [NSMutableIndexSet indexSet];
                [toRemove addIndex:i];
                continue;
            }
            twab_processTree(val, arraySet, fieldSet, opName, dirty);
        }
        if (toRemove) {
            *dirty = YES;
            [a removeObjectsAtIndexes:toRemove];
        }
    }
}

// The Evolve "Live" feed stops a preview after `watchBehavior.maxStreamWatchSeconds`
// and shows the EvolveFeedMaxWatchtimeOverlayView (the Watch/Follow blocking
// overlay). Rewriting that value to an effectively-infinite number means the
// countdown bar never depletes within a session, so playback continues. We set
// a large value rather than deleting the key so any `if let max = ...`
// breakpoint logic still gets a (huge) number instead of treating nil as a
// different default. INT_MAX seconds ≈ 68 years. Sets *dirty=YES on change.
static void twab_neutralizeWatchLimits(id obj, BOOL *dirty) {
    if ([obj isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *d = obj;
        for (NSString *key in [d allKeys]) {
            id val = d[key];
            if ([key isEqualToString:@"maxStreamWatchSeconds"] &&
                [val isKindOfClass:NSNumber.class]) {
                NSNumber *capped = @(2147483647);
                if (![val isEqual:capped]) {
                    d[key] = capped;
                    *dirty = YES;
                    os_log(OS_LOG_DEFAULT,
                        "[TWAB-Watch] neutralized maxStreamWatchSeconds (was %{public}@)", val);
                }
                continue;
            }
            twab_neutralizeWatchLimits(val, dirty);
        }
    } else if ([obj isKindOfClass:NSMutableArray.class]) {
        for (id val in (NSMutableArray *)obj) twab_neutralizeWatchLimits(val, dirty);
    }
}

static void twab_applyPlatformSpoof(NSMutableDictionary *op) {
    NSString *opName = op[@"operationName"];
    NSString *query  = op[@"query"];
    NSString *spoof  = [NSUUID UUID].UUIDString;

    BOOL isStream = [opName isEqualToString:@"PlaybackAccessToken"] ||
                    [opName isEqualToString:@"PlaybackAccessToken_Template"] ||
                    [opName isEqualToString:@"StreamAccessToken"] ||
                    [query containsString:@"PlaybackAccessToken"] ||
                    [query containsString:@"StreamAccessToken"];
    BOOL isVod    = [opName isEqualToString:@"VodAccessToken"];
    BOOL isClip   = [opName isEqualToString:@"ClipAccessToken"];

    if (isStream || isVod) {
        NSMutableDictionary *vars = op[@"variables"];
        if (!vars) return;
        // 29.x: playerType at top level of variables
        if (vars[@"playerType"])
            vars[@"playerType"] = spoof;
        // pre-29.x: platform nested under params
        NSMutableDictionary *params = vars[@"params"];
        if ([params isKindOfClass:NSMutableDictionary.class] && params[@"platform"])
            params[@"platform"] = spoof;
    } else if (isClip) {
        NSMutableDictionary *tokenParams = op[@"variables"][@"tokenParams"];
        if ([tokenParams isKindOfClass:NSMutableDictionary.class] && tokenParams[@"platform"])
            tokenParams[@"platform"] = spoof;
    }
}

@implementation NSData (TwitchAdBlock)

- (NSData *)twab_requestDataForRequest:(NSURLRequest *)request {
    if (!request) return self;
    if (![request.URL.host isEqualToString:@"gql.twitch.tv"] ||
        ![request.URL.path isEqualToString:@"/gql"])
        return self;

    NSError *error;
    id json = [NSJSONSerialization JSONObjectWithData:self
                                             options:NSJSONReadingMutableContainers
                                               error:&error];
    if (!json || error) return self;

    // Handle both single operation (dict) and Apollo-batched operations (array)
    if ([json isKindOfClass:NSMutableDictionary.class]) {
        twab_applyPlatformSpoof(json);
    } else if ([json isKindOfClass:NSMutableArray.class]) {
        for (id op in json)
            if ([op isKindOfClass:NSMutableDictionary.class])
                twab_applyPlatformSpoof(op);
    } else {
        return self;
    }

    NSData *out = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    return (out && !error) ? out : self;
}

- (NSData *)twab_responseDataForRequest:(NSURLRequest *)request {
    if (!request) return self;
    if (![request.URL.host isEqualToString:@"gql.twitch.tv"] ||
        ![request.URL.path isEqualToString:@"/gql"])
        return self;

    NSError *error;
    id json = [NSJSONSerialization JSONObjectWithData:self
                                             options:NSJSONReadingMutableContainers
                                               error:&error];
    if (!json || error) return self;

    // Strip ad nodes. Two strip semantics: arraySet matches array elements
    // (including edge-style {node: {...}}) and is the safe-default; fieldSet
    // additionally removes the parent's key when a dict field has a
    // matching typename — used only for confirmed top-level banners.
    // Skip re-serialize if nothing was removed (Apollo cache normalization
    // is sensitive to byte-level differences, which broke Clips).
    NSSet *arraySet = twab_arrayAdTypenames();
    NSSet *fieldSet = twab_fieldAdTypenames();
    BOOL stripWatchLimit = [tweakDefaults boolForKey:TWABKeyDisableWatchLimit];
    BOOL dirty = NO;
    NSArray *ops = [json isKindOfClass:NSMutableArray.class] ? json : @[json];
    for (NSMutableDictionary *op in ops) {
        if (![op isKindOfClass:NSMutableDictionary.class]) continue;
        twab_processTree(op[@"data"], arraySet, fieldSet, op[@"operationName"], &dirty);
        if (stripWatchLimit) twab_neutralizeWatchLimits(op[@"data"], &dirty);
    }
    if (!dirty) return self;
    NSData *out = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    return (out && !error) ? out : self;
}

@end
