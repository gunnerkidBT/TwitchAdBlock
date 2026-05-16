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

// Register an emote word -> (provider, realId, room). Allocates a synthetic
// id and updates all indexes atomically. First write wins per word; later
// writes with the same word are silently dropped, even from a different
// room. `room` of nil means "global" — never evicted.
static void twab_registerEmote(NSString *word, NSString *provider,
                               NSString *realId, NSString *room) {
    if (!word.length || !provider.length || !realId.length) return;
    NSString *roomKey = room.length ? room : TWAB_GLOBAL_ROOM;
    dispatch_barrier_async(twab_emoteQueue(), ^{
        if (twab_byWord()[word]) return;
        NSString *fakeId = [NSString stringWithFormat:@"%llu", twab_nextSyntheticId()];
        twab_byWord()[word] = @{@"provider": provider,
                                @"id": realId,
                                @"fake": fakeId};
        twab_byFakeId()[fakeId] = @{@"provider": provider,
                                    @"id": realId,
                                    @"word": word,
                                    @"room": roomKey};
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
            if ([name isKindOfClass:NSString.class] && name.length &&
                [eid isKindOfClass:NSString.class] && eid.length) {
                twab_registerEmote(name, @"7tv", eid, room);
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
                if ([code isKindOfClass:NSString.class] && code.length &&
                    [eid isKindOfClass:NSString.class] && eid.length) {
                    twab_registerEmote(code, @"bttv", eid, roomId);
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
            if ([code isKindOfClass:NSString.class] && code.length &&
                [eid isKindOfClass:NSString.class] && eid.length) {
                twab_registerEmote(code, @"bttv", eid, nil);
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
                if ([name isKindOfClass:NSString.class] && name.length &&
                    [idNum isKindOfClass:NSNumber.class]) {
                    twab_registerEmote(name, @"ffz", idNum.stringValue, room);
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

// ─── URL redirect ───────────────────────────────────────────────────────────

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

    // 7TV's CDN doesn't pre-generate .gif for every emote — many only have
    // .webp / .avif, so requesting .gif returns 404 and we render blank.
    // .webp is universally available and iOS decodes static WebP natively.
    if ([provider isEqualToString:@"7tv"])
        return [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.7tv.app/emote/%@/2x.webp", realId]];
    if ([provider isEqualToString:@"bttv"])
        return [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.betterttv.net/emote/%@/2x", realId]];
    if ([provider isEqualToString:@"ffz"])
        return [NSURL URLWithString:[NSString stringWithFormat:
            @"https://cdn.frankerfacez.com/emote/%@/2", realId]];
    return nil;
}

%hook __NSURLSessionLocal
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    if (![tweakDefaults boolForKey:TWABKeyEmotesEnabled]) return %orig;
    NSURL *real = twab_rewriteEmoteURL(request.URL);
    if (real) {
        NSMutableURLRequest *m = [request mutableCopy];
        m.URL = real;
        return %orig(m);
    }
    return %orig;
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
    if (![tweakDefaults objectForKey:TWABKeyEmotesEnabled])
        [tweakDefaults setBool:YES forKey:TWABKeyEmotesEnabled];
    twab_loadGlobalEmotes();
}
