//
//  SecureTextEntryManager.m
//  Notation
//
//  Created by Zachary Schneirov on 1/5/11.

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
  Redistribution and use in source and binary forms, with or without modification, are permitted 
  provided that the following conditions are met:
   - Redistributions of source code must retain the above copyright notice, this list of conditions 
     and the following disclaimer.
   - Redistributions in binary form must reproduce the above copyright notice, this list of 
     conditions and the following disclaimer in the documentation and/or other materials provided with
     the distribution.
   - Neither the name of Notational Velocity nor the names of its contributors may be used to endorse 
     or promote products derived from this software without specific prior written permission. */


#import "SecureTextEntryManager.h"
#include <Carbon/Carbon.h>

NSString *ShouldHideSecureTextEntryWarningKey = @"ShouldHideSecureTextEntryWarning";

static SecureTextEntryManager *sharedInstance = nil;

@implementation SecureTextEntryManager

+ (SecureTextEntryManager*)sharedInstance {
	//not synchronized because there should be no need for non-main threads to access this class
	//also, NSThread access potentially enables a locking 
	
	if (sharedInstance == nil)
		sharedInstance = [[SecureTextEntryManager alloc] init];
    return sharedInstance;
}

+ (id)allocWithZone:(NSZone *)zone {
	if (sharedInstance == nil) {
		sharedInstance = [super allocWithZone:zone];
		return sharedInstance;  // assignment and return on first allocation
	}
    return nil; // on subsequent allocation attempts return nil
}

- (id)init {
	if ((self = [super init])) {
		
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) 
													 name:NSApplicationDidBecomeActiveNotification object:NSApp];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActive:) 
													 name:NSApplicationWillResignActiveNotification object:NSApp];		
	}
	return self;
}

- (void)applicationDidBecomeActive:(NSNotification *)aNotification {
	
	if (secureTextEntry) {
		[self _enableSecureEventInput];
	}
}

- (void)applicationWillResignActive:(NSNotification *)aNotification {
	if (secureTextEntry) {
		[self _disableSecureEventInput];
	}
}

//_enableSecureEventInput/_disableSecureEventInput are private; do not call them directly
- (void)_enableSecureEventInput {

	if (!_calledSecureEventInput) {
		NSAssert([NSApp isActive], @"not fair; app is currently inactive");
		//could also assert -[NSThread isMainThread] here
		
		_calledSecureEventInput = YES;
		//NSLog(@"%s: enabled secure input", _cmd);
		
		EnableSecureEventInput();
	}
}

- (void)_disableSecureEventInput {
	if (_calledSecureEventInput) {
		
		DisableSecureEventInput();
		
		//NSLog(@"%s: disabled secure input", _cmd);
		_calledSecureEventInput = NO;
		
		if (IsSecureEventInputEnabled())
			NSLog(@"%@: WARNING: secure input is still enabled, possibly by another app", NSStringFromSelector(_cmd));
	}
}


//these enable/disable methods refer to the behavior of calling EnableSecureEventInput/DisableSecureEventInput;
//rather than being wrappers for those calls themselves

- (void)disableSecureTextEntry {
	if (secureTextEntry) {
		[self _disableSecureEventInput];
		
		secureTextEntry = NO;
	}
}

- (void)enableSecureTextEntry {
	
	if (!secureTextEntry) {
		//should do -[checkForIncompatibleApps] here, but that would add about 0.056 seconds of latency to launch time
		if ([NSApp isActive]) {
			[self _enableSecureEventInput];
		}
		
		secureTextEntry = YES;
	}
}

- (NSSet*)_bundleIdentifiersOfIncompatibleApps {
	return [NSSet setWithObjects:@"com.smileonmymac.textexpander", @"com.macility.typinator2", @"com.typeit4me.TypeIt4MeMenu", @"uk.co.activata.Autopilot2", @"au.com.tech.AutoTyper", nil];
}

- (void)checkForIncompatibleApps {
	
	if (!secureTextEntry || [[NSUserDefaults standardUserDefaults] boolForKey:ShouldHideSecureTextEntryWarningKey])
		return;
	
	NSSet *identifiers = [self _bundleIdentifiersOfIncompatibleApps];

	NSRunningApplication *runningApp;
	NSEnumerator *enumerator = [[[NSWorkspace sharedWorkspace] runningApplications] objectEnumerator];
	while ((runningApp = [enumerator nextObject])) {
		
		NSString *identifier = [runningApp bundleIdentifier];
		if (identifier && [identifiers containsObject:identifier]) {
			
			NSString *offendingAppName = [[NSBundle bundleWithURL:[runningApp bundleURL]] objectForInfoDictionaryKey:(NSString *)kCFBundleNameKey];
			if (!offendingAppName) offendingAppName = [runningApp localizedName];
			NSAlert *alert = [[[NSAlert alloc] init] autorelease];
			[alert setMessageText:[NSString stringWithFormat:NSLocalizedString(@"Secure Text Entry will prevent %@, which is currently installed on this computer, from working in Notational Velocity.", 
																		   @"for warning about incompatibility with TextExpander, Typinator, etc."), offendingAppName]];
			[alert addButtonWithTitle:NSLocalizedString(@"OK", nil)];
			[alert setShowsSuppressionButton:YES];
			[alert runModal];
			if ([[alert suppressionButton] state] == NSControlStateValueOn) {
				[[NSUserDefaults standardUserDefaults] setBool:YES forKey:ShouldHideSecureTextEntryWarningKey];
			}
			break;
		}
	}
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (id)retain {
    return self;
}

- (NSUInteger)retainCount {
    return UINT_MAX;  // denotes an object that cannot be released
}

- (oneway void)release {
    //do nothing
}

- (id)autorelease {
    return self;
}

@end
