//
//  ODBEditor.m
//  B-Quartic

// http://gusmueller.com/odb/

/**
    
    Nov 30- Updates from Eric Blair:
        removed entries from the _filesBeingEdited dictionary when the odb connection is closed.
        added support for handling Save As messages and differentiate between editing a file and editing a string.
 
    Nov 30- Updates from Gus Mueller:
        Added stringByResolvingSymlinksInPath around the file paths passed around, because it seems if you write to
        /tmp/, sometimes you'll get back /private/tmp as a param

*/


#import "NSAppleEventDescriptor-Extensions.h"
#import "ODBEditor.h"
#import "ODBEditorSuite.h"
#import "ExternalEditorListController.h"
#import "NoteObject.h"
#import "NSFileManager_NV.h"
#import <Carbon/Carbon.h>

NSString * const ODBEditorCustomPathKey		= @"ODBEditorCustomPath";
NSString * const ODBEditorNonRetainedClient = @"ODBEditorNonRetainedClient";
NSString * const ODBEditorClientContext		= @"ODBEditorClientContext";
NSString * const ODBEditorFileName			= @"ODBEditorFileName";
NSString * const ODBEditorIsEditingString	= @"ODBEditorIsEditingString";

@interface ODBEditor(Private)

- (BOOL)_launchExternalEditor:(ExternalEditor*)ed;
- (OSStatus)_sendOpenEvent:(NSAppleEventDescriptor *)event reply:(AEDesc *)reply;
- (NSString*)_nonexistingTemporaryPathForFilename:(NSString*)filename;
- (NSString *)_tempFilePathForEditingString:(NSString *)string;
- (BOOL)_editFile:(NSString *)path inEditor:(ExternalEditor*)ed isEditingString:(BOOL)editingStringFlag options:(NSDictionary *)options forClient:(id)client context:(NSDictionary *)context;
- (void)handleModifiedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent;
- (void)handleClosedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent;

@end

@implementation ODBEditor

static ODBEditor	*_sharedODBEditor;

+ (id)sharedODBEditor {
	if (_sharedODBEditor == nil) {
		_sharedODBEditor = [[ODBEditor alloc] init];
	}
	return _sharedODBEditor;
}

- (id)init {
	self = [super init];
	if (self != nil) {
		UInt32  packageType = 0;
		UInt32  packageCreator = 0;
		
		if (_sharedODBEditor != nil && [self class] == [ODBEditor class]) {
			[self autorelease];
			[NSException raise: NSInternalInconsistencyException format: @"ODBEditor is a singleton - use [ODBEditor sharedODBEditor]"];
			return nil;
		}
		// our initialization
		
		CFBundleGetPackageInfo(CFBundleGetMainBundle(), &packageType, &packageCreator);
		_signature = packageCreator;
		
		_filePathsBeingEdited = [[NSMutableDictionary alloc] init];

		// setup our event handlers
		
		if ([self class] == [ODBEditor class]) {
			NSAppleEventManager *appleEventManager = [NSAppleEventManager sharedAppleEventManager];
			[appleEventManager setEventHandler: self andSelector: @selector(handleModifiedFileEvent:withReplyEvent:) forEventClass: kODBEditorSuite andEventID: kAEModifiedFile];
			[appleEventManager setEventHandler: self andSelector: @selector(handleClosedFileEvent:withReplyEvent:) forEventClass: kODBEditorSuite andEventID: kAEClosedFile];
		}
				
	}
	
	return self;
}

- (void)dealloc {
	if ([self class] == [ODBEditor class]) {
		NSAppleEventManager *appleEventManager = [NSAppleEventManager sharedAppleEventManager];
		[appleEventManager removeEventHandlerForEventClass: kODBEditorSuite andEventID: kAEModifiedFile];
		[appleEventManager removeEventHandlerForEventClass: kODBEditorSuite andEventID: kAEClosedFile];
	}
	[_filePathsBeingEdited release];
	[super dealloc];
}

