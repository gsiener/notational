//
//  NVNoteContent.h
//  Notation
//
//  Splits Simplenote's single `content` string into nvALT's title and body, and
//  recombines them so that a note nobody edited round-trips byte for byte
//  (ADR 0001 §9): leading whitespace, the exact separator between title and body,
//  and an empty first line are all remembered.
//

#import <Foundation/Foundation.h>

@interface NVNoteContent : NSObject <NSCopying>

+ (NVNoteContent *)contentWithString:(NSString *)content;

//shown in the notes list; "Untitled Note" when the first line is empty
@property (nonatomic, readonly) NSString *title;
@property (nonatomic, readonly) NSString *body;
//the verbatim content this was split from
@property (nonatomic, readonly) NSString *string;

//Content for an edited title and/or body, reusing this split's leading whitespace and
//separator. Returns -string unchanged when neither changed.
- (NSString *)stringWithTitle:(NSString *)title body:(NSString *)body;

@end
