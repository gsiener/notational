//
//  NVLegacyPreferences.m
//  Notation
//

#import "NVLegacyPreferences.h"

NSString *const NVLegacyPreferencesDomain = @"net.elasticthreads.nv";
static NSString *const ImportedKey = @"ImportedLegacyPreferences";

@implementation NVLegacyPreferences

+ (NSSet *)excludedKeys {
	return [NSSet setWithObjects:
			//session state that would make the list or selection look wrong on first launch (#24)
			@"LastSearchString", @"LastSelectedNoteUUIDBytes", @"LastScrollOffset", @"LastSelectedPrefsPane",
			//old storage: notes folder, and bookmarks that point at note ids from the old database
			@"DirectoryAlias", @"Bookmarks", @"BookmarksVisible",
			ImportedKey, nil];
}

+ (BOOL)isExcluded:(NSString *)key {
	//Sparkle's settings (SU…) and its window frame: the updater was removed
	return [[self excludedKeys] containsObject:key] || [key hasPrefix:@"SU"] || [key hasSuffix:@"SUStatusFrame"];
}

//the value saved in exactly this domain; unlike CFPreferencesCopyAppValue, this ignores the
//search list (global domain, registered defaults)
static id SavedValue(NSString *key, NSString *domain) {
	return [(id)CFPreferencesCopyValue((CFStringRef)key, (CFStringRef)domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) autorelease];
}

+ (NSUInteger)importFromDomain:(NSString *)sourceDomain intoDomain:(NSString *)targetDomain {
	if (![sourceDomain length] || ![targetDomain length] || [sourceDomain isEqualToString:targetDomain]) return 0;
	if ([SavedValue(ImportedKey, targetDomain) boolValue]) return 0;
	
	NSUInteger copied = 0;
	CFArrayRef keys = CFPreferencesCopyKeyList((CFStringRef)sourceDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	for (NSString *key in (NSArray *)keys) {
		if ([self isExcluded:key] || SavedValue(key, targetDomain)) continue;
		id value = SavedValue(key, sourceDomain);
		if (value) {
			CFPreferencesSetValue((CFStringRef)key, (CFPropertyListRef)value, (CFStringRef)targetDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
			copied++;
		}
	}
	if (keys) CFRelease(keys);
	
	CFPreferencesSetValue((CFStringRef)ImportedKey, kCFBooleanTrue, (CFStringRef)targetDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	CFPreferencesSynchronize((CFStringRef)targetDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	if (copied) NSLog(@"Imported %lu preferences from %@", (unsigned long)copied, sourceDomain);
	return copied;
}

+ (void)importIfNeeded {
	[self importFromDomain:NVLegacyPreferencesDomain intoDomain:[[NSBundle mainBundle] bundleIdentifier]];
}

@end