- (void)abortEditingFile:(NSString *)path {
	 //#warning REVIEW if we created a temporary file for this session should we try to delete it and/or close it in the editor?
	
	if (path) {
		if (nil == [_filePathsBeingEdited objectForKey: path])
			NSLog(@"ODBEditor: No active editing session for \"%@\"", path);
		
		[_filePathsBeingEdited removeObjectForKey: path];
	} else {
		NSLog(@"abortEditingFile: path is nil");
	}
}

- (void)abortAllEditingSessionsForClient:(id)client {
	 //#warning REVIEW if we created a temporary file for this session should we try to delete it and/or close it in the editor?

	if (![_filePathsBeingEdited count]) return;
	
	BOOL found = NO;
	NSEnumerator *enumerator = [_filePathsBeingEdited objectEnumerator];
	NSMutableArray *keysToRemove = [NSMutableArray array];
	NSDictionary *dictionary = nil;
	
	while (nil != (dictionary = [enumerator nextObject])) {
		id  iterClient = [[dictionary objectForKey: ODBEditorNonRetainedClient] nonretainedObjectValue];
		
		if (iterClient == client) {
			found = YES;
			[keysToRemove addObject:[dictionary objectForKey: ODBEditorFileName]];
		}
	}
	
	[_filePathsBeingEdited removeObjectsForKeys: keysToRemove];
	
	if (! found) {
		//NSLog(@"ODBEditor: No active editing session for \"%@\" in '%@'", client, _filePathsBeingEdited);
	}
}

- (BOOL)editNote:(NoteObject*)aNote inEditor:(ExternalEditor*)ed context:(NSDictionary *)context {
	if (!aNote) goto beepReturn;
	
	//notes are no longer separate files, so edit a temporary copy of the text using the ODB protocol
	
	if (![ed isODBEditor]) {
		NSLog(@"not editing '%@' with '%@' because it is not an ODB editor", aNote, ed);
		goto beepReturn;
	}
	
	//now write aNote as text to path?
	NSString *path = [self _nonexistingTemporaryPathForFilename:[[aNote titleAsFilename] stringByAppendingPathExtension:@"txt"]];	
	NSError *error = nil;
	if (!path || ![[[aNote contentString] string] writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:&error]) {
		NSLog(@"not editing '%@' because it could not be written to '%@'", aNote, path);
		goto beepReturn;
	}
	
	BOOL opened = [self editFile:path inEditor:ed options:[NSDictionary dictionaryWithObject:titleOfNote(aNote) forKey:ODBEditorCustomPathKey] forClient:aNote context:context];
	if (!opened) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
	return opened;
beepReturn:
	NSBeep();
	return NO;
}

- (BOOL)editFile:(NSString *)path inEditor:(ExternalEditor*)ed options:(NSDictionary *)options forClient:(id)client context:(NSDictionary *)context {
	return [self _editFile:path inEditor:ed isEditingString:NO options:options forClient:client context:context];
}

- (BOOL)editString:(NSString *)string inEditor:(ExternalEditor*)ed options:(NSDictionary *)options forClient:(id)client context:(NSDictionary *)context {
	NSString *path = [self _tempFilePathForEditingString:string];

	if (path != nil) {
		BOOL opened = [self _editFile:path inEditor:ed isEditingString:YES options:options forClient:client context:context];
		if (!opened) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
		return opened;
    }
    
	return NO;
}


@end

@implementation ODBEditor(Private)

- (OSStatus)_sendOpenEvent:(NSAppleEventDescriptor *)event reply:(AEDesc *)reply {
	return AESendMessage([event aeDesc], reply, kAEWaitReply, kAEDefaultTimeout);
}

- (BOOL)_launchExternalEditor:(ExternalEditor*)ed {
	BOOL success = NO;
	BOOL running = NO;
	NSWorkspace	*workspace = [NSWorkspace sharedWorkspace];
	NSArray	*runningApplications = [workspace launchedApplications];
	NSEnumerator *enumerator = [runningApplications objectEnumerator];
	NSDictionary *applicationInfo;
	
	NSString *editorBundleIdentifier = [ed bundleIdentifier];
	
	while (nil != (applicationInfo = [enumerator nextObject])) {
		NSString *bundleIdentifier = [applicationInfo objectForKey: @"NSApplicationBundleIdentifier"];
		
		if ([bundleIdentifier isEqualToString: editorBundleIdentifier]) {
			running = YES;
			// bring the app forward
			success = [workspace launchApplication: [applicationInfo objectForKey: @"NSApplicationPath"]];
			break;
		}
	}
	
	if (running == NO) {
		success = [workspace launchAppWithBundleIdentifier: editorBundleIdentifier options:NSWorkspaceLaunchDefault additionalEventParamDescriptor: nil launchIdentifier:NULL];
	}
	
	return success;
}

