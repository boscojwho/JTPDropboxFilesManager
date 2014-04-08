#import "JTPDropboxFilesManager.h"
#import <Dropbox/Dropbox.h>
#import <Reachability.h>
#import "UIAlertView+MKBlockAdditions.h"

static dispatch_queue_t managedFilesConcurrentQueue;
static dispatch_queue_t managedFilesSerialQueue;

static NSString* const JTPDropboxFilesManager_FileKey = @"JTPDropboxFilesManager_FileKey";
static NSString* const JTPDropboxFilesManager_OpenFileCompletionHandlerKey = @"JTPDropboxFilesManager_OpenFileCompletionHandlerKey";

@interface JTPDropboxFilesManager ()

/**
 Serial dispatch queues associated with a given DBFile. Labeled using [DBPath stringValue] key.
 */
@property (nonatomic, strong) NSMutableDictionary* managedFilesSerialQueues;

/**
 Serial dispatch queues associated with a given Dropbox folder path. Labeled using [DBPath stringValue] key.
 */
@property (nonatomic, strong) NSMutableDictionary* managedFoldersSerialQueues;

/**
 Instances of DBFile that are open.
 */
@property (nonatomic, strong) NSMutableDictionary* managedFiles;

@property (nonatomic, strong) NSTimer* ensureOpenedFileIsNewerVersionTimer;

@end

@implementation JTPDropboxFilesManager

+ (JTPDropboxFilesManager *)sharedManager
{
    static JTPDropboxFilesManager* sharedManager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [JTPDropboxFilesManager new];
    });
    return sharedManager;
}

- (id)init
{
    if (!(self = [super init])) return nil;
    
    _managedFiles = [NSMutableDictionary new];
    _managedFilesSerialQueues = [NSMutableDictionary new];
    
    managedFilesConcurrentQueue = dispatch_queue_create("com.boz.ios.JTPDropboxManagedFilesConcurrent", DISPATCH_QUEUE_CONCURRENT);
    managedFilesSerialQueue = dispatch_queue_create("com.boz.ios.JTPDropboxManagedFilesSerial", DISPATCH_QUEUE_SERIAL);
    
    return self;
}

#pragma mark - Create
- (void)createFile:(DBPath *)path completionHandler:(JTPDropboxFilesManagerCompletionHandler)completionHandler
{
    if (!path) {
        completionHandler(NO, nil, nil);
    }
    
    NSString* key = [self _keyForPath:path];
    dispatch_queue_t serialQueueForFile = [self _serialQueueForFileAtPath:path];
    dispatch_async(serialQueueForFile, ^{
        DBError* error;
        DBFile* file = [[DBFilesystem sharedFilesystem] createFile:path error:&error];
        
        dispatch_async(managedFilesSerialQueue, ^{
            if (error) {
                [self.managedFilesSerialQueues removeObjectForKey:key];
                completionHandler(NO, error, file);
            }
            else {
                [self.managedFiles setObject:file forKey:key];
                completionHandler(YES, error, file);
            }
        });
    });
}

- (void)createFolder:(DBPath *)path completionHandler:(JTPDropboxFilesManagerCreateFolderHandler)completionHandler
{
    if (!path) {
        completionHandler(NO, nil, path);
    }
    
    dispatch_queue_t serialQueueForFolder = [self _serialQueueForFolderAtPath:path];
    dispatch_async(serialQueueForFolder, ^{
        DBError* error;
        BOOL success = [[DBFilesystem sharedFilesystem] createFolder:path error:&error];
        
        dispatch_async(managedFilesSerialQueue, ^{
            NSString* key = [self _keyForPath:path];
            [self.managedFoldersSerialQueues removeObjectForKey:key];
            completionHandler(success, error, path);
        });
    });
}

#pragma mark - Open
- (void)openFile:(DBPath *)path completionHandler:(JTPDropboxFilesManagerCompletionHandler)completionHandler
{
    if (!path) {
        completionHandler(NO, nil, nil);
    }
    
    NSString* key = [self _keyForPath:path];
    
    __block DBFile* file;
    dispatch_async(managedFilesSerialQueue, ^{
        file = [self.managedFiles objectForKey:key];
    });
    
    if (!file) {
        dispatch_queue_t serialQueueForFile = [self _serialQueueForFileAtPath:path];
        dispatch_async(serialQueueForFile, ^{
            DBError* error;
            DBFile* file = [[DBFilesystem sharedFilesystem] openFile:path error:&error];
            if (error) {
                completionHandler(NO, error, file);
            }
            else {
                dispatch_async(managedFilesSerialQueue, ^{
                    [self.managedFiles setObject:file forKey:key];
                    [self _ensureOpenedFileIsNewerVersion:file completionHandler:completionHandler];
                });
            }
        });
    }
    else {
        [self _ensureOpenedFileIsNewerVersion:file completionHandler:completionHandler];
    }
}

