#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioUnit/AudioUnit.h>
#import <AudioToolbox/AudioToolbox.h>
#include <signal.h>

// Global variables
AudioUnit audioUnit;
ExtAudioFileRef audioFileRef = NULL;
AudioStreamBasicDescription clientFormat;

// Declare volatile flags to indicate termination and playback completion
volatile sig_atomic_t gShouldExit = 0;
volatile sig_atomic_t gPlaybackFinished = 0;

// Signal handler function
void handle_sigint(int signum) {
    gShouldExit = 1;
}

// Function to list all available output devices
NSArray<NSDictionary *> *listOutputDevices(void) {
    NSMutableArray<NSDictionary *> *devices = [NSMutableArray array];
    
    // Define the property address to get all audio devices
    AudioObjectPropertyAddress propertyAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
    };
    
    // Get the size of the data
    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize);
    if (status != noErr) {
        NSLog(@"Error getting property data size: %d", status);
        return devices;
    }
    
    // Calculate the number of devices
    UInt32 deviceCount = dataSize / sizeof(AudioDeviceID);
    AudioDeviceID *deviceIDs = malloc(dataSize);
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize, deviceIDs);
    if (status != noErr) {
        NSLog(@"Error getting device IDs: %d", status);
        free(deviceIDs);
        return devices;
    }
    
    // Iterate through each device and get its name and UID
    for (UInt32 i = 0; i < deviceCount; i++) {
        AudioDeviceID deviceID = deviceIDs[i];
        
        // Get device name
        CFStringRef deviceNameCF = NULL;
        UInt32 nameSize = sizeof(deviceNameCF);
        AudioObjectPropertyAddress nameProperty = {
            kAudioObjectPropertyName,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMaster
        };
        status = AudioObjectGetPropertyData(deviceID, &nameProperty, 0, NULL, &nameSize, &deviceNameCF);
        NSString *deviceName = status == noErr ? (__bridge NSString *)(deviceNameCF) : @"Unknown";
        
        // Get device UID
        CFStringRef deviceUIDCF = NULL;
        UInt32 uidSize = sizeof(deviceUIDCF);
        AudioObjectPropertyAddress uidProperty = {
            kAudioDevicePropertyDeviceUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMaster
        };
        status = AudioObjectGetPropertyData(deviceID, &uidProperty, 0, NULL, &uidSize, &deviceUIDCF);
        NSString *deviceUID = status == noErr ? (__bridge NSString *)(deviceUIDCF) : @"Unknown";
        
        // Add device info to the array
        NSDictionary *deviceInfo = @{
            @"DeviceID": @(deviceID),
            @"Name": deviceName,
            @"UID": deviceUID
        };
        [devices addObject:deviceInfo];
        
        if (deviceNameCF) {
            CFRelease(deviceNameCF);
        }
        if (deviceUIDCF) {
            CFRelease(deviceUIDCF);
        }
    }
    
    free(deviceIDs);
    return devices;
}

// Function to get the default output device ID
AudioDeviceID getDefaultOutputDevice(void) {
    AudioDeviceID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);
    AudioObjectPropertyAddress propertyAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
    };
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                 &propertyAddress,
                                                 0,
                                                 NULL,
                                                 &size,
                                                 &deviceID);
    if (status != noErr) {
        NSLog(@"Error getting default output device: %d", status);
    }
    return deviceID;
}

// Function to get the current hog PID
pid_t getCurrentHogPID(AudioDeviceID deviceID) {
    pid_t hogPID = -1;
    UInt32 size = sizeof(hogPID);
    AudioObjectPropertyAddress propertyAddress = {
        kAudioDevicePropertyHogMode,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
    };
    OSStatus status = AudioObjectGetPropertyData(deviceID,
                                                 &propertyAddress,
                                                 0,
                                                 NULL,
                                                 &size,
                                                 &hogPID);
    if (status != noErr) {
        NSLog(@"Failed to get current hog PID: %d", status);
    }
    return hogPID;
}

