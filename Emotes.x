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
//      and FFZ public APIs. Globals are loaded once at startup.
//
// Known limitations:
//   • Animated emotes render as a static first frame. Twitch picks UIImage
//     vs FLAnimatedImage from MessageStringImageData.isAnimated, but the
//     rendering pipeline does not call initWithStaticURL:...:isAnimated:
//     for non-Twitch emotes — verified in a previous session. The hook
//     target for forcing animation is not yet identified.
//   • Local-user outgoing messages are tokenized locally and bypass the IRC
//     echo, so your own emotes only render for OTHER viewers.

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <objc/runtime.h>

extern NSUserDefaults *tweakDefaults;

// ─── Emote registry ─────────────────────────────────────────────────────────
//
// Synthetic numeric IDs in [9_000_000_000, 9_999_999_999]. Real Twitch IDs are
// always < 10 digits (~hundreds of millions) so no collision risk.

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

// Monotonically increasing synthetic ID generator. Starts at 9_000_000_000 so
// it never collides with real Twitch numeric IDs (which top out around
// 3 billion as of 2025) or with v2 ids (which contain underscores).
static uint64_t twab_nextSyntheticId(void) {
    static uint64_t counter = 9000000000;
    static dispatch_queue_t serialQ;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        serialQ = dispatch_queue_create("com.level3tjg.twitchadblock.idgen",
                                        DISPATCH_QUEUE_SERIAL);
    });
    __block uint64_t result;
    dispatch_sync(serialQ, ^{ result = counter++; });
    return result;
}

// Register an emote word -> (provider, realId). Allocates a synthetic id and
// updates both maps atomically. First write wins per word.
static void twab_registerEmote(NSString *word, NSString *provider, NSString *realId) {
    if (!word.length || !provider.length || !realId.length) return;
    dispatch_barrier_async(twab_emoteQueue(), ^{
        if (twab_byWord()[word]) return;
        NSString *fakeId = [NSString stringWithFormat:@"%llu", twab_nextSyntheticId()];
        twab_byWord()[word] = @{@"provider": provider,
                                @"id": realId,
                                @"fake": fakeId};
        twab_byFakeId()[fakeId] = @{@"provider": provider, @"id": realId};
    });
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

static void twab_load7TVSet(NSString *url) {
    NSURLSession *sess = NSURLSession.sharedSession;
    [[sess dataTaskWithURL:[NSURL URLWithString:url]
         completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!d || e) return;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSDictionary *set = j[@"emote_set"] ?: j;  // /users/twitch wraps in emote_set
        NSArray *emotes = set[@"emotes"];
        NSUInteger n = 0;
        for (NSDictionary *em in emotes) {
            NSString *name = em[@"name"];
            NSString *eid = em[@"id"];
            if (name.length && eid.length) { twab_registerEmote(name, @"7tv", eid); n++; }
        }
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] 7TV +%lu %{public}s",
               (unsigned long)n, url.UTF8String);
    }] resume];
}

static void twab_loadBTTVChannel(NSString *roomId) {
    if (!roomId.length) return;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://api.betterttv.net/3/cached/users/twitch/%@", roomId]];
    [[NSURLSession.sharedSession dataTaskWithURL:url
                              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!d || e) return;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSUInteger n = 0;
        for (NSString *key in @[ @"channelEmotes", @"sharedEmotes" ]) {
            for (NSDictionary *em in j[key]) {
                NSString *code = em[@"code"];
                NSString *eid = em[@"id"];
                if (code.length && eid.length) { twab_registerEmote(code, @"bttv", eid); n++; }
            }
        }
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] BTTV channel +%lu room=%{public}s",
               (unsigned long)n, roomId.UTF8String);
    }] resume];
}

