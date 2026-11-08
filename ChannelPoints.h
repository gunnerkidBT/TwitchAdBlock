#import <Foundation/Foundation.h>

extern NSString *const TWABKeyAutoClaimPoints;

// Stash GQL headers (Authorization, client-integrity, etc.) from any
// passing request to gql.twitch.tv so the auto-claim can reuse them.
void twab_pointsStashHeaders(NSURLRequest *request);

// Watch GQL responses for an availableClaim in ChatChannelPoints data.
// When the setting is on, fires the ClaimCommunityPoints mutation.
void twab_pointsCheckResponse(NSData *data, NSURLRequest *request);

// Watch socket frames for claim-available notifications.
void twab_pointsCheckFrame(NSString *frame);
