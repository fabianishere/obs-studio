#include <obs-module.h>
#include <AppKit/AppKit.h>
#include "OBSDALMachServer.h"
#include "Defines.h"

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("mac-virtualcam", "en-US")
MODULE_EXPORT const char *obs_module_description(void)
{
	return "macOS virtual webcam output";
}

obs_output_t *outputRef;
obs_video_info videoInfo;
CVPixelBufferPoolRef pool;
static OBSDALMachServer *sMachServer;

static bool check_dal_plugin()
{
	NSFileManager *fileManager = [NSFileManager defaultManager];

	NSString *dalPluginDestinationPath =
		@"/Library/CoreMediaIO/Plug-Ins/DAL/";
	NSString *dalPluginFileName =
		@"/Library/CoreMediaIO/Plug-Ins/DAL/obs-mac-virtualcam.plugin";

	BOOL dalPluginDirExists =
		[fileManager fileExistsAtPath:dalPluginDestinationPath];
	BOOL dalPluginInstalled =
		[fileManager fileExistsAtPath:dalPluginFileName];
	BOOL dalPluginUpdateNeeded = NO;

	if (dalPluginInstalled) {
		NSDictionary *dalPluginInfoPlist = [NSDictionary
			dictionaryWithContentsOfURL:
				[NSURL fileURLWithPath:
						@"/Library/CoreMediaIO/Plug-Ins/DAL/obs-mac-virtualcam.plugin/Contents/Info.plist"]];
		NSString *dalPluginVersion = [dalPluginInfoPlist
			valueForKey:@"CFBundleShortVersionString"];
		NSString *dalPluginBuild =
			[dalPluginInfoPlist valueForKey:@"CFBundleVersion"];

		NSString *obsVersion = [[[NSBundle mainBundle] infoDictionary]
			objectForKey:@"CFBundleShortVersionString"];
		NSString *obsBuild = [[[NSBundle mainBundle] infoDictionary]
			objectForKey:(NSString *)kCFBundleVersionKey];
		dalPluginUpdateNeeded =
			!([dalPluginVersion isEqualToString:obsVersion] &&
			  [dalPluginBuild isEqualToString:obsBuild]);
	}

	if (!dalPluginInstalled || dalPluginUpdateNeeded) {
		NSString *dalPluginSourcePath;

		NSURL *bundleURL = [[NSBundle mainBundle] bundleURL];
		NSString *pluginPath =
			@"Contents/Resources/obs-mac-virtualcam.plugin";

		NSURL *pluginUrl =
			[bundleURL URLByAppendingPathComponent:pluginPath];
		dalPluginSourcePath = [pluginUrl path];

		NSString *createPluginDirCmd =
			(!dalPluginDirExists)
				? [NSString stringWithFormat:
						    @"mkdir -p '%@' && ",
						    dalPluginDestinationPath]
				: @"";
		NSString *deleteOldPluginCmd =
			(dalPluginUpdateNeeded)
				? [NSString stringWithFormat:@"rm -rf '%@' && ",
							     dalPluginFileName]
				: @"";
		NSString *copyPluginCmd =
			[NSString stringWithFormat:@"cp -R '%@' '%@'",
						   dalPluginSourcePath,
						   dalPluginDestinationPath];
		if ([fileManager fileExistsAtPath:dalPluginSourcePath]) {
			NSString *copyCmd = [NSString
				stringWithFormat:
					@"do shell script \"%@%@%@\" with administrator privileges",
					createPluginDirCmd, deleteOldPluginCmd,
					copyPluginCmd];

			NSDictionary *errorDict;
			NSAppleEventDescriptor *returnDescriptor = NULL;
			NSAppleScript *scriptObject =
				[[NSAppleScript alloc] initWithSource:copyCmd];
			returnDescriptor =
				[scriptObject executeAndReturnError:&errorDict];
			if (errorDict != nil) {
				const char *errorMessage = [[errorDict
					objectForKey:@"NSAppleScriptErrorMessage"]
					UTF8String];
				blog(LOG_INFO,
				     "[macOS] VirtualCam DAL Plugin Installation status: %s",
				     errorMessage);
				return false;
			}
		} else {
			blog(LOG_INFO,
			     "[macOS] VirtualCam DAL Plugin not shipped with OBS");
			return false;
		}
	}
	return true;
}

FourCharCode convert_video_format_to_mac(enum video_format format)
{
	switch (format) {
	case VIDEO_FORMAT_I420:
		return kCVPixelFormatType_420YpCbCr8Planar;
	case VIDEO_FORMAT_NV12:
		return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
	case VIDEO_FORMAT_UYVY:
		return kCVPixelFormatType_422YpCbCr8;
	default:
		// Zero indicates that the format is not supported on macOS
		// Note that some formats do have an associated constant, but
		// constructing such formats fails with kCVReturnInvalidPixelFormat.
		return 0;
	}
}

static const char *virtualcam_output_get_name(void *type_data)
{
	(void)type_data;
	return obs_module_text("Plugin_Name");
}

// This is a dummy pointer so we have something to return from virtualcam_output_create
static void *data = &data;

static void *virtualcam_output_create(obs_data_t *settings,
				      obs_output_t *output)
{
	UNUSED_PARAMETER(settings);

	outputRef = output;

	blog(LOG_DEBUG, "output_create");
	sMachServer = [[OBSDALMachServer alloc] init];
	return data;
}

static void virtualcam_output_destroy(void *data)
{
	UNUSED_PARAMETER(data);
	blog(LOG_DEBUG, "output_destroy");
	sMachServer = nil;
}

