//
//  MachServer.m
//  mac-virtualcam
//
//  Created by John Boiles  on 5/5/20.
//

#import "OBSDALMachServer.h"
#include <obs-module.h>
#include <CoreVideo/CoreVideo.h>
#include "MachProtocol.h"
#include "Defines.h"

@interface OBSDALMachServer () <NSPortDelegate>
@property NSPort *port;
@property NSMutableSet *clientPorts;
@property NSRunLoop *runLoop;
@end

@implementation OBSDALMachServer

- (id)init
{
	if (self = [super init]) {
		self.clientPorts = [[NSMutableSet alloc] init];
	}
	return self;
}

- (void)dealloc
{
	blog(LOG_DEBUG, "tearing down MachServer");
	[self.runLoop removePort:self.port forMode:NSDefaultRunLoopMode];
	[self.port invalidate];
	self.port.delegate = nil;
}

- (void)run
{
	if (self.port != nil) {
		blog(LOG_DEBUG, "mach server already running!");
		return;
	}

// It's a bummer this is deprecated. The replacement, NSXPCConnection, seems to require
// an assistant process that lives inside the .app bundle. This would be more modern, but adds
// complexity and I think makes it impossible to just run the `obs` binary from the commandline.
// So let's stick with NSMachBootstrapServer at least until it fully goes away.
// At that point we can decide between NSXPCConnection and using the CoreFoundation versions of
// these APIs (which are, interestingly, not deprecated)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
	self.port = [[NSMachBootstrapServer sharedInstance]
		servicePortWithName:@MACH_SERVICE_NAME];
#pragma clang diagnostic pop
	if (self.port == nil) {
		// This probably means another instance is running.
		blog(LOG_ERROR, "Unable to open mach server port.");
		return;
	}

	self.port.delegate = self;

	self.runLoop = [NSRunLoop currentRunLoop];
	[self.runLoop addPort:self.port forMode:NSDefaultRunLoopMode];

	blog(LOG_DEBUG, "mach server running!");
}

- (void)handlePortMessage:(NSPortMessage *)message
{
	switch (message.msgid) {
	case MachMsgIdConnect:
		if (message.sendPort != nil) {
			blog(LOG_DEBUG,
			     "mach server received connect message from port %d!",
			     ((NSMachPort *)message.sendPort).machPort);
			[self.clientPorts addObject:message.sendPort];
		}
		break;
	default:
		blog(LOG_ERROR, "Unexpected mach message ID %u",
		     (unsigned)message.msgid);
		break;
	}
}

- (void)sendMessageToClientsWithMsgId:(uint32_t)msgId
			   components:(nullable NSArray *)components
{
	if ([self.clientPorts count] <= 0) {
		return;
	}

	NSMutableSet *removedPorts = [NSMutableSet set];

	for (NSPort *port in self.clientPorts) {
		@try {
			NSPortMessage *message = [[NSPortMessage alloc]
				initWithSendPort:port
				     receivePort:nil
				      components:components];
			message.msgid = msgId;
			if (![message
				    sendBeforeDate:
					    [NSDate dateWithTimeIntervalSinceNow:
							    1.0]]) {
				blog(LOG_DEBUG,
				     "failed to send message to %d, removing it from the clients!",
				     ((NSMachPort *)port).machPort);
				[removedPorts addObject:port];
			}
		} @catch (NSException *exception) {
			blog(LOG_DEBUG,
			     "failed to send message (exception) to %d, removing it from the clients!",
			     ((NSMachPort *)port).machPort);
			[removedPorts addObject:port];
		}
	}

	// Remove dead ports if necessary
	[self.clientPorts minusSet:removedPorts];
}

- (void)sendFrameWithPixelBuffer:(CVPixelBufferRef)frame
		       timestamp:(uint64_t)timestamp
		    fpsNumerator:(uint32_t)fpsNumerator
		  fpsDenominator:(uint32_t)fpsDenominator
{
	if ([self.clientPorts count] <= 0) {
		return;
	}

	@autoreleasepool {
		NSData *timestampData = [NSData
			dataWithBytes:&timestamp
			       length:sizeof(timestamp)];
		NSData *fpsNumeratorData = [NSData
			dataWithBytes:&fpsNumerator
			       length:sizeof(fpsNumerator)];
		NSData *fpsDenominatorData = [NSData
			dataWithBytes:&fpsDenominator
			       length:sizeof(fpsDenominator)];

		mach_port_t framePort = IOSurfaceCreateMachPort(
			CVPixelBufferGetIOSurface(frame));

		if (!framePort) {
			blog(LOG_ERROR,
			     "unable to allocate mach port for pixel buffer");
			return;
		}

		[self sendMessageToClientsWithMsgId:MachMsgIdFrame
					 components:@[
						 [NSMachPort portWithMachPort:
								     framePort],
						 timestampData,
						 fpsNumeratorData,
						 fpsDenominatorData
					 ]];

		mach_port_deallocate(mach_task_self(), framePort);
	}
}

- (void)stop
{
	blog(LOG_DEBUG, "sending stop message to %lu clients",
	     self.clientPorts.count);
	[self sendMessageToClientsWithMsgId:MachMsgIdStop components:nil];
}

@end
