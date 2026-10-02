//
//  NSString_NV.m
//  Notation
//
//  Created by Zachary Schneirov on 1/13/06.

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

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "NSString_NV.h"
#import "NSData_transformations.h"
#import "NSFileManager_NV.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "LabelObject.h"

@implementation NSString (NV)

static int dayFromAbsoluteTime(CFAbsoluteTime absTime);

enum {NoSpecialDay = -1, ThisDay = 0, NextDay = 1, PriorDay = 2};

static const double dayInSeconds = 86400.0;
static CFTimeInterval secondsAfterGMT = 0.0;
static int currentDay = 0;
static CFMutableDictionaryRef dateStringsCache = NULL;
static CFDateFormatterRef dateAndTimeFormatter = NULL;

unsigned int hoursFromAbsoluteTime(CFAbsoluteTime absTime) {
	return (unsigned int)floor(absTime / 3600.0);
}

//should be called after midnight, and then all the notes should have their date-strings recomputed
void resetCurrentDayTime(void) {
    CFAbsoluteTime current = CFAbsoluteTimeGetCurrent();
    
    CFTimeZoneRef timeZone = CFTimeZoneCopyDefault();
    secondsAfterGMT = CFTimeZoneGetSecondsFromGMT(timeZone, current);
    
    currentDay = (int)floor((current + secondsAfterGMT) / dayInSeconds); // * dayInSeconds - secondsAfterGMT;
	
	if (dateStringsCache)
		CFDictionaryRemoveAllValues(dateStringsCache);
	
	if (dateAndTimeFormatter) {
		CFRelease(dateAndTimeFormatter);
		dateAndTimeFormatter = NULL;
	}
		
	CFRelease(timeZone);
}
//the epoch is defined at midnight GMT, so we have to convert from GMT to find the days

static int dayFromAbsoluteTime(CFAbsoluteTime absTime) {
    if (currentDay == 0)
	resetCurrentDayTime();
    
    int timeDay = (int)floor((absTime + secondsAfterGMT) / dayInSeconds); // * dayInSeconds - secondsAfterGMT;
    if (timeDay == currentDay) {
	return ThisDay;
    } else if (timeDay == currentDay + 1 /*dayInSeconds*/) {
	return NextDay;
    } else if (timeDay == currentDay - 1 /*dayInSeconds*/) {
	return PriorDay;
    }
    
    return NoSpecialDay;
}

+ (NSString*)relativeTimeStringWithDate:(CFDateRef)date relativeDay:(int)day {
    static CFDateFormatterRef timeOnlyFormatter = nil;
    static NSString *days[3] = { NULL };
    
    if (!timeOnlyFormatter) {
        CFLocaleRef localeRef2 = CFLocaleCopyCurrent();
		timeOnlyFormatter = CFDateFormatterCreate(kCFAllocatorDefault, localeRef2, kCFDateFormatterNoStyle, kCFDateFormatterShortStyle);
        CFRelease(localeRef2);
    }
    
    if (!days[ThisDay]) {
		days[ThisDay] = NSLocalizedString(@"Today", nil);
		days[NextDay] = NSLocalizedString(@"Tomorrow", nil);
		days[PriorDay] = NSLocalizedString(@"Yesterday", nil);
    }

    CFStringRef dateString = CFDateFormatterCreateStringWithDate(kCFAllocatorDefault, timeOnlyFormatter, date);
	if ([[GlobalPrefs defaultPrefs] horizontalLayout]) {
		//if today, return the time only; otherwise say "Yesterday", etc.; and this method shouldn't be called unless day != NoSpecialDay
		if (day == PriorDay || day == NextDay){
		CFRelease(dateString);
            return days[day];
        }
		return (__bridge_transfer id)dateString;
	}
    
    NSString *relativeTimeString = [days[day] stringByAppendingFormat:@"  %@", (__bridge NSString *)dateString];
	CFRelease(dateString);
	
	return relativeTimeString;
}