// Function to set exclusive access (hog mode)
void setExclusiveAccess(AudioDeviceID deviceID) {
    pid_t hogPID = getpid(); // Your application's PID
    UInt32 size = sizeof(hogPID);
    AudioObjectPropertyAddress propertyAddress = {
        kAudioDevicePropertyHogMode,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
    };
    OSStatus status = AudioObjectSetPropertyData(deviceID,
                                                 &propertyAddress,
                                                 0,
                                                 NULL,
                                                 size,
                                                 &hogPID);
    if (status != noErr) {
        NSLog(@"Failed to set exclusive access: %d", status);
    } else {
        NSLog(@"Exclusive access granted.");
    }
}

// Function to release exclusive access
void releaseExclusiveAccess(AudioDeviceID deviceID) {
    pid_t hogPID = -1; // -1 releases hog mode
    UInt32 size = sizeof(hogPID);
    AudioObjectPropertyAddress propertyAddress = {
        kAudioDevicePropertyHogMode,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
    };
    OSStatus status = AudioObjectSetPropertyData(deviceID,
                                                 &propertyAddress,
                                                 0,
                                                 NULL,
                                                 size,
                                                 &hogPID);
    if (status != noErr) {
        NSLog(@"Failed to release exclusive access: %d", status);
    } else {
        NSLog(@"Exclusive access released.");
    }
}

// Function to initialize the audio file
BOOL initializeAudioFile(const char *filePath) {
    // Check if the file exists
    NSString *filePathString = [NSString stringWithUTF8String:filePath];
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:filePathString];
    if (!fileExists) {
        NSLog(@"Audio file does not exist at path: %s", filePath);
        return NO;
    }

    CFURLRef fileURL = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
                                                                 (const UInt8 *)filePath,
                                                                 strlen(filePath),
                                                                 false);
    if (fileURL == NULL) {
        NSLog(@"Failed to create file URL.");
        return NO;
    }

    OSStatus status = ExtAudioFileOpenURL(fileURL, &audioFileRef);
    CFRelease(fileURL);

    if (status != noErr) {
        NSLog(@"Failed to open audio file: %d", status);
        return NO;
    }

    // Get the file's audio format
    AudioStreamBasicDescription fileFormat;
    UInt32 size = sizeof(fileFormat);
    status = ExtAudioFileGetProperty(audioFileRef,
                                     kExtAudioFileProperty_FileDataFormat,
                                     &size,
                                     &fileFormat);
    if (status != noErr) {
        NSLog(@"Failed to get file data format: %d", status);
        ExtAudioFileDispose(audioFileRef);
        audioFileRef = NULL;
        return NO;
    }

    // Set the client format to match the device's format
    clientFormat.mSampleRate = 44100.0;
    clientFormat.mFormatID = kAudioFormatLinearPCM;
    clientFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    clientFormat.mBytesPerPacket = sizeof(Float32) * 2; // Stereo
    clientFormat.mFramesPerPacket = 1;
    clientFormat.mBytesPerFrame = sizeof(Float32) * 2; // Stereo
    clientFormat.mChannelsPerFrame = 2; // Stereo
    clientFormat.mBitsPerChannel = 32;
    clientFormat.mReserved = 0;

    status = ExtAudioFileSetProperty(audioFileRef,
                                     kExtAudioFileProperty_ClientDataFormat,
                                     sizeof(clientFormat),
                                     &clientFormat);
    if (status != noErr) {
        NSLog(@"Failed to set client data format: %d", status);
        ExtAudioFileDispose(audioFileRef);
        audioFileRef = NULL;
        return NO;
    }

    return YES;
}

