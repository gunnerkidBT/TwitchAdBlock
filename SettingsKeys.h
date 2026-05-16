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

// Resolves which proxy address to use right now: the user's custom value
// when the custom-proxy toggle is on, otherwise the bundled default.
// Preserves the prior call-site semantics exactly (returns whatever
// stringForKey: returned, including nil/empty, when custom is enabled).
NSString *twab_effectiveProxyAddress(void);
