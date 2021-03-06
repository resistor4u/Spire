
#import <Foundation/Foundation.h>
#include <CoreFoundation/CFPropertyList.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <string.h>
#include <stdint.h>

#include "partial.h"
#import "SPLogging.h"

#define kSPUpdateZIPURL @"http://appldnld.apple.com/iPhone4/041-3249.20111103.Qswe3/com_apple_MobileAsset_SoftwareUpdate/554f7813ac09d45256faad560b566814c983bd4b.zip"
#define kSPUpdateZIPRootPath @"AssetData/payload/replace/"
#define kSPWorkingDirectory @"/tmp/spire/"


void SavePropertyList(CFPropertyListRef plist, char *path, CFURLRef url, CFPropertyListFormat format) {
    if (path[0] != '\0')
        url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (uint8_t *) path, strlen(path), false);
    CFWriteStreamRef stream = CFWriteStreamCreateWithFile(kCFAllocatorDefault, url);
    CFWriteStreamOpen(stream);
    CFPropertyListWriteToStream(plist, stream, format, NULL);
    CFWriteStreamClose(stream);
}


@interface SPSiriInstaller : NSObject {

}

@end


@implementation SPSiriInstaller

- (NSArray *)directories {
    static NSArray *cached = nil;

    if (cached == nil) {
        NSMutableArray *valid = [NSMutableArray array];
        NSArray *files = [[NSString stringWithContentsOfFile:@"/var/spire/dirs.txt" encoding:NSUTF8StringEncoding error:NULL] componentsSeparatedByString:@"\n"];

        for (NSString *file in files) {
            if ([[file stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] != 0) {
                [valid addObject:file];
            }
        }

        // FIXME: this is a memory leak
        cached = [valid copy];
    }

    return cached;
}

- (NSArray *)files {
    static NSArray *cached = nil;

    if (cached == nil) {
        NSMutableArray *valid = [NSMutableArray array];
        NSArray *files = [[NSString stringWithContentsOfFile:@"/var/spire/files.txt" encoding:NSUTF8StringEncoding error:NULL] componentsSeparatedByString:@"\n"];

        for (NSString *file in files) {
            if ([[file stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] != 0) {
                [valid addObject:file];
            }
        }

        // FIXME: this is a memory leak
        cached = [valid copy];
    }

    return cached;
}

typedef struct {
    CDFile *lastFile;
    FILE *fd;
    size_t charactersToSkip;
} downloadCurrentFileData;

size_t downloadFileCallback(ZipInfo* info, CDFile* file, unsigned char *buffer, size_t size, void *userInfo)
{
	downloadCurrentFileData *fileData = userInfo;
	if (fileData->lastFile != file) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		if (fileData->lastFile)
			fclose(fileData->fd);
		fileData->lastFile = file;
		if (file) {
			unsigned char *zipFileName = PartialZipCopyFileName(info, file);
			NSString *diskFileName = [kSPWorkingDirectory stringByAppendingFormat:@"%s", zipFileName + fileData->charactersToSkip];
			free(zipFileName);

		    [[NSFileManager defaultManager] createDirectoryAtPath:[diskFileName stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
			fileData->fd = fopen([diskFileName UTF8String], "wb");
		}
		[pool drain];
	}
	return fwrite(buffer, size, 1, fileData->fd) ? size : 0;
}

- (ZipInfo *)openZipFile {
    ZipInfo *info = PartialZipInit([kSPUpdateZIPURL UTF8String]);
	return info;
}

- (BOOL)downloadFilesFromZip:(ZipInfo *)info {
    BOOL success = YES;

	NSArray *files = [self files];

	NSInteger count = [files count];
	CDFile *fileReferences[count];
	int i = 0;
    for (NSString *path in files) {
        NSString *zipPath = [kSPUpdateZIPRootPath stringByAppendingString:path];
        CDFile *file = PartialZipFindFile(info, [zipPath UTF8String]);
        if (file == NULL) {
            SPLog(@"Unable to find file %@", path);
            return NO;
        }
        fileReferences[i++] = file;
    }

	downloadCurrentFileData data = { NULL, NULL, 26 };
	PartialZipGetFiles(info, fileReferences, count, downloadFileCallback, &data);
	downloadFileCallback(info, NULL, NULL, 0, &data);

    return success;
}

- (BOOL)installItemAtCachePath:(NSString *)cachePath intoPath:(NSString *)path {
    BOOL success = YES;
    NSError *error = nil;

    NSString *resolvedCachePath = [kSPWorkingDirectory stringByAppendingString:cachePath];
    NSString *resolvedGlobalPath = [@"/" stringByAppendingString:path];

    // Assume that any file already there is valid (XXX: is this a valid assumption?)
    if (![[NSFileManager defaultManager] fileExistsAtPath:resolvedGlobalPath]) {
        success = [[NSFileManager defaultManager] moveItemAtPath:resolvedCachePath toPath:resolvedGlobalPath error:&error];
        if (!success) { SPLog(@"Unable to move item into installed position. (%@)", [error localizedDescription]); return success; }

        int ret = chmod([resolvedGlobalPath UTF8String], 0755);
        if (ret != 0) { success = NO; SPLog(@"Unable to chmod file: %d", errno); return success; }
    }

    return success;
}

- (BOOL)installFiles {
    BOOL success = YES;

    for (NSString *path in [self files]) {
        success = [self installItemAtCachePath:path intoPath:path];
        if (!success) { SPLog(@"Unable to install file: %@", path); break; }
    }

    return success;
}

- (BOOL)createDirectoriesInRootPath:(NSString *)path {
    BOOL success = YES;

    for (NSString *dir in [self directories]) {
        // creating directories is always successful: if it fails, the directory is already there!
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByAppendingString:dir] withIntermediateDirectories:NO attributes:nil error:NULL];
    }

    return success;
}

- (BOOL)createDirectories {
    return [self createDirectoriesInRootPath:@"/"];
}

- (void)applyAlternativeSharedCacheToEnvironmentVariables:(NSMutableDictionary *)ev {
    if ([[ev objectForKey:@"DYLD_SHARED_CACHE_DIR"] length] == 0) {
        [ev setObject:@"/var/spire" forKey:@"DYLD_SHARED_CACHE_DIR"];
    }

    if ([[ev objectForKey:@"DYLD_SHARED_REGION"] length] == 0) {
        [ev setObject:@"private" forKey:@"DYLD_SHARED_REGION"];
    }

    if ([[ev objectForKey:@"DYLD_SHARED_CACHE_DONT_VALIDATE"] length] == 0) {
        [ev setObject:@"1" forKey:@"DYLD_SHARED_CACHE_DONT_VALIDATE"];
    }
}

- (void)applyMobileSubstrateToEnvironmentVariables:(NSMutableDictionary *)ev {
    if ([[ev objectForKey:@"DYLD_INSERT_LIBRARIES"] length] == 0) {
        [ev setObject:@"/Library/MobileSubstrate/MobileSubstrate.dylib" forKey:@"DYLD_INSERT_LIBRARIES"];
    }
}

- (BOOL)applyMobileSubstrateToDaemonAtPath:(const char *)path {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (uint8_t *) path, strlen(path), false);

    CFPropertyListRef plist; {
        CFReadStreamRef stream = CFReadStreamCreateWithFile(kCFAllocatorDefault, url);
        CFReadStreamOpen(stream);
        plist = CFPropertyListCreateFromStream(kCFAllocatorDefault, stream, 0, kCFPropertyListMutableContainers, NULL, NULL);
        CFReadStreamClose(stream);
    }

    NSMutableDictionary *root = (NSMutableDictionary *) plist;
    if (root == nil) return NO;
    NSMutableDictionary *ev = [root objectForKey:@"EnvironmentVariables"];
    if (ev == nil) {
        ev = [NSMutableDictionary dictionary];
        [root setObject:ev forKey:@"EnvironmentVariables"];
    }

	[self applyMobileSubstrateToEnvironmentVariables:ev];

    SavePropertyList(plist, "", url, kCFPropertyListBinaryFormat_v1_0);
    return YES;
}

