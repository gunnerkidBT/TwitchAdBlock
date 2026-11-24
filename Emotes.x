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
//   3. Hook KMPMCChatMessageTokenizer.tokenizeMessage…
//      Post-process the token array: scan TextTokens for emote names and
//      split them into EmoteTokens with our synthetic IDs. This makes the
//      local echo (user's own messages) render third-party emotes
//      immediately without waiting for the IRC server echo.
//
//   4. Per-channel emote loading: when we first see a ROOMSTATE or PRIVMSG
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
//   • Sending works by typing the emote's name (it's plain chat text). The
//     picker button in EmotePicker.x inserts names for you.

#import "TWABProxyAuthDelegate.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>
#import <os/log.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "SettingsKeys.h"
#import "NSURL+TwitchAdBlock.h"
#import "NSData+TwitchAdBlock.h"
#import "NSURLSession+TwitchAdBlock.h"
#import "TWABProxyPool.h"
#import "ChannelPoints.h"

// Forward declarations for host matchers defined in Tweak.x — needed by
// the consolidated __NSURLSessionLocal hook below.
extern BOOL twab_isAdHost(NSString *host);
extern BOOL twab_isPlaylistHost(NSString *host);
extern BOOL twab_isMasterPlaylistHost(NSString *host);
extern BOOL twab_isExternalPlayback(void);
extern void twab_emoteNetStart(NSURL *url);  // Tweak.x diagnostics  // Cast/AirPlay — skip proxy rewrite

extern NSUserDefaults *tweakDefaults;

// ─── Emote registry ─────────────────────────────────────────────────────────
//
// Synthetic numeric IDs in [9_000_000_000, 9_999_999_999]. Real Twitch IDs are
// always < 10 digits (~hundreds of millions) so no collision risk.

static NSString *const TWAB_GLOBAL_ROOM = @"__global__";
static NSString *twab_currentRoom;  // room-id of the latest ROOMSTATE
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

// Words are per room: different channels can use the same name for
// different emotes.
static NSString *twab_wordKey(NSString *roomKey, NSString *word) {
    return [NSString stringWithFormat:@"%@%@", roomKey, word];
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

// Synthetic ID for an emote, derived from provider + real id so it's the
// same every launch: Twitch caches emote images by URL, so a stable ID lets
// that cache work across restarts (and never shows a stale image for a
// reused ID). Range [9_000_000_000, 9_999_999_998] stays clear of real Twitch
// emote IDs. Caller holds the emote queue's barrier.
static NSString *twab_stableFakeIdLocked(NSString *provider, NSString *realId) {
    NSString *key = [NSString stringWithFormat:@"%@/%@", provider, realId];
    uint64_t h = 1469598103934665603ULL;
    for (const char *c = key.UTF8String; *c; c++) { h ^= (uint8_t)*c; h *= 1099511628211ULL; }
    uint64_t n = 9000000000ULL + h % 999999999ULL;
    for (;;) {
        NSString *fakeId = [NSString stringWithFormat:@"%llu", n];
        NSDictionary *e = twab_byFakeId()[fakeId];
        if (!e || ([e[@"provider"] isEqualToString:provider] && [e[@"id"] isEqualToString:realId]))
            return fakeId;
        n = n >= 9999999998ULL ? 9000000000ULL : n + 1;
    }
}

static NSURL *twab_computeThumbCDNURL(NSString *provider, NSString *realId, BOOL animated);
static void twab_setupTokenizerHook(void);
static NSDictionary *twab_entryForFakeId(NSString *fakeId);
static void twab_loadChannelEmotes(NSString *roomId);
static void twab_noteSentChatRequest(NSURLRequest *request);

static BOOL twab_isAccessTokenRequest(NSURLRequest *request) {
    NSData *body = request.HTTPBody;
    if (!body.length) return NO;
    for (NSString *name in @[@"PlaybackAccessToken", @"StreamAccessToken", @"VodAccessToken"]) {
        NSData *needle = [name dataUsingEncoding:NSUTF8StringEncoding];
        if ([body rangeOfData:needle options:0 range:NSMakeRange(0, body.length)].location != NSNotFound)
            return YES;
    }
    return NO;
}
static void twab_registerEmote(NSString *word, NSString *provider,
                               NSString *realId, NSString *room,
                               BOOL animated, CGFloat ratio);
static void twab_registerEmoteLocked(NSString *word, NSString *provider,
                                     NSString *realId, NSString *roomKey,
                                     BOOL animated, CGFloat ratio);


static NSURLSession *twab_prefetchSession(void) {
    static NSURLSession *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.networkServiceType = NSURLNetworkServiceTypeBackground;
        cfg.HTTPMaximumConnectionsPerHost = 4;
        s = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}

static NSURLSession *twab_emoteAPISession(void) {
    static NSURLSession *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForResource = 5;
        cfg.timeoutIntervalForRequest = 5;
        s = [NSURLSession sessionWithConfiguration:cfg];
    });
    return s;
}

// ─── Disk cache ────────────────────────────────────────────────────────────
//
// Emote sets are cached to Library/Caches/TwitchAdBlock/emotes/ as plist
// files keyed by room ID (or "__global__"). Each file contains an array of
// dicts: {word, provider, id, animated}. On channel join the cache is loaded
// synchronously (< 10ms for typical sets) so emotes are available before the
// first PRIVMSG arrives. API fetches update the cache in the background.

static NSString *twab_emoteCacheDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *caches = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        dir = [caches stringByAppendingPathComponent:@"TwitchAdBlock/emotes"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil];
    });
    return dir;
}

static NSString *twab_emoteCachePath(NSString *roomKey) {
    NSString *safe = [roomKey stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [twab_emoteCacheDir() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.plist", safe]];
}

static void twab_saveEmotesToDisk(NSString *roomKey, NSArray<NSDictionary *> *emotes) {
    if (!emotes.count) return;
    NSString *path = twab_emoteCachePath(roomKey);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [emotes writeToFile:path atomically:YES];
    });
}

static NSArray<NSDictionary *> *twab_loadEmotesFromDisk(NSString *roomKey) {
    NSString *path = twab_emoteCachePath(roomKey);
    NSArray *arr = [NSArray arrayWithContentsOfFile:path];
    if (![arr isKindOfClass:NSArray.class]) return nil;
    return arr;
}

// Register a provider's cached emotes for `roomKey` (a room id or
// TWAB_GLOBAL_ROOM). Caller holds the emote queue's barrier, so the emotes
// are in place before any later chat message is matched.
static void twab_registerCachedEmotesLocked(NSString *roomKey, NSString *provider) {
    NSString *fileKey = [NSString stringWithFormat:@"%@_%@", roomKey, provider];
    NSArray<NSDictionary *> *cached = twab_loadEmotesFromDisk(fileKey);
    if (!cached.count) return;
    NSUInteger n = 0;
    for (NSDictionary *e in cached) {
        if (![e isKindOfClass:NSDictionary.class]) continue;
        NSString *word = e[@"word"];
        NSString *prov = e[@"provider"];
        NSString *realId = e[@"id"];
        if (word.length && prov.length && realId.length) {
            twab_registerEmoteLocked(word, prov, realId, roomKey,
                                     [e[@"animated"] boolValue], [e[@"ratio"] doubleValue]);
            n++;
        }
    }
    os_log(OS_LOG_DEFAULT, "[TWAB-Emote] cache loaded +%lu %{public}@",
           (unsigned long)n, fileKey);
}

// ─── Emote aspect ratios ───────────────────────────────────────────────────
//
// Width/height of each third-party emote, keyed "provider/id", learned from
// the prefetched thumbnail and persisted so it's known before the first
// message arrives. Wide emotes get a wider slot in the chat line.

extern CGFloat twab_emoteAspectForURL(NSURL *url);

static NSString *twab_ratioPath(void) {
    return [[twab_emoteCacheDir() stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"emote_ratios.plist"];
}

static NSMutableDictionary<NSString *, NSNumber *> *twab_ratioStore(void) {
    static NSMutableDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:twab_ratioPath()];
        m = [disk isKindOfClass:NSDictionary.class] ? [disk mutableCopy] : [NSMutableDictionary dictionary];
    });
    return m;
}

static void twab_setRatio(NSString *key, CGFloat ratio) {
    static BOOL saveScheduled;
    NSMutableDictionary *store = twab_ratioStore();
    @synchronized (store) {
        NSNumber *old = store[key];
        if (old && fabs(old.doubleValue - ratio) < 0.01) return;
        store[key] = @(ratio);
        if (saveScheduled) return;
        saveScheduled = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *snapshot;
        @synchronized (store) { snapshot = [store copy]; saveScheduled = NO; }
        [snapshot writeToFile:twab_ratioPath() atomically:YES];
    });
}

static BOOL twab_hasRatio(NSString *key) {
    NSMutableDictionary *store = twab_ratioStore();
    @synchronized (store) { return store[key] != nil; }
}

// Width/height from API-provided dimensions, or 0 if missing.
static CGFloat twab_ratioFromDims(id w, id h) {
    if (![w isKindOfClass:NSNumber.class] || ![h isKindOfClass:NSNumber.class]) return 0;
    double hv = [h doubleValue];
    return hv > 0 ? [w doubleValue] / hv : 0;
}

static CGFloat twab_imageDataAspect(NSData *data) {
    if (!data.length) return 0;
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!src) return 0;
    NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, NULL));
    CFRelease(src);
    double w = [props[(id)kCGImagePropertyPixelWidth] doubleValue];
    double h = [props[(id)kCGImagePropertyPixelHeight] doubleValue];
    return (w > 0 && h > 0) ? w / h : 0;
}