// Render callback function
OSStatus renderCallback(void *inRefCon,
                        AudioUnitRenderActionFlags *ioActionFlags,
                        const AudioTimeStamp *inTimeStamp,
                        UInt32 inBusNumber,
                        UInt32 inNumberFrames,
                        AudioBufferList *ioData) {
    if (audioFileRef == NULL) {
        // Fill with silence if no audio file is loaded
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        }
        return noErr;
    }

    // Prepare a buffer list to read data
    AudioBufferList bufferList;
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0].mNumberChannels = clientFormat.mChannelsPerFrame;
    bufferList.mBuffers[0].mDataByteSize = inNumberFrames * sizeof(Float32) * clientFormat.mChannelsPerFrame;
    bufferList.mBuffers[0].mData = malloc(bufferList.mBuffers[0].mDataByteSize);
    if (bufferList.mBuffers[0].mData == NULL) {
        NSLog(@"Failed to allocate memory for audio data.");
        // Fill with silence on error
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        }
        return noErr;
    }

    UInt32 framesToRead = inNumberFrames;
    OSStatus status = ExtAudioFileRead(audioFileRef, &framesToRead, &bufferList);
    if (status != noErr) {
        NSLog(@"Failed to read audio data: %d", status);
        free(bufferList.mBuffers[0].mData);
        // Fill with silence on error
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        }
        return noErr;
    }

    // If end of file reached, set the playback finished flag
    if (framesToRead < inNumberFrames) {
        NSLog(@"End of audio file reached.");
        gPlaybackFinished = 1; // Signal that playback has finished

        // Fill the remaining frames with silence
        memset(((Float32 *)bufferList.mBuffers[0].mData) + framesToRead * clientFormat.mChannelsPerFrame, 0,
               (inNumberFrames - framesToRead) * sizeof(Float32) * clientFormat.mChannelsPerFrame);
    }

    // Copy the data to ioData
    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
        memcpy(ioData->mBuffers[i].mData, bufferList.mBuffers[0].mData, bufferList.mBuffers[0].mDataByteSize);
    }

    free(bufferList.mBuffers[0].mData);

    return noErr;
}

// Function to set up the audio unit with a specific device
void setupAudioUnit(AudioDeviceID selectedDeviceID) {
    AudioComponentDescription desc = {0};
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_HALOutput; // HAL Output
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (comp == NULL) {
        NSLog(@"Failed to find HALOutput AudioComponent.");
        return;
    }

    OSStatus status = AudioComponentInstanceNew(comp, &audioUnit);
    if (status != noErr) {
        NSLog(@"Failed to create audio unit instance: %d", status);
        return;
    }

    // Set the selected device as the output device
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioOutputUnitProperty_CurrentDevice,
                                  kAudioUnitScope_Global,
                                  0,
                                  &selectedDeviceID,
                                  sizeof(selectedDeviceID));
    if (status != noErr) {
        NSLog(@"Failed to set current device: %d", status);
        return;
    }

    // Enable output on the audio unit
    UInt32 enableIO = 1;
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Output,
                                  0, // Output bus
                                  &enableIO,
                                  sizeof(enableIO));
    if (status != noErr) {
        NSLog(@"Failed to enable IO on output scope: %d", status);
        return;
    }

    // Disable input on the audio unit
    enableIO = 0;
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Input,
                                  1, // Input bus
                                  &enableIO,
                                  sizeof(enableIO));
    if (status != noErr) {
        NSLog(@"Failed to disable IO on input scope: %d", status);
        return;
    }

    // Get the device's audio format
    AudioStreamBasicDescription deviceFormat;
    UInt32 size = sizeof(deviceFormat);
    status = AudioUnitGetProperty(audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Output,
                                  0,
                                  &deviceFormat,
                                  &size);
    if (status != noErr) {
        NSLog(@"Failed to get device stream format: %d", status);
        return;
    }

    // Set the audio unit's input format to match the device's format
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  0,
                                  &deviceFormat,
                                  size);
    if (status != noErr) {
        NSLog(@"Failed to set stream format: %d", status);
        return;
    }

    // Set the render callback
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = renderCallback;
    callbackStruct.inputProcRefCon = NULL;
    status = AudioUnitSetProperty(audioUnit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input,
                                  0,
                                  &callbackStruct,
                                  sizeof(callbackStruct));
    if (status != noErr) {
        NSLog(@"Failed to set render callback: %d", status);
        return;
    }

    // Initialize the audio unit
    status = AudioUnitInitialize(audioUnit);
    if (status != noErr) {
        NSLog(@"Failed to initialize audio unit: %d", status);
        return;
    }

    NSLog(@"Audio unit setup complete with selected device.");
}

// Function to start the audio unit
void startAudioUnit(void) {
    OSStatus status = AudioOutputUnitStart(audioUnit);
    if (status != noErr) {
        NSLog(@"Failed to start audio unit: %d", status);
        return;
    }
    NSLog(@"Audio unit started.");
}

