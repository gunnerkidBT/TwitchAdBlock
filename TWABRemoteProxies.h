#import <Foundation/Foundation.h>

// The built-in server list can be replaced from proxies.json in the repo, so
// servers can be swapped without an app update. The last good copy is saved
// and used at launch; a fresh one is fetched in the background. Anything
// missing or invalid falls back to the list built into the app.

// The current list from the repo, each @{ @"name", @"addr", @"backup" }, or
// nil when there is no valid one (use the built-in list).
NSArray<NSDictionary *> *twab_remoteProxyEntries(void);

// Loads the saved copy and fetches a fresh one (again when the app returns
// after a few hours). Safe to call more than once.
void twab_remoteProxiesStart(void);

// The list built into the app (from Secrets.h), same entry format. Empty
// when the app was built without Secrets.h.
NSArray<NSDictionary *> *twab_builtinProxyEntries(void);

// When the list was last fetched successfully, or nil.
NSDate *twab_remoteProxiesUpdated(void);
