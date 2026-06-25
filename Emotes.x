// TwitchAdBlock — third-party emote injection (7TV / BTTV / FFZ).
//
// Architecture:
//   1. Hook NSURLSessionWebSocketTask.receiveMessageWithCompletionHandler:
//      For each incoming IRC frame, parse the message body for words in our
//      emote map and inject synthetic numeric emote IDs into the `emotes=`
//      tag. Twitch's KMP parser sees these as native emote ranges and
//      produces EmoteTokens.
//
//   2. Hook __NSURLSessionLocal.dataTaskWithRequest:
//      When Twitch fetches https://static-cdn.jtvnw.net/emoticons/v2/{N}/...
//      where {N} is one of our synthetic IDs, rewrite the URL to the real
//      7TV/BTTV/FFZ CDN.
//
//   3. Per-channel emote loading: when we first see a ROOMSTATE or PRIVMSG
//      with a new `room-id=`, kick off async fetches against the 7TV, BTTV,
//      and FFZ public APIs. Globals are loaded once at startup. Per-channel
//      sets are tracked in an LRU (capped at TWAB_MAX_ROOMS); when a room
//      is evicted, its first-write-wins emote entries are removed too.
//      Globals (TWAB_GLOBAL_ROOM) are never evicted.
//
// Known limitations:
//   • Animated emotes render as a static first frame. Animation in this
//     Twitch build is server-gated for the account; no client-side hook
//     reaches the decision (verified via extensive ObjC swizzle attempts).
//   • Local-user outgoing messages are tokenized locally and bypass the IRC
//     echo, so your own emotes only render for OTHER viewers.

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "SettingsKeys.h"
#import "NSURL+TwitchAdBlock.h"
#import "NSData+TwitchAdBlock.h"
#import "NSURLSession+TwitchAdBlock.h"

// Forward declarations for host matchers defined in Tweak.x — needed by
// the consolidated __NSURLSessionLocal hook below.
extern BOOL twab_isAdHost(NSString *host);
extern BOOL twab_isPlaylistHost(NSString *host);
extern BOOL twab_isMasterPlaylistHost(NSString *host);

extern NSUserDefaults *tweakDefaults;

// ─── Emote registry ─────────────────────────────────────────────────────────
//
// Synthetic numeric IDs in [9_000_000_000, 9_999_999_999]. Real Twitch IDs are
// always < 10 digits (~hundreds of millions) so no collision risk.

static NSString *const TWAB_GLOBAL_ROOM = @"__global__";
static const NSUInteger TWAB_MAX_ROOMS = 50;

static dispatch_queue_t twab_emoteQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.level3tjg.twitchadblock.emotes",
                                  DISPATCH_QUEUE_CONCURRENT);
    });
    return q;
}

static NSMutableDictionary<NSString *, NSDictionary *> *twab_byWord(void) {
    static NSMutableDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [NSMutableDictionary dictionary]; });
    return m;
}

static NSMutableDictionary<NSString *, NSDictionary *> *twab_byFakeId(void) {
    static NSMutableDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [NSMutableDictionary dictionary]; });
    return m;
}

static NSMutableSet<NSString *> *twab_loadedRooms(void) {
    static NSMutableSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [NSMutableSet set]; });
    return s;
}

// LRU order of room IDs (oldest at index 0). Mutated only under the emote
// queue's barrier.
static NSMutableArray<NSString *> *twab_lruRooms(void) {
    static NSMutableArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ a = [NSMutableArray array]; });
    return a;
}

// room -> set of fakeIds registered against that room. Used by eviction to
// reverse-look up which entries to drop.
static NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *twab_roomFakeIds(void) {
    static NSMutableDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [NSMutableDictionary dictionary]; });
    return m;
}

// Monotonically increasing synthetic ID generator. Starts at 9_000_000_000 so
// it never collides with real Twitch numeric IDs (which top out around
// 3 billion as of 2025) or with v2 ids (which contain underscores).
static uint64_t twab_nextSyntheticId(void) {
    static _Atomic uint64_t counter = 9000000000;
    return atomic_fetch_add(&counter, 1);
}

