//
//  NVNoteDelegate.h
//  Notation
//

#import <Cocoa/Cocoa.h>

@class NoteObject;

//what a note tells, and asks of, the notes controller that owns it (#2); a note works without one
@protocol NVNoteDelegate <NSObject>
- (void)note:(NoteObject *)note attributeChanged:(NSString *)attribute;
- (void)note:(NoteObject *)note didAddLabelSet:(NSSet *)labelSet;
- (void)note:(NoteObject *)note didRemoveLabelSet:(NSSet *)labelSet;
- (void)scheduleWriteForNote:(NoteObject *)note;
//the note's text changed (e.g. from sync or an external editor): whoever shows it should refresh
- (void)noteContentsDidChange:(NoteObject *)note;
//width available to the title column, for the list's title and body preview
- (float)titleColumnWidth;
- (NSImage *)labelImageForWord:(NSString *)word highlighted:(BOOL)highlighted;
@end

