//
//  NVArchiving.h
//  Notation
//
//  Archiving helpers: new data is always written with NSKeyedArchiver; the one place that still
//  understands the pre-10.2 NSArchiver format (values nvALT stored in user defaults) lives here.
//

#import <Foundation/Foundation.h>

//the data for a keyed archive of `object` (no secure-coding requirement; the app's own NSCoding classes don't adopt it)
NSData *NVKeyedArchivedData(id object);

//the root object of a keyed archive made by NVKeyedArchivedData (or the old +archivedDataWithRootObject:), or nil if `data` isn't a readable keyed archive
id NVUnarchiveKeyedObject(NSData *data);

//decodes a value saved in user defaults: a keyed archive (written by this app) or, failing that, an NSArchiver
//typedstream (written by nvALT). Returns nil for nil, empty or unreadable data.
id NVUnarchivePreferenceValue(NSData *data);