// Register an emote word -> (provider, realId, animated, room). Allocates a
// synthetic id and updates all indexes atomically. First write wins per
// word; later writes with the same word are silently dropped, even from
// a different room. `room` of nil means "global" — never evicted. The
// `animated` flag drives format selection in twab_rewriteEmoteURL —
// animated emotes need .gif on 7TV (only GIF carries animation in the
// renderer); static emotes need .webp (some 7TV emotes lack a GIF
// variant entirely and .gif would 404).
static void twab_registerEmote(NSString *word, NSString *provider,
                               NSString *realId, NSString *room,
                               BOOL animated) {
    if (!word.length || !provider.length || !realId.length) return;
    NSString *roomKey = room.length ? room : TWAB_GLOBAL_ROOM;
    dispatch_barrier_async(twab_emoteQueue(), ^{
        if (twab_byWord()[word]) return;
        NSString *fakeId = [NSString stringWithFormat:@"%llu", twab_nextSyntheticId()];
        twab_byWord()[word] = @{@"provider": provider,
                                @"id": realId,
                                @"fake": fakeId,
                                @"animated": @(animated)};
        twab_byFakeId()[fakeId] = @{@"provider": provider,
                                    @"id": realId,
                                    @"word": word,
                                    @"room": roomKey,
                                    @"animated": @(animated)};
        NSMutableSet *set = twab_roomFakeIds()[roomKey];
        if (!set) {
            set = [NSMutableSet set];
            twab_roomFakeIds()[roomKey] = set;
        }
        [set addObject:fakeId];
    });
}

// Drop the oldest room beyond TWAB_MAX_ROOMS. Caller must already hold the
// emote queue's barrier. Globals (TWAB_GLOBAL_ROOM) are not in the LRU
// array, so they're never considered for eviction.
static void twab_evictOldestRoomsLocked(void) {
    NSMutableArray *lru = twab_lruRooms();
    while (lru.count > TWAB_MAX_ROOMS) {
        NSString *evicted = lru.firstObject;
        [lru removeObjectAtIndex:0];
        [twab_loadedRooms() removeObject:evicted];
        NSSet *fakeIds = [twab_roomFakeIds()[evicted] copy];
        for (NSString *fakeId in fakeIds) {
            NSDictionary *entry = twab_byFakeId()[fakeId];
            NSString *word = entry[@"word"];
            if (word) [twab_byWord() removeObjectForKey:word];
            [twab_byFakeId() removeObjectForKey:fakeId];
        }
        [twab_roomFakeIds() removeObjectForKey:evicted];
        os_log(OS_LOG_DEFAULT,
               "[TWAB-Emote] evicted room=%{public}@ emotes=%lu",
               evicted, (unsigned long)fakeIds.count);
    }
}

static NSString *twab_fakeIdForWord(NSString *word) {
    __block NSString *result = nil;
    dispatch_sync(twab_emoteQueue(), ^{
        NSDictionary *e = twab_byWord()[word];
        result = e ? e[@"fake"] : nil;
    });
    return result;
}

static NSDictionary *twab_entryForFakeId(NSString *fakeId) {
    __block NSDictionary *result = nil;
    dispatch_sync(twab_emoteQueue(), ^{
        result = twab_byFakeId()[fakeId];
    });
    return result;
}

// ─── Emote loaders ──────────────────────────────────────────────────────────

// Loader helpers are deliberately defensive — third-party JSON shapes can
// drift without notice. Every container access is type-guarded so a
// surprise null/array/string at any level fails the request rather than
// crashing the chat thread.

static void twab_load7TVSet(NSString *url, NSString *room) {
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url]
                              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e || !d) {
            os_log_error(OS_LOG_DEFAULT, "[TWAB-Emote] 7TV fetch failed url=%{public}@ err=%{public}@",
                         url, e.localizedDescription);
            return;
        }
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![j isKindOfClass:NSDictionary.class]) return;
        id set = j[@"emote_set"];  // /users/twitch wraps in emote_set
        if (![set isKindOfClass:NSDictionary.class]) set = j;
        id emotes = set[@"emotes"];
        if (![emotes isKindOfClass:NSArray.class]) return;
        NSUInteger n = 0;
        for (id em in emotes) {
            if (![em isKindOfClass:NSDictionary.class]) continue;
            NSString *name = em[@"name"];
            NSString *eid = em[@"id"];
            // animated flag lives at em.data.animated (7TV v3). Falls
            // back to NO if missing — safer to under-animate than to
            // request a non-existent .gif and render blank.
            BOOL animated = NO;
            id data = em[@"data"];
            if ([data isKindOfClass:NSDictionary.class]) {
                id a = ((NSDictionary *)data)[@"animated"];
                if ([a isKindOfClass:NSNumber.class]) animated = [a boolValue];
            }
            if ([name isKindOfClass:NSString.class] && name.length &&
                [eid isKindOfClass:NSString.class] && eid.length) {
                twab_registerEmote(name, @"7tv", eid, room, animated);
                n++;
            }
        }
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] 7TV +%lu %{public}@", (unsigned long)n, url);
    }] resume];
}