- (BOOL)applyAlternativeCacheToDaemonAtPath:(const char *)path {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (uint8_t *) path, strlen(path), false);

    CFPropertyListRef plist; {
        CFReadStreamRef stream = CFReadStreamCreateWithFile(kCFAllocatorDefault, url);
        CFReadStreamOpen(stream);
        plist = CFPropertyListCreateFromStream(kCFAllocatorDefault, stream, 0, kCFPropertyListMutableContainers, NULL, NULL);
        CFReadStreamClose(stream);
    }

    NSMutableDictionary *root = (NSMutableDictionary *) plist;
    if (root == nil) return NO;
    NSMutableDictionary *ev = [root objectForKey:@"EnvironmentVariables"];
    if (ev == nil) {
        ev = [NSMutableDictionary dictionary];
        [root setObject:ev forKey:@"EnvironmentVariables"];
    }

	[self applyAlternativeSharedCacheToEnvironmentVariables:ev];

    SavePropertyList(plist, "", url, kCFPropertyListBinaryFormat_v1_0);
    return YES;
}

- (BOOL)applyAlternativeCacheToAppAtPath:(const char *)path {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (uint8_t *) path, strlen(path), false);

    CFPropertyListRef plist; {
        CFReadStreamRef stream = CFReadStreamCreateWithFile(kCFAllocatorDefault, url);
        CFReadStreamOpen(stream);
        plist = CFPropertyListCreateFromStream(kCFAllocatorDefault, stream, 0, kCFPropertyListMutableContainers, NULL, NULL);
        CFReadStreamClose(stream);
    }

    NSMutableDictionary *root = (NSMutableDictionary *) plist;
    if (root == nil) return NO;
    NSMutableDictionary *ev = [root objectForKey:@"LSEnvironment"];
    if (ev == nil) {
        ev = [NSMutableDictionary dictionary];
        [root setObject:ev forKey:@"LSEnvironment"];
    }

	[self applyAlternativeSharedCacheToEnvironmentVariables:ev];

    SavePropertyList(plist, "", url, kCFPropertyListBinaryFormat_v1_0);
    return YES;
}

