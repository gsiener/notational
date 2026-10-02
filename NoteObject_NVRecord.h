//
//  NoteObject_NVRecord.h
//  Notation
//
//  Converts between the app's in-memory notes (NoteObject) and the Notes store's
//  records (NVNoteRecord). See docs/adr/0001-simplenote-backed-storage.md.
//

#import "NoteObject.h"

@class NVNoteRecord, NVNoteContent;

@interface NoteObject (NVRecord)

- (id)initWithNoteRecord:(NVNoteRecord *)record delegate:(id)aDelegate;

//A new note made from content (see -[NSMutableAttributedString trimLeadingTitle]): content's title,
//and body, which is content's body as styled text, perhaps with something added to its top. It is
//stored as content's leading space, title and separator then the body, so the note has from the
//start the title and body it will have when read back from the store.
- (id)initWithNoteBody:(NSAttributedString *)body content:(NVNoteContent *)content delegate:(id)aDelegate labels:(NSString *)labels;

//Simplenote id of this note; assigned on first use for notes created in nvALT
- (NSString *)noteRecordID;

//the note as a store record (content recombined exactly; tags from labels, split as the tag UI
//splits them; dates in 1970 seconds)
- (NVNoteRecord *)noteRecordRepresentation;

//Replace title, body, labels and dates with the record's. Returns YES if anything visible changed.
//The delegate hears about the change as for an edit, but the note isn't dirtied and no write is
//scheduled: the record is already in the store.
- (BOOL)applyNoteRecord:(NVNoteRecord *)record;

@end