// Ratio rounded to quarters (what the chat slot uses), or 0 if the emote
// isn't one of ours, isn't known yet, or isn't wide.
CGFloat twab_wideRatioForEmoteId(NSString *fakeId) {
    if (!fakeId.length) return 0;
    NSDictionary *entry = twab_entryForFakeId(fakeId);
    if (!entry) return 0;
    NSString *key = [NSString stringWithFormat:@"%@/%@", entry[@"provider"], entry[@"id"]];
    NSMutableDictionary *store = twab_ratioStore();
    double r;
    @synchronized (store) { r = [store[key] doubleValue]; }
    double q = round(fmin(r, 6.0) * 4.0) / 4.0;
    return q >= 1.25 ? q : 0;
}

static void twab_prefetchThumb(NSString *provider, NSString *realId, BOOL animated) {
    NSURL *url = twab_computeThumbCDNURL(provider, realId, animated);
    if (!url) return;
    [[twab_prefetchSession() dataTaskWithURL:url
                           completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        CGFloat ratio = twab_emoteAspectForURL(url);
        if (ratio <= 0) ratio = twab_imageDataAspect(d);
        if (ratio > 0)
            twab_setRatio([NSString stringWithFormat:@"%@/%@", provider, realId], ratio);
    }] resume];
}

// Register an emote word -> (provider, realId, animated, room). Allocates a
// synthetic id and updates all indexes atomically. First write wins per
// word; later writes with the same word are silently dropped, even from
// a different room. `room` of nil means "global" — never evicted. The
// `animated` flag drives format selection in twab_rewriteEmoteURL —
// animated emotes need .gif on 7TV (only GIF carries animation in the
// renderer); static emotes need .webp (some 7TV emotes lack a GIF
// variant entirely and .gif would 404).
// Caller holds the emote queue's barrier.
static void twab_registerEmoteLocked(NSString *word, NSString *provider,
                                     NSString *realId, NSString *roomKey,
                                     BOOL animated, CGFloat ratio) {
        NSString *wordKey = twab_wordKey(roomKey, word);
        if (twab_byWord()[wordKey]) return;
        NSString *fakeId = twab_stableFakeIdLocked(provider, realId);
        twab_byWord()[wordKey] = @{@"provider": provider,
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
        NSString *ratioKey = [NSString stringWithFormat:@"%@/%@", provider, realId];
        if (ratio > 0) twab_setRatio(ratioKey, ratio);
        else if (!twab_hasRatio(ratioKey)) twab_prefetchThumb(provider, realId, animated);
}

static void twab_registerEmote(NSString *word, NSString *provider,
                               NSString *realId, NSString *room,
                               BOOL animated, CGFloat ratio) {
    if (!word.length || !provider.length || !realId.length) return;
    NSString *roomKey = room.length ? room : TWAB_GLOBAL_ROOM;
    dispatch_barrier_async(twab_emoteQueue(), ^{
        twab_registerEmoteLocked(word, provider, realId, roomKey, animated, ratio);
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
        [twab_roomFakeIds() removeObjectForKey:evicted];
        NSString *prefix = twab_wordKey(evicted, @"");
        for (NSString *k in twab_byWord().allKeys)
            if ([k hasPrefix:prefix]) [twab_byWord() removeObjectForKey:k];
        // IDs are shared between rooms that use the same emote.
        NSMutableSet *stillUsed = [NSMutableSet set];
        for (NSSet *set in twab_roomFakeIds().allValues) [stillUsed unionSet:set];
        for (NSString *fakeId in fakeIds)
            if (![stillUsed containsObject:fakeId]) [twab_byFakeId() removeObjectForKey:fakeId];
        os_log(OS_LOG_DEFAULT,
               "[TWAB-Emote] evicted room=%{public}@ emotes=%lu",
               evicted, (unsigned long)fakeIds.count);
    }
}

// The channel's own emote wins over a global one with the same name.
static NSString *twab_fakeIdForWord_inRoom(NSString *word, NSString *roomId) {
    if (!word.length) return nil;
    __block NSString *result = nil;
    dispatch_sync(twab_emoteQueue(), ^{
        NSDictionary *e = roomId.length ? twab_byWord()[twab_wordKey(roomId, word)] : nil;
        if (!e) e = twab_byWord()[twab_wordKey(TWAB_GLOBAL_ROOM, word)];
        result = e[@"fake"];
    });
    return result;
}

static NSString *twab_fakeIdForWord(NSString *word) {
    return twab_fakeIdForWord_inRoom(word, twab_currentRoom);
}

static NSDictionary *twab_entryForFakeId(NSString *fakeId) {
    __block NSDictionary *result = nil;
    dispatch_sync(twab_emoteQueue(), ^{
        result = twab_byFakeId()[fakeId];
    });
    return result;
}

// ─── Picker support ─────────────────────────────────────────────────────────
//
// The chat emote picker (EmotePicker.x) lists the emotes usable in the
// channel you're watching. "Current room" is the room-id of the most recent
// ROOMSTATE — Twitch sends one on every JOIN, so it tracks channel switches.
// Mutated only under the emote queue's barrier.


// Snapshot of the emotes for the current channel + globals, for the picker.
// Each entry: word, provider, id, animated, channel (BOOL — NO for globals).
// Channel emotes first, then globals; each group sorted case-insensitively.
NSArray<NSDictionary *> *twab_pickerEmotes(void) {
    NSMutableArray *channel = [NSMutableArray array];
    NSMutableArray *global = [NSMutableArray array];
    dispatch_sync(twab_emoteQueue(), ^{
        NSString *room = twab_currentRoom;
        NSMutableSet *ids = [NSMutableSet set];
        if (room) [ids unionSet:twab_roomFakeIds()[room] ?: [NSSet set]];
        [ids unionSet:twab_roomFakeIds()[TWAB_GLOBAL_ROOM] ?: [NSSet set]];
        for (NSString *fakeId in ids) {
            NSDictionary *e = twab_byFakeId()[fakeId];
            if (!e) continue;
            BOOL isChannel = room && [twab_roomFakeIds()[room] containsObject:fakeId];
            NSDictionary *out = @{@"word": e[@"word"],
                                  @"provider": e[@"provider"],
                                  @"id": e[@"id"],
                                  @"animated": e[@"animated"] ?: @NO,
                                  @"channel": @(isChannel)};
            [(isChannel ? channel : global) addObject:out];
        }
    });
    NSSortDescriptor *byWord = [NSSortDescriptor sortDescriptorWithKey:@"word"
        ascending:YES selector:@selector(caseInsensitiveCompare:)];
    NSSet *channelWords = [NSSet setWithArray:[channel valueForKey:@"word"]];
    [global filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *e, id b) {
        return ![channelWords containsObject:e[@"word"]];
    }]];
    [channel sortUsingDescriptors:@[byWord]];
    [global sortUsingDescriptors:@[byWord]];
    return [channel arrayByAddingObjectsFromArray:global];
}

// ─── Twitch emote list ──────────────────────────────────────────────────────
//
// Twitch's chat builds the copy of your own sent message, and its emote
// picker, from the ChatEmoteSets GQL response (your available Twitch emote
// sets). Appending our emotes there as two extra sets (this channel's, and
// globals) makes sent messages show them and lists them in Twitch's picker.
// Our synthetic IDs go through the usual URL rewrite for images.

static NSString *twab_gqlChannelIDForOperation(NSURLRequest *request, NSString *operation, NSInteger *index) {
    if (!request.HTTPBody) return nil;
    id body = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
    NSArray *ops = [body isKindOfClass:NSArray.class] ? body : (body ? @[body] : @[]);
    for (NSInteger i = 0; i < (NSInteger)ops.count; i++) {
        NSDictionary *op = ops[i];
        if (![op isKindOfClass:NSDictionary.class] || ![op[@"operationName"] isEqual:operation]) continue;
        NSDictionary *vars = op[@"variables"];
        if (![vars isKindOfClass:NSDictionary.class]) return nil;
        id cid = vars[@"channelID"];
        if ([cid isKindOfClass:NSNumber.class]) cid = [cid stringValue];
        if (![cid isKindOfClass:NSString.class]) return nil;
        if (index) *index = [body isKindOfClass:NSArray.class] ? i : -1;
        return cid;
    }
    return nil;
}

// Words for `roomKey`: [{word, fake, animated}], sorted case-insensitively.
static NSArray<NSDictionary *> *twab_emotesForRoomLocked(NSString *roomKey) {
    NSString *prefix = twab_wordKey(roomKey, @"");
    NSMutableArray *out = [NSMutableArray array];
    [twab_byWord() enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSDictionary *e, BOOL *stop) {
        if (![k hasPrefix:prefix]) return;
        [out addObject:@{@"word": [k substringFromIndex:prefix.length],
                         @"fake": e[@"fake"], @"animated": e[@"animated"] ?: @NO}];
    }];
    [out sortUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"word" ascending:YES
                                    selector:@selector(caseInsensitiveCompare:)]]];
    return out;
}

static NSMutableDictionary *twab_emoteSetFor(NSArray<NSDictionary *> *emotes, NSString *setID,
                                             NSDictionary *emoteTemplate, NSDictionary *setTemplate,
                                             NSDictionary *owner) {
    NSMutableArray *list = [NSMutableArray arrayWithCapacity:emotes.count];
    for (NSDictionary *e in emotes) {
        NSMutableDictionary *em = emoteTemplate ? [emoteTemplate mutableCopy] : [NSMutableDictionary dictionary];
        em[@"id"] = e[@"fake"];
        em[@"setID"] = setID;
        em[@"token"] = e[@"word"];
        em[@"type"] = @"GLOBALS";
        em[@"assetType"] = [e[@"animated"] boolValue] ? @"ANIMATED" : @"STATIC";
        em[@"modifiers"] = @[];
        [list addObject:em];
    }
    NSMutableDictionary *set = setTemplate ? [setTemplate mutableCopy] : [NSMutableDictionary dictionary];
    set[@"id"] = setID;
    set[@"emotes"] = list;
    set[@"owner"] = owner ?: (id)[NSNull null];
    return set;
}