//take into account yesterday/today thing
//this method _will_ affect application launch time
+ (NSString*)relativeDateStringWithAbsoluteTime:(CFAbsoluteTime)absTime {
	if (!dateStringsCache) {
		CFDictionaryKeyCallBacks keyCallbacks = { kCFTypeDictionaryKeyCallBacks.version, (CFDictionaryRetainCallBack)NULL, (CFDictionaryReleaseCallBack)NULL, 
			(CFDictionaryCopyDescriptionCallBack)NULL, (CFDictionaryEqualCallBack)NULL, (CFDictionaryHashCallBack)NULL };
		dateStringsCache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &keyCallbacks, &kCFTypeDictionaryValueCallBacks);
	}
	NSInteger minutesCount = (NSInteger)((NSInteger)absTime / 60);
	
	NSString *dateString = (__bridge NSString*)CFDictionaryGetValue(dateStringsCache, (const void *)minutesCount);
	
	if (!dateString) {
		int day = dayFromAbsoluteTime(absTime);
		
		if (!dateAndTimeFormatter) {
            CFLocaleRef localeRef2 = CFLocaleCopyCurrent();
			BOOL horiz = [[GlobalPrefs defaultPrefs] horizontalLayout];
			dateAndTimeFormatter = CFDateFormatterCreate(kCFAllocatorDefault, localeRef2,
														 horiz ? kCFDateFormatterShortStyle : kCFDateFormatterMediumStyle, 
														 horiz ? kCFDateFormatterNoStyle : kCFDateFormatterShortStyle);
            CFRelease(localeRef2);
		}
		
		CFDateRef date = CFDateCreate(kCFAllocatorDefault, absTime);
		
		if (day == NoSpecialDay) {
			dateString = (__bridge_transfer NSString*)CFDateFormatterCreateStringWithDate(kCFAllocatorDefault, dateAndTimeFormatter, date);
		} else {
			dateString = [NSString relativeTimeStringWithDate:date relativeDay:day];
		}
        
		CFRelease(date);
		
		//ints as pointers ints as pointers ints as pointers
		CFDictionarySetValue(dateStringsCache, (const void *)minutesCount, (__bridge const void *)dateString);
	}
	
    return dateString;
}

// TODO: possibly obsolete? SN api2 formats dates as doubles from start of unix epoch
CFDateFormatterRef simplenoteDateFormatter(int lowPrecision) {
	//CFStringRef dateStr = CFSTR("2010-01-02 23:23:31.876229");
	static CFDateFormatterRef dateFormatter = NULL;
	static CFDateFormatterRef lowPrecisionDateFormatter = NULL;
	static CFLocaleRef locale = NULL;
	static CFTimeZoneRef zone = NULL;
	if (!dateFormatter) {
		locale = CFLocaleCreate(NULL,CFSTR("en"));
		zone = CFTimeZoneCreateWithTimeIntervalFromGMT(NULL, 0.0);		
		dateFormatter = CFDateFormatterCreate(NULL, locale, kCFDateFormatterNoStyle, kCFDateFormatterNoStyle);
		lowPrecisionDateFormatter = CFDateFormatterCreate(NULL, locale, kCFDateFormatterNoStyle, kCFDateFormatterNoStyle);
		CFDateFormatterSetFormat(dateFormatter, CFSTR("yyyy-MM-dd HH:mm:ss.SSSSSS"));
		CFDateFormatterSetFormat(lowPrecisionDateFormatter, CFSTR("yyyy-MM-dd HH:mm:ss"));
		CFDateFormatterSetProperty(dateFormatter, kCFDateFormatterTimeZone, zone);
		CFDateFormatterSetProperty(lowPrecisionDateFormatter, kCFDateFormatterTimeZone, zone);
	}
	return lowPrecision ? lowPrecisionDateFormatter	: dateFormatter;
}