static void twab_loadBTTVChannel(NSString *roomId) {
    if (!roomId.length) return;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://api.betterttv.net/3/cached/users/twitch/%@", roomId]];
    [[NSURLSession.sharedSession dataTaskWithURL:url
                              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e || !d) {
            os_log_error(OS_LOG_DEFAULT, "[TWAB-Emote] BTTV channel fetch failed room=%{public}@ err=%{public}@",
                         roomId, e.localizedDescription);
            return;
        }
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![j isKindOfClass:NSDictionary.class]) return;
        NSUInteger n = 0;
        for (NSString *key in @[ @"channelEmotes", @"sharedEmotes" ]) {
            id arr = j[key];
            if (![arr isKindOfClass:NSArray.class]) continue;
            for (id em in arr) {
                if (![em isKindOfClass:NSDictionary.class]) continue;
                NSString *code = em[@"code"];
                NSString *eid = em[@"id"];
                // BTTV: imageType == "gif" → animated; "png" → static.
                NSString *imgType = em[@"imageType"];
                BOOL animated = [imgType isKindOfClass:NSString.class] &&
                                [imgType isEqualToString:@"gif"];
                if ([code isKindOfClass:NSString.class] && code.length &&
                    [eid isKindOfClass:NSString.class] && eid.length) {
                    twab_registerEmote(code, @"bttv", eid, roomId, animated);
                    n++;
                }
            }
        }
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] BTTV channel +%lu room=%{public}@",
               (unsigned long)n, roomId);
    }] resume];
}

static void twab_loadBTTVGlobal(void) {
    NSURL *url = [NSURL URLWithString:@"https://api.betterttv.net/3/cached/emotes/global"];
    [[NSURLSession.sharedSession dataTaskWithURL:url
                              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e || !d) {
            os_log_error(OS_LOG_DEFAULT, "[TWAB-Emote] BTTV global fetch failed err=%{public}@",
                         e.localizedDescription);
            return;
        }
        id list = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![list isKindOfClass:NSArray.class]) return;
        NSUInteger n = 0;
        for (id em in list) {
            if (![em isKindOfClass:NSDictionary.class]) continue;
            NSString *code = em[@"code"];
            NSString *eid = em[@"id"];
            NSString *imgType = em[@"imageType"];
            BOOL animated = [imgType isKindOfClass:NSString.class] &&
                            [imgType isEqualToString:@"gif"];
            if ([code isKindOfClass:NSString.class] && code.length &&
                [eid isKindOfClass:NSString.class] && eid.length) {
                twab_registerEmote(code, @"bttv", eid, nil, animated);
                n++;
            }
        }
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] BTTV global +%lu", (unsigned long)n);
    }] resume];
}

static void twab_loadFFZSet(NSString *url, NSString *room) {
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url]
                              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e || !d) {
            os_log_error(OS_LOG_DEFAULT, "[TWAB-Emote] FFZ fetch failed url=%{public}@ err=%{public}@",
                         url, e.localizedDescription);
            return;
        }
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![j isKindOfClass:NSDictionary.class]) return;
        id sets = j[@"sets"];
        if (![sets isKindOfClass:NSDictionary.class]) return;
        NSUInteger n = 0;
        for (NSString *setKey in sets) {
            id setVal = sets[setKey];
            if (![setVal isKindOfClass:NSDictionary.class]) continue;
            id arr = setVal[@"emoticons"];
            if (![arr isKindOfClass:NSArray.class]) continue;
            for (id em in arr) {
                if (![em isKindOfClass:NSDictionary.class]) continue;
                NSString *name = em[@"name"];
                NSNumber *idNum = em[@"id"];
                // FFZ: animated emotes have an `animated` dict of
                // {scale: cdn_path}. Static emotes have it null/absent.
                id animatedDict = em[@"animated"];
                BOOL animated = [animatedDict isKindOfClass:NSDictionary.class] &&
                                ((NSDictionary *)animatedDict).count > 0;
                if ([name isKindOfClass:NSString.class] && name.length &&
                    [idNum isKindOfClass:NSNumber.class]) {
                    twab_registerEmote(name, @"ffz", idNum.stringValue, room, animated);
                    n++;
                }
            }
        }
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] FFZ +%lu %{public}@", (unsigned long)n, url);
    }] resume];
}

