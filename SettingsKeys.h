#pragma once
#import <Foundation/Foundation.h>

// Single source of truth for every NSUserDefaults key the tweak reads or
// writes. Use these constants everywhere instead of @"..." literals so a
// typo becomes a compile-time error rather than a silently-NO boolForKey.

extern NSString *const TWABKeyAdBlockEnabled;
extern NSString *const TWABKeyAdBlockProxyEnabled;
extern NSString *const TWABKeyAdBlockCustomProxyEnabled;
extern NSString *const TWABKeyAdBlockProxy;
extern NSString *const TWABKeyEmotesEnabled;
// Integer index of the tab to land on at launch. Key absent (or value < 0)
// means "use Twitch's default tab".
extern NSString *const TWABKeyLaunchTab;
// Integer index of the SUB-tab within the chosen LaunchTab (Home or Browse
// have sub-tabs). Key absent means "no sub-tab override". Paired with
// TWABKeyLaunchTab — sub-tab is only applied when the chosen parent's
// container view controller appears.
extern NSString *const TWABKeyLaunchSubTab;
// BOOL — when YES, the Twitch Stories horizontal strip at the top of the
// Home tab is removed from the view hierarchy on first layout.
extern NSString *const TWABKeyHideStories;
// BOOL — when YES, the Turbo "Go Ad-Free" upsell banner on the Following tab
// is hidden/collapsed on layout.
extern NSString *const TWABKeyHideAdFreeButton;
// BOOL — when YES, the Evolve "Live" feed's max-watch-time limit is
// neutralized so a live preview keeps playing instead of stopping and
// showing the Watch/Follow blocking overlay. Implemented by rewriting the
// `maxStreamWatchSeconds` field in the FeedItems GraphQL response.
extern NSString *const TWABKeyDisableWatchLimit;

// Resolves which proxy address to use right now: the user's custom value
// when the custom-proxy toggle is on, otherwise the bundled default.
// Preserves the prior call-site semantics exactly (returns whatever
// stringForKey: returned, including nil/empty, when custom is enabled).
NSString *twab_effectiveProxyAddress(void);

// Normalizes a proxy address string into an NSURL. Prepends http:// if no
// scheme is present so addresses like "user:pass@host:port" parse with the
// expected scheme/host instead of NSURL treating "user" as the scheme.
// Returns nil if the address can't be parsed into something with a host.
NSURL *twab_normalizedProxyURL(NSString *address);

// Splits the effective proxy address on commas / newlines / whitespace into
// an ordered list of proxy addresses to try. Returns an empty array if the
// configured value has no parseable entries. Order is preserved — callers
// should ping each in sequence and use the first that responds.
NSArray<NSString *> *twab_effectiveProxyAddresses(void);

// Returns YES if the Twitch auth token embedded in the URL query string
// marks the user as subscribed or Turbo. Such users don't see preroll ads
// anyway, so proxying their requests just exposes their credentials to a
// third party with no ad-block benefit. The "token" query parameter is a
// JSON-encoded blob; this parses it leniently and returns NO on any
// malformed input.
BOOL twab_userIsAdExempt(NSString *queryString);