// TODO: possibly obsolete? SN api2 formats dates as doubles from start of unix epoch
+ (NSString*)simplenoteDateWithAbsoluteTime:(CFAbsoluteTime)absTime {
	CFStringRef str = CFDateFormatterCreateStringWithAbsoluteTime(NULL, simplenoteDateFormatter(0), absTime);
	return (__bridge_transfer id)str;
}

// TODO: possibly obsolete? SN api2 formats dates as doubles from start of unix epoch
- (CFAbsoluteTime)absoluteTimeFromSimplenoteDate {
	
	CFAbsoluteTime absTime = 0;
	if (!CFDateFormatterGetAbsoluteTimeFromString(simplenoteDateFormatter(0), (__bridge CFStringRef)self, NULL, &absTime)) {
		if (!CFDateFormatterGetAbsoluteTimeFromString(simplenoteDateFormatter(1), (__bridge CFStringRef)self, NULL, &absTime)) {
			NSLog(@"can't get date from %@; returning current time instead", self);
			return 0;
		}
	}
	return absTime;
}

- (NSArray*)labelCompatibleWords {
	NSArray *array = nil;
	array = [self componentsSeparatedByCharactersInSet:[NSCharacterSet labelSeparatorCharacterSet]];
    if (array&&([array count]>0)) {
        NSMutableArray *titles = [[NSMutableArray alloc]initWithCapacity:[array count]];
        for (NSString *aWord in array) {
            if (aWord&&(aWord.length>0)&&(![titles containsObject:aWord])) {
                [titles addObject:aWord];
            }
        }
        if (titles&&([titles count]>0)) {
            NSArray *retArray=[NSArray arrayWithArray:titles];
            return retArray;
        }
    }
	return [NSArray array];
}

- (CFArrayRef)copyRangesOfWordsInString:(NSString*)findString inRange:(NSRange)limitRange {
	CFStringRef quoteStr = CFSTR("\"");
	CFRange quoteRange = CFStringFind((__bridge CFStringRef)findString, quoteStr, 0);
	CFArrayRef terms = CFStringCreateArrayBySeparatingStrings(NULL, (__bridge CFStringRef)findString, 
															  quoteRange.location == kCFNotFound ? CFSTR(" ") : quoteStr);
	if (terms) {
		CFIndex termIndex;
		CFMutableArrayRef allRanges = NULL;
		
		for (termIndex = 0; termIndex < CFArrayGetCount(terms); termIndex++) {
			CFStringRef term = CFArrayGetValueAtIndex(terms, termIndex);
			if (CFStringGetLength(term) > 0) {
				CFArrayRef ranges = CFStringCreateArrayWithFindResults(NULL, (__bridge CFStringRef)self, term, CFRangeMake(limitRange.location,limitRange.length), kCFCompareCaseInsensitive);
				
				if (ranges) {
					if (!allRanges) {
						//to make sure we get the right cfrange callbacks
						allRanges = CFArrayCreateMutableCopy(NULL, 0, ranges);
					} else {
						CFArrayAppendArray(allRanges, ranges, CFRangeMake(0, CFArrayGetCount(ranges)));
					}
					CFRelease(ranges);
				}
			}
		}
		//should sort them all now by location
		//CFArraySortValues(allRanges, CFRangeMake(0, CFArrayGetCount(allRanges)), <#CFComparatorFunction comparator#>,<#void * context#>);
		CFRelease(terms);
		return allRanges;
	}
	
	return NULL;
}

+ (NSString*)customPasteboardTypeOfCode:(int)code {
	//returns something like CorePasteboardFlavorType 0x4D5A0003
	return [NSString stringWithFormat:@"CorePasteboardFlavorType 0x%X", code];
}

- (NSString*)stringAsSafePathExtension {
	return [self stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"./*: \t\n\r"]];
}