- (NSString*)_nonexistingTemporaryPathForFilename:(NSString*)filename {
	unsigned int sTempFileSequence = 0;
	NSString *path = nil;
	NSString *basename = [filename stringByDeletingPathExtension];
	NSFileManager *fileManager = [NSFileManager defaultManager];
	
	NSString *directory = [fileManager temporaryNotesDirectory];
	if (!directory) return nil;
	
	do {
		path = sTempFileSequence++ ? [NSString stringWithFormat: @"%@ %03d.txt", basename, sTempFileSequence] : [basename stringByAppendingPathExtension:@"txt"];
		path = [directory stringByAppendingPathComponent: path];
	} while ([fileManager fileExistsAtPath:path]);
	
	return path;
}


- (NSString *)_tempFilePathForEditingString:(NSString *)string {
	NSString *path = [self _nonexistingTemporaryPathForFilename:@"Untitled Text"];
	
	NSError *error = nil;
	if (NO == [string writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:&error]) {
		NSLog([error description], nil);
		path = nil;
	}

	return path;
}

- (BOOL)_editFile:(NSString *)path inEditor:(ExternalEditor*)ed isEditingString:(BOOL)editingStringFlag options:(NSDictionary *)options forClient:(id)client context:(NSDictionary *)context {
    // 10.2 fix- akm Nov 30 2004
    path = [path stringByResolvingSymlinksInPath];
    
	BOOL success = NO;
	OSStatus status = noErr;
	if (!ed) ed = [[ExternalEditorListController sharedInstance] defaultExternalEditor];
	NSData *targetBundleID = [[ed bundleIdentifier] dataUsingEncoding: NSUTF8StringEncoding];
	NSAppleEventDescriptor *targetDescriptor = [NSAppleEventDescriptor descriptorWithDescriptorType: typeApplicationBundleID data: targetBundleID];
	NSAppleEventDescriptor *appleEvent = [NSAppleEventDescriptor appleEventWithEventClass: kCoreEventClass
																				   eventID: kAEOpenDocuments
																		  targetDescriptor: targetDescriptor
																				  returnID: kAutoGenerateReturnID
																		     transactionID: kAnyTransactionID];
	NSAppleEventDescriptor  *replyDescriptor = nil;
	NSAppleEventDescriptor  *errorDescriptor = nil;
	AEDesc reply = {typeNull, NULL};														
	NSString *customPath = [options objectForKey: ODBEditorCustomPathKey];
	
	if (![self _launchExternalEditor:ed]) return NO;
	
	[appleEvent setParamDescriptor: [NSAppleEventDescriptor descriptorWithFilePath: path] forKeyword: keyDirectObject];
	[appleEvent setParamDescriptor: [NSAppleEventDescriptor descriptorWithTypeCode: _signature] forKeyword: keyFileSender];
	if (customPath != nil)
		[appleEvent setParamDescriptor: [NSAppleEventDescriptor descriptorWithString: customPath] forKeyword: keyFileCustomPath];
	
	status = [self _sendOpenEvent:appleEvent reply:&reply];
	
	if (status == noErr) {
		if (reply.descriptorType == typeNull) return NO;
		// initWithAEDescNoCopy takes ownership; its autorelease disposes the reply.
		replyDescriptor = [[[NSAppleEventDescriptor alloc] initWithAEDescNoCopy: &reply] autorelease];
		errorDescriptor = [replyDescriptor paramDescriptorForKeyword: keyErrorNumber];
		
		if (errorDescriptor != nil) {
			status = [errorDescriptor int32Value];
		}
		
		if (status == noErr) {
			// save off some information that we'll need when we get called back
			
			NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
			
			[dictionary setObject: [NSValue valueWithNonretainedObject: client] forKey: ODBEditorNonRetainedClient];
			if (context != NULL)
				[dictionary setObject: context forKey: ODBEditorClientContext];
			[dictionary setObject: path forKey: ODBEditorFileName];
			[dictionary setObject: [NSNumber numberWithBool: editingStringFlag] forKey: ODBEditorIsEditingString];
			
			[_filePathsBeingEdited setObject: dictionary forKey: path];
		}
	}
	else if (reply.descriptorType != typeNull) {
		AEDisposeDesc(&reply);
	}
	
	success = (status == noErr);
	
	return success;
}

