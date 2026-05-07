#import "NSData+TwitchAdBlock.h"

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

    // Filter FeedAd nodes from Following-tab feed responses
    NSArray *ops = [json isKindOfClass:NSMutableArray.class] ? json : @[json];
    for (NSMutableDictionary *op in ops) {
        if (![op isKindOfClass:NSMutableDictionary.class]) continue;
        NSMutableDictionary *feedItems = op[@"data"][@"feedItems"];
        if (!feedItems) continue;
        NSArray *edges = feedItems[@"edges"];
        if (![edges isKindOfClass:NSArray.class]) continue;
        feedItems[@"edges"] = [edges filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"node.__typename != 'FeedAd'"]];
    }

    NSData *out = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    return (out && !error) ? out : self;
}

@end
