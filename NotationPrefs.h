//
//  NotationPrefs.h
//  Notation
//
//  Created by Zachary Schneirov on 4/1/06.

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


#import <Cocoa/Cocoa.h>
#import "NotationController.h"

/* this class is responsible for managing all preferences specific to a notational database,
including encryption, file formats, synchronization, passwords management, and others */

#define EPOC_ITERATION 4

enum { SingleDatabaseFormat = 0, PlainTextFormat, RTFTextFormat, HTMLFormat, WordDocFormat, WordXMLFormat };

extern NSString *NotationPrefsDidChangeNotification;

@interface NotationPrefs : NSObject {
	BOOL doesEncryption, storesPasswordInKeychain, secureTextEntry;
	NSString *keychainDatabaseIdentifier;
	
	//password(s) stored in keychain or otherwise encrypted using notes password
	NSMutableDictionary *syncServiceAccounts;
	
	unsigned int hashIterationCount, keyLengthInBits;
	
	NSColor *foregroundColor;
	NSFont *baseBodyFont;
	NSInteger notesStorageFormat;
	BOOL confirmFileDeletion;
	
	NSData *masterSalt, *dataSessionSalt, *verifierKey;
	
	UInt32 epochIteration;
	BOOL firstTimeUsed;
	BOOL preferencesChanged;
	id delegate;
	
	@private 
	//masterKey is not to be stored anywhere
	NSData *masterKey;
}

NSMutableDictionary *ServiceAccountDictInit(NotationPrefs *prefs, NSString* serviceName);

+ (int)appVersion;
- (BOOL)preferencesChanged;
- (void)setForegroundTextColor:(NSColor*)aColor;
- (NSColor*)foregroundColor;
- (void)setBaseBodyFont:(NSFont*)aFont;
- (NSFont*)baseBodyFont;

- (BOOL)storesPasswordInKeychain;
- (NSInteger)notesStorageFormat;
- (BOOL)confirmFileDeletion;
- (BOOL)doesEncryption;
- (NSDictionary*)syncServiceAccounts;
- (NSDictionary*)syncServiceAccountsForArchiving;
- (NSDictionary*)syncAccountForServiceName:(NSString*)serviceName;
- (NSString*)syncPasswordForServiceName:(NSString*)serviceName;
- (NSUInteger)syncFrequencyInMinutesForServiceName:(NSString*)serviceName;
- (BOOL)syncNotesShouldMergeForServiceName:(NSString*)serviceName;
- (BOOL)syncServiceIsEnabled:(NSString*)serviceName;
- (unsigned int)keyLengthInBits;
- (unsigned int)hashIterationCount;
- (UInt32)epochIteration;
- (BOOL)firstTimeUsed;
- (BOOL)secureTextEntry;

- (void)forgetKeychainIdentifier;
- (const char *)setKeychainIdentifier;
- (SecKeychainItemRef)currentKeychainItem;
- (NSData*)passwordDataFromKeychain;
- (void)removeKeychainData;
- (void)setKeychainData:(NSData*)data;

- (void)setPreferencesAreStored;
- (void)setStoresPasswordInKeychain:(BOOL)value;
- (BOOL)canLoadPassphraseData:(NSData*)passData;
- (BOOL)canLoadPassphrase:(NSString*)pass;
- (void)setPassphraseData:(NSData*)passData inKeychain:(BOOL)inKeychain;
- (void)setPassphraseData:(NSData*)passData inKeychain:(BOOL)inKeychain withIterations:(int)iterationCount;
- (BOOL)encryptDataInNewSession:(NSMutableData*)data;
- (BOOL)decryptDataWithCurrentSettings:(NSMutableData*)data;
- (NSData*)WALSessionKey;

- (void)setNotesStorageFormat:(NSInteger)formatID;
- (void)setConfirmsFileDeletion:(BOOL)value;
- (void)setDoesEncryption:(BOOL)value;
- (void)setSecureTextEntry:(BOOL)value;
- (const char*)keychainSyncAccountNameForService:(NSString*)serviceName;
- (void)setSyncUsername:(NSString*)username forService:(NSString*)serviceName;
- (void)setSyncPassword:(NSString*)password forService:(NSString*)serviceName;
- (void)setSyncFrequency:(NSUInteger)frequencyInMinutes forService:(NSString*)serviceName;
- (void)setSyncEnabled:(BOOL)isEnabled forService:(NSString*)serviceName;
- (void)setSyncShouldMerge:(BOOL)shouldMerge inCurrentAccountForService:(NSString*)serviceName;
- (void)removeSyncPasswordForService:(NSString*)serviceName;
- (void)setKeyLengthInBits:(unsigned int)newLength;

+ (NSString*)pathExtensionForFormat:(NSInteger)format;

- (id)delegate;
- (void)setDelegate:(id)aDelegate;

@end

@interface NotationPrefs (DelegateMethods)

- (void)databaseEncryptionSettingsChanged;
- (void)syncSettingsChangedForService:(NSString*)serviceName;
- (void)databaseSettingsChangedFromOldFormat:(NSInteger)oldFormat;

@end
