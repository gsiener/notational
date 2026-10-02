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


#import "URLGetter.h"
#import "GlobalPrefs.h"
#import "NSFileManager_NV.h"

// A getter owns itself while its download is in flight (it used to be leaked on purpose by MRC callers);
// endDownloadWithPath: lets it go.
static NSMutableSet *ActiveURLGetters(void) {
	static NSMutableSet *active = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{ active = [[NSMutableSet alloc] init]; });
	return active;
}

@implementation URLGetter

- (id)initWithURL:(NSURL*)aUrl delegate:(id)aDelegate userData:(id)someObj {
	if (!aUrl || [aUrl isFileURL]) {
		return nil;
	}
	if (self=[super init]) {
		maxExpectedByteCount = 0;
		isImporting = isIndicating = NO;
		delegate = aDelegate;
		url = aUrl;
		userData = someObj;
		
		[ActiveURLGetters() addObject:self];
		//callbacks arrive on the main queue, so the progress panel and the delegate are only touched from there
		session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:self delegateQueue:[NSOperationQueue mainQueue]];
		downloadTask = [session downloadTaskWithURL:url];
		[downloadTask resume];
		
		[self startProgressIndication:self];
        return self;
	}
	
	return nil;
}

- (NSURL*)url {
	return url;
}

- (id)userData {
	return userData;
}

- (IBAction)cancelDownload:(id)sender {
	[downloadTask cancel];

	[self endDownloadWithPath:nil];
}

- (void)stopProgressIndication {
	[window close];
	[progress stopAnimation:nil];
	
	isImporting = isIndicating = NO;
}

- (void)startProgressIndication:(id)sender {
	if (!window) {
		if (!NVLoadNib(@"URLGetter", self))  {
			NSLog(@"Failed to load URLGetter.nib");
			NSBeep();
			return;
		}
		[window setReleasedWhenClosed:NO];
		[progress setUsesThreadedAnimation:YES];
	}
	
	[progress setIndeterminate:YES];
	[progress startAnimation:nil];
	
	[cancelButton setEnabled:YES];
	[progressStatus setStringValue:NSLocalizedString(@"Download: waiting to begin.", @"download dialog status message")];
	[objectURLStatus setStringValue:[url absoluteString]];
	
	[window center];
	[window makeKeyAndOrderFront:sender];
	
	isIndicating = YES;
}

- (void)updateProgress {
	if (isIndicating) {
		[progress setIndeterminate:!maxExpectedByteCount || isImporting];
		[progress setMaxValue:(double)maxExpectedByteCount];
		
		[progress setDoubleValue:(double)totalReceivedByteCount];
		if (isImporting) {
			[progressStatus setStringValue:NSLocalizedString(@"Importing content...", @"Status message after downloading a URL")];
		} else if (maxExpectedByteCount > 0) {
			[progressStatus setStringValue:[NSString stringWithFormat:NSLocalizedString(@"%.0lf KB of %.0lf KB", nil), 
				(double)totalReceivedByteCount / 1024.0, (double)maxExpectedByteCount / 1024.0]];
		} else {
			[progressStatus setStringValue:[NSString stringWithFormat:NSLocalizedString(@"%.0lf KB received",nil), (double)totalReceivedByteCount / 1024.0]];
		}
	}
}

- (void)URLSession:(NSURLSession *)urlSession downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
	if (hasEnded) return;
	
	totalReceivedByteCount = totalBytesWritten;
	maxExpectedByteCount = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0;
	
	[self updateProgress];
}

//the session deletes the file it downloaded as soon as this returns, so move it somewhere we control
- (void)URLSession:(NSURLSession *)urlSession downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
	if (hasEnded) return;
	
	NSString *name = [[task response] suggestedFilename];
	if (![name length]) name = [[task originalRequest].URL lastPathComponent];
	if (![name length]) name = @"download";
	
	tempDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
	if (![[NSFileManager defaultManager]createFolderAtPath:tempDirectory]) {
		NSLog(@"URLGetter: Couldn't create temporary directory!");
		tempDirectory = nil;
		NSBeep();
		return;
	}
	
	NSString *destination = [tempDirectory stringByAppendingPathComponent:name];
	if ([[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:destination] error:NULL])
		downloadPath = destination;
}

- (void)URLSession:(NSURLSession *)urlSession task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
	if (hasEnded) return; //cancelled
	
	if (error) {
		NSString *reason = [error localizedDescription];
		if (!reason) reason = NSLocalizedString(@"unknown error.", @"error description of last resort for why a URL couldn't be accessed");
		NVRunAlert(NSAlertStyleWarning, [NSString stringWithFormat:NSLocalizedString(@"The URL quotemark%@quotemark could not be accessed: %@.", nil), 
			[url absoluteString], reason], @"", NSLocalizedString(@"OK",nil), nil, nil);
		
		[self endDownloadWithPath:nil];
		return;
	}
	
	[self endDownloadWithPath:downloadPath];
}

- (void)endDownloadWithPath:(NSString*)path {
	if (hasEnded) return;
	hasEnded = YES;
	
	//the session retains its delegate until it is invalidated
	[session invalidateAndCancel];
	session = nil;
	downloadTask = nil;
	
	isImporting = YES;
	[self updateProgress];
	
	// stay alive until the end of this method, even if the delegate drops its reference
	URLGetter *keepAlive = self;
	[delegate URLGetter:self returnedDownloadedFile:path];
	
	//clean up after ourselves
	NSFileManager *fileMan = [NSFileManager defaultManager];
	if (downloadPath) {
        [fileMan deleteFileAtPath:downloadPath];
//		[fileMan removeFileAtPath:downloadPath handler:NULL];
		downloadPath = nil;
	}
	
	if (tempDirectory) {
		//only remove temporary directory if there's nothing in it
		
        
        if (![[fileMan folderContentsAtPath:tempDirectory] count])
			[fileMan deleteFileAtPath:tempDirectory];
//            [fileMan removeFileAtPath:tempDirectory handler:NULL];
		else
			NSLog(@"note removing %@ because it still contains files!", tempDirectory);
		tempDirectory = nil;
	}
	
   
    [self stopProgressIndication];

	[ActiveURLGetters() removeObject:keepAlive];
}

- (NSString*)downloadPath {
	return downloadPath;
}

- (id)delegate {
	return delegate;
}
- (void)setDelegate:(id)aDelegate {
	delegate = aDelegate;
}

@end
