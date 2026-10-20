#import <Photos/Photos.h>

long long LiveResourceFileSize(PHAssetResource *resource);

/// YES when this resource is stored on the device. A missing key or an
/// unexpected value is treated as local so a failed lookup does not offer
/// the whole library as iCloud-only.
BOOL LiveResourceIsLocal(PHAssetResource *resource);
