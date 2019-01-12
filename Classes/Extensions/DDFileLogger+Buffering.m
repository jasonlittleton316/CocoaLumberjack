// Software License Agreement (BSD License)
//
// Copyright (c) 2010-2018, Deusty, LLC
// All rights reserved.
//
// Redistribution and use of this software in source and binary forms,
// with or without modification, are permitted provided that the following conditions are met:
//
// * Redistributions of source code must retain the above copyright notice,
//   this list of conditions and the following disclaimer.
//
// * Neither the name of Deusty nor the names of its contributors may be used
//   to endorse or promote products derived from this software without specific
//   prior written permission of Deusty, LLC.

#import "DDFileLogger+Buffering.h"
#import "DDFileLogger+Internal.h"

#import <sys/mount.h>

static NSUInteger kDDDefaultBufferSize = 4096; // 4 kB, block f_bsize on iphone7
static NSUInteger kDDMaxBufferSize = 1048576; // ~1 mB, f_iosize on iphone7

// Reads attributes from base file system to determine buffer size.
// see statfs in sys/mount.h for descriptions of f_iosize and f_bsize.
static NSUInteger DDGetDefaultBufferSizeBytesMax(BOOL max) {
    struct statfs *mntbufp = NULL;
    int count = getmntinfo(&mntbufp, 0);

    for (int i = 0; i < count; i++) {
        const char *name = mntbufp[i].f_mntonname;
        if (strlen(name) == 1 && *name == '/') {
            return max ? mntbufp[i].f_iosize : mntbufp[i].f_bsize;
        }
    }

    return max ? kDDMaxBufferSize : kDDDefaultBufferSize;
}

@interface DDBufferedProxy : NSProxy

@property (nonatomic) DDFileLogger *fileLogger;
@property (nonatomic) NSOutputStream *buffer;

@property (nonatomic) NSUInteger maxBufferSizeBytes;
@property (nonatomic) NSUInteger currentBufferSizeBytes;

@end

@implementation DDBufferedProxy

@synthesize maxBufferSizeBytes = _maxBufferSizeBytes;

#pragma mark - Properties

- (void)setMaxBufferSizeBytes:(NSUInteger)maximumBytesCountInBuffer {
    const NSUInteger maxBufferLength = DDGetDefaultBufferSizeBytesMax(YES);
    _maxBufferSizeBytes = MIN(maximumBytesCountInBuffer, maxBufferLength);
}

#pragma mark - Initialization

- (instancetype)initWithFileLogger:(DDFileLogger *)fileLogger {
    _fileLogger = fileLogger;
    _maxBufferSizeBytes = DDGetDefaultBufferSizeBytesMax(NO);
    [self flushBuffer];

    return self;
}

- (void)dealloc {
    [self lt_sendBufferedDataToFileLogger];
    self.fileLogger = nil;
}

- (void)flushBuffer {
    [_buffer close];
    _buffer = [NSOutputStream outputStreamToMemory];
    _currentBufferSizeBytes = 0;
}

- (void)lt_sendBufferedDataToFileLogger {
    NSData *data = [_buffer propertyForKey:NSStreamDataWrittenToMemoryStreamKey];
    [_fileLogger lt_logData:data];
    [self flushBuffer];
}

#pragma mark - Logging

- (void)logMessage:(DDLogMessage *)logMessage {
    NSData *data = [_fileLogger lt_dataForMessage:logMessage];
    NSUInteger length = data.length;
    if (length == 0) {
        return;
    }

    [_buffer write:[data bytes] maxLength:length];
    _currentBufferSizeBytes += length;

    if (_currentBufferSizeBytes >= _maxBufferSizeBytes) {
        [self lt_sendBufferedDataToFileLogger];
    }
}

- (void)flush {
    // This method is public.
    // We need to execute the rolling on our logging thread/queue.

    dispatch_block_t block = ^{
        @autoreleasepool {
            [self lt_sendBufferedDataToFileLogger];
            [self.fileLogger flush];
        }
    };

    // The design of this method is taken from the DDAbstractLogger implementation.
    // For extensive documentation please refer to the DDAbstractLogger implementation.

    if ([self.fileLogger isOnInternalLoggerQueue]) {
        block();
    } else {
        dispatch_queue_t globalLoggingQueue = [DDLog loggingQueue];
        NSAssert(![self.fileLogger isOnGlobalLoggingQueue], @"Core architecture requirement failure");

        dispatch_sync(globalLoggingQueue, ^{
            dispatch_sync(self.fileLogger.loggerQueue, block);
        });
    }
}

#pragma mark - Wrapping

- (DDFileLogger *)wrapWithBuffer {
    return (DDFileLogger *)self;
}

- (DDFileLogger *)unwrapFromBuffer {
    return (DDFileLogger *)self.fileLogger;
}

#pragma mark - NSProxy

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [self.fileLogger methodSignatureForSelector:sel];
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [self.fileLogger respondsToSelector:aSelector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    [invocation invokeWithTarget:self.fileLogger];
}

@end

@implementation DDFileLogger (Buffering)

- (instancetype)wrapWithBuffer {
    return (DDFileLogger *)[[DDBufferedProxy alloc] initWithFileLogger:self];
}

- (instancetype)unwrapFromBuffer {
    return self;
}

@end