// Fetch global emote sets — called once at startup.
static void twab_loadGlobalEmotes(void) {
    twab_load7TVSet(@"https://7tv.io/v3/emote-sets/global", nil);
    twab_loadBTTVGlobal();
    twab_loadFFZSet(@"https://api.frankerfacez.com/v1/set/global", nil);
}

// Fetch channel-specific emote sets for a given Twitch room id. Fully async —
// never blocks the WebSocket thread, even on the seen-room check. Touches
// the LRU and may evict the oldest channel(s) past the cap.
static void twab_loadChannelEmotes(NSString *roomId) {
    if (!roomId.length) return;
    NSString *room = [roomId copy];
    dispatch_barrier_async(twab_emoteQueue(), ^{
        NSMutableArray *lru = twab_lruRooms();
        if ([twab_loadedRooms() containsObject:room]) {
            [lru removeObject:room];
            [lru addObject:room];
            return;
        }
        [twab_loadedRooms() addObject:room];
        [lru addObject:room];
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] loading channel room=%{public}@", room);
        twab_load7TVSet([NSString stringWithFormat:@"https://7tv.io/v3/users/twitch/%@", room], room);
        twab_loadBTTVChannel(room);
        twab_loadFFZSet([NSString stringWithFormat:@"https://api.frankerfacez.com/v1/room/id/%@", room], room);
        twab_evictOldestRoomsLocked();
    });
}

// Clear every emote registry and re-fetch the global sets. Channel sets
// re-load lazily on the next ROOMSTATE/PRIVMSG for each room (twab_injectIRCEmotes
// calls twab_loadChannelEmotes on every PRIVMSG, and loadedRooms is now empty,
// so the current channel repopulates within a message or two). Non-static so
// the settings "Reload Emotes" action can call it. Safe from any thread —
// all mutation happens under the emote queue's barrier.
void twab_reloadEmotes(void) {
    dispatch_barrier_async(twab_emoteQueue(), ^{
        [twab_byWord() removeAllObjects];
        [twab_byFakeId() removeAllObjects];
        [twab_loadedRooms() removeAllObjects];
        [twab_lruRooms() removeAllObjects];
        [twab_roomFakeIds() removeAllObjects];
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] registry cleared by user reload");
    });
    // Re-fetch globals off the barrier — twab_loadGlobalEmotes only kicks off
    // async URL tasks, and each registration takes its own barrier.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        twab_loadGlobalEmotes();
    });
}

// ─── URL redirect ───────────────────────────────────────────────────────────

