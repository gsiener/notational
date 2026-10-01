//
//  NVLegacyPreferences.h
//  Notation
//
//  One-time copy of the old nvALT app's preferences (domain net.elasticthreads.nv)
//  into Notational's own domain, so the renamed app keeps the user's look and feel:
//  fonts, colours, hotkey, layout, columns, dock/menu-bar choice. Transient session
//  state (saved search, selection, scroll position), the old notes-folder alias,
//  bookmarks of old note ids and Sparkle settings are left behind.
//

#import <Foundation/Foundation.h>

extern NSString *const NVLegacyPreferencesDomain;

@interface NVLegacyPreferences : NSObject

//keys never copied, exactly as named
+ (NSSet *)excludedKeys;

//Copies every allowed key from sourceDomain that targetDomain hasn't saved itself (registered
//defaults don't count). Runs once per target (remembered under ImportedLegacyPreferences).
//Returns the number of keys copied.
+ (NSUInteger)importFromDomain:(NSString *)sourceDomain intoDomain:(NSString *)targetDomain;

//importFromDomain:NVLegacyPreferencesDomain intoDomain:<this app's bundle identifier>
+ (void)importIfNeeded;

@end
