// Auto-claim bonus channel points.
//
// When enabled, watches for Twitch's availableClaim in ChatChannelPoints
// responses and fires the ClaimCommunityPoints GQL mutation automatically.
// Uses headers stashed from passing GQL requests (Authorization,
// client-integrity, etc.) so no credentials are stored.

#import <Foundation/Foundation.h>
#import <os/log.h>
#import "ChannelPoints.h"
#import "SettingsKeys.h"

extern NSUserDefaults *tweakDefaults;

NSString *const TWABKeyAutoClaimPoints = @"TWAutoClaimPoints";

// ─── Header stash ───────────────────────────────────────────────────────────
// We need headers with client-integrity for the claim mutation. Not every
// GQL request carries it, so we stash the best set we've seen.

static NSDictionary *twab_stashedGQLHeaders;
static dispatch_queue_t twab_pointsQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.level3tjg.twitchadblock.points",
                                  DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

void twab_pointsStashHeaders(NSURLRequest *request) {
    if (![request.URL.host isEqualToString:@"gql.twitch.tv"]) return;
    NSDictionary *headers = request.allHTTPHeaderFields;
    if (!headers[@"Authorization"] || !headers[@"client-id"]) return;
    BOOL hasIntegrity = headers[@"client-integrity"] != nil;
    dispatch_async(twab_pointsQueue(), ^{
        // Prefer headers that include client-integrity.
        if (twab_stashedGQLHeaders[@"client-integrity"] && !hasIntegrity) return;
        twab_stashedGQLHeaders = [headers copy];
    });
}

// ─── Claim sender───────────────────────────────────────────────────────────

static void twab_sendClaim(NSString *claimID, NSString *channelID) {
    __block NSDictionary *headers;
    dispatch_sync(twab_pointsQueue(), ^{ headers = twab_stashedGQLHeaders; });
    if (!headers) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Points] no stashed GQL headers, skipping claim");
        return;
    }
    if (!headers[@"client-integrity"]) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Points] stashed headers missing client-integrity, trying anyway");
    }

    NSDictionary *body = @{
        @"operationName": @"ClaimCommunityPoints",
        @"variables": @{
            @"input": @{
                @"channelID": channelID,
                @"claimID": claimID,
            }
        },
        @"extensions": @{
            @"persistedQuery": @{
                @"version": @1,
                @"sha256Hash": @"46aaeebe02c99afdf4fc97c7c0cba964124bf6b0af229395f1f6d1feed05b3d0",
            }
        }
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!jsonData) return;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://gql.twitch.tv/gql"]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = jsonData;

    for (NSString *key in headers) {
        [req setValue:headers[key] forHTTPHeaderField:key];
    }
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    os_log(OS_LOG_DEFAULT, "[TWAB-Points] claiming bonus claimID=%{public}@ channel=%{public}@",
           claimID, channelID);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            if (error) {
                os_log_error(OS_LOG_DEFAULT, "[TWAB-Points] claim error: %{public}@", error.localizedDescription);
                return;
            }
            NSString *snippet = @"";
            if (data.length) {
                NSUInteger len = MIN(data.length, (NSUInteger)300);
                snippet = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, len)]
                                                encoding:NSUTF8StringEncoding] ?: @"(not UTF-8)";
            }
            os_log(OS_LOG_DEFAULT, "[TWAB-Points] claim response %ld: %{public}@",
                   (long)http.statusCode, snippet);
        }];
    [task resume];
}

// ─── Dedup ──────────────────────────────────────────────────────────────────
// Avoid claiming the same bonus twice (response + socket can both fire).

static NSString *twab_lastClaimedID;
static dispatch_queue_t twab_claimDedup(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.level3tjg.twitchadblock.claimdedup",
                                  DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static void twab_claimIfNew(NSString *claimID, NSString *channelID) {
    dispatch_async(twab_claimDedup(), ^{
        if ([twab_lastClaimedID isEqualToString:claimID]) return;
        twab_lastClaimedID = [claimID copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            twab_sendClaim(claimID, channelID);
        });
    });
}

// ─── Byte-level extractors ──────────────────────────────────────────────────
// didReceiveData delivers chunks, not full responses, so JSON parsing fails.
// Extract IDs from raw bytes with simple pattern matching.