// Single source of truth for the CDN URL format used by a given emote.
// Both the hot-path URL rewrite (twab_rewriteEmoteURL) and the background
// prefetcher (twab_prefetchEmoteImage) call into this so the two paths
// can't drift.
//
// Format selection: Twitch's renderer animates emotes by decoding the
// response bytes — native animated emotes are served as image/gif from
// static-cdn.jtvnw.net (verified empirically). iOS UIImage natively
// decodes animated GIF but NOT animated WebP, so animated emotes have
// to be served as GIF.
//
// 7TV: animated emotes have a .gif variant on their CDN; static emotes
// often DON'T (only .webp / .avif / .png), so blindly requesting .gif
// 404s for those. The animated flag from the API drives the extension.
//
// BTTV: /2x serves GIF for animated emotes, PNG for static. Single URL
// works for both, no need to branch.
//
// FFZ: animated emotes live at /animated/<scale>.gif; static at /<scale>
// (no extension). The flag drives the path.
static NSURL *twab_computeEmoteCDNURL(NSString *provider, NSString *realId, BOOL animated) {
    if ([provider isEqualToString:@"7tv"]) {
        NSString *ext = animated ? @"gif" : @"webp";
        return [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.7tv.app/emote/%@/2x.%@", realId, ext]];
    }
    if ([provider isEqualToString:@"bttv"])
        return [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.betterttv.net/emote/%@/2x", realId]];
    if ([provider isEqualToString:@"ffz"]) {
        if (animated)
            return [NSURL URLWithString:[NSString stringWithFormat:
                @"https://cdn.frankerfacez.com/emote/%@/animated/2.gif", realId]];
        return [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.frankerfacez.com/emote/%@/2", realId]];
    }
    return nil;
}

static NSURL *twab_rewriteEmoteURL(NSURL *url) {
    NSString *s = url.absoluteString;
    if (!s || ![s containsString:@"emoticons/v2/"]) return nil;
    NSArray<NSString *> *parts = url.pathComponents;
    if (parts.count < 4) return nil;
    NSString *fakeId = parts[3];
    NSDictionary *entry = twab_entryForFakeId(fakeId);
    if (!entry) return nil;
    NSString *provider = entry[@"provider"];
    NSString *realId = entry[@"id"];
    NSNumber *animBox = entry[@"animated"];
    BOOL animated = [animBox isKindOfClass:NSNumber.class] && [animBox boolValue];
    return twab_computeEmoteCDNURL(provider, realId, animated);
}

// The leaf NSURLSession implementation in iOS is __NSURLSessionLocal,
// which overrides dataTaskWithRequest:. Twitch's video stack ends up
// calling this concrete class directly, so any %hook on the parent
// NSURLSession is shadowed for video traffic. Consolidating all our
// dataTaskWithRequest: logic here:
//   1. Diagnostic log (TWAB-URL, first 200 calls)
//   2. Ad-host hard block (TWAdBlockEnabled)
//   3. GQL platform spoof on request body (TWAdBlockEnabled)
//   4. 7TV/BTTV/FFZ emote URL redirect (TWEmotesEnabled)
//   5. Playlist host proxy URL rewrite (TWAdBlockEnabled + TWAdBlockProxyEnabled)
//
// Order matters: ad host block → body spoof → emote redirect → proxy route.
// The proxy route only rewrites the URL (Luminous-style); the
// session-switch fallback was removed because it crashes Twitch's video
// stack when the substituted session is foreign to __NSURLSessionLocal.
%hook __NSURLSessionLocal
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    // Recursion guard: when the proxy-routing fallback below creates a
    // task on a foreign proxy-configured session, that session's
    // dataTaskWithRequest: call re-enters this hook. The guard makes the
    // recursive call return %orig immediately so the proxy session sets
    // up its task naturally and we don't re-route forever.
    NSMutableDictionary *_td = [NSThread currentThread].threadDictionary;
    if ([_td[@"twab_inProxyDispatch"] boolValue]) {
        return %orig(request);
    }

    // Targeted diagnostic only. Logging every URL through this hook
    // floods the system log past what Console.app / idevicesyslog can
    // keep up with under Twitch's request rate; the relevant
    // [TWAB-Proxy] and rewrite lines get dropped. Only log playlist /
    // segment hosts (and our own proxy host) so the signal is preserved.
    NSString *_host = request.URL.host;
    if (_host && (twab_isPlaylistHost(_host) ||
                  [_host hasSuffix:@"ttvnw.net"])) {
        os_log(OS_LOG_DEFAULT,
            "[TWAB-URL] __NSURLSessionLocal host=%{public}@ path=%{public}@",
            _host, request.URL.path ?: @"?");
    }

    // Emote URL capture — log every distinct emoticons/v2/ URL the chat
    // requests (deduped so each unique URL prints once). Used to compare
    // the URL format Twitch uses for native animated emotes (likely has
    // "/animated/" in the path) vs static emotes (likely "/static/"). If
    // Twitch's renderer keys animation off the URL path, we can route
    // our synthetic IDs through the same scheme.
    NSString *_path = request.URL.path;
    if (_path && [_path containsString:@"emoticons/v2/"]) {
        static NSMutableSet<NSString *> *seenEmoteURLs;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ seenEmoteURLs = [NSMutableSet set]; });
        NSString *urlString = request.URL.absoluteString;
        @synchronized (seenEmoteURLs) {
            if (urlString && ![seenEmoteURLs containsObject:urlString]) {
                [seenEmoteURLs addObject:urlString];
                os_log(OS_LOG_DEFAULT, "[TWAB-EmoteURL] %{public}@", urlString);
            }
        }
    }

    BOOL adBlockOn = [tweakDefaults boolForKey:TWABKeyAdBlockEnabled];
    BOOL emotesOn = [tweakDefaults boolForKey:TWABKeyEmotesEnabled];

    if (adBlockOn && twab_isAdHost(request.URL.host)) return nil;

    // GQL platform spoof — twab_requestDataForRequest: no-ops for non-gql hosts.
    if (adBlockOn) {
        NSData *body = request.HTTPBody;
        NSData *xformed = [body twab_requestDataForRequest:request];
        if (xformed != body) {
            if (![request isKindOfClass:NSMutableURLRequest.class]) request = request.mutableCopy;
            ((NSMutableURLRequest *)request).HTTPBody = xformed;
        }
    }

    // Emote URL rewrite (jtvnw.net emoticons -> 7TV/BTTV/FFZ CDNs).
    if (emotesOn) {
        NSURL *real = twab_rewriteEmoteURL(request.URL);
        if (real) {
            if (![request isKindOfClass:NSMutableURLRequest.class]) request = request.mutableCopy;
            ((NSMutableURLRequest *)request).URL = real;
            return %orig(request);
        }
    }

    // Master playlist routing. Two paths:
    //   1. ttv-lol-pro V2 / Luminous proxies — rewrite URL to
    //      proxy/<type>/<encoded "channel.m3u8?sanitized-query">.
    //      Returns clean (ad-free) master playlist; variant URLs go
    //      direct to Twitch CDN. Tries each configured proxy in order;
    //      first whose /ping returns 200 wins.
    //   2. Standard HTTP CONNECT proxies — create a proxy-configured
    //      NSURLSession via twab_proxySessionWithAddress: and dispatch
    //      the task there. Proxy tunnels CONNECT to usher.ttvnw.net so
    //      Twitch's ad-targeting (which keys off client IP) misses.
    //      Proxy session is strong-associated with the returned task so
    //      it can't be deallocated mid-request.
    //
    // Subscriber/Turbo users bypass both paths — their accounts already
    // serve ad-free playlists, so proxying just exposes their token.
    if (twab_isMasterPlaylistHost(request.URL.host)) {
        BOOL proxyEnabled = [tweakDefaults boolForKey:TWABKeyAdBlockProxyEnabled];
        NSArray<NSString *> *proxyAddrs = twab_effectiveProxyAddresses();
        os_log(OS_LOG_DEFAULT,
            "[TWAB-URL] master playlist seen host=%{public}@ adBlock=%d proxyEnabled=%d proxies=%lu",
            request.URL.host, adBlockOn, proxyEnabled, (unsigned long)proxyAddrs.count);

        if (adBlockOn && proxyEnabled && proxyAddrs.count) {
            if (twab_userIsAdExempt(request.URL.query)) {
                os_log(OS_LOG_DEFAULT,
                    "[TWAB-URL] subscriber/turbo detected — skipping proxy host=%{public}@",
                    request.URL.host);
            } else {
                BOOL rewrote = NO;
                for (NSString *proxyAddr in proxyAddrs) {
                    NSURL *proxyURL = twab_normalizedProxyURL(proxyAddr);
                    if (!proxyURL) continue;
                    NSURL *rewritten = [request.URL twab_URLWithProxyURL:proxyURL];
                    if (![rewritten isEqual:request.URL]) {
                        os_log(OS_LOG_DEFAULT,
                            "[TWAB-URL] V2-rewrote master playlist via %{public}@:%{public}@",
                            proxyURL.host, proxyURL.port ?: @0);
                        if (![request isKindOfClass:NSMutableURLRequest.class]) request = request.mutableCopy;
                        ((NSMutableURLRequest *)request).URL = rewritten;
                        // Inject Basic auth header — NSURLSession ignores
                        // user:pass embedded in URLs, but the proxy needs
                        // it to authorize the request.
                        NSString *auth = twab_basicAuthHeader(proxyURL);
                        if (auth) [(NSMutableURLRequest *)request setValue:auth forHTTPHeaderField:@"Authorization"];
                        rewrote = YES;
                        break;
                    }
                }

                if (!rewrote) {
                    // Standard HTTP CONNECT proxy fallback on the first
                    // parseable proxy. Cast to NSURLSession because
                    // __NSURLSessionLocal is only forward-declared here.
                    NSString *connectAddr = nil;
                    for (NSString *a in proxyAddrs) {
                        if (twab_normalizedProxyURL(a)) { connectAddr = a; break; }
                    }
                    if (connectAddr) {
                        NSURLSession *proxySession = [(NSURLSession *)self twab_proxySessionWithAddress:connectAddr];
                        if (proxySession) {
                            _td[@"twab_inProxyDispatch"] = @YES;
                            NSURLSessionDataTask *task = [proxySession dataTaskWithRequest:request];
                            _td[@"twab_inProxyDispatch"] = nil;
                            if (task) {
                                static char proxySessionKey;
                                objc_setAssociatedObject(task, &proxySessionKey, proxySession,
                                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                                os_log(OS_LOG_DEFAULT,
                                    "[TWAB-URL] routed master playlist via HTTP CONNECT proxy host=%{public}@",
                                    request.URL.host);
                                return task;
                            }
                        }
                    }
                    os_log(OS_LOG_DEFAULT,
                        "[TWAB-URL] master playlist NOT rewritten/routed host=%{public}@",
                        request.URL.host);
                }
            }
        }
    }

    return %orig(request);
}
%end

// ─── IRC tag injection ──────────────────────────────────────────────────────
//
// IRC tagged-PRIVMSG format:
//   @badges=...;emotes=305288392:0-7;room-id=12345;... :nick!... PRIVMSG #ch :hi PogChamp
//
// emotes= value format: emoteId:start-end[,start-end][/emoteId:start-end[...]]
// Twitch indexes positions in Unicode code points, not UTF-16 units.

// Extract a tag value from the leading "@key=value;key=value;..." section.
// Returns nil if not found.
static NSString *twab_extractTag(NSString *tagsPart, NSString *key) {
    NSString *needle = [key stringByAppendingString:@"="];
    NSRange r = [tagsPart rangeOfString:needle];
    if (r.location == NSNotFound) return nil;
    NSUInteger start = r.location + r.length;
    NSRange semi = [tagsPart rangeOfString:@";"
                                  options:0
                                    range:NSMakeRange(start, tagsPart.length - start)];
    NSUInteger end = (semi.location == NSNotFound) ? tagsPart.length : semi.location;
    return [tagsPart substringWithRange:NSMakeRange(start, end - start)];
}

// Count grapheme clusters over a range. Close enough to Unicode code points
// for normal chat content (emoji ZWJ sequences differ, but those are rare
// in chat text and Twitch's parser is grapheme-cluster oriented anyway).
static NSUInteger twab_charCount(NSString *s, NSRange range) {
    __block NSUInteger n = 0;
    [s enumerateSubstringsInRange:range
                          options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *sub, NSRange r, NSRange er, BOOL *stop) {
        n++;
    }];
    return n;
}