- (BOOL)setupSharedCacheFromZip:(ZipInfo *)info {
    BOOL success = YES;

	NSString *zipPath = [kSPUpdateZIPRootPath stringByAppendingString:@"System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7"];
	CDFile *file = PartialZipFindFile(info, [zipPath UTF8String]);
	if (!file) { SPLog(@"Failed to find dyld_shared_cache_armv7"); return NO; }

	downloadCurrentFileData data = { NULL, NULL, 63 };
	success = PartialZipGetFile(info, file, downloadFileCallback, &data);
    if (!success) { SPLog(@"Failed downloading shared cache."); return success; }
	downloadFileCallback(info, NULL, NULL, 0, &data);

    success = [self installItemAtCachePath:@"dyld_shared_cache_armv7" intoPath:@"var/spire/dyld_shared_cache_armv7"];
    if (!success) { SPLog(@"Failed installing cache."); return success; }

    success = [self applyAlternativeCacheToAppAtPath:"/Applications/Preferences.app/Info.plist"];
    if (!success) { SPLog(@"Failed applying cache to Preferences."); return success; }

    success = [self applyAlternativeCacheToDaemonAtPath:"/System/Library/LaunchDaemons/com.apple.SpringBoard.plist"];
    if (!success) { SPLog(@"Failed applying cache to SpringBoard."); return success; }

    success = [self applyAlternativeCacheToDaemonAtPath:"/System/Library/LaunchDaemons/com.apple.assistantd.plist"];
    if (!success) { SPLog(@"Failed applying cache to assistantd."); return success; }

    success = [self applyMobileSubstrateToDaemonAtPath:"/System/Library/LaunchDaemons/com.apple.assistantd.plist"];
    if (!success) { SPLog(@"Failed applying MobileSubstrate to assistantd."); return success; }

    success = [self applyAlternativeCacheToDaemonAtPath:"/System/Library/LaunchDaemons/com.apple.assistant_service.plist"];
    if (!success) { SPLog(@"Failed applying MobileSubstrate to assistantd."); return success; }

    return success;
}