static void twab_loadBTTVGlobal(void) {
    NSURL *url = [NSURL URLWithString:@"https://api.betterttv.net/3/cached/emotes/global"];
    [[NSURLSession.sharedSession dataTaskWithURL:url
                              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!d || e) return;
        NSArray *list = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSUInteger n = 0;
        for (NSDictionary *em in list) {
            NSString *code = em[@"code"];
            NSString *eid = em[@"id"];
            if (code.length && eid.length) { twab_registerEmote(code, @"bttv", eid); n++; }
        }
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] BTTV global +%lu", (unsigned long)n);
    }] resume];
}

static void twab_loadFFZSet(NSString *url) {
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url]
                              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!d || e) return;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSDictionary *sets = j[@"sets"];
        NSUInteger n = 0;
        for (NSString *setKey in sets) {
            for (NSDictionary *em in sets[setKey][@"emoticons"]) {
                NSString *name = em[@"name"];
                NSNumber *idNum = em[@"id"];
                if (name.length && idNum) {
                    twab_registerEmote(name, @"ffz", idNum.stringValue);
                    n++;
                }
            }
        }
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] FFZ +%lu %{public}s",
               (unsigned long)n, url.UTF8String);
    }] resume];
}

// Fetch global emote sets — called once at startup.
static void twab_loadGlobalEmotes(void) {
    twab_load7TVSet(@"https://7tv.io/v3/emote-sets/global");
    twab_loadBTTVGlobal();
    twab_loadFFZSet(@"https://api.frankerfacez.com/v1/set/global");
}

// Fetch channel-specific emote sets for a given Twitch room id. Fully async —
// never blocks the WebSocket thread, even on the seen-room check.
static void twab_loadChannelEmotes(NSString *roomId) {
    if (!roomId.length) return;
    NSString *room = [roomId copy];
    dispatch_barrier_async(twab_emoteQueue(), ^{
        if ([twab_loadedRooms() containsObject:room]) return;
        [twab_loadedRooms() addObject:room];
        os_log(OS_LOG_DEFAULT, "[TWAB-Emote] loading channel room=%{public}s",
               room.UTF8String);
        twab_load7TVSet([NSString stringWithFormat:@"https://7tv.io/v3/users/twitch/%@", room]);
        twab_loadBTTVChannel(room);
        twab_loadFFZSet([NSString stringWithFormat:@"https://api.frankerfacez.com/v1/room/id/%@", room]);
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
    // Animation is a separate problem (see file header) so this is no regression.
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
    if (![tweakDefaults boolForKey:@"TWEmotesEnabled"]) return %orig;
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

    // Scan words for matches.
    NSMutableArray<NSString *> *newEntries = [NSMutableArray array];
    NSArray<NSString *> *words = [text componentsSeparatedByString:@" "];
    NSUInteger pos = 0;
    for (NSString *word in words) {
        NSString *fakeId = twab_fakeIdForWord(word);
        if (fakeId) {
            NSUInteger end = pos + word.length - 1;
            [newEntries addObject:[NSString stringWithFormat:@"%@:%lu-%lu",
                                   fakeId, (unsigned long)pos, (unsigned long)end]];
        }
        pos += word.length + 1;
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
typedef void (^twab_recvHandler)(NSURLSessionWebSocketMessage *, NSError *);

static twab_recvHandler twab_wrapHandler(twab_recvHandler h) {
    if (!h) return h;
    return ^(NSURLSessionWebSocketMessage *msg, NSError *err) {
        if (![tweakDefaults boolForKey:@"TWEmotesEnabled"]) {
            h(msg, err);
            return;
        }
        if (!msg || msg.type != NSURLSessionWebSocketMessageTypeString || !msg.string) {
            h(msg, err);
            return;
        }
        NSArray<NSString *> *lines = [msg.string componentsSeparatedByString:@"\r\n"];
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
    // Default the feature ON unless explicitly toggled off.
    if (![tweakDefaults objectForKey:@"TWEmotesEnabled"])
        [tweakDefaults setBool:YES forKey:@"TWEmotesEnabled"];
    twab_loadGlobalEmotes();
}