// Observe non-PRIVMSG lines (ROOMSTATE etc.) for room-id so we can preload
// channel emotes before any chat message arrives.
static void twab_observeIRCLine(NSString *line) {
    if (![line hasPrefix:@"@"]) return;
    if (![line containsString:@" ROOMSTATE #"]) return;
    NSRange tagsEnd = [line rangeOfString:@" :"];
    if (tagsEnd.location == NSNotFound) return;
    NSString *tagsPart = [line substringToIndex:tagsEnd.location];
    NSString *roomId = twab_extractTag(tagsPart, @"room-id");
    if (roomId.length) twab_loadChannelEmotes(roomId);
}

static NSString *twab_injectIRCEmotes(NSString *line) {
    if (![line hasPrefix:@"@"]) return nil;
    NSRange privmsg = [line rangeOfString:@" PRIVMSG #"];
    if (privmsg.location == NSNotFound) return nil;

    NSRange textSep = [line rangeOfString:@" :"
                                  options:0
                                    range:NSMakeRange(privmsg.location,
                                                       line.length - privmsg.location)];
    if (textSep.location == NSNotFound) return nil;
    NSUInteger textStart = textSep.location + 2;
    if (textStart >= line.length) return nil;
    NSString *text = [line substringFromIndex:textStart];

    NSRange tagsEnd = [line rangeOfString:@" :"];
    if (tagsEnd.location == NSNotFound) return nil;
    NSString *tagsPart = [line substringToIndex:tagsEnd.location];

    // Kick off channel emote load on first sight of a new room-id.
    NSString *roomId = twab_extractTag(tagsPart, @"room-id");
    if (roomId.length) twab_loadChannelEmotes(roomId);

    // Scan words for matches. Positions are code-point-based, so we track a
    // grapheme-cluster cursor separately from any UTF-16 indexing.
    NSMutableArray<NSString *> *newEntries = [NSMutableArray array];
    NSArray<NSString *> *words = [text componentsSeparatedByString:@" "];
    NSUInteger codePos = 0;
    for (NSString *word in words) {
        NSUInteger wordLen = twab_charCount(word, NSMakeRange(0, word.length));
        NSString *fakeId = twab_fakeIdForWord(word);
        if (fakeId && wordLen > 0) {
            NSUInteger end = codePos + wordLen - 1;
            [newEntries addObject:[NSString stringWithFormat:@"%@:%lu-%lu",
                                   fakeId, (unsigned long)codePos, (unsigned long)end]];
        }
        codePos += wordLen + 1;  // +1 for the space separator
    }
    if (newEntries.count == 0) return nil;

    // Append our entries to the existing emotes= value (or add the tag if missing).
    NSString *combined = [newEntries componentsJoinedByString:@"/"];
    NSString *newTags;
    NSRange emotesTag = [tagsPart rangeOfString:@"emotes="];
    if (emotesTag.location == NSNotFound) {
        newTags = [tagsPart stringByAppendingFormat:@";emotes=%@", combined];
    } else {
        NSUInteger valStart = emotesTag.location + emotesTag.length;
        NSRange semicolon = [tagsPart rangeOfString:@";"
                                            options:0
                                              range:NSMakeRange(valStart,
                                                                 tagsPart.length - valStart)];
        NSUInteger valEnd = (semicolon.location == NSNotFound) ? tagsPart.length
                                                                : semicolon.location;
        NSString *existing = [tagsPart substringWithRange:NSMakeRange(valStart,
                                                                      valEnd - valStart)];
        NSString *newVal = existing.length
            ? [existing stringByAppendingFormat:@"/%@", combined]
            : combined;
        newTags = [NSString stringWithFormat:@"%@emotes=%@%@",
                   [tagsPart substringToIndex:emotesTag.location],
                   newVal,
                   [tagsPart substringFromIndex:valEnd]];
    }
    return [newTags stringByAppendingString:[line substringFromIndex:tagsEnd.location]];
}