NSData *twab_injectChatEmoteSets(NSData *data, NSURLRequest *request) {
    if (!data.length || ![tweakDefaults boolForKey:TWABKeyEmotesEnabled]) return data;
    NSInteger index = -1;
    NSString *room = twab_gqlChannelIDForOperation(request, @"ChatEmoteSets", &index);
    if (!room.length) return data;
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    NSMutableDictionary *resp = nil;
    if ([json isKindOfClass:NSArray.class]) {
        if (index >= 0 && index < (NSInteger)[json count]) resp = json[index];
    } else {
        resp = json;
    }
    if (![resp isKindOfClass:NSMutableDictionary.class]) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Sent] emote list not edited: response isn't JSON (index %ld)", (long)index);
        return data;
    }
    id dataObj = resp[@"data"];
    id channelObj = [dataObj isKindOfClass:NSDictionary.class] ? dataObj[@"channel"] : nil;
    NSMutableDictionary *selfObj = [channelObj isKindOfClass:NSDictionary.class] ? channelObj[@"self"] : nil;
    if (![selfObj isKindOfClass:NSMutableDictionary.class]) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Sent] emote list not edited: no channel.self in response");
        return data;
    }
    NSMutableArray *sets = selfObj[@"availableEmoteSets"];
    if (![sets isKindOfClass:NSMutableArray.class]) {
        sets = [NSMutableArray array];
        selfObj[@"availableEmoteSets"] = sets;
    }

    // Make sure the channel's cached emotes are registered before reading.
    twab_loadChannelEmotes(room);
    __block NSArray *channel, *global;
    dispatch_sync(twab_emoteQueue(), ^{
        channel = twab_emotesForRoomLocked(room);
        global = twab_emotesForRoomLocked(TWAB_GLOBAL_ROOM);
    });
    if (!channel.count && !global.count) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Sent] emote list not edited: no 3rd-party emotes registered yet");
        return data;
    }
    NSSet *channelWords = [NSSet setWithArray:[channel valueForKey:@"word"]];
    global = [global filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *e, id b) {
        return ![channelWords containsObject:e[@"word"]];
    }]];

    // Copy the shape (including __typename) of Twitch's own entries.
    NSDictionary *setTemplate = nil, *emoteTemplate = nil, *ownerTemplate = nil;
    NSString *avatar = nil;
    for (NSDictionary *set in sets) {
        if (![set isKindOfClass:NSDictionary.class]) continue;
        if (!setTemplate) setTemplate = set;
        NSArray *ems = set[@"emotes"];
        if (!emoteTemplate && [ems isKindOfClass:NSArray.class] && [ems.firstObject isKindOfClass:NSDictionary.class])
            emoteTemplate = ems.firstObject;
        NSDictionary *own = set[@"owner"];
        if ([own isKindOfClass:NSDictionary.class]) {
            if (!ownerTemplate) ownerTemplate = own;
            if ([own[@"id"] isEqual:room] && [own[@"profileImageURL"] isKindOfClass:NSString.class])
                avatar = own[@"profileImageURL"];
        }
    }
    if (!avatar) avatar = [ownerTemplate[@"profileImageURL"] isKindOfClass:NSString.class] ? ownerTemplate[@"profileImageURL"] : @"";
    NSMutableDictionary *(^makeOwner)(NSString *, NSString *, NSString *) = ^NSMutableDictionary *(NSString *oid, NSString *login, NSString *name) {
        NSMutableDictionary *o = ownerTemplate ? [ownerTemplate mutableCopy] : [NSMutableDictionary dictionary];
        o[@"id"] = oid;
        o[@"login"] = login;
        o[@"displayName"] = name;
        o[@"profileImageURL"] = avatar;
        return o;
    };
    if (channel.count)
        [sets addObject:twab_emoteSetFor(channel, [NSString stringWithFormat:@"twab-channel-%@", room],
                                         emoteTemplate, setTemplate,
                                         makeOwner(@"9000000000", @"twab_channel", @"7TV / BTTV / FFZ Channel"))];
    if (global.count)
        [sets addObject:twab_emoteSetFor(global, @"twab-global", emoteTemplate, setTemplate,
                                         makeOwner(@"9000000001", @"twab_global", @"7TV / BTTV / FFZ Global"))];
    NSData *out = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    if (!out) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Sent] emote list not edited: couldn't re-encode");
        return data;
    }
    os_log(OS_LOG_DEFAULT, "[TWAB-Sent] added %lu channel + %lu global emotes to Twitch's emote list room=%{public}@",
           (unsigned long)channel.count, (unsigned long)global.count, room);
    return out;
}

// ─── Emote loaders ──────────────────────────────────────────────────────────

// Loader helpers are deliberately defensive — third-party JSON shapes can
// drift without notice. Every container access is type-guarded so a
// surprise null/array/string at any level fails the request rather than
// crashing the chat thread.

static void twab_load7TVSet(NSString *url, NSString *room) {
    [[twab_emoteAPISession() dataTaskWithURL:[NSURL URLWithString:url]
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
        NSString *roomKey = room.length ? room : TWAB_GLOBAL_ROOM;
        NSMutableArray *cacheEntries = [NSMutableArray array];
        NSUInteger n = 0;
        for (id em in emotes) {
            if (![em isKindOfClass:NSDictionary.class]) continue;
            NSString *name = em[@"name"];
            NSString *eid = em[@"id"];
            BOOL animated = NO;
            CGFloat ratio = 0;
            id data = em[@"data"];
            if ([data isKindOfClass:NSDictionary.class]) {
                id a = ((NSDictionary *)data)[@"animated"];
                if ([a isKindOfClass:NSNumber.class]) animated = [a boolValue];
                id host = ((NSDictionary *)data)[@"host"];
                id files = [host isKindOfClass:NSDictionary.class] ? ((NSDictionary *)host)[@"files"] : nil;
                id f0 = [files isKindOfClass:NSArray.class] ? [(NSArray *)files firstObject] : nil;
                if ([f0 isKindOfClass:NSDictionary.class])
                    ratio = twab_ratioFromDims(f0[@"width"], f0[@"height"]);
            }
            if ([name isKindOfClass:NSString.class] && name.length &&
                [eid isKindOfClass:NSString.class] && eid.length) {
                twab_registerEmote(name, @"7tv", eid, room, animated, ratio);
                [cacheEntries addObject:@{@"word": name, @"provider": @"7tv",
                                          @"id": eid, @"animated": @(animated),
                                          @"ratio": @(ratio)}];
                n++;
            }
        }
        if (cacheEntries.count)
            twab_saveEmotesToDisk([NSString stringWithFormat:@"%@_7tv", roomKey], cacheEntries);
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] 7TV +%lu %{public}@", (unsigned long)n, url);
    }] resume];
}

static void twab_loadBTTVChannel(NSString *roomId) {
    if (!roomId.length) return;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://api.betterttv.net/3/cached/users/twitch/%@", roomId]];
    [[twab_emoteAPISession() dataTaskWithURL:url
                              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e || !d) {
            os_log_error(OS_LOG_DEFAULT, "[TWAB-Emote] BTTV channel fetch failed room=%{public}@ err=%{public}@",
                         roomId, e.localizedDescription);
            return;
        }
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![j isKindOfClass:NSDictionary.class]) return;
        NSMutableArray *cacheEntries = [NSMutableArray array];
        NSUInteger n = 0;
        for (NSString *key in @[ @"channelEmotes", @"sharedEmotes" ]) {
            id arr = j[key];
            if (![arr isKindOfClass:NSArray.class]) continue;
            for (id em in arr) {
                if (![em isKindOfClass:NSDictionary.class]) continue;
                NSString *code = em[@"code"];
                NSString *eid = em[@"id"];
                NSString *imgType = em[@"imageType"];
                BOOL animated = [imgType isKindOfClass:NSString.class] &&
                                [imgType isEqualToString:@"gif"];
                if ([code isKindOfClass:NSString.class] && code.length &&
                    [eid isKindOfClass:NSString.class] && eid.length) {
                    CGFloat ratio = twab_ratioFromDims(em[@"width"], em[@"height"]);
                    twab_registerEmote(code, @"bttv", eid, roomId, animated, ratio);
                    [cacheEntries addObject:@{@"word": code, @"provider": @"bttv",
                                              @"id": eid, @"animated": @(animated),
                                              @"ratio": @(ratio)}];
                    n++;
                }
            }
        }
        if (cacheEntries.count)
            twab_saveEmotesToDisk([NSString stringWithFormat:@"%@_bttv", roomId], cacheEntries);
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] BTTV channel +%lu room=%{public}@",
               (unsigned long)n, roomId);
    }] resume];
}

static void twab_loadBTTVGlobal(void) {
    NSURL *url = [NSURL URLWithString:@"https://api.betterttv.net/3/cached/emotes/global"];
    [[twab_emoteAPISession() dataTaskWithURL:url
                              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (e || !d) {
            os_log_error(OS_LOG_DEFAULT, "[TWAB-Emote] BTTV global fetch failed err=%{public}@",
                         e.localizedDescription);
            return;
        }
        id list = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![list isKindOfClass:NSArray.class]) return;
        NSMutableArray *cacheEntries = [NSMutableArray array];
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
                CGFloat ratio = twab_ratioFromDims(em[@"width"], em[@"height"]);
                twab_registerEmote(code, @"bttv", eid, nil, animated, ratio);
                [cacheEntries addObject:@{@"word": code, @"provider": @"bttv",
                                          @"id": eid, @"animated": @(animated),
                                          @"ratio": @(ratio)}];
                n++;
            }
        }
        if (cacheEntries.count)
            twab_saveEmotesToDisk(@"__global___bttv", cacheEntries);
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] BTTV global +%lu", (unsigned long)n);
    }] resume];
}

