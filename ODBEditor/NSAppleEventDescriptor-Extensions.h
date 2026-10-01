#import <Foundation/Foundation.h>

@interface NSAppleEventDescriptor(Extensions)

+ (NSAppleEventDescriptor *)descriptorWithFilePath:(NSString *)fileName;

@end