- (BOOL)addCapabilities {
    static char platform[1024];
    size_t len = sizeof(platform);
    int ret = sysctlbyname("hw.model", &platform, &len, NULL, 0);
    if (ret == -1) { SPLog(@"sysctlbyname failed."); return NO; }

    NSString *platformPath = [NSString stringWithFormat:@"/System/Library/CoreServices/SpringBoard.app/%s.plist", platform];
    const char *path = [platformPath UTF8String];

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault, (uint8_t *) path, strlen(path), false);

    CFPropertyListRef plist; {
        CFReadStreamRef stream = CFReadStreamCreateWithFile(kCFAllocatorDefault, url);
        CFReadStreamOpen(stream);
        plist = CFPropertyListCreateFromStream(kCFAllocatorDefault, stream, 0, kCFPropertyListMutableContainers, NULL, NULL);
        CFReadStreamClose(stream);
    }

    NSMutableDictionary *root = (NSMutableDictionary *) plist;
    if (root == nil) return NO;
    NSMutableDictionary *capabilities = [root objectForKey:@"capabilities"];
    if (capabilities == nil) return NO;

    NSNumber *yes = [NSNumber numberWithBool:YES];
    [capabilities setObject:yes forKey:@"mars-volta"];
    [capabilities setObject:yes forKey:@"assistant"];

    SavePropertyList(plist, "", url, kCFPropertyListBinaryFormat_v1_0);

    return YES;
}

- (BOOL)createCache {
    BOOL success =  YES;

    success = [[NSFileManager defaultManager] createDirectoryAtPath:kSPWorkingDirectory withIntermediateDirectories:NO attributes:nil error:NULL];
    success = [self createDirectoriesInRootPath:kSPWorkingDirectory];

    return success;
}

- (BOOL)cleanUp {
    return [[NSFileManager defaultManager] removeItemAtPath:kSPWorkingDirectory error:NULL];
}

- (BOOL)install {
    BOOL success = YES;

    SPLog(@"Preparing...");
    [self cleanUp];

    SPLog(@"Creating download cache.");
    success = [self createCache];
    if (!success) { SPLog(@"Failed creating cache."); return success; }

    SPLog(@"Opening remote ZIP.");
	ZipInfo *info = [self openZipFile];
	if (!info) { [self cleanUp]; return false; }

    SPLog(@"Downloading files to cache.");
    success = [self downloadFilesFromZip:info];
    if (!success) { PartialZipRelease(info); [self cleanUp]; SPLog(@"Failed downloading files."); return success; }

    SPLog(@"Creating install directories.");
    success = [self createDirectories];
    if (!success) { PartialZipRelease(info); [self cleanUp]; SPLog(@"Failed creating directories."); return success; }

    SPLog(@"Installing downloaded files.");
    success = [self installFiles];
    if (!success) { PartialZipRelease(info); [self cleanUp];  SPLog(@"Failed installing files."); return success; }

    SPLog(@"Setting up shared cache.");
    success = [self setupSharedCacheFromZip:info];
    if (!success) { PartialZipRelease(info); [self cleanUp];  SPLog(@"Failed setting up shared cache."); return success; }

    PartialZipRelease(info);

    SPLog(@"Modifying system files.");
    success = [self addCapabilities];
    if (!success) { [self cleanUp]; SPLog(@"Failed adding capabilities."); return success; }

    SPLog(@"Cleaning up.");
    [self cleanUp];

    SPLog(@"Done!");
    return success;
}

@end


int main(int argc, char **argv, char **envp) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    SPSiriInstaller *installer = [[SPSiriInstaller alloc] init];
    BOOL success = [installer install];
    [installer release];

    [pool release];

	return (success ? 0 : 1);
}