static void twab_loadFFZSet(NSString *url, NSString *room) {
    [[twab_emoteAPISession() dataTaskWithURL:[NSURL URLWithString:url]
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
        NSString *roomKey = room.length ? room : TWAB_GLOBAL_ROOM;
        NSMutableArray *cacheEntries = [NSMutableArray array];
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
                id animatedDict = em[@"animated"];
                BOOL animated = [animatedDict isKindOfClass:NSDictionary.class] &&
                                ((NSDictionary *)animatedDict).count > 0;
                if ([name isKindOfClass:NSString.class] && name.length &&
                    [idNum isKindOfClass:NSNumber.class]) {
                    CGFloat ratio = twab_ratioFromDims(em[@"width"], em[@"height"]);
                    twab_registerEmote(name, @"ffz", idNum.stringValue, room, animated, ratio);
                    [cacheEntries addObject:@{@"word": name, @"provider": @"ffz",
                                              @"id": idNum.stringValue, @"animated": @(animated),
                                              @"ratio": @(ratio)}];
                    n++;
                }
            }
        }
        if (cacheEntries.count)
            twab_saveEmotesToDisk([NSString stringWithFormat:@"%@_ffz", roomKey], cacheEntries);
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] FFZ +%lu %{public}@", (unsigned long)n, url);
    }] resume];
}