- (NSString*)filenameExpectingAdditionalCharCount:(NSUInteger)charCount {
	NSString *newfilename = self;
	if ([self length] + charCount > 255)
		newfilename = [self substringToIndex: 255 - charCount];

	return newfilename;
}

- (BOOL)isAMachineDirective {
	return [self hasPrefix:@"#!"] || [self hasPrefix:@"#import "] || [self hasPrefix:@"#include "] || 
	[self hasPrefix:@"<!DOCTYPE "] || [self hasPrefix:@"<?xml "] || [self hasPrefix:@"<html "] || 
	[self hasPrefix:@"@import "] || [self hasPrefix:@"<?php"] || [self hasPrefix:@"bplist0"]; 
	
}


- (NSString*)fourCharTypeString {
	if ([[self dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES] length] >= 4) {
		//only truncate; don't return a string containing null characters for the last few bytes
		return NVStringFromOSType(NVOSTypeFromString(self));
	}
	return self;
}

- (BOOL)superficiallyResemblesAnHTTPURL {
	//has the right protocol and contains no whitespace or line breaks
	
	return ([self rangeOfString:@"http" options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound ||
			[self rangeOfString:@"https" options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound) &&
	[self rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] options:NSLiteralSearch].location == NSNotFound;
}

- (void)copyItemToPasteboard:(id)sender {
	
	NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
	[pasteboard declareTypes:[NSArray arrayWithObject:NSPasteboardTypeString] owner:nil];
	[pasteboard setString:[sender isKindOfClass:[NSMenuItem class]] ? [sender representedObject] : self
				  forType:NSPasteboardTypeString];
}


//the following three methods + function come courtesy of Mike Ferris' TextExtras
+ (NSString *)tabbifiedStringWithNumberOfSpaces:(NSInteger)origNumSpaces tabWidth:(NSInteger)tabWidth usesTabs:(BOOL)usesTabs {
	static NSMutableString *sharedString = nil;
	static NSInteger numTabs = 0;
    static NSInteger numSpaces = 0;
	
    NSInteger diffInTabs;
    NSInteger diffInSpaces;
	
    // TabWidth of 0 means don't use tabs!
    if (!usesTabs || (tabWidth == 0)) {
        diffInTabs = 0 - numTabs;
        diffInSpaces = origNumSpaces - numSpaces;
    } else {
        diffInTabs = (origNumSpaces / tabWidth) - numTabs;
        diffInSpaces = (origNumSpaces % tabWidth) - numSpaces;
    }
    
    if (!sharedString) {
        sharedString = [[NSMutableString alloc] init];
    }
    
    if (diffInTabs < 0) {
        [sharedString deleteCharactersInRange:NSMakeRange(0, -diffInTabs)];
    } else {
        NSInteger numToInsert = diffInTabs;
        while (numToInsert > 0) {
            [sharedString replaceCharactersInRange:NSMakeRange(0, 0) withString:@"\t"];
            numToInsert--;
        }
    }
    numTabs += diffInTabs;
	
    if (diffInSpaces < 0) {
        [sharedString deleteCharactersInRange:NSMakeRange(numTabs, -diffInSpaces)];
    } else {
        NSInteger numToInsert = diffInSpaces;
        while (numToInsert > 0) {
            [sharedString replaceCharactersInRange:NSMakeRange(numTabs, 0) withString:@" "];
            numToInsert--;
        }
    }
    numSpaces += diffInSpaces;
	
	
    return sharedString;
}

- (NSInteger)numberOfLeadingSpacesFromRange:(NSRange*)range tabWidth:(NSInteger)tabWidth {
    // Returns number of spaces, accounting for expanding tabs.
    NSRange searchRange = (range ? *range : NSMakeRange(0, [self length]));
    unichar buff[100];
    unsigned i = 0;
    NSInteger spaceCount = 0;
    BOOL done = NO;
    NSInteger tabW = tabWidth;
    NSUInteger endOfWhiteSpaceIndex = NSNotFound;
	
    if (!range || range->length == 0) {
        return 0;
    }
    
    while ((searchRange.length > 0) && !done) {
        [self getCharacters:buff range:NSMakeRange(searchRange.location, ((searchRange.length > 100) ? 100 : searchRange.length))];
        for (i=0; i < ((searchRange.length > 100) ? 100 : searchRange.length); i++) {
            if (buff[i] == (unichar)' ') {
                spaceCount++;
            } else if (buff[i] == (unichar)'\t') {
                // MF:!!! Perhaps this should account for the case of 2 spaces follwed by a tab really being visually equivalent to 8 spaces (for 8 space tabs) and not 10 spaces.
                spaceCount += tabW;
            } else {
                done = YES;
                endOfWhiteSpaceIndex = searchRange.location + i;
                break;
            }
        }
        searchRange.location += ((searchRange.length > 100) ? 100 : searchRange.length);
        searchRange.length -= ((searchRange.length > 100) ? 100 : searchRange.length);
    }
    if (range && (endOfWhiteSpaceIndex != NSNotFound)) {
        range->length = endOfWhiteSpaceIndex - range->location;
    }
    return spaceCount;
}

BOOL IsHardLineBreakUnichar(unichar uchar, NSString *str, unsigned charIndex) {
    // This function redundantly takes both the character and the string and index.  This is because often we only have to look at that one character and usually we already have it when this is called (usually from a source cheaper than characterAtIndex: too.)
    // Returns yes if the unichar given is a hard line break, that is it will always cause a new line fragment to begin.
    // MF:??? Is this test complete?
    if ((uchar == (unichar)'\n') || (uchar == NSParagraphSeparatorCharacter) || (uchar == NSLineSeparatorCharacter)) {
        return YES;
    } else if ((uchar == (unichar)'\r') && ((charIndex + 1 >= [str length]) || ([str characterAtIndex:charIndex + 1] != (unichar)'\n'))) {
        return YES;
    }
    return NO;
}

- (char*)copyLowercaseASCIIString {
	
	const char *cstringPtr = NULL;
	
	//here we are making assumptions (based on observations and CFString.c) about the implementation of CFStringGetCStringPtr:
	//with a non-western language preference, kCFStringEncodingASCII or another Latin variant must be used instead of kCFStringEncodingMacRoman
	if ((cstringPtr = CFStringGetCStringPtr((__bridge CFStringRef)self, kCFStringEncodingMacRoman)) ||
		(cstringPtr = CFStringGetCStringPtr((__bridge CFStringRef)self, kCFStringEncodingASCII))) {
		
		size_t length = [self length];
		char *cstringBuffer = (char*)malloc(length + 1);
		//modp will add the NULL terminator
		modp_tolower_copy(cstringBuffer, cstringPtr, length);
		
		return cstringBuffer;
	} else {
		//will be true on Snow Leopard for empty strings
		//NSLog(@"found string that should have been 7 bit, but (apparently) is not.");
	}
	
	return NULL;
}

- (const char*)lowercaseUTF8String {
	
	CFMutableStringRef str2 = CFStringCreateMutableCopy(NULL, 0, (__bridge CFStringRef)self);
	CFStringLowercase(str2, NULL);
	
	// the pointer is only valid while the string lives, so keep it in the autorelease pool for the caller
	__autoreleasing NSString *lowered = (__bridge_transfer NSString*)str2;
	return [lowered UTF8String];
}

- (NSString *)stringByReplacingPercentEscapes {
    return (__bridge_transfer NSString*) CFURLCreateStringByReplacingPercentEscapes(NULL, (__bridge CFStringRef) self, CFSTR(""));
}

- (NSString*)stringWithPercentEscapes {
	//everything but ASCII alphanumerics and the unreserved (plus bracket) characters is escaped, as before
	static NSCharacterSet *allowedSet = nil;
	if (!allowedSet) allowedSet = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~[]"];
	return [self stringByAddingPercentEncodingWithAllowedCharacters:allowedSet];
}

+ (NSString*)reasonStringFromCarbonFSError:(OSStatus)err {
	static NSDictionary *reasons = nil;
	if (!reasons) {
		NSString *path = [[NSBundle mainBundle] pathForResource:@"CarbonErrorStrings" ofType:@"plist"];
		reasons = [NSDictionary dictionaryWithContentsOfFile:path];
	}
	
	NSString *reason = [reasons objectForKey:[[NSNumber numberWithInt:(int)err] stringValue]];
	if (!reason)
		return [NSString stringWithFormat:NSLocalizedString(@"an error of type %d occurred", @"string of last resort for errors not found in CarbonErrorStrings"), (int)err];
	return reason;
}

- (BOOL)UTIOfFileConformsToType:(NSString*)type {
	
	UTType *fileType = nil;
	NSURL *url = [NSURL fileURLWithPath:self];
	if ([url getResourceValue:&fileType forKey:NSURLContentTypeKey error:NULL] && fileType) {
		UTType *otherType = [UTType typeWithIdentifier:type];
		return otherType && [fileType conformsToType:otherType];
	}
	return NO;
}

- (CFUUIDBytes)uuidBytes {
	CFUUIDBytes bytes = {0};
	CFUUIDRef uuidRef = CFUUIDCreateFromString(NULL, (__bridge CFStringRef)self);
	if (uuidRef) {
		bytes = CFUUIDGetUUIDBytes(uuidRef);
		CFRelease(uuidRef);
	}

	return bytes;
}

+ (NSString*)uuidStringWithBytes:(CFUUIDBytes)bytes {
	CFUUIDRef uuidRef = CFUUIDCreateFromUUIDBytes(NULL, bytes);
	CFStringRef uuidString = NULL;
	
	if (uuidRef) {
		uuidString = CFUUIDCreateString(NULL, uuidRef);
		CFRelease(uuidRef);
	}
	
	return (__bridge_transfer NSString*)uuidString;	
}


- (NSData *)decodeBase64 {
    return [self decodeBase64WithNewlines:YES];
}

- (NSData *)decodeBase64WithNewlines:(BOOL)encodedWithNewlines {
    //like OpenSSL's BIO_f_base64, yield empty data rather than nil for undecodable input
    NSDataBase64DecodingOptions options = encodedWithNewlines ? NSDataBase64DecodingIgnoreUnknownCharacters : 0;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:self options:options];
    return data ? data : [NSData data];
}