// Function to stop the audio unit
void stopAudioUnit(void) {
    OSStatus status = AudioOutputUnitStop(audioUnit);
    if (status != noErr) {
        NSLog(@"Failed to stop audio unit: %d", status);
        return;
    }
    AudioUnitUninitialize(audioUnit);
    AudioComponentInstanceDispose(audioUnit);
    NSLog(@"Audio unit stopped and disposed.");
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // List available output devices
        NSArray<NSDictionary *> *outputDevices = listOutputDevices();
        if (outputDevices.count == 0) {
            NSLog(@"No output devices found.");
            return -1;
        }
        
        NSLog(@"Available Output Devices:");
        for (NSUInteger i = 0; i < outputDevices.count; i++) {
            NSDictionary *device = outputDevices[i];
            NSLog(@"%lu: %@ (UID: %@)", (unsigned long)i, device[@"Name"], device[@"UID"]);
        }
        
        // Ensure audio file path is provided
        if (argc < 2) {
            NSLog(@"Usage: %s <path_to_audio_file> [output_device_index_or_name]", argv[0]);
            return -1;
        }
        
        const char *filePath = argv[1];
        
        // Handle device selection if provided
        NSString *selectedDeviceName = nil;
        AudioDeviceID deviceID = kAudioObjectUnknown;
        
        if (argc >= 3) {
            NSString *deviceArg = [NSString stringWithUTF8String:argv[2]];
            
            // Try interpreting the device argument as an index
            NSInteger deviceIndex = [deviceArg integerValue];
            if ([deviceArg integerValue] >= 0 && [deviceArg integerValue] < outputDevices.count) {
                deviceIndex = [deviceArg integerValue];
                selectedDeviceName = outputDevices[deviceIndex][@"Name"];
            } else {
                // If not a valid index, treat it as a device name
                selectedDeviceName = deviceArg;
            }
            
            // Search for the device by name
            BOOL deviceFound = NO;
            for (NSDictionary *device in outputDevices) {
                if ([device[@"Name"] isEqualToString:selectedDeviceName]) {
                    deviceID = [device[@"DeviceID"] unsignedIntValue];
                    deviceFound = YES;
                    break;
                }
            }
            
            if (!deviceFound) {
                NSLog(@"Device named '%@' not found. Exiting.", selectedDeviceName);
                return -1;
            }
        } else {
            // Use the default output device if no device is specified
            deviceID = getDefaultOutputDevice();
            if (deviceID == kAudioObjectUnknown) {
                NSLog(@"No default output device found.");
                return -1;
            }
        }
        
        // Initialize the audio file
        if (!initializeAudioFile(filePath)) {
            NSLog(@"Failed to initialize audio file.");
            return -1;
        }
        
        // Check if the device is already hogged
        pid_t currentHogPID = getCurrentHogPID(deviceID);
        if (currentHogPID == -1 || currentHogPID == 0) {
            // Device is free
            setExclusiveAccess(deviceID);
        } else if (currentHogPID == getpid()) {
            // Already have exclusive access
            NSLog(@"Already have exclusive access.");
        } else {
            NSLog(@"Cannot obtain exclusive access. Device is hogged by PID: %d", currentHogPID);
            // Decide how to proceed (e.g., exit or use non-exclusive access)
            return -1;
        }
        
        // Set up the audio unit with the selected device
        setupAudioUnit(deviceID);
        startAudioUnit();
        
        // Set up the signal handler
        signal(SIGINT, handle_sigint);
        
        NSLog(@"Audio player is running. Press Ctrl+C to exit.");
        
        // Main loop
        while (!gShouldExit && !gPlaybackFinished) {
            // Run the run loop for a short duration to allow processing
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        }
        
        // Cleanup
        if (gPlaybackFinished) {
            NSLog(@"Playback finished. Exiting...");
        } else {
            NSLog(@"Received SIGINT. Exiting...");
        }
        
        stopAudioUnit();
        releaseExclusiveAccess(deviceID);
        if (audioFileRef != NULL) {
            ExtAudioFileDispose(audioFileRef);
        }
        
        return 0;
    }
}