// Fetch global emote sets — called once at startup. Loads from disk cache
// first for instant availability, then refreshes from APIs in background.
static void twab_loadGlobalEmotes(void) {
    dispatch_barrier_async(twab_emoteQueue(), ^{
        for (NSString *prov in @[@"7tv", @"bttv", @"ffz"])
            twab_registerCachedEmotesLocked(TWAB_GLOBAL_ROOM, prov);
    });
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
        for (NSString *prov in @[@"7tv", @"bttv", @"ffz"])
            twab_registerCachedEmotesLocked(room, prov);
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
        NSString *cacheDir = twab_emoteCacheDir();
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:cacheDir error:nil];
        for (NSString *f in files)
            [[NSFileManager defaultManager] removeItemAtPath:
                [cacheDir stringByAppendingPathComponent:f] error:nil];
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] registry + cache cleared by user reload");
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
    // WebP throughout: an animated emote's GIF is often 300-600 KB, its WebP
    // a fraction of that. Tweak.x converts animated WebP to GIF on arrival.
    if ([provider isEqualToString:@"7tv"])
        return [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.7tv.app/emote/%@/2x.webp", realId]];
    if ([provider isEqualToString:@"bttv"])
        return [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.betterttv.net/emote/%@/2x.webp", realId]];
    if ([provider isEqualToString:@"ffz"]) {
        if (animated)
            return [NSURL URLWithString:[NSString stringWithFormat:
                @"https://cdn.frankerfacez.com/emote/%@/animated/2.webp", realId]];
        return [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.frankerfacez.com/emote/%@/2", realId]];
    }
    return nil;
}

// Thumbnail CDN URL — 1x for the picker (cells are 36pt; 1x is sharp enough
// and loads ~4× faster on congested CDNs like 7TV during big game launches).
static NSURL *twab_computeThumbCDNURL(NSString *provider, NSString *realId, BOOL animated) {
    if ([provider isEqualToString:@"7tv"]) {
        NSString *ext = animated ? @"gif" : @"webp";
        return [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.7tv.app/emote/%@/1x.%@", realId, ext]];
    }
    if ([provider isEqualToString:@"bttv"])
        return [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.betterttv.net/emote/%@/1x", realId]];
    if ([provider isEqualToString:@"ffz"]) {
        if (animated)
            return [NSURL URLWithString:[NSString stringWithFormat:
                @"https://cdn.frankerfacez.com/emote/%@/animated/1.gif", realId]];
        return [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.frankerfacez.com/emote/%@/1", realId]];
    }
    return nil;
}

NSURL *twab_pickerImageURL(NSDictionary *emote) {
    NSNumber *animBox = emote[@"animated"];
    BOOL animated = [animBox isKindOfClass:NSNumber.class] && [animBox boolValue];
    return twab_computeThumbCDNURL(emote[@"provider"], emote[@"id"], animated);
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

// For Tweak.x's completion-handler hook (used by native views such as the
// chat box's emote preview).
NSURL *twab_realEmoteURL(NSURL *url) {
    if (![tweakDefaults boolForKey:TWABKeyEmotesEnabled]) return nil;
    NSURL *real = twab_rewriteEmoteURL(url);
    if (real) twab_emoteNetStart(real);
    return real;
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

    // Emote URL capture — log each distinct emoticons/v2/ URL for OUR
    // synthetic 3rd-party emote IDs (≥ 9,000,000,000), deduped. Twitch's
    // own emote URLs used to be logged too, which flooded the log.
    NSString *_path = request.URL.path;
    NSArray<NSString *> *_parts = request.URL.pathComponents;
    if (_path && [_path containsString:@"emoticons/v2/"] && _parts.count > 3 &&
        _parts[3].longLongValue >= 9000000000LL) {
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
        twab_noteSentChatRequest(request);
        NSURL *real = twab_rewriteEmoteURL(request.URL);
        if (real) {
            twab_emoteNetStart(real);
            if (![request isKindOfClass:NSMutableURLRequest.class]) request = request.mutableCopy;
            ((NSMutableURLRequest *)request).URL = real;
            return %orig(request);
        }
    }

    BOOL proxyEnabled = adBlockOn && [tweakDefaults boolForKey:TWABKeyAdBlockProxyEnabled];
    NSArray<NSString *> *proxyAddrs = proxyEnabled ? twab_effectiveProxyAddresses() : @[];
    BOOL isMasterPlaylist = twab_isMasterPlaylistHost(request.URL.host);
    // Other API requests go direct, so content settings follow the viewer.
    BOOL isGql = [request.URL.host isEqualToString:@"gql.twitch.tv"] &&
                 twab_isAccessTokenRequest(request);
    // Proxy variant playlists (.m3u8) and video-weaver hosts but NOT
    // raw .ts segment fetches — those are bulk video data that would
    // kill throughput if tunnelled through the proxy.
    BOOL isPlaylistOrWeaver = NO;
    if (!isMasterPlaylist && !isGql && twab_isPlaylistHost(request.URL.host)) {
        NSString *lastComp = request.URL.lastPathComponent;
        isPlaylistOrWeaver = [lastComp hasSuffix:@".m3u8"] ||
            [request.URL.host containsString:@"video-weaver"];
    }

    // Route ad-related requests through the proxy.
    if ((isMasterPlaylist || isGql || isPlaylistOrWeaver) && proxyAddrs.count && !twab_isExternalPlayback()) {
        if (isMasterPlaylist) {
            os_log(OS_LOG_DEFAULT,
                "[TWAB-URL] master playlist seen host=%{public}@ proxyEnabled=%d proxies=%lu",
                request.URL.host, proxyEnabled, (unsigned long)proxyAddrs.count);
        }

        if (isMasterPlaylist && twab_userIsAdExempt(request.URL.query)) {
            os_log(OS_LOG_DEFAULT,
                "[TWAB-URL] subscriber/turbo detected — skipping proxy host=%{public}@",
                request.URL.host);
        } else if (isMasterPlaylist && twab_channelIsWhitelisted(request.URL)) {
            os_log(OS_LOG_DEFAULT,
                "[TWAB-URL] whitelisted channel — skipping proxy path=%{public}@",
                request.URL.path);
        } else {
            // Try Luminous URL rewrite (master playlist only).
            BOOL rewrote = NO;
            if (isMasterPlaylist) {
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
                        NSString *auth = twab_basicAuthHeader(proxyURL);
                        if (auth) [(NSMutableURLRequest *)request setValue:auth forHTTPHeaderField:@"Authorization"];
                        rewrote = YES;
                        break;
                    }
                }
            }

            if (!rewrote) {
                // HTTP CONNECT proxy fallback — used for both master
                // playlist (when not Luminous) and GQL requests.
                // The pool picks among the configured proxies (spread by
                // speed, sticky, steps around ones that fail).
                NSMutableArray<NSString *> *validAddrs = [NSMutableArray array];
                for (NSString *a in proxyAddrs) {
                    if (twab_normalizedProxyURL(a)) [validAddrs addObject:a];
                }
                NSString *connectAddr = twab_proxyPoolPick(validAddrs);
                if (connectAddr) {
                    static char sharedProxySessionKey, sharedProxyAddressKey;
                    NSURLSession *proxySession = nil;
                    @synchronized (self) {
                        NSString *sessionAddress = objc_getAssociatedObject(self, &sharedProxyAddressKey);
                        proxySession = [sessionAddress isEqualToString:connectAddr]
                            ? objc_getAssociatedObject(self, &sharedProxySessionKey) : nil;
                        if (!proxySession) {
                            // Switching proxy: let the old session finish its
                            // tasks, then free it.
                            [(NSURLSession *)objc_getAssociatedObject(self, &sharedProxySessionKey)
                                finishTasksAndInvalidate];
                            proxySession = [(NSURLSession *)self twab_proxySessionWithAddress:connectAddr];
                            objc_setAssociatedObject(self, &sharedProxySessionKey, proxySession,
                                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            objc_setAssociatedObject(self, &sharedProxyAddressKey, connectAddr,
                                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
                        }
                    }
                    if (proxySession) {
                        if (isMasterPlaylist && request.URL.query.length) {
                            NSURLComponents *uc = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
                            NSMutableArray *qi = [uc.queryItems mutableCopy];
                            NSUInteger before = qi.count;
                            [qi filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURLQueryItem *item, NSDictionary *b) {
                                return ![item.name isEqualToString:@"play_session_id"];
                            }]];
                            if (qi.count < before) {
                                uc.queryItems = qi.count ? qi : nil;
                                if (![request isKindOfClass:NSMutableURLRequest.class]) request = request.mutableCopy;
                                ((NSMutableURLRequest *)request).URL = uc.URL;
                                os_log(OS_LOG_DEFAULT, "[TWAB-URL] stripped play_session_id from CONNECT path");
                            }
                        }
                        _td[@"twab_inProxyDispatch"] = @YES;
                        NSURLSessionDataTask *task = [proxySession dataTaskWithRequest:request];
                        _td[@"twab_inProxyDispatch"] = nil;
                        if (task) {
                            static char proxySessionKey;
                            objc_setAssociatedObject(task, &proxySessionKey, proxySession,
                                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                            os_log(OS_LOG_DEFAULT,
                                "[TWAB-URL] routed %{public}@ via HTTP CONNECT proxy host=%{public}@",
                                isMasterPlaylist ? @"master playlist" : isGql ? @"GQL" : @"playlist/weaver",
                                request.URL.host);
                            if ((isMasterPlaylist || isPlaylistOrWeaver) &&
                                [NSStringFromClass([((NSURLSession *)self).delegate class]) isEqualToString:@"IVSPlayerURLSessionDelegate"])
                                return twab_playerTaskForProxiedTask(task);
                            return task;
                        }
                    }
                }
                os_log(OS_LOG_DEFAULT,
                    "[TWAB-URL] %{public}@ NOT routed host=%{public}@",
                    isMasterPlaylist ? @"master playlist" : isGql ? @"GQL" : @"playlist/weaver",
                    request.URL.host);
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
static NSString *twab_myDisplayName;  // from USERSTATE / GLOBALUSERSTATE

static void twab_observeIRCLine(NSString *line) {
    if (![line hasPrefix:@"@"]) return;
    if ([line containsString:@" USERSTATE #"] || [line containsString:@" GLOBALUSERSTATE"]) {
        NSRange te = [line rangeOfString:@" :"];
        NSString *name = te.location != NSNotFound
            ? twab_extractTag([line substringToIndex:te.location], @"display-name") : nil;
        if (name.length) twab_myDisplayName = [name copy];
        return;
    }
    if (![line containsString:@" ROOMSTATE #"]) return;
    NSRange tagsEnd = [line rangeOfString:@" :"];
    if (tagsEnd.location == NSNotFound) return;
    NSString *tagsPart = [line substringToIndex:tagsEnd.location];
    NSString *roomId = twab_extractTag(tagsPart, @"room-id");
    if (!roomId.length) return;
    NSString *room = [roomId copy];
    dispatch_barrier_async(twab_emoteQueue(), ^{ twab_currentRoom = room; });
    twab_loadChannelEmotes(room);
}

// Shift Twitch's own emote ranges ("id:s-e,s-e/id:s-e") to account for
// marker text inserted at the given original code-point positions.
static NSString *twab_shiftEmoteRanges(NSString *value, NSArray<NSArray<NSNumber *> *> *inserts) {
    NSMutableArray *outGroups = [NSMutableArray array];
    for (NSString *group in [value componentsSeparatedByString:@"/"]) {
        NSRange colon = [group rangeOfString:@":"];
        if (colon.location == NSNotFound) { [outGroups addObject:group]; continue; }
        NSString *eid = [group substringToIndex:colon.location];
        NSMutableArray *ranges = [NSMutableArray array];
        for (NSString *r in [[group substringFromIndex:colon.location + 1] componentsSeparatedByString:@","]) {
            NSArray *se = [r componentsSeparatedByString:@"-"];
            if (se.count != 2) { [ranges addObject:r]; continue; }
            NSInteger st = [se[0] integerValue], en = [se[1] integerValue], d = 0;
            for (NSArray<NSNumber *> *ins in inserts)
                if (ins[0].integerValue <= st) d += ins[1].integerValue;
            [ranges addObject:[NSString stringWithFormat:@"%ld-%ld", (long)(st + d), (long)(en + d)]];
        }
        [outGroups addObject:[NSString stringWithFormat:@"%@:%@", eid, [ranges componentsJoinedByString:@","]]];
    }
    return [outGroups componentsJoinedByString:@"/"];
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
    if (roomId.length) {
        __block NSUInteger roomCount = 0;
        dispatch_sync(twab_emoteQueue(), ^{ roomCount = twab_roomFakeIds()[roomId].count; });
        static CFAbsoluteTime lastWarn;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (!roomCount && now - lastWarn > 2) {
            lastWarn = now;
            os_log(OS_LOG_DEFAULT, "[TWAB-EmoteMsg] message arrived before this channel's emotes were loaded room=%{public}@", roomId);
        }
    }

    // Scan words for matches. Positions are code-point-based, so we track a
    // grapheme-cluster cursor separately from any UTF-16 indexing.
    // Room-aware: channel emotes first, then globals.
    // Wide emotes also get an invisible marker inserted before the word (see
    // twab_markWideEmotes); later emote positions shift by its length.
    BOOL markWide = [tweakDefaults boolForKey:TWABKeyFitWideEmotes];
    NSMutableArray<NSString *> *newEntries = [NSMutableArray array];
    NSMutableArray<NSString *> *outWords = [NSMutableArray array];
    NSMutableArray<NSArray<NSNumber *> *> *inserts = [NSMutableArray array];  // [origPos, len]
    NSArray<NSString *> *words = [text componentsSeparatedByString:@" "];
    NSUInteger codePos = 0, shift = 0;
    for (NSString *word in words) {
        NSUInteger wordLen = twab_charCount(word, NSMakeRange(0, word.length));
        NSString *fakeId = wordLen ? twab_fakeIdForWord_inRoom(word, roomId) : nil;
        NSString *outWord = word;
        if (fakeId) {
            CGFloat q = markWide ? twab_wideRatioForEmoteId(fakeId) : 0;
            if (q > 0) {
                NSUInteger n = (NSUInteger)lround(q * 4.0);
                NSMutableString *mark = [NSMutableString stringWithString:[NSString stringWithFormat:@"%C", (unichar)0x2063]];
                for (NSUInteger k = 0; k < n; k++) [mark appendString:[NSString stringWithFormat:@"%C", (unichar)0x2064]];
                outWord = [mark stringByAppendingString:word];
                [inserts addObject:@[@(codePos), @(n + 1)]];
                shift += n + 1;
            }
            NSUInteger start = codePos + shift;
            [newEntries addObject:[NSString stringWithFormat:@"%@:%lu-%lu",
                                   fakeId, (unsigned long)start,
                                   (unsigned long)(start + wordLen - 1)]];
        }
        [outWords addObject:outWord];
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
        if (inserts.count && existing.length) existing = twab_shiftEmoteRanges(existing, inserts);
        NSString *newVal = existing.length
            ? [existing stringByAppendingFormat:@"/%@", combined]
            : combined;
        newTags = [NSString stringWithFormat:@"%@emotes=%@%@",
                   [tagsPart substringToIndex:emotesTag.location],
                   newVal,
                   [tagsPart substringFromIndex:valEnd]];
    }

    if (inserts.count) {
        NSString *prefix = [line substringWithRange:NSMakeRange(tagsEnd.location,
                                                                textStart - tagsEnd.location)];
        return [NSString stringWithFormat:@"%@%@%@", newTags, prefix,
                [outWords componentsJoinedByString:@" "]];
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

// ─── Keep Deleted Messages ───────────────────────────────────────────────────
// A moderator deleting a message arrives as CLEARMSG (target-msg-id); a
// timeout / ban as CLEARCHAT with a target user (ban-duration present for
// timeouts); a full chat clear as CLEARCHAT with no user. With the setting
// on, these never reach Twitch's chat — so nothing gets removed — and a
// NOTICE system line saying what happened takes their place.
static NSString *twab_formatDuration(NSInteger secs) {
    if (secs < 60) return [NSString stringWithFormat:@"%lds", (long)secs];
    if (secs < 3600) return [NSString stringWithFormat:@"%ldm", (long)(secs / 60)];
    if (secs < 86400) return [NSString stringWithFormat:@"%ldh", (long)(secs / 3600)];
    return [NSString stringWithFormat:@"%ldd", (long)(secs / 86400)];
}

// Returns the NOTICE line replacing a moderation command, or nil if `line`
// isn't one.
static NSString *twab_moderationNotice(NSString *line) {
    NSString *tags = @"", *rest = line;
    if ([line hasPrefix:@"@"]) {
        NSRange sp = [line rangeOfString:@" "];
        if (sp.location == NSNotFound) return nil;
        tags = [line substringWithRange:NSMakeRange(1, sp.location - 1)];
        rest = [line substringFromIndex:sp.location + 1];
    }
    BOOL isMsg = [rest rangeOfString:@" CLEARMSG #"].location != NSNotFound;
    BOOL isChat = !isMsg && [rest rangeOfString:@" CLEARCHAT #"].location != NSNotFound;
    if (!isMsg && !isChat) return nil;

    NSString *cmd = isMsg ? @" CLEARMSG #" : @" CLEARCHAT #";
    NSString *afterCmd = [rest substringFromIndex:NSMaxRange([rest rangeOfString:cmd])];
    NSRange colon = [afterCmd rangeOfString:@" :"];
    NSString *channel = colon.location == NSNotFound ? afterCmd : [afterCmd substringToIndex:colon.location];
    NSString *trailing = colon.location == NSNotFound ? nil : [afterCmd substringFromIndex:NSMaxRange(colon)];
    channel = [channel stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!channel.length) return nil;

    NSString *text;
    if (isMsg) {
        NSString *login = twab_extractTag(tags, @"login") ?: @"someone";
        NSString *msg = trailing ?: @"";
        if (msg.length > 200) msg = [[msg substringToIndex:200] stringByAppendingString:@"…"];
        text = msg.length ? [NSString stringWithFormat:@"🛡 %@'s message was deleted: %@", login, msg]
                          : [NSString stringWithFormat:@"🛡 A message from %@ was deleted", login];
    } else if (trailing.length) {
        NSString *dur = twab_extractTag(tags, @"ban-duration");
        text = dur.length ? [NSString stringWithFormat:@"🛡 %@ was timed out for %@", trailing,
                                twab_formatDuration(dur.integerValue)]
                          : [NSString stringWithFormat:@"🛡 %@ was banned", trailing];
    } else {
        text = @"🛡 Chat was cleared by a moderator";
    }
    os_log(OS_LOG_DEFAULT, "[TWAB-Deleted] kept messages: %{public}@", text);
    // Sent as a chat message from "TwitchMods" tagged msg-id=highlighted-message,
    // so Twitch draws it with the channel-points "Highlight My Message"
    // background — it stands out from normal chat. (A plain NOTICE rendered,
    // but with no background.) room-id / timestamp come from the moderation
    // command; the user-id is a fixed placeholder no real account uses.
    // Settings → "Highlight Notes" off: plain system line, no background.
    if (![tweakDefaults boolForKey:TWABKeyHighlightDeletedNotes])
        return [NSString stringWithFormat:@"@msg-id=twab_moderation :tmi.twitch.tv NOTICE #%@ :%@", channel, text];
    NSString *roomID = twab_extractTag(tags, @"room-id") ?: @"";
    NSString *ts = twab_extractTag(tags, @"tmi-sent-ts") ?:
        [NSString stringWithFormat:@"%lld", (long long)(NSDate.date.timeIntervalSince1970 * 1000)];
    return [NSString stringWithFormat:
        @"@badge-info=;badges=;color=#9146FF;display-name=TwitchMods;emotes=;first-msg=0;flags=;"
        @"id=%@;mod=0;msg-id=highlighted-message;returning-chatter=0;room-id=%@;subscriber=0;"
        @"tmi-sent-ts=%@;turbo=0;user-id=9999999999;user-type= "
        @":twitchmods!twitchmods@twitchmods.tmi.twitch.tv PRIVMSG #%@ :%@",
        NSUUID.UUID.UUIDString.lowercaseString, roomID, ts, channel, text];
}

// Filter Hermes PubSub notification frames that deliver community highlight
// data (predictions, polls, hype trains) via WebSocket. Returns a replacement
// frame to suppress the notification, or nil to pass the original through.
static NSString *twab_filterHermesNotification(NSString *frame) {
    if (!frame.length || [frame characterAtIndex:0] != '{') return nil;
    if (![tweakDefaults boolForKey:TWABKeyHideCommunityHighlights]) return nil;

    NSRange notifRange = [frame rangeOfString:@"\"notification\""];
    if (notifRange.location == NSNotFound) return nil;
    NSRange pubsubRange = [frame rangeOfString:@"\"pubsub\""];
    if (pubsubRange.location == NSNotFound) return nil;

    NSData *data = [frame dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) return nil;

    NSDictionary *notif = json[@"notification"];
    if (![notif isKindOfClass:NSDictionary.class]) return nil;
    if (![@"pubsub" isEqualToString:notif[@"type"]]) return nil;

    NSString *pubsub = notif[@"pubsub"];
    if (![pubsub isKindOfClass:NSString.class] || !pubsub.length) return nil;

    if ([tweakDefaults boolForKey:TWABKeyHidePredictions] &&
        [pubsub rangeOfString:@"\"outcomes\""].location != NSNotFound &&
        [pubsub rangeOfString:@"\"color\""].location != NSNotFound) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Hide] dropped prediction WS notification");
        return @"{\"type\":\"keepalive\"}";
    }

    if ([tweakDefaults boolForKey:TWABKeyHidePolls] &&
        [pubsub rangeOfString:@"\"poll\"" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Hide] dropped poll WS notification");
        return @"{\"type\":\"keepalive\"}";
    }

    if ([tweakDefaults boolForKey:TWABKeyHideHypeTrains] &&
        ([pubsub rangeOfString:@"\"hype-train\"" options:NSCaseInsensitiveSearch].location != NSNotFound ||
         [pubsub rangeOfString:@"\"hype_train\"" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Hide] dropped hype train WS notification");
        return @"{\"type\":\"keepalive\"}";
    }

    if ([tweakDefaults boolForKey:TWABKeyHideDrops] &&
        [pubsub rangeOfString:@"\"drop\"" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Hide] dropped drops WS notification");
        return @"{\"type\":\"keepalive\"}";
    }

    return nil;
}

// Rewrite one received chat text frame (one or more CRLF-separated IRC
// lines). Returns the rewritten frame, or nil to deliver the original.
// Shared by the native chat socket (NSURLSessionWebSocketTask) and the React
// Native chat socket (SocketRocket, Twitch 31.x+). `path` is only for a
// one-time log naming which chat implementation is live.
static NSString *twab_rewriteIRCFrame(NSString *s, const char *path) {
    twab_pointsCheckFrame(s);
    BOOL emotes = [tweakDefaults boolForKey:TWABKeyEmotesEnabled];
    BOOL keepDeleted = [tweakDefaults boolForKey:TWABKeyKeepDeletedMessages];
    static int lastState = -1;
    if (lastState != (int)keepDeleted) {
        lastState = (int)keepDeleted;
        os_log(OS_LOG_DEFAULT, "[TWAB-Deleted] Keep Deleted Messages is %{public}s", keepDeleted ? "ON" : "OFF");
    }
    if ((!emotes && !keepDeleted) || !s.length) return nil;
    // Fast bail for non-IRC frames. Twitch IRC lines always start with
    // `@` (tagged), `:` (prefixed), or a command word — for the chat
    // socket that's PING/PONG. Anything else is a different protocol
    // (e.g., a pubsub or graphql subscription frame) and shouldn't be
    // split-by-CRLF or scanned for emote tokens.
    unichar first = [s characterAtIndex:0];
    if (first != '@' && first != ':' && first != 'P') return nil;

    static NSMutableSet *loggedPaths;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ loggedPaths = [NSMutableSet set]; });
    NSString *pathKey = @(path);
    @synchronized (loggedPaths) {
        if (![loggedPaths containsObject:pathKey]) {
            [loggedPaths addObject:pathKey];
            os_log(OS_LOG_DEFAULT, "[TWAB-Chat] IRC frames arriving via %{public}s", path);
            twab_setupTokenizerHook();
        }
    }

    NSArray<NSString *> *lines = [s componentsSeparatedByString:@"\r\n"];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:lines.count];
    BOOL changed = NO;
    for (NSString *line in lines) {
        NSString *notice = keepDeleted ? twab_moderationNotice(line) : nil;
        if (notice) { [out addObject:notice]; changed = YES; continue; }
        if (!emotes) { [out addObject:line]; continue; }
        twab_observeIRCLine(line);  // ROOMSTATE preload
        NSString *mod = twab_injectIRCEmotes(line);
        if (mod) { [out addObject:mod]; changed = YES; }
        else     { [out addObject:line]; }
    }
    return changed ? [out componentsJoinedByString:@"\r\n"] : nil;
}

static twab_recvHandler twab_wrapHandler(twab_recvHandler h) {
    if (!h) return h;
    if (objc_getAssociatedObject(h, &twab_handlerWrappedKey)) return h;
    twab_recvHandler wrapped = ^(NSURLSessionWebSocketMessage *msg, NSError *err) {
        if (msg.type == NSURLSessionWebSocketMessageTypeString) {
            NSString *filtered = twab_filterHermesNotification(msg.string);
            if (filtered) {
                h([[NSURLSessionWebSocketMessage alloc] initWithString:filtered], err);
                return;
            }
        }
        NSString *rewritten = (msg.type == NSURLSessionWebSocketMessageTypeString)
            ? twab_rewriteIRCFrame(msg.string, "native chat (NSURLSessionWebSocketTask)") : nil;
        h(rewritten ? [[NSURLSessionWebSocketMessage alloc] initWithString:rewritten] : msg, err);
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

// Twitch 31.x ships a React Native chat that connects to irc-ws.chat.twitch.tv
// through React Native's WebSocket module, which uses SocketRocket rather than
// NSURLSessionWebSocketTask. SocketRocket hands each text frame to its delegate
// (RCTWebSocketModule) via -webSocket:didReceiveMessageWithString: if the
// delegate implements it, else -webSocket:didReceiveMessage:. Each selector is
// its own group, installed only when RCTWebSocketModule itself implements it —
// adding a method it lacks would change which one SocketRocket calls.
%group RNWSString
%hook RCTWebSocketModule
- (void)webSocket:(id)webSocket didReceiveMessageWithString:(NSString *)string {
    if ([string isKindOfClass:NSString.class]) {
        NSString *filtered = twab_filterHermesNotification(string);
        if (filtered) { %orig(webSocket, filtered); return; }
    }
    NSString *rewritten = [string isKindOfClass:NSString.class]
        ? twab_rewriteIRCFrame(string, "React Native chat (SocketRocket)") : nil;
    %orig(webSocket, rewritten ?: string);
}
%end
%end

%group RNWSAny
%hook RCTWebSocketModule
- (void)webSocket:(id)webSocket didReceiveMessage:(id)message {
    if ([message isKindOfClass:NSString.class]) {
        NSString *filtered = twab_filterHermesNotification(message);
        if (filtered) { %orig(webSocket, filtered); return; }
    }
    NSString *rewritten = [message isKindOfClass:NSString.class]
        ? twab_rewriteIRCFrame(message, "React Native chat (SocketRocket)") : nil;
    %orig(webSocket, rewritten ?: message);
}
%end
%end

// ─── Tokenizer hook (local echo emotes) ─────────────────────────────────────
// The KMP tokenizer creates the message token array for display. For the
// user's own messages (local echo), only Twitch-native emotes appear in the
// sortedEmoteRanges input. By post-processing the output, we split text
// tokens that contain 7TV/BTTV/FFZ emote names into emote tokens with our
// synthetic IDs, so the local echo renders third-party emotes immediately.
// For other users' messages, the IRC-level injection already adds our emote
// IDs to the emotes= tag, so those words are already EmoteTokens and the
// post-processing is a no-op.

static NSArray *twab_injectEmoteTokens(NSArray *tokens) {
    static Class textTokenCls, emoteTokenCls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        textTokenCls  = objc_getClass("KMPMCMessageTokenTextToken");
        emoteTokenCls = objc_getClass("KMPMCMessageTokenEmoteToken");
    });
    if (!textTokenCls || !emoteTokenCls) return tokens;

    NSMutableArray *result = nil;
    NSString *room = twab_currentRoom;

    for (NSUInteger i = 0; i < tokens.count; i++) {
        id token = tokens[i];
        if (![token isKindOfClass:textTokenCls]) {
            if (result) [result addObject:token];
            continue;
        }

        NSString *text = nil;
        @try { text = [token performSelector:@selector(text)]; } @catch (id e) {}
        if (!text.length) {
            if (result) [result addObject:token];
            continue;
        }

        // Quick scan: does any word match a third-party emote?
        NSArray<NSString *> *words = [text componentsSeparatedByString:@" "];
        BOOL hasEmote = NO;
        for (NSString *w in words) {
            if (!w.length) continue;
            NSString *fid = room.length ? twab_fakeIdForWord_inRoom(w, room)
                                        : twab_fakeIdForWord(w);
            if (fid) { hasEmote = YES; break; }
        }
        if (!hasEmote) {
            if (result) [result addObject:token];
            continue;
        }

        // Lazy-init result array with everything before this token
        if (!result) {
            result = [NSMutableArray arrayWithCapacity:tokens.count + 8];
            for (NSUInteger j = 0; j < i; j++)
                [result addObject:tokens[j]];
        }

        // Extract flags from the original text token for new text tokens
        id flags = nil;
        @try { flags = [token valueForKey:@"flags"]; } @catch (id e) {}

        // Build position list of emote matches
        NSMutableArray *ranges = [NSMutableArray array];
        NSUInteger pos = 0;
        for (NSString *w in words) {
            if (w.length) {
                NSString *fid = room.length ? twab_fakeIdForWord_inRoom(w, room)
                                            : twab_fakeIdForWord(w);
                if (fid) {
                    [ranges addObject:@{@"s": @(pos), @"e": @(pos + w.length),
                                        @"fid": fid, @"w": w}];
                }
            }
            pos += w.length + 1;
        }

        // Split the text token around matched emotes.
        // Use objc_msgSend since these are KMP-generated classes without
        // compile-time declarations.
        SEL textInitSel  = @selector(initWithText:flags:);
        SEL emoteInitSel = @selector(initWithText:id:);
        NSUInteger cursor = 0;
        for (NSDictionary *m in ranges) {
            NSUInteger s = [m[@"s"] unsignedIntegerValue];
            NSUInteger e = [m[@"e"] unsignedIntegerValue];
            if (cursor < s) {
                NSString *seg = [text substringWithRange:NSMakeRange(cursor, s - cursor)];
                id t = ((id (*)(id, SEL, NSString *, id))objc_msgSend)(
                    [textTokenCls alloc], textInitSel, seg, flags);
                if (t) [result addObject:t];
            }
            id et = ((id (*)(id, SEL, NSString *, NSString *))objc_msgSend)(
                [emoteTokenCls alloc], emoteInitSel, m[@"w"], m[@"fid"]);
            if (et) [result addObject:et];
            cursor = e;
        }
        if (cursor < text.length) {
            NSString *seg = [text substringFromIndex:cursor];
            id t = ((id (*)(id, SEL, NSString *, id))objc_msgSend)(
                [textTokenCls alloc], textInitSel, seg, flags);
            if (t) [result addObject:t];
        }
    }

    return result ?: tokens;
}

// Wide emotes: put an invisible marker (U+2063 then one U+2064 per quarter of
// width/height) right before the emote so the text layout hook in Tweak.x
// can give that emote a wider slot in the line.
static NSArray *twab_markWideEmotes(NSArray *tokens) {
    if (![tweakDefaults boolForKey:TWABKeyFitWideEmotes]) return tokens;
    static Class textTokenCls, emoteTokenCls;
    static id lastFlags;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        textTokenCls  = objc_getClass("KMPMCMessageTokenTextToken");
        emoteTokenCls = objc_getClass("KMPMCMessageTokenEmoteToken");
    });
    if (!textTokenCls || !emoteTokenCls) return tokens;

    // Flags only style the marker text, which is invisible, so any text
    // token's flags will do (an emote-only message has none of its own).
    for (id t in tokens) {
        if (![t isKindOfClass:textTokenCls]) continue;
        id f = nil;
        @try { f = [t valueForKey:@"flags"]; } @catch (id e) {}
        if (f) { lastFlags = f; break; }
    }
    id flags = lastFlags;
    if (!flags) return tokens;

    NSMutableArray *out = nil;
    for (NSUInteger i = 0; i < tokens.count; i++) {
        id t = tokens[i];
        CGFloat q = 0;
        if ([t isKindOfClass:emoteTokenCls]) {
            id eid = nil;
            @try { eid = [t valueForKey:@"id"]; } @catch (id e) {}
            if ([eid isKindOfClass:NSString.class]) q = twab_wideRatioForEmoteId(eid);
        }
        if (q > 0) {
            if (!out) out = [[tokens subarrayWithRange:NSMakeRange(0, i)] mutableCopy];
            NSUInteger n = (NSUInteger)lround(q * 4.0);
            NSMutableString *mark = [NSMutableString stringWithCapacity:n + 1];
            [mark appendString:[NSString stringWithFormat:@"%C", (unichar)0x2063]];
            for (NSUInteger k = 0; k < n; k++) [mark appendString:[NSString stringWithFormat:@"%C", (unichar)0x2064]];
            id mt = ((id (*)(id, SEL, NSString *, id))objc_msgSend)(
                [textTokenCls alloc], @selector(initWithText:flags:), mark, flags);
            if (mt) [out addObject:mt];
        }
        if (out) [out addObject:t];
    }
    return out ?: tokens;
}

// ─── Your own sent messages: wide emote slots ──────────────────────────────
//
// Twitch's JavaScript shows your sent message straight away from your own
// text, so it never gets the width marker IRC messages get. Instead we note
// each message as it goes out over the chat socket, and the text layout
// hook (Tweak.x) widens the attachments of a message ending with the same
// words, for the words that are wide third-party emotes.

static NSMutableArray<NSDictionary *> *twab_sentMessages(void) {
    static NSMutableArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ a = [NSMutableArray array]; });
    return a;
}

// {words, ratios, t} for `text`, or nil if it has no wide third-party emote.
static NSDictionary *twab_wideWordsEntry(NSString *text) {
    if (![tweakDefaults boolForKey:TWABKeyEmotesEnabled] ||
        ![tweakDefaults boolForKey:TWABKeyFitWideEmotes] || !text.length) return nil;
    NSArray<NSString *> *words = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                                  componentsSeparatedByString:@" "];
    NSMutableArray<NSNumber *> *ratios = [NSMutableArray arrayWithCapacity:words.count];
    BOOL any = NO;
    for (NSString *w in words) {
        CGFloat q = w.length ? twab_wideRatioForEmoteId(twab_fakeIdForWord_inRoom(w, twab_currentRoom)) : 0;
        [ratios addObject:@(q)];
        if (q > 0) any = YES;
    }
    if (!any) return nil;
    return @{@"words": words, @"ratios": ratios, @"t": @(CFAbsoluteTimeGetCurrent())};
}

// What's in the chat box. Your message is shown before it's sent anywhere,
// so the draft is the only thing known in time to size its emotes.
static NSDictionary *twab_draftEntry;

static void twab_noteDraftText(NSString *text) {
    NSDictionary *e = twab_wideWordsEntry(text);
    if (!e) return;  // keep the last draft with emotes; the box clears on send
    @synchronized (twab_sentMessages()) { twab_draftEntry = e; }
}

static void twab_noteSentText(NSString *text) {
    if (![tweakDefaults boolForKey:TWABKeyEmotesEnabled] ||
        ![tweakDefaults boolForKey:TWABKeyFitWideEmotes] || !text.length) return;
    NSArray<NSString *> *words = [text componentsSeparatedByString:@" "];
    NSMutableArray<NSNumber *> *ratios = [NSMutableArray arrayWithCapacity:words.count];
    BOOL any = NO;
    for (NSString *w in words) {
        CGFloat q = w.length ? twab_wideRatioForEmoteId(twab_fakeIdForWord_inRoom(w, twab_currentRoom)) : 0;
        [ratios addObject:@(q)];
        if (q > 0) any = YES;
    }
    if (!any) return;
    NSMutableArray *sent = twab_sentMessages();
    @synchronized (sent) {
        [sent addObject:@{@"words": words, @"ratios": ratios, @"t": @(CFAbsoluteTimeGetCurrent())}];
        while (sent.count > 5) [sent removeObjectAtIndex:0];
    }
}

static void twab_noteSentLine(NSString *line) {
    NSRange pm = [line rangeOfString:@"PRIVMSG #"];
    if (pm.location == NSNotFound) return;
    NSRange sep = [line rangeOfString:@" :" options:0
                                range:NSMakeRange(pm.location, line.length - pm.location)];
    if (sep.location == NSNotFound) return;
    twab_noteSentText([[line substringFromIndex:sep.location + 2]
                       stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);
}

// Chat is sent with the SendChatMessage GQL mutation (input.message).
static void twab_noteSentChatRequest(NSURLRequest *request) {
    if (![request.URL.host isEqualToString:@"gql.twitch.tv"] || !request.HTTPBody) return;
    NSData *needle = [@"\"SendChatMessage\"" dataUsingEncoding:NSUTF8StringEncoding];
    if ([request.HTTPBody rangeOfData:needle options:0 range:NSMakeRange(0, request.HTTPBody.length)].location == NSNotFound)
        return;
    id body = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
    for (id op in [body isKindOfClass:NSArray.class] ? body : (body ? @[body] : @[])) {
        if (![op isKindOfClass:NSDictionary.class] || ![op[@"operationName"] isEqual:@"SendChatMessage"]) continue;
        id input = [op[@"variables"] isKindOfClass:NSDictionary.class] ? op[@"variables"][@"input"] : nil;
        id msg = [input isKindOfClass:NSDictionary.class] ? input[@"message"] : nil;
        if ([msg isKindOfClass:NSString.class]) twab_noteSentText(msg);
    }
}

// Returns (index in s.string, ratio) pairs to widen, as NSValue ranges
// {location: index, length: quarters}.
NSArray<NSValue *> *twab_sentEmoteSlots(NSString *str) {
    NSMutableArray *sent = twab_sentMessages();
    NSArray *snapshot;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @synchronized (sent) {
        if (!sent.count && !twab_draftEntry) return nil;
        [sent filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *m, id b) {
            return now - [m[@"t"] doubleValue] < 30;
        }]];
        snapshot = [sent copy];
        if (twab_draftEntry && now - [twab_draftEntry[@"t"] doubleValue] < 60)
            snapshot = [snapshot arrayByAddingObject:twab_draftEntry];
    }
    if (!snapshot.count || [str rangeOfString:@"\uFFFC"].location == NSNotFound) return nil;
    // Twitch wraps message text in invisible direction marks (U+2068/U+2069,
    // U+200E) and ends lines with a space; match on the text without them,
    // keeping each kept character's index in the original string.
    NSMutableString *clean = [NSMutableString stringWithCapacity:str.length];
    NSMutableArray<NSNumber *> *origIndex = [NSMutableArray arrayWithCapacity:str.length];
    for (NSUInteger k = 0; k < str.length; k++) {
        unichar c = [str characterAtIndex:k];
        if (c == 0x200E || c == 0x200F || (c >= 0x2066 && c <= 0x2069)) continue;
        [clean appendFormat:@"%C", c];
        [origIndex addObject:@(k)];
    }
    while (clean.length && [clean characterAtIndex:clean.length - 1] == ' ') {
        [clean deleteCharactersInRange:NSMakeRange(clean.length - 1, 1)];
        [origIndex removeLastObject];
    }
    NSArray<NSString *> *rendered = [clean componentsSeparatedByString:@" "];
    for (NSDictionary *m in snapshot.reverseObjectEnumerator) {
        NSArray<NSString *> *words = m[@"words"];
        NSArray<NSNumber *> *ratios = m[@"ratios"];
        if (rendered.count < words.count + 1) continue;
        NSUInteger start = rendered.count - words.count;
        // Must be your own line: "<you>: <message>".
        NSString *me = twab_myDisplayName;
        NSString *who = rendered[start - 1];
        if (!me.length || ![who hasSuffix:@":"] ||
            [[who substringToIndex:who.length - 1] rangeOfString:me
                options:NSCaseInsensitiveSearch | NSBackwardsSearch | NSAnchoredSearch].location == NSNotFound) continue;
        BOOL match = YES;
        for (NSUInteger i = 0; i < words.count && match; i++) {
            NSString *r = rendered[start + i];
            match = [r isEqualToString:words[i]] || [r isEqualToString:@"\uFFFC"];
        }
        if (!match) continue;
        NSUInteger offset = 0;
        for (NSUInteger i = 0; i < start; i++) offset += rendered[i].length + 1;
        NSMutableArray *slots = [NSMutableArray array];
        for (NSUInteger i = 0; i < words.count; i++) {
            NSString *r = rendered[start + i];
            CGFloat q = ratios[i].doubleValue;
            if (q > 0 && [r isEqualToString:@"\uFFFC"] && offset < origIndex.count)
                [slots addObject:[NSValue valueWithRange:NSMakeRange(origIndex[offset].unsignedIntegerValue,
                                                                     (NSUInteger)lround(q * 4.0))]];
            offset += r.length + 1;
        }
        return slots.count ? slots : nil;
    }
    return nil;
}

// The chat box is Twitch's own native view (twitch_rn_emote_input). It tells
// JavaScript the plain text (emote names, not images) through onChangeText;
// wrapping that callback gives us the draft exactly as it will be sent.
%hook _TtC21twitch_rn_emote_input20TwitchEmoteInputView
- (void)setOnChangeText:(void (^)(NSDictionary *))block {
    if (!block) { %orig; return; }
    void (^wrapped)(NSDictionary *) = ^(NSDictionary *body) {
        id text = [body isKindOfClass:NSDictionary.class] ? body[@"text"] : nil;
        if ([text isKindOfClass:NSString.class]) twab_noteDraftText(text);
        block(body);
    };
    %orig(wrapped);
}
%end

%hook SRWebSocket
- (BOOL)sendString:(NSString *)string error:(NSError **)error {
    if ([string isKindOfClass:NSString.class] && [string containsString:@"PRIVMSG #"])
        twab_noteSentLine(string);
    return %orig;
}
%end

// ─── Deferred tokenizer hook ────────────────────────────────────────────────
//
// KMPMCChatMessageTokenizer is a Kotlin/Native class — its ObjC methods are
// registered by the KMP runtime AFTER our %ctor runs, so class_copyMethodList
// returns 0 at init time. We defer the hook to the first IRC frame, by which
// point KMP is fully initialized.

static IMP twab_origTokenizerChar = NULL;
static IMP twab_origTokenizerUtf  = NULL;

static NSArray *twab_hookTokenizerChar(id self, SEL _cmd, NSString *message,
                                        id emoteRanges, id gifRanges,
                                        id bitsConfig, id options, id currentUser) {
    NSArray *tokens = ((NSArray *(*)(id, SEL, NSString *, id, id, id, id, id))
                       twab_origTokenizerChar)(self, _cmd, message, emoteRanges,
                                               gifRanges, bitsConfig, options, currentUser);
    if (![tweakDefaults boolForKey:TWABKeyEmotesEnabled]) return tokens;
    NSArray *result = twab_markWideEmotes(twab_injectEmoteTokens(tokens));
    os_log(OS_LOG_DEFAULT, "[TWAB-Chat] tokenizerChar msg=\"%{public}@\" in=%lu out=%lu",
           message, (unsigned long)tokens.count, (unsigned long)result.count);
    return result;
}

static NSArray *twab_hookTokenizerUtf(id self, SEL _cmd, NSString *message,
                                       id emoteRanges, id gifRanges,
                                       id bitsConfig, id options, id currentUser) {
    NSArray *tokens = ((NSArray *(*)(id, SEL, NSString *, id, id, id, id, id))
                       twab_origTokenizerUtf)(self, _cmd, message, emoteRanges,
                                              gifRanges, bitsConfig, options, currentUser);
    if (![tweakDefaults boolForKey:TWABKeyEmotesEnabled]) return tokens;
    NSArray *result = twab_markWideEmotes(twab_injectEmoteTokens(tokens));
    os_log(OS_LOG_DEFAULT, "[TWAB-Chat] tokenizerUtf msg=\"%{public}@\" in=%lu out=%lu",
           message, (unsigned long)tokens.count, (unsigned long)result.count);
    return result;
}

static void twab_setupTokenizerHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("KMPMCChatMessageTokenizer");
        if (!cls) return;
        SEL selC = @selector(tokenizeMessageWithCharacterRangesMessage:sortedEmoteRanges:sortedGifRanges:bitsConfig:options:currentUser:);
        SEL selU = @selector(tokenizeMessageWithUtf8RangesMessage:sortedEmoteRanges:sortedGifRanges:bitsConfig:options:currentUser:);
        Method mC = class_getInstanceMethod(cls, selC);
        Method mU = class_getInstanceMethod(cls, selU);
        if (mC) twab_origTokenizerChar = method_setImplementation(mC, (IMP)twab_hookTokenizerChar);
        if (mU) twab_origTokenizerUtf  = method_setImplementation(mU, (IMP)twab_hookTokenizerUtf);
        os_log(OS_LOG_DEFAULT, "[TWAB-Chat] deferred tokenizer hook char=%d utf=%d",
               mC != NULL, mU != NULL);

    });
}