// Wrap the completion handler to rewrite each received text frame.
//
// The same WebSocket task can have its `receiveMessageWithCompletionHandler:`
// reached through either the public class or the private subclass. Without
// the associated-object marker, we'd double-wrap the handler whenever both
// hook sites fire for the same call, processing the message twice.
typedef void (^twab_recvHandler)(NSURLSessionWebSocketMessage *, NSError *);

static char twab_handlerWrappedKey;

static twab_recvHandler twab_wrapHandler(twab_recvHandler h) {
    if (!h) return h;
    if (objc_getAssociatedObject(h, &twab_handlerWrappedKey)) return h;
    twab_recvHandler wrapped = ^(NSURLSessionWebSocketMessage *msg, NSError *err) {
        if (![tweakDefaults boolForKey:TWABKeyEmotesEnabled]) {
            h(msg, err);
            return;
        }
        if (!msg || msg.type != NSURLSessionWebSocketMessageTypeString || !msg.string) {
            h(msg, err);
            return;
        }
        NSString *s = msg.string;
        // Fast bail for non-IRC frames. Twitch IRC lines always start with
        // `@` (tagged), `:` (prefixed), or a command word — for the chat
        // socket that's PING/PONG. Anything else is a different protocol
        // (e.g., a pubsub or graphql subscription frame) and shouldn't be
        // split-by-CRLF or scanned for emote tokens.
        unichar first = s.length ? [s characterAtIndex:0] : 0;
        if (first != '@' && first != ':' && first != 'P') {
            h(msg, err);
            return;
        }
        NSArray<NSString *> *lines = [s componentsSeparatedByString:@"\r\n"];
        NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:lines.count];
        BOOL changed = NO;
        for (NSString *line in lines) {
            twab_observeIRCLine(line);  // ROOMSTATE preload
            NSString *mod = twab_injectIRCEmotes(line);
            if (mod) { [out addObject:mod]; changed = YES; }
            else     { [out addObject:line]; }
        }
        if (changed) {
            NSString *joined = [out componentsJoinedByString:@"\r\n"];
            h([[NSURLSessionWebSocketMessage alloc] initWithString:joined], err);
        } else {
            h(msg, err);
        }
    };
    objc_setAssociatedObject(wrapped, &twab_handlerWrappedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return wrapped;
}

// NSURLSessionWebSocketTask (public) is sometimes the dispatch target; the
// concrete impl is __NSURLSessionWebSocketTask (private). Hook both.

%hook NSURLSessionWebSocketTask
- (void)receiveMessageWithCompletionHandler:(void (^)(NSURLSessionWebSocketMessage *, NSError *))handler {
    %orig(twab_wrapHandler(handler));
}
%end

%group PrivateWS
%hook __NSURLSessionWebSocketTask
- (void)receiveMessageWithCompletionHandler:(void (^)(NSURLSessionWebSocketMessage *, NSError *))handler {
    %orig(twab_wrapHandler(handler));
}
%end
%end

%ctor {
    %init;
    if (objc_getClass("__NSURLSessionWebSocketTask")) %init(PrivateWS);
    // NB: defaults for TWABKeyEmotesEnabled / TWABKeyEmotePrefetchEnabled
    // are set in Tweak.x's %ctor, NOT here — Logos doesn't guarantee
    // inter-file ctor ordering and tweakDefaults may be nil at this
    // point, making any setBool: silently fail.
    twab_loadGlobalEmotes();
}