- (void)handleModifiedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
	NSAppleEventDescriptor *fpDescriptor = [[event paramDescriptorForKeyword: keyDirectObject] coerceToDescriptorType: typeFileURL];
	NSString *urlString = [[[NSString alloc] initWithData: [fpDescriptor data] encoding: NSUTF8StringEncoding] autorelease];
	NSString *path = [[[NSURL URLWithString: urlString] path] stringByResolvingSymlinksInPath];
	NSAppleEventDescriptor	*nfpDescription = [[event paramDescriptorForKeyword: keyNewLocation] coerceToDescriptorType: typeFileURL];
	NSString *newUrlString = [[[NSString alloc] initWithData: [nfpDescription data] encoding: NSUTF8StringEncoding] autorelease];
	NSString *newPath = [[NSURL URLWithString: newUrlString] path];
	NSDictionary *dictionary = nil;
	NSError *error = nil;
	
	dictionary = [_filePathsBeingEdited objectForKey: path];
	
	if (dictionary != nil)
	{
		id  client		= [[dictionary objectForKey: ODBEditorNonRetainedClient] nonretainedObjectValue];
		id isString		= [dictionary objectForKey: ODBEditorIsEditingString];
		NSDictionary *context	= [dictionary objectForKey: ODBEditorClientContext];
		
		if([isString boolValue]) {
			NSString *stringContents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
			if (stringContents) {
				[client odbEditor: self didModifyFileForString: stringContents context: context];
			} else {
				NSLog([error description], nil);
			}
		} else {
			[client odbEditor:self didModifyFile:path newFileLocation:newPath context:context];
		}

		// if we've received a Save As message, remove the file from the list of edited files
		// This may be break compatibility with BBEdit versioner < 6.0, since these versions
		// continue to send notifications after after doing a Save As...
		if(newPath) {
			[_filePathsBeingEdited removeObjectForKey: newPath];
	    }

	}
	else
	{
		NSLog(@"Got ODB editor event for unknown file '%@'", path);
	}
}

- (void)handleClosedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
	NSAppleEventDescriptor  *descriptor = [[event paramDescriptorForKeyword: keyDirectObject] coerceToDescriptorType: typeFileURL];
	NSString				*urlString = [[[NSString alloc] initWithData: [descriptor data] encoding: NSUTF8StringEncoding] autorelease];
	NSString				*fileName = [[[NSURL URLWithString: urlString] path] stringByResolvingSymlinksInPath];
	NSDictionary			*dictionary = nil;
	NSError *error = nil;
	
	dictionary = [_filePathsBeingEdited objectForKey: fileName];
	
	if (dictionary != nil) {
		id client		= [[dictionary objectForKey: ODBEditorNonRetainedClient] nonretainedObjectValue];
		id isString		= [dictionary objectForKey: ODBEditorIsEditingString];
		NSDictionary *context	= [dictionary objectForKey: ODBEditorClientContext];
		
		if([isString boolValue]) {
			 NSString	*stringContents = [NSString stringWithContentsOfURL:[NSURL fileURLWithPath:fileName] encoding:NSUTF8StringEncoding error:&error];
			if (stringContents) {
				[client odbEditor: self didCloseFileForString: stringContents context: context];
			} else {
				NSLog([error description], nil);
			}
		} else {
			[client odbEditor:self didClosefile:fileName context:context];
		}
	}
	else
	{
		NSLog(@"Got ODB editor event for unknown file '%@'", fileName);
	}
	if (fileName)
		[_filePathsBeingEdited removeObjectForKey: fileName];
}

@end