- (NSString *)firstNumberFromStringWithinRange:(NSRange)subRange isInRange:(NSRange *)foundRange{
    if (NSMaxRange(subRange)<=self.length) {
        NSString *thisString=[self substringWithRange:subRange];
        NSRange txtRange=[thisString rangeOfCharacterFromSet:[[NSCharacterSet whitespaceAndNewlineCharacterSet] invertedSet]];
        if ((txtRange.location!=NSNotFound)&&([thisString rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location==txtRange.location)) {
            NSPredicate *pred=[NSPredicate predicateWithFormat:@"SELF.length > 0"];
            NSArray *comp=[thisString componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet]invertedSet]];
            comp=[comp filteredArrayUsingPredicate:pred];
            NSString *numString=(NSString *)[comp objectAtIndex:0];
            NSRange numRange=[thisString rangeOfString:numString];
            if(NSMaxRange(numRange)<NSMaxRange(subRange)){
                if ([[thisString substringWithRange:NSMakeRange(NSMaxRange(numRange), 1)] isEqualToString:@"."]) {
                    //            numRange.location+=subRange.location;
                    *foundRange=numRange;
                    return numString;
                }
            }
        }
        
    }
    *foundRange=NSMakeRange(NSNotFound, 0);
    return @"";
}

- (NSInteger)isPairedCharacterWithMatchString:(NSString **)matchString{
    if (self.length==1) {
        unichar ch=[self characterAtIndex:0];
        NSInteger chNum=(NSInteger)ch;
        if (chNum==34){
             *matchString=@"\"";
            return 1;
        }
        static NSCharacterSet *leftSidePairCharacterSet;
        if(!leftSidePairCharacterSet){
            leftSidePairCharacterSet=[NSCharacterSet characterSetWithCharactersInString:@"([{"];
        }
        static NSCharacterSet *rightSidePairCharacterSet;
        if(!rightSidePairCharacterSet){
            rightSidePairCharacterSet=[NSCharacterSet characterSetWithCharactersInString:@")]}"];
        }
        
        if ([leftSidePairCharacterSet characterIsMember:ch]){
            if (chNum==91){//[@"[" isEqualToString:self]) {
                *matchString=@"]";
    //            return @"]";
            }else if (chNum==40){//([@"(" isEqualToString:self]) {
                *matchString=@")";
    //            return @")";
            }else if (chNum==123){//([@"{" isEqualToString:self]) {
                *matchString=@"}";
    //            return @"}";
            }
            return 2;
        }else if ([rightSidePairCharacterSet characterIsMember:ch]) {
             if (chNum==93){//if ([@"]" isEqualToString:self]) {
                *matchString=@"[";
            }else  if (chNum==41){//if ([@")" isEqualToString:self]) {
                *matchString=@"(";
            }else if (chNum==125){// if ([@"}" isEqualToString:self]) {
                *matchString=@"{";
            }
            return 0;
        }        
    }
    return -1;
//    return @"";
}

