#import "ResourceSize.h"

long long LiveResourceFileSize(PHAssetResource *resource) {
    @try {
        id value = [resource valueForKey:@"fileSize"];
        if ([value isKindOfClass:[NSNumber class]]) {
            return [(NSNumber *)value longLongValue];
        }
    } @catch (NSException *exception) {
        return 0;
    }
    return 0;
}

static int LiveResourceLocalityForKey(PHAssetResource *resource, NSString *key) {
    @try {
        id value = [resource valueForKey:key];
        if ([value isKindOfClass:[NSNumber class]]) {
            return [(NSNumber *)value boolValue] ? 1 : 0;
        }
    } @catch (NSException *exception) {
        return -1;
    }
    return -1;
}

BOOL LiveResourceIsLocal(PHAssetResource *resource) {
    int locality = LiveResourceLocalityForKey(resource, @"locallyAvailable");
    if (locality < 0) {
        locality = LiveResourceLocalityForKey(resource, @"isLocallyAvailable");
    }
    // Unknown is not evidence the file is only in iCloud. Download and Keep
    // Originals, and a key that does not report eviction, both look local.
    return locality != 0;
}
