//
//  PreviewController.h
//  Notation
//
//  Created by Christian Tietze on 15.10.10.
//  Copyright 2010

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@class AppController;
@class NoteObject;
@class ETTransparentButton;

@interface PreviewController : NSWindowController <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
{
  IBOutlet NSView *previewContainer;
  WKWebView *preview;
	IBOutlet NSTextView *sourceView;
	IBOutlet NSTabView *tabView;
	IBOutlet NSButton *tabSwitcher;
  IBOutlet NSButton *saveButton;
  IBOutlet NSButton *stickyPreviewButton;
  IBOutlet NSButton *printPreviewButton;
  BOOL isPreviewOutdated;
  BOOL isPreviewSticky;
	NSString *cssString;
	NSString *htmlString;

	IBOutlet NSButton *includeTemplate;
  IBOutlet NSTextField *templateNote;
	IBOutlet NSView *accessoryView;
	
	__weak NoteObject *lastNote;
}

@property (assign) BOOL isPreviewOutdated;
@property (readonly) WKWebView *preview;
@property (assign) BOOL isPreviewSticky;

-(IBAction)saveHTML:(id)sender;
-(IBAction)switchTabs:(id)sender;

-(IBAction)makePreviewSticky:(id)sender;
-(IBAction)makePreviewNotSticky:(id)sender;
-(IBAction)printPreview:(id)sender;
-(BOOL)previewIsVisible;
-(void)togglePreview:(id)sender;
-(void)requestPreviewUpdate:(NSNotification *)notification;
+(void)createCustomFiles;
+(NSString *)css;
+(NSString *)html;
@end