@end


@implementation NSMutableString (NV)

- (void)replaceTabsWithSpacesOfWidth:(NSInteger)tabWidth {
	NSAssert(tabWidth < 50 && tabWidth > 0, @"that's a ridiculous tab width");
	
	@try {
		NSRange tabRange, nextRange = NSMakeRange(0, [self length]);
		while ((tabRange = [self rangeOfString:@"\t" options:NSLiteralSearch range:nextRange]).location != NSNotFound) {
			
			NSInteger numberOfSpacesPerTab = tabWidth;
			NSUInteger locationOnLine = tabRange.location - [self lineRangeForRange:tabRange].location;
			if (numberOfSpacesPerTab != 0) {
				NSUInteger numberOfSpacesLess = locationOnLine % numberOfSpacesPerTab;
				numberOfSpacesPerTab = numberOfSpacesPerTab - numberOfSpacesLess;
			}
			//NSLog(@"loc on line: %d, numberOfSpacesPerTab: %d", locationOnLine, numberOfSpacesPerTab);
			
			NSMutableString *spacesString = [[NSMutableString alloc] initWithCapacity:numberOfSpacesPerTab];
			while (numberOfSpacesPerTab-- > 0) {
				[spacesString appendString:@" "];
			}
			
			[self replaceCharactersInRange:tabRange withString:spacesString];
			
			NSUInteger rangeLoc = MIN((tabRange.location + numberOfSpacesPerTab), [self length]);
			nextRange = NSMakeRange(rangeLoc, [self length] - rangeLoc);
		}
	} @catch (NSException *e) {
		NSLog(@"%@ got an exception: %@", NSStringFromSelector(_cmd), [e reason]);
	}
}

