//
//  NVArchiving.m
//  Notation
//

#import "NVArchiving.h"

NSData *NVKeyedArchivedData(id object) {
	if (!object) return nil;
	NSError *error = nil;
	NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:NO error:&error];
	if (!data) NSLog(@"NVKeyedArchivedData: could not archive %@: %@", [object class], error);
	return data;
}

id NVUnarchiveKeyedObject(NSData *data) {
	if (![data length]) return nil;
	@try {
		NSError *error = nil;
		NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
		if (!unarchiver) return nil;
		[unarchiver setRequiresSecureCoding:NO];
		id object = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
		[unarchiver finishDecoding];
		return object;
	} @catch (NSException *e) {
		NSLog(@"NVUnarchiveKeyedObject: %@, %@", [e name], [e reason]);
		return nil;
	}
}

id NVUnarchivePreferenceValue(NSData *data) {
	if (![data length]) return nil;
	
	id object = NVUnarchiveKeyedObject(data);
	if (object) return object;
	
	//not a keyed archive: it may be an NSArchiver typedstream, which is how nvALT saved colours and fonts in user defaults.
	//NSUnarchiver is deprecated, but it is the only way to read those values, so existing users keep their settings.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	@try {
		return [NSUnarchiver unarchiveObjectWithData:data];
	} @catch (NSException *e) {
		NSLog(@"NVUnarchivePreferenceValue: %@, %@", [e name], [e reason]);
		return nil;
	}
#pragma clang diagnostic pop
}