static BOOL twab_classImplements(Class cls, SEL sel) {
    unsigned int n = 0;
    Method *methods = class_copyMethodList(cls, &n);
    BOOL found = NO;
    for (unsigned int i = 0; i < n && !found; i++) found = method_getName(methods[i]) == sel;
    free(methods);
    return found;
}

%ctor {
    %init;
    if (objc_getClass("__NSURLSessionWebSocketTask")) %init(PrivateWS);
    Class rnws = objc_getClass("RCTWebSocketModule");
    if (rnws && twab_classImplements(rnws, @selector(webSocket:didReceiveMessageWithString:)))
        %init(RNWSString);
    if (rnws && twab_classImplements(rnws, @selector(webSocket:didReceiveMessage:)))
        %init(RNWSAny);
    os_log(OS_LOG_DEFAULT, "[TWAB-Chat] React Native WebSocket module %{public}s",
           !rnws ? "not present"
           : twab_classImplements(rnws, @selector(webSocket:didReceiveMessageWithString:)) ? "hooked (string)"
           : twab_classImplements(rnws, @selector(webSocket:didReceiveMessage:)) ? "hooked (any)"
           : "present but no receive method found");
    // Tokenizer hook is deferred — see twab_setupTokenizerHook(), triggered
    // on first IRC frame when KMP runtime has registered its ObjC methods.

    twab_loadGlobalEmotes();
}