- (DBFile *)fileForPath:(DBPath *)path
{
    NSString* key = [self _keyForPath:path];
    DBFile* file = [self.managedFiles objectForKey:key];
    return file;
}

#pragma mark - Read
- (void)readDataFromPath:(DBPath *)path completionHandler:(JTPDropboxFilesManagerReadDataHandler)completionHandler
{
    if (!path) {
        completionHandler(NO, nil, nil);
    }
    
    NSString* key = [self _keyForPath:path];
    dispatch_queue_t serialQueueForFile = [self _serialQueueForFileAtPath:path];
    
    dispatch_async(serialQueueForFile, ^{
        DBFile* file = [self.managedFiles objectForKey:key];
        DBError* error;
        NSData* data = [file readData:&error];
        if (error) {
            completionHandler(NO, error, data);
        }
        else {
            completionHandler(YES, error, data);
        }
    });
}

#pragma mark - Write
- (void)writeString:(NSString *)string toPath:(DBPath *)path completionHandler:(JTPDropboxFilesManagerCompletionHandler)completionHandler
{
    if (!path) {
        completionHandler(NO, nil, nil);
    }
    
    NSString* key = [self _keyForPath:path];
    dispatch_queue_t serialQueueForFile = [self _serialQueueForFileAtPath:path];
    
    dispatch_async(serialQueueForFile, ^{
        DBFile* file = [self.managedFiles objectForKey:key];
        DBError* error;
        BOOL success = [file writeString:string error:&error];
        completionHandler(success, error, file);
    });
}

#pragma mark - Close
- (void)closeFile:(DBPath *)path completionHandler:(JTPDropboxFilesManagerCloseFileHandler)completionHandler
{
    if (!path) {
        return;
    }
    
    NSString* key = [self _keyForPath:path];
    dispatch_queue_t serialQueueForFile = [self _serialQueueForFileAtPath:path];

    dispatch_async(serialQueueForFile, ^{
        DBFile* file = [self.managedFiles objectForKey:key];
        [file close];
        
        dispatch_async(managedFilesSerialQueue, ^{
            [self.managedFiles removeObjectForKey:key];
            [self.managedFilesSerialQueues removeObjectForKey:key];
            completionHandler();
        });
    });
}

#pragma mark - PRIVATE LOGIC
#pragma mark - Path-Key Mapping
- (NSString*)_keyForPath:(DBPath*)path
{
    return path.stringValue;
}

#pragma mark - Dispatch Queues
- (dispatch_queue_t)_serialQueueForFileAtPath:(DBPath*)path
{    
    NSString* key = [self _keyForPath:path];
    dispatch_queue_t serialQueueForFile = [self.managedFilesSerialQueues objectForKey:key];
    
    if (!serialQueueForFile) {
        const char *label = [key UTF8String];
        serialQueueForFile = dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
        [self.managedFilesSerialQueues setObject:serialQueueForFile forKey:key];
    }
    
    return serialQueueForFile;
}

- (dispatch_queue_t)_serialQueueForFolderAtPath:(DBPath*)path
{
    NSString* key = [self _keyForPath:path];
    dispatch_queue_t serialQueueForFolder = [self.managedFoldersSerialQueues objectForKey:key];
    
    if (!serialQueueForFolder) {
        const char *label = [key UTF8String];
        serialQueueForFolder = dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
        [self.managedFilesSerialQueues setObject:serialQueueForFolder forKey:key];
    }
    
    return serialQueueForFolder;
}

