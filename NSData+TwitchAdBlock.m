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
// countdown bar never depletes within a session, so playback continues (1,000,000
// seconds, see below for why not INT_MAX). Sets *dirty=YES on change.
//
// SCOPED to the Evolve feed only. The Following "Live Now" list shares the SAME
// FeedItemsQuery, and its `feedItems` object also carries watchBehavior — but it
// has no watch limit. Rewriting it there changed every paginated Following page,
// which made Apollo re-render the whole list and snap the user's scroll to the
// top (reported bug). Both feeds request the `isEvolveFeed` flag, so we skip any
// feedItems object where it's explicitly false — leaving the Following response
// byte-identical while still neutralizing the real Evolve feed.
static void twab_neutralizeWatchLimits(id obj, BOOL *dirty) {
    if ([obj isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *d = obj;
        // A feedItems object: has watchBehavior. Only rewrite it when this isn't
        // explicitly the Following (non-Evolve) feed.
        id wb = d[@"watchBehavior"];
        if ([wb isKindOfClass:NSMutableDictionary.class]) {
            id evolve = d[@"isEvolveFeed"];
            BOOL isFollowingFeed = [evolve isKindOfClass:NSNumber.class] && ![evolve boolValue];
            // 31.x's Live feed is React Native, which turns this into a
            // JavaScript timer in milliseconds. The old INT_MAX seconds
            // overflowed JS's maximum timer delay (2^31-1 ms ≈ 24.8 days) —
            // and an overflowed timer fires immediately, so the "infinite"
            // limit cut streams off instead. 1,000,000 s (≈11.5 days) is
            // 1e9 ms: effectively unlimited, and safe for both native and JS.
            NSNumber *capped = @(1000000);
            for (NSString *key in @[@"maxStreamWatchSeconds", @"maxWatchSeconds"]) {
                id secs = ((NSMutableDictionary *)wb)[key];
                if (isFollowingFeed || ![secs isKindOfClass:NSNumber.class]) continue;
                if ([secs isEqual:capped]) continue;
                ((NSMutableDictionary *)wb)[key] = capped;
                *dirty = YES;
                os_log(OS_LOG_DEFAULT,
                    "[TWAB-Watch] neutralized %{public}@ (was %{public}@)", key, secs);
            }
        }
        for (NSString *key in d) twab_neutralizeWatchLimits(d[key], dirty);
    } else if ([obj isKindOfClass:NSMutableArray.class]) {
        for (id val in (NSMutableArray *)obj) twab_neutralizeWatchLimits(val, dirty);
    }
}

// Hide Stories, data side. The Stories shelf at the top of Home is fed by one
// GraphQL query — StoryPreviewsWithOrder (native Home) or StoryShelfPreviews
// (React Native Home, Twitch 31.x) — both returning storyPreviewsWithOrder.
// Emptying its previews works no matter which Home implementation renders the
// shelf (the native view-removal in Tweak.x can't see a React Native shelf).
// Matched by operation name, NOT by field: RecapsPreviews uses the same
// storyPreviewsWithOrder field for Recaps and must be left alone.
static BOOL twab_isStoryShelfOperation(NSString *opName) {
    return [opName isEqualToString:@"StoryShelfPreviews"] ||
           [opName isEqualToString:@"StoryPreviewsWithOrder"];
}

static void twab_emptyStoryShelf(NSMutableDictionary *data, BOOL *dirty) {
    NSMutableDictionary *shelf = data[@"storyPreviewsWithOrder"];
    if (![shelf isKindOfClass:NSMutableDictionary.class]) return;
    for (NSString *key in [shelf allKeys]) {
        id val = shelf[key];
        if ([val isKindOfClass:NSArray.class] && [(NSArray *)val count]) {
            shelf[key] = [NSMutableArray array];   // previews (and any other lists)
            *dirty = YES;
        } else if ([key isEqualToString:@"creatorSelfPreview"] && val && val != (id)kCFNull) {
            shelf[key] = (id)kCFNull;               // native: your own story bubble
            *dirty = YES;
        } else if ([key isEqualToString:@"hasNextPage"] && [val isEqual:@YES]) {
            shelf[key] = @NO;
            *dirty = YES;
        }
    }
    if (*dirty) os_log(OS_LOG_DEFAULT, "[TWAB-Stories] emptied Stories shelf response");
}

// The stronger lever: StoriesViewAccess / StoriesCreationAccess return the
// account's story eligibilities, which decide whether the Stories shelf (and
// the "add your story" bubble) is shown at all. Emptying them hides the shelf
// even when the React Native Apollo cache still holds old previews — the
// paginated previews list merges, so an empty StoryShelfPreviews alone doesn't
// clear what's cached; these plain arrays overwrite on every fetch.
static BOOL twab_isStoryAccessOperation(NSString *opName) {
    return [opName isEqualToString:@"StoriesViewAccess"] ||
           [opName isEqualToString:@"StoriesCreationAccess"];
}

static void twab_denyStoryAccess(NSMutableDictionary *data, NSString *opName, BOOL *dirty) {
    for (NSString *key in [data allKeys]) {
        NSMutableDictionary *access = data[key];
        if (![access isKindOfClass:NSMutableDictionary.class]) continue;
        NSArray *elig = access[@"eligibilities"];
        if ([elig isKindOfClass:NSArray.class] && elig.count) {
            os_log(OS_LOG_DEFAULT, "[TWAB-Stories] %{public}@: cleared eligibilities %{public}@",
                   opName, [elig componentsJoinedByString:@","]);
            access[@"eligibilities"] = [NSMutableArray array];
            *dirty = YES;
        }
    }
}

// Operation name for a response element: Twitch echoes it in
// extensions.operationName; fall back to the matching request op (batched
// requests and responses are index-aligned).
static NSString *twab_responseOperationName(NSDictionary *op, NSURLRequest *request, NSUInteger index) {
    NSString *name = op[@"extensions"][@"operationName"];
    if ([name isKindOfClass:NSString.class]) return name;
    if (!request.HTTPBody) return nil;
    id req = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
    NSArray *reqOps = [req isKindOfClass:NSArray.class] ? req : (req ? @[req] : @[]);
    NSDictionary *reqOp = index < reqOps.count ? reqOps[index] : nil;
    name = [reqOp isKindOfClass:NSDictionary.class] ? reqOp[@"operationName"] : nil;
    return [name isKindOfClass:NSString.class] ? name : nil;
}

static void twab_applyPlatformSpoof(NSMutableDictionary *op) {
    NSString *opName = op[@"operationName"];
    NSString *query  = op[@"query"];
    NSString *spoof  = [NSUUID UUID].UUIDString;

    // 31.x's React Native player names its operations StreamAccessTokenQuery /
    // VodAccessTokenQuery / PrefetchPlaybackAccessToken; match by prefix so a
    // hash-only (no query text) request is still caught.
    BOOL isStream = [opName isEqualToString:@"PlaybackAccessToken"] ||
                    [opName isEqualToString:@"PlaybackAccessToken_Template"] ||
                    [opName hasPrefix:@"StreamAccessToken"] ||
                    [opName isEqualToString:@"PrefetchPlaybackAccessToken"] ||
                    [query containsString:@"PlaybackAccessToken"] ||
                    [query containsString:@"StreamAccessToken"];
    BOOL isVod    = [opName hasPrefix:@"VodAccessToken"];
    BOOL isClip   = [opName isEqualToString:@"ClipAccessToken"];

    if (isStream || isVod) {
        NSMutableDictionary *vars = op[@"variables"];
        if (!vars) return;
        // 29.x: playerType at top level of variables
        if (vars[@"playerType"])
            vars[@"playerType"] = spoof;
        // 31.x PrefetchPlaybackAccessToken: platform at top level too
        if (vars[@"platform"])
            vars[@"platform"] = spoof;
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
    // Ad stripping + watch limit ride on the ad-block toggle; Hide Stories is
    // independent of it.
    BOOL adBlock = [tweakDefaults boolForKey:TWABKeyAdBlockEnabled];
    BOOL stripWatchLimit = adBlock && [tweakDefaults boolForKey:TWABKeyDisableWatchLimit];
    BOOL hideStories = [tweakDefaults boolForKey:TWABKeyHideStories];
    if (!adBlock && !hideStories) return self;
    BOOL dirty = NO;
    NSArray *ops = [json isKindOfClass:NSMutableArray.class] ? json : @[json];
    for (NSUInteger i = 0; i < ops.count; i++) {
        NSMutableDictionary *op = ops[i];
        if (![op isKindOfClass:NSMutableDictionary.class]) continue;
        if (adBlock) twab_processTree(op[@"data"], arraySet, fieldSet, op[@"operationName"], &dirty);
        if (stripWatchLimit) twab_neutralizeWatchLimits(op[@"data"], &dirty);
        if (hideStories) {
            NSString *opName = twab_responseOperationName(op, request, i);
            if ([op[@"data"] isKindOfClass:NSMutableDictionary.class] && twab_isStoryShelfOperation(opName))
                twab_emptyStoryShelf(op[@"data"], &dirty);
            if ([op[@"data"] isKindOfClass:NSMutableDictionary.class] && twab_isStoryAccessOperation(opName))
                twab_denyStoryAccess(op[@"data"], opName, &dirty);
        }
    }
    if (!dirty) return self;
    NSData *out = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    return (out && !error) ? out : self;
}

@end
