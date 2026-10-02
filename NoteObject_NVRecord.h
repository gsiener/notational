//
//  NoteObject_NVRecord.h
//  Notation
//
//  Converts between the app's in-memory notes (NoteObject) and the Notes store's
//  records (NVNoteRecord). See docs/adr/0001-simplenote-backed-storage.md.
//

#import "NoteObject.h"

@class NVNoteRecord;

@interface NoteObject (NVRecord)

- (id)initWithNoteRecord:(NVNoteRecord *)record delegate:(id)aDelegate;

//Simplenote id of this note; assigned on first use for notes created in nvALT
- (NSString *)noteRecordID;

//the note as a store record (content recombined exactly; tags from labels; dates in 1970 seconds)
- (NVNoteRecord *)noteRecordRepresentation;

//Replace title, body, labels and dates with the record's. Returns YES if anything visible changed.
//The delegate hears about the change as for an edit, but the note isn't dirtied and no write is
//scheduled: the record is already in the store.
- (BOOL)applyNoteRecord:(NVNoteRecord *)record;

@end