static NSString *twab_extractAfter(NSString *text, NSString *prefix) {
    NSRange r = [text rangeOfString:prefix];
    if (r.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(r);
    // Read until next quote
    NSRange end = [text rangeOfString:@"\"" options:0
                                range:NSMakeRange(start, MIN(text.length - start, (NSUInteger)80))];
    if (end.location == NSNotFound) return nil;
    return [text substringWithRange:NSMakeRange(start, end.location - start)];
}

// ─── Response watcher ───────────────────────────────────────────────────────

void twab_pointsCheckResponse(NSData *data, NSURLRequest *request) {
    if (!data.length || ![request.URL.host isEqualToString:@"gql.twitch.tv"]) return;
    if (![tweakDefaults boolForKey:TWABKeyAutoClaimPoints]) return;

    // Quick byte scan for availableClaim with a non-null id.
    // Pattern: "availableClaim":{"id":"<uuid>"
    // A null claim looks like "availableClaim":null
    NSData *needle = [@"availableClaim\":{\"id\":\"" dataUsingEncoding:NSUTF8StringEncoding];
    if ([data rangeOfData:needle options:0 range:NSMakeRange(0, data.length)].location == NSNotFound)
        return;

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return;

    // Extract claim ID: after availableClaim":{"id":"
    NSString *claimID = twab_extractAfter(text, @"availableClaim\":{\"id\":\"");
    if (!claimID.length) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Points] found availableClaim but couldn't extract id");
        return;
    }

    // Extract channel ID. Try several patterns that appear in the same response chunk:
    //   "channel":{"id":"12345"   (common in GQL responses)
    //   "channelID":"12345"       (in request variables echoed back)
    //   "channel_id":"12345"      (in some response formats)
    NSString *channelID = twab_extractAfter(text, @"channel\":{\"id\":\"");
    if (!channelID.length) channelID = twab_extractAfter(text, @"channelID\":\"");
    if (!channelID.length) channelID = twab_extractAfter(text, @"channel_id\":\"");

    if (!channelID.length) {
        os_log(OS_LOG_DEFAULT, "[TWAB-Points] found claim=%{public}@ but no channelID in chunk",
               claimID);
        return;
    }

    os_log(OS_LOG_DEFAULT, "[TWAB-Points] found claim=%{public}@ channel=%{public}@",
           claimID, channelID);
    twab_claimIfNew(claimID, channelID);
}

// ─── Socket frame watcher ───────────────────────────────────────────────────

static void twab_parseClaimFromFrame(NSString *frame) {
    NSData *frameData = [frame dataUsingEncoding:NSUTF8StringEncoding];
    if (!frameData) return;

    id json = [NSJSONSerialization JSONObjectWithData:frameData options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) return;

    NSDictionary *notification = json[@"notification"];
    if (![notification isKindOfClass:NSDictionary.class]) return;
    NSString *pubsub = notification[@"pubsub"];
    if (![pubsub isKindOfClass:NSString.class]) return;

    NSData *innerData = [pubsub dataUsingEncoding:NSUTF8StringEncoding];
    if (!innerData) return;
    id inner = [NSJSONSerialization JSONObjectWithData:innerData options:0 error:nil];
    if (![inner isKindOfClass:NSDictionary.class]) return;

    NSString *type = inner[@"type"];
    if (![type isEqualToString:@"claim-available"]) return;

    NSDictionary *data = inner[@"data"];
    if (![data isKindOfClass:NSDictionary.class]) return;
    NSDictionary *claimObj = data[@"claim"];
    if (![claimObj isKindOfClass:NSDictionary.class]) return;

    NSString *claimID = claimObj[@"id"];
    NSString *channelID = claimObj[@"channel_id"];
    if (!claimID.length || !channelID.length) return;

    os_log(OS_LOG_DEFAULT, "[TWAB-Points] socket claim-available claim=%{public}@ channel=%{public}@",
           claimID, channelID);
    twab_claimIfNew(claimID, channelID);
}

void twab_pointsCheckFrame(NSString *frame) {
    if (![frame isKindOfClass:NSString.class]) return;
    if (![tweakDefaults boolForKey:TWABKeyAutoClaimPoints]) return;
    if ([frame rangeOfString:@"claim-available"].location == NSNotFound) return;
    twab_parseClaimFromFrame(frame);
}