+ (NSMutableString*)newShortLivedStringFromFile:(NSString*)filename {
	NSStringEncoding anEncoding = NSMacOSRomanStringEncoding; //won't use this, doesn't matter
	
	return [self newShortLivedStringFromData:[NSMutableData dataWithContentsOfFile:filename options:NSUncachedRead error:NULL] 
						   ofGuessedEncoding:&anEncoding withPath:[filename fileSystemRepresentation]];
}

+ (NSMutableString*)newShortLivedStringFromData:(NSMutableData*)data ofGuessedEncoding:(NSStringEncoding*)encoding withPath:(const char*)aPath {
	//this will fail if data lacks a BOM, but try it first as it's the fastest check
	NSMutableString* stringFromData = [data newStringUsingBOMReturningEncoding:encoding];
	if (stringFromData) {
		return stringFromData;
	}
	
	//TODO: there are some false positives for UTF-8 detection; e.g., the MacOSRoman-encoded copyright symbol
	
	//if it's just 7-bit ASCII, jump straight to the fastest encoding; don't even try UTF-8 (but report UTF-8, anyway)
	BOOL hasHighASCII = ContainsHighAscii([data bytes], [data length]);
	CFStringEncoding cfasciiEncoding = CFStringGetSystemEncoding() == kCFStringEncodingMacRoman ? kCFStringEncodingMacRoman : kCFStringEncodingASCII;
	NSStringEncoding firstEncodingToTry = hasHighASCII ? NSUTF8StringEncoding : CFStringConvertEncodingToNSStringEncoding(cfasciiEncoding);
	
#define AddIfUnique(enc) if (!ContainsUInteger(encodingsToTry, encodingIndex, (enc))) encodingsToTry[encodingIndex++] = (enc)
	
	NSStringEncoding encodingsToTry[5];
	NSUInteger encodingIndex = 0;
	
	AddIfUnique(firstEncodingToTry);
	
	if (hasHighASCII) {
		//check the file on disk for extended attributes only if absolutely necessary
		NSStringEncoding extendedAttrsEncoding = 0;
		if (aPath) {
			extendedAttrsEncoding = [[NSFileManager defaultManager] textEncodingAttributeOfFSPath:aPath];
		}
		if (extendedAttrsEncoding) AddIfUnique(extendedAttrsEncoding);
	}
	AddIfUnique(*encoding);
	NSStringEncoding systemEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringGetSystemEncoding());
	AddIfUnique(systemEncoding);
	AddIfUnique(NSMacOSRomanStringEncoding);
	
	encodingIndex = 0;
	do {
		stringFromData = [[NSMutableString alloc] initWithBytesNoCopy:[data mutableBytes] length:[data length] 
															 encoding:encodingsToTry[encodingIndex] freeWhenDone:NO];
	} while (!stringFromData && ++encodingIndex < 5);
		
	if (stringFromData) {
		NSAssert(encodingIndex < 5, @"got valid string from data, but encodingIndex is too high!");
		//report ASCII files as UTF-8 data in case this encoding will be used for future writes of a note
		*encoding = hasHighASCII ? encodingsToTry[encodingIndex] : NSUTF8StringEncoding;
		return stringFromData;
	}
		
	return nil;
}

@end

@implementation NSCharacterSet (NV)


+ (NSCharacterSet*)labelSeparatorCharacterSet {
	static NSMutableCharacterSet *charSet = nil;
	if (!charSet) {
		charSet = [NSMutableCharacterSet whitespaceCharacterSet];
		[charSet formUnionWithCharacterSet:[NSCharacterSet characterSetWithCharactersInString:@",;"]];
	}

	return charSet;
}

+ (NSCharacterSet*)listBulletsCharacterSet {
	static NSCharacterSet *charSet = nil;
	if (!charSet) {
		charSet = [NSCharacterSet characterSetWithCharactersInString:[NSString stringWithFormat:@"-+*!%C%C%C", 0x2022, 0x2014, 0x2013]];
	}
	
	return charSet;
	
}


@end



@implementation NSEvent (NV)

- (unichar)firstCharacter {
	NSString *chars = [self characters];
	if ([chars length]) return [chars characterAtIndex:0];
	return USHRT_MAX;
}

- (unichar)firstCharacterIgnoringModifiers {
	NSString *chars = [self charactersIgnoringModifiers];
	if ([chars length]) return [chars characterAtIndex:0];
	return USHRT_MAX;
}

@end