#pragma mark - File Updates
- (void)_ensureOpenedFileIsNewerVersion:(DBFile*)file completionHandler:(JTPDropboxFilesManagerCompletionHandler)completionHandler
{
    if (!file.newerStatus) {
        if (file.status.cached) {
            completionHandler(YES, nil, file);
        }
        else {
            Reachability* reachability = [Reachability reachabilityForInternetConnection];
            if ([reachability isReachable] && ![reachability isConnectionRequired] && ![reachability isConnectionOnDemand] && ![reachability isInterventionRequired]) {
                
                __weak DBFile* weakFile = file;
                
                [self.ensureOpenedFileIsNewerVersionTimer invalidate];
                self.ensureOpenedFileIsNewerVersionTimer = [NSTimer timerWithTimeInterval:20.0 target:self selector:@selector(_ensureOpenedFileIsNewerVersionFailureTimer:) userInfo:@{JTPDropboxFilesManager_OpenFileCompletionHandlerKey: completionHandler, JTPDropboxFilesManager_FileKey: file} repeats:NO];
                [[NSRunLoop mainRunLoop] addTimer:self.ensureOpenedFileIsNewerVersionTimer forMode:NSRunLoopCommonModes];
                
                [file addObserver:self block:^{
                    if (weakFile.status.cached) {
                        [self.ensureOpenedFileIsNewerVersionTimer invalidate];
                        [weakFile removeObserver:self];
                        
                        DBError* error;
                        BOOL success = [weakFile update:&error];
                        completionHandler(success, error, weakFile);
                    }
                }];
            }
            else {
                if (file.status.cached) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [UIAlertView alertViewWithTitle:@"No Internet Connection" message:@"Opening a previously cached version of the selected document." cancelButtonTitle:@"Dismiss" otherButtonTitles:nil onDismiss:NULL onCancel:^{
                            completionHandler(YES, nil, file);
                        }];
                    });
                }
                else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [UIAlertView alertViewWithTitle:@"No Internet Connection" message:@"The selected document cannot be opened because it has not yet been saved locally to your device." cancelButtonTitle:@"Dismiss" otherButtonTitles:nil onDismiss:NULL onCancel:^{
                            [[JTPDropboxFilesManager sharedManager] closeFile:file.info.path completionHandler:^{
                                completionHandler(NO, file.status.error, file);
                            }];
                        }];
                    });
                }
            }
        }
    }
    else {
        if (file.newerStatus.cached) {
            completionHandler(YES, nil, file);
        }
        else {
            Reachability* reachability = [Reachability reachabilityForInternetConnection];
            if ([reachability isReachable] && ![reachability isConnectionRequired] && ![reachability isConnectionOnDemand] && ![reachability isInterventionRequired]) {
                
                __weak DBFile* weakFile = file;
                
                [self.ensureOpenedFileIsNewerVersionTimer invalidate];
                self.ensureOpenedFileIsNewerVersionTimer = [NSTimer timerWithTimeInterval:20.0 target:self selector:@selector(_ensureOpenedFileIsNewerVersionFailureTimer:) userInfo:@{JTPDropboxFilesManager_OpenFileCompletionHandlerKey: completionHandler, JTPDropboxFilesManager_FileKey: file} repeats:NO];
                [[NSRunLoop mainRunLoop] addTimer:self.ensureOpenedFileIsNewerVersionTimer forMode:NSRunLoopCommonModes];
                
                [file addObserver:self block:^{
                    if (weakFile.newerStatus.cached) {
                        [self.ensureOpenedFileIsNewerVersionTimer invalidate];
                        [weakFile removeObserver:self];
                        
                        DBError* error;
                        BOOL success = [weakFile update:&error];
                        completionHandler(success, error, weakFile);
                    }
                }];
            }
            else {
                if (file.status.cached) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [UIAlertView alertViewWithTitle:@"No Internet Connection" message:@"Opening a previously cached version of the selected document." cancelButtonTitle:@"Dismiss" otherButtonTitles:nil onDismiss:NULL onCancel:^{
                            completionHandler(YES, nil, file);
                        }];
                    });
                }
                else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [UIAlertView alertViewWithTitle:@"No Internet Connection" message:@"The selected document cannot be opened because it has not yet been saved locally to your device." cancelButtonTitle:@"Dismiss" otherButtonTitles:nil onDismiss:NULL onCancel:^{
                            [[JTPDropboxFilesManager sharedManager] closeFile:file.info.path completionHandler:^{
                                completionHandler(NO, file.status.error, file);
                            }];
                        }];
                    });
                }
            }
        }
    }
}

- (void)_ensureOpenedFileIsNewerVersionFailureTimer:(NSTimer*)aTimer
{
    DBFile* file = aTimer.userInfo[JTPDropboxFilesManager_FileKey];
    [file removeObserver:self];
    
    [[JTPDropboxFilesManager sharedManager] closeFile:file.info.path completionHandler:^{
        JTPDropboxFilesManagerCompletionHandler completionHandler = aTimer.userInfo[JTPDropboxFilesManager_OpenFileCompletionHandlerKey];
        completionHandler(NO, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:@{NSLocalizedDescriptionKey: @"Document Download Timed-Out.", NSLocalizedFailureReasonErrorKey: @"Ensure you have a good internet connection, and try again."}], nil);
    }];
}

@end