static bool virtualcam_output_start(void *data)
{
	UNUSED_PARAMETER(data);

	bool hasDalPlugin = check_dal_plugin();

	if (!hasDalPlugin) {
		return false;
	}

	blog(LOG_DEBUG, "output_start");

	obs_get_video_info(&videoInfo);

	FourCharCode video_format =
		convert_video_format_to_mac(videoInfo.output_format);

	if (!video_format) {
		// Selected output format is not supported natively by CoreVideo, CPU conversion necessary
		blog(LOG_WARNING,
		     "Selected output format (%s) not supported by CoreVideo, enabling CPU transcoding...",
		     get_video_format_name(videoInfo.output_format));

		struct video_scale_info conversion = {};
		conversion.format = VIDEO_FORMAT_NV12;
		conversion.width = videoInfo.output_width;
		conversion.height = videoInfo.output_height;
		obs_output_set_video_conversion(outputRef, &conversion);

		video_format = convert_video_format_to_mac(conversion.format);
	}

	NSDictionary *pAttr = @{};
	NSDictionary *pbAttr = @{
		(id)kCVPixelBufferPixelFormatTypeKey: @(video_format),
		(id)kCVPixelBufferWidthKey: @(videoInfo.output_width),
		(id)kCVPixelBufferHeightKey: @(videoInfo.output_height),
		(id)kCVPixelBufferIOSurfacePropertiesKey: @{}
	};
	CVReturn status = CVPixelBufferPoolCreate(
		kCFAllocatorDefault, (__bridge CFDictionaryRef)pAttr,
		(__bridge CFDictionaryRef)pbAttr, &pool);
	if (status != kCVReturnSuccess) {
		blog(LOG_ERROR,
		     "unable to allocate pixel buffer pool (error %d)", status);
		return false;
	}

	[sMachServer run];

	if (!obs_output_begin_data_capture(outputRef, 0)) {
		return false;
	}

	return true;
}

static void virtualcam_output_stop(void *data, uint64_t ts)
{
	UNUSED_PARAMETER(data);
	UNUSED_PARAMETER(ts);

	blog(LOG_DEBUG, "output_stop");
	obs_output_end_data_capture(outputRef);
	[sMachServer stop];

	CVPixelBufferPoolRelease(pool);
}

static void virtualcam_output_raw_video(void *data, struct video_data *frame)
{
	UNUSED_PARAMETER(data);

	CVPixelBufferRef frameRef = NULL;
	CVReturn status = CVPixelBufferPoolCreatePixelBuffer(
		kCFAllocatorDefault, pool, &frameRef);

	if (status != kCVReturnSuccess) {
		blog(LOG_ERROR, "unable to allocate pixel buffer (error %d)",
		     status);
		return;
	}

	// Copy all planes into pixel buffer
	size_t planeCount = CVPixelBufferGetPlaneCount(frameRef);
	CVPixelBufferLockBaseAddress(frameRef, 0);

	if (planeCount == 0) {
		uint8_t *src = frame->data[0];
		uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddress(frameRef);

		size_t destBytesPerRow = CVPixelBufferGetBytesPerRow(frameRef);
		size_t srcBytesPerRow = frame->linesize[0];
		size_t height = CVPixelBufferGetHeight(frameRef);

		// Sometimes CVPixelBufferCreate will create a pixel buffer that's a different
		// size than necessary to hold the frame (probably for some optimization reason).
		// If that is the case this will do a row-by-row copy into the buffer.
		if (destBytesPerRow == srcBytesPerRow) {
			memcpy(dst, src, destBytesPerRow * height);
		} else {
			for (int line = 0; (size_t)line < height; line++) {
				memcpy(dst, src, srcBytesPerRow);
				src += srcBytesPerRow;
				dst += destBytesPerRow;
			}
		}
	} else {
		for (size_t plane = 0; plane < planeCount; plane++) {
			uint8_t *src = frame->data[plane];

			if (!src) {
				blog(LOG_WARNING,
				     "Video data from OBS contains less planes than CVPixelBuffer");
				break;
			}

			uint8_t *dst =
				(uint8_t *)CVPixelBufferGetBaseAddressOfPlane(
					frameRef, plane);

			size_t destBytesPerRow =
				CVPixelBufferGetBytesPerRowOfPlane(frameRef,
								   plane);
			size_t srcBytesPerRow = frame->linesize[plane];
			size_t height =
				CVPixelBufferGetHeightOfPlane(frameRef, plane);

			if (destBytesPerRow == srcBytesPerRow) {
				memcpy(dst, src, destBytesPerRow * height);
			} else {
				for (int line = 0; (size_t)line < height;
				     line++) {
					memcpy(dst, src, srcBytesPerRow);
					src += srcBytesPerRow;
					dst += destBytesPerRow;
				}
			}
		}
	}

	CVPixelBufferUnlockBaseAddress(frameRef, 0);

	// Share pixel buffer with clients
	[sMachServer sendFrameWithPixelBuffer:frameRef
				    timestamp:frame->timestamp
				 fpsNumerator:videoInfo.fps_num
			       fpsDenominator:videoInfo.fps_den];

	CVPixelBufferRelease(frameRef);
}

struct obs_output_info virtualcam_output_info = {
	.id = "virtualcam_output",
	.flags = OBS_OUTPUT_VIDEO,
	.get_name = virtualcam_output_get_name,
	.create = virtualcam_output_create,
	.destroy = virtualcam_output_destroy,
	.start = virtualcam_output_start,
	.stop = virtualcam_output_stop,
	.raw_video = virtualcam_output_raw_video,
};

bool obs_module_load(void)
{
	obs_register_output(&virtualcam_output_info);

	obs_data_t *obs_settings = obs_data_create();
	obs_data_set_bool(obs_settings, "vcamEnabled", true);
	obs_apply_private_data(obs_settings);
	obs_data_release(obs_settings);

	return true;
}
