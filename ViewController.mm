/*
  This file is part of the Structure SDK.
  Copyright © 2019 Occipital, Inc. All rights reserved.
  http://structure.io
*/

#import "ViewController.h"
#import "Viewer-Swift.h"
#import <Structure/Structure.h>
#import <AVFoundation/AVFoundation.h>
#import <Accelerate/Accelerate.h>
#import <algorithm>

//------------------------------------------------------------------------------
//UILabel *fromLabel = [[UILabel alloc]initWithFrame:CGRectMake(0, 100, 380, 20)];

STDepthFrame *depthToSend;

static bool convertYCbCrToBGRA (size_t width,
                                size_t height,
                                const uint8_t* yData,
                                const uint8_t* cbcrData,
                                uint8_t* rgbaData,
                                uint8_t alpha,
                                size_t yBytesPerRow,
                                size_t cbCrBytesPerRow,
                                size_t rgbaBytesPerRow)
{
    assert(width <= rgbaBytesPerRow);
    
    // Input RGBA buffer:
    
    vImage_Buffer rgbaBuffer
    {
        .data = (void*)rgbaData,
        .width = (size_t)width,
        .height = (size_t)height,
        .rowBytes = rgbaBytesPerRow
    };
    
    // Destination Y, CbCr buffers:
    
    vImage_Buffer cbCrBuffer
    {
        .data = (void*)cbcrData,
        .width = (size_t)width/2,
        .height = (size_t)height/2,
        .rowBytes = (size_t)cbCrBytesPerRow // 2 bytes per pixel (Cb+Cr)
    };
    
    vImage_Buffer yBuffer
    {
        .data = (void*)yData,
        .width = (size_t)width,
        .height = (size_t)height,
        .rowBytes = (size_t)yBytesPerRow
    };
    
    vImage_Error error = kvImageNoError;
    
    // Conversion information:
    static vImage_YpCbCrToARGB info;
    {
        static bool infoGenerated = false;
        
        if(!infoGenerated)
        {
            vImage_Flags flags = kvImageNoFlags;
            
            vImage_YpCbCrPixelRange pixelRange
            {
                .Yp_bias =      0,
                .CbCr_bias =    128,
                .YpRangeMax =   255,
                .CbCrRangeMax = 255,
                .YpMax =        255,
                .YpMin =        0,
                .CbCrMax=       255,
                .CbCrMin =      1
            };
            
            error = vImageConvert_YpCbCrToARGB_GenerateConversion(
                                                                  kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
                                                                  &pixelRange,
                                                                  &info,
                                                                  kvImage420Yp8_CbCr8, kvImageARGB8888,
                                                                  flags
                                                                  );
            
            if (kvImageNoError != error)
                return false;
            
            infoGenerated = true;
        }
    }
    
    static const uint8_t permuteMapBGRA [4] { 3, 2, 1, 0 };
    error = vImageConvert_420Yp8_CbCr8ToARGB8888(&yBuffer,
                                                 &cbCrBuffer,
                                                 &rgbaBuffer,
                                                 &info,
                                                 permuteMapBGRA,
                                                 255,
                                                 kvImageNoFlags | kvImageDoNotTile // Disable multithreading.
                                                 );
    return kvImageNoError == error;
}

//------------------------------------------------------------------------------

struct AppStatus
{
    NSString* const   pleaseConnectSensorMessage = @"Please connect Structure Sensor.";
    NSString* const    pleaseChargeSensorMessage = @"Please charge Structure Sensor.";
    NSString* const needColorCameraAccessMessage = @"This app requires camera access to capture color.\nAllow access by going to Settings → Privacy → Camera.";
    NSString* const      sensorIsWakingUpMessage = @"Sensor is initializing. Please wait...";
    
    // Whether there is currently a message to show.
    bool needsDisplayOfStatusMessage = false;
    
    // Flag to disable entirely status message display.
    bool statusMessageDisabled = false;
};

//------------------------------------------------------------------------------

@interface ViewController () <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    STCaptureSession* _captureSession;

    UIImageView *_depthImageView;
    UIImageView *_normalsImageView;
    UIImageView *_colorImageView;
    
    uint8_t *_coloredDepthBuffer;
    uint8_t *_normalsBuffer;
    uint8_t *_colorImageBuffer;

    STNormalEstimator *_normalsEstimator;
    
    UILabel* _statusLabel;
    
    AppStatus _appStatus;
}



- (void)renderDepthFrame:(STDepthFrame*)depthFrame;
- (void)renderNormalsFrame:(STDepthFrame*)normalsFrame;
- (void)renderColorFrame:(CMSampleBufferRef)sampleBuffer;

@end

//------------------------------------------------------------------------------

@implementation ViewController

+ (instancetype) viewController
{
    return [[ViewController alloc] initWithNibName:@"ViewController" bundle:nil];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    
//    fromLabel.text = @"Distance : ";
//    fromLabel.numberOfLines = 1;
//    fromLabel.baselineAdjustment = UIBaselineAdjustmentAlignBaselines; // or UIBaselineAdjustmentAlignCenters, or UIBaselineAdjustmentNone
//    fromLabel.adjustsFontSizeToFitWidth = YES;
//    fromLabel.adjustsLetterSpacingToFitWidth = YES;
//    fromLabel.minimumScaleFactor = 10.0f/12.0f;
//    fromLabel.clipsToBounds = YES;
//    fromLabel.backgroundColor = [UIColor clearColor];
//    fromLabel.textColor = [UIColor blackColor];
//    fromLabel.textAlignment = NSTextAlignmentLeft;
//    [self.view addSubview:fromLabel];
    
    
    // Create an STCaptureSession instance
    _captureSession = [STCaptureSession newCaptureSession];
    
    NSDictionary* sensorConfig = @{
                                   kSTCaptureSessionOptionColorResolutionKey: @(STCaptureSessionColorResolution640x480),
                                   kSTCaptureSessionOptionDepthSensorVGAEnabledIfAvailableKey: @(YES),
                                   kSTCaptureSessionOptionColorMaxFPSKey: @(30.0f),
                                   kSTCaptureSessionOptionDepthSensorEnabledKey: @(YES),
                                   kSTCaptureSessionOptionUseAppleCoreMotionKey: @(YES),
                                   kSTCaptureSessionOptionSimulateRealtimePlaybackKey: @(YES),
                                   };
    
    // Set the lens detector on, and default lens state as "non-WVL" mode
    _captureSession.lens = STLensNormal;
    _captureSession.lensDetection = STLensDetectorOn;
    _captureSession.properties = @{
                                kSTCaptureSessionPropertyIOSCameraFocusValueKey:@(0),
    };
    
    // Set ourself as the delegate to receive sensor data.
    _captureSession.delegate = self;
    [_captureSession startMonitoringWithOptions:sensorConfig];
}

- (void)dealloc
{
    free(_coloredDepthBuffer);
    free(_normalsBuffer);
    free(_colorImageBuffer);
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
    static BOOL fromLaunch = YES;
    
    if(!fromLaunch)
        return;

    // Create a UILabel in the center of our view to display status messages.

    if (!_statusLabel)
    {
        // We do this here instead of in viewDidLoad so that we get the correctly size/rotation view bounds.
        _statusLabel = [[UILabel alloc] initWithFrame:self.view.bounds];
        _statusLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
        _statusLabel.textAlignment = NSTextAlignmentCenter;
        _statusLabel.font = [UIFont systemFontOfSize:35.0];
        _statusLabel.numberOfLines = 2;
        _statusLabel.textColor = [UIColor whiteColor];

        [self updateAppStatusMessage];
        
        [self.view addSubview: _statusLabel];
        [_statusLabel.layer setZPosition:1.0];
    }

    // Allocate the depth to surface normals converter class.
    _normalsEstimator = [[STNormalEstimator alloc] init];
  
    fromLaunch = NO;

    // From now on, make sure we get notified when the app becomes active to restore the sensor state if necessary.

    [[NSNotificationCenter defaultCenter]
        addObserver:self
        selector:@selector(appDidBecomeActive)
        name:UIApplicationDidBecomeActiveNotification
        object:nil
    ];
}

// Create the subview here to get the correctly size/rotation view bounds
-(void)viewDidLayoutSubviews
{
    #pragma mark - Only Color Frame is Displayed
    CGRect depthFrame = self.view.frame;
    depthFrame.size.height /= 2;
    depthFrame.origin.y = self.view.frame.size.height/2;
    depthFrame.origin.x = 1;
    depthFrame.origin.x = -self.view.frame.size.width * 0.25;
    
    CGRect normalsFrame = self.view.frame;
    normalsFrame.size.height /= 2;
    normalsFrame.origin.y = self.view.frame.size.height/2;
    normalsFrame.origin.x = 1;
    normalsFrame.origin.x = self.view.frame.size.width * 0.25;
    
    CGRect colorFrame = self.view.frame;
    colorFrame.origin.x = 200;
    colorFrame.origin.y = 80;
    colorFrame.size.width = 640;
    colorFrame.size.height = 480;
    
    _coloredDepthBuffer = NULL;
    _normalsBuffer = NULL;
    _colorImageBuffer = NULL;
    
    _depthImageView = [[UIImageView alloc] initWithFrame:depthFrame];
    _depthImageView.contentMode = UIViewContentModeScaleAspectFit;
    //[self.view addSubview:_depthImageView];
    
    _normalsImageView = [[UIImageView alloc] initWithFrame:normalsFrame];
    _normalsImageView.contentMode = UIViewContentModeScaleAspectFit;
    //[self.view addSubview:_normalsImageView];
    
    _colorImageView = [[UIImageView alloc] initWithFrame:colorFrame];
    _colorImageView.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:_colorImageView];
}

- (void)appDidBecomeActive
{
    [self updateAppStatusMessage];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

- (void)showAppStatusMessage:(NSString *)msg
{
    _appStatus.needsDisplayOfStatusMessage = true;
    
    [self.view.layer removeAllAnimations];

    [_statusLabel setText:msg];
    [_statusLabel setHidden:NO];
    
    // Progressively show the message label.

    [self.view setUserInteractionEnabled:false];
    [UIView
        animateWithDuration:0.5f
        animations:^{
            self->_statusLabel.alpha = 1.0f;
        }
        completion:nil
    ];
}

- (void)hideAppStatusMessage
{
    _appStatus.needsDisplayOfStatusMessage = false;

    [self.view.layer removeAllAnimations];
    
    [UIView
        animateWithDuration:0.5f
        animations:^{
            self->_statusLabel.alpha = 0.0f;
        }
        completion:^(BOOL finished) {

            // If nobody called showAppStatusMessage before the end of the animation, do not hide it.

            if (!self->_appStatus.needsDisplayOfStatusMessage)
            {
                [self->_statusLabel setHidden:YES];
                [self.view setUserInteractionEnabled:true];
            }
        }
    ];
}

-(void)updateAppStatusMessage
{
    // Skip everything if we should not show app status messages (e.g. in viewing state).
    if (_appStatus.statusMessageDisabled)
    {
        [self hideAppStatusMessage];
        return;
    }

    STCaptureSessionUserInstruction userInstructions = _captureSession.userInstructions;

    // First show sensor issues, if any.
    if (userInstructions & STCaptureSessionUserInstructionNeedToConnectSensor)
    {
        [self showAppStatusMessage:_appStatus.pleaseConnectSensorMessage];
        return;
    }

    if (_captureSession.sensorMode == STCaptureSessionSensorModeWakingUp)
    {
        [self showAppStatusMessage:_appStatus.sensorIsWakingUpMessage];
        return;
    }

    if (userInstructions & STCaptureSessionUserInstructionNeedToChargeSensor)
    {
        [self showAppStatusMessage:_appStatus.pleaseChargeSensorMessage];
    }

    // Then show color camera permission issues, if any.
    if (userInstructions & STCaptureSessionUserInstructionNeedToAuthorizeColorCamera)
    {
        [self showAppStatusMessage:_appStatus.needColorCameraAccessMessage];
        return;
    }

    // Ignore the FW update notification here, we don't need new firmware for Viewer.

    // If we reach this point, no status to show.
    [self hideAppStatusMessage];
}

-(bool) isConnected
{
    return _captureSession.sensorMode >= STCaptureSessionSensorModeNotConnected;
}

//------------------------------------------------------------------------------

#pragma mark - STCaptureSession Delegate Methods

- (void)captureSession:(STCaptureSession *)captureSession sensorDidEnterMode:(STCaptureSessionSensorMode)mode
{
    switch (mode)
    {
            #pragma mark - Stop/Start Streaming
        case STCaptureSessionSensorModeNotConnected:
            _captureSession.streamingEnabled = NO;
            break;
        case STCaptureSessionSensorModeStandby:
        case STCaptureSessionSensorModeWakingUp:
            break;
        case STCaptureSessionSensorModeReady:
            _captureSession.streamingEnabled = YES;
            break;
        case STCaptureSessionSensorModeBatteryDepleted:
            _captureSession.streamingEnabled = NO;
            break;
        // Fall through intentional
        case STCaptureSessionSensorModeUnknown:
        default:
            @throw [NSException exceptionWithName:@"Viewer"
                                           reason:@"Unknown STCaptureSessionSensorMode!"
                                         userInfo:nil];
            break;
    }
    [self updateAppStatusMessage];
}

- (void)captureSession:(STCaptureSession *)captureSession colorCameraDidEnterMode:(STCaptureSessionColorCameraMode)mode
{
    switch (mode)
    {
        case STCaptureSessionColorCameraModeReady:
            break;
        case STCaptureSessionColorCameraModePermissionDenied:
            break;
        // Fall through intentional
        case STCaptureSessionColorCameraModeUnknown:
        default:
            @throw [NSException exceptionWithName:@"Viewer"
                                           reason:@"Unknown STCaptureSessionColorCameraMode!"
                                         userInfo:nil];
            break;
    }
    [self updateAppStatusMessage];
}

- (void)captureSession:(STCaptureSession *)captureSession sensorChargerStateChanged:(STCaptureSessionSensorChargerState) chargerState
{
    switch (chargerState)
    {
        case STCaptureSessionSensorChargerStateConnected:
            break;
        case STCaptureSessionSensorChargerStateDisconnected:
            // Do nothing, we only need to handle low-power notifications based on the sensor mode.
            break;
        case STCaptureSessionSensorChargerStateUnknown:
        default:
            @throw [NSException exceptionWithName:@"Viewer"
                                           reason:@"Unknown STCaptureSessionSensorChargerState!"
                                         userInfo:nil];
            break;
    }
    [self updateAppStatusMessage];
}

- (void)captureSession:(STCaptureSession *)captureSession didStartAVCaptureSession:(AVCaptureSession *)avCaptureSession
{
}

- (void)captureSession:(STCaptureSession *)captureSession didStopAVCaptureSession:(AVCaptureSession *)avCaptureSession
{
}

- (void)captureSession:(STCaptureSession *)captureSession didOutputSample:(NSDictionary *)sample type:(STCaptureSessionSampleType)type
{
    // Rendering is performed on the main thread since we use UIKit APIs
    // See https://developer.apple.com/documentation/uikit/uiview#1652866
    switch (type)
    {
        case STCaptureSessionSampleTypeSensorDepthFrame:
        {
            STDepthFrame* depthFrame = [sample objectForKey:kSTCaptureSessionSampleEntryDepthFrame];
            [depthFrame applyExpensiveCorrection];
            dispatch_async(dispatch_get_main_queue(), ^{
#pragma mark - No need To Render them as they aren not displayed
                //[self renderDepthFrame:depthFrame];
                //[self renderNormalsFrame:depthFrame];
            });
            break;
        }
        case STCaptureSessionSampleTypeIOSColorFrame:
        {
            STColorFrame* colorFrame = [sample objectForKey:kSTCaptureSessionSampleEntryIOSColorFrame];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self renderColorFrame:colorFrame.sampleBuffer];
            });
            break;
        }
        case STCaptureSessionSampleTypeSynchronizedFrames:
        {
            STDepthFrame* depthFrame = [sample objectForKey:kSTCaptureSessionSampleEntryDepthFrame];
            STColorFrame* colorFrame = [sample objectForKey:kSTCaptureSessionSampleEntryIOSColorFrame];
            [depthFrame applyExpensiveCorrection];
            depthToSend = depthFrame;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self renderDepthFrame:depthFrame];
                [self renderNormalsFrame:depthFrame];
                [self renderColorFrame:colorFrame.sampleBuffer];
            });
            break;
        }
        case STCaptureSessionSampleTypeDeviceMotionData:
        case STCaptureSessionSampleTypeAccelData:
        case STCaptureSessionSampleTypeGyroData:
            // We'll always skip IMU / motion data. Adding cases here so as not
            // to spam the logs by saying "skipping capture session sample type 6".
            break;
        case STCaptureSessionSampleTypeUnknown:
            @throw [NSException exceptionWithName:@"Viewer"
                                           reason:@"Unknown STCaptureSessionSampleType!"
                                         userInfo:nil];
            break;
        default:
            NSLog(@"Skipping Capture Session sample type: %ld", static_cast<long>(type));
            break;
    }
}

- (void)captureSession:(STCaptureSession *)captureSession onLensDetectorOutput:(STDetectedLensStatus)detectedLensStatus
{
    switch (detectedLensStatus)
    {
        case STDetectedLensNormal:
            // Detected a WVL is not attached to the bracket.
            NSLog(@"Detected that the WVL is off!");
            break;
        case STDetectedLensWideVisionLens:
            // Detected a WVL is attached to the bracket.
            NSLog(@"Detected that the WVL is on!");
            break;
        case STDetectedLensPerformingInitialDetection:
            // Triggers immediately when detector is turned on. Can put a message here
            // showing the user that the detector is working and they need to pan the
            // camera for best results
            NSLog(@"Performing initial detection!");
            break;
        case STDetectedLensUnsure:
            break;
        default:
            @throw [NSException exceptionWithName:@"Viewer"
                                           reason:@"Unknown STDetectedLensStatus!"
                                         userInfo:nil];
            break;
    }
}

//------------------------------------------------------------------------------

#pragma mark - Rendering

- (void)renderDepthFrame:(STDepthFrame *)depthFrame
{
    if (depthFrame == nil) { return; }
    size_t cols = depthFrame.width;
    size_t rows = depthFrame.height;

    STDepthToRgba* depthToRgba = [[STDepthToRgba alloc]
                                  initWithOptions:@{ kSTDepthToRgbaStrategyKey: @(STDepthToRgbaStrategyRedToBlueGradient) }];
    _coloredDepthBuffer = [depthToRgba convertDepthFrameToRgba:depthFrame];

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    CGBitmapInfo bitmapInfo;
    bitmapInfo = (CGBitmapInfo)kCGImageAlphaNoneSkipLast;
    bitmapInfo |= kCGBitmapByteOrder32Big;
    
    NSData *data = [NSData dataWithBytes:_coloredDepthBuffer length:cols * rows * 4];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data); //toll-free ARC bridging
    
    CGImageRef imageRef = CGImageCreate(cols,                       //width
                                       rows,                        //height
                                       8,                           //bits per component
                                       8 * 4,                       //bits per pixel
                                       cols * 4,                    //bytes per row
                                       colorSpace,                  //Quartz color space
                                       bitmapInfo,                  //Bitmap info (alpha channel?, order, etc)
                                       provider,                    //Source of data for bitmap
                                       NULL,                        //decode
                                       false,                       //pixel interpolation
                                       kCGRenderingIntentDefault);  //rendering intent
    
    _depthImageView.image = [UIImage imageWithCGImage:imageRef];
    
    CGImageRelease(imageRef);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
}

- (void) renderNormalsFrame: (STDepthFrame*) depthFrame
{
    if (depthFrame == nil) { return; }
    // Estimate surface normal direction from depth float values
    STNormalFrame *normalsFrame = [_normalsEstimator calculateNormalsWithDepthFrame:depthFrame];

    size_t cols = normalsFrame.width;
    size_t rows = normalsFrame.height;
    
    // Convert normal unit vectors (ranging from -1 to 1) to RGB (ranging from 0 to 255)
    // Z can be slightly positive in some cases too!
    if (_normalsBuffer == NULL)
    {
        _normalsBuffer = (uint8_t*)malloc(cols * rows * 4);
    }
    for (size_t i = 0; i < cols * rows; i++)
    {
        _normalsBuffer[4*i+0] = (uint8_t)( ( ( normalsFrame.normals[i].x / 2 ) + 0.5 ) * 255);
        _normalsBuffer[4*i+1] = (uint8_t)( ( ( normalsFrame.normals[i].y / 2 ) + 0.5 ) * 255);
        _normalsBuffer[4*i+2] = (uint8_t)( ( ( normalsFrame.normals[i].z / 2 ) + 0.5 ) * 255);
    }
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    CGBitmapInfo bitmapInfo;
    bitmapInfo = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
    bitmapInfo |= kCGBitmapByteOrder32Little;
    
    NSData *data = [NSData dataWithBytes:_normalsBuffer length:cols * rows * 4];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data);
    
    CGImageRef imageRef = CGImageCreate(cols,
                                        rows,
                                        8,
                                        8 * 4,
                                        cols * 4,
                                        colorSpace,
                                        bitmapInfo,
                                        provider,
                                        NULL,
                                        false,
                                        kCGRenderingIntentDefault);
    
    _normalsImageView.image = [[UIImage alloc] initWithCGImage:imageRef];
    
    CGImageRelease(imageRef);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
}

- (void)renderColorFrame:(CMSampleBufferRef)yCbCrSampleBuffer
{
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(yCbCrSampleBuffer);

    // get image size
    size_t cols = CVPixelBufferGetWidth(pixelBuffer);
    size_t rows = CVPixelBufferGetHeight(pixelBuffer);
    
    // allocate memory for RGBA image for the first time
    if(_colorImageBuffer==NULL)
        _colorImageBuffer = (uint8_t*)malloc(cols * rows * 4);
    
    // color space
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    
    // get y plane
    const uint8_t* yData = reinterpret_cast<uint8_t*> (CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
    
    // get cbCr plane
    const uint8_t* cbCrData = reinterpret_cast<uint8_t*> (CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
    
    size_t yBytePerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    size_t cbcrBytePerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    assert( yBytePerRow==cbcrBytePerRow );

    uint8_t* bgra = _colorImageBuffer;
    
    bool ok = convertYCbCrToBGRA(cols, rows, yData, cbCrData, bgra, 0xff, yBytePerRow, cbcrBytePerRow, 4 * cols);

    if (!ok)
    {
        NSLog(@"YCbCr to BGRA conversion failed.");
        CGColorSpaceRelease(colorSpace);
        return;
    }

    NSData *data = [[NSData alloc] initWithBytes:_colorImageBuffer length:rows*cols*4];
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    
    CGBitmapInfo bitmapInfo;
    bitmapInfo = (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
    bitmapInfo |= kCGBitmapByteOrder32Little;
    
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((CFDataRef)data);
    
    CGImageRef imageRef = CGImageCreate(
        cols,
        rows,
        8,
        8 * 4,
        cols*4,
        colorSpace,
        bitmapInfo,
        provider,
        NULL,
        false,
        kCGRenderingIntentDefault
    );
    
    _colorImageView.image = [[UIImage alloc] initWithCGImage:imageRef];
    
    CGImageRelease(imageRef);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(colorSpace);
}

- (IBAction)tapCaptureButton:(id)sender {
    
//    _captureSession.streamingEnabled = !(_captureSession.streamingEnabled);
//    if(!(_captureSession.streamingEnabled)){

//        NSString *distanceInfo = [NSString stringWithFormat:@"Distance : %f mm", depthToSend.depthInMillimeters[153600]];
//
//
//
//        //fromLabel.text = distanceInfo;
//
//        for( int i = 153590; i < 153610; i++ ){
//             NSLog(@"%f",depthToSend.depthInMillimeters[i]);
//        }

//        UIImage *img = [UIImage imageNamed:@"watershed_segmentation_sample"];
//
//        UIImage *capturedImage = [OpenCVWrapper watershedAuto:img];
//
//        _colorImageView.image = capturedImage;
//
//
//    }
    
    
    float distance = depthToSend.depthInMillimeters[153600] / 10;
    NSLog(@"Distance: %f", distance);

    if (isnan(distance)) {
        [self showAppStatusMessage:@"Distance Capture Fail"];
        [self performSelector:@selector(hideAppStatusMessage) withObject:nil afterDelay:2.0];
    } else if(distance > 180) {
        [self showAppStatusMessage:@"Too Far, Get Closer for Better Accuracy"];
        [self performSelector:@selector(hideAppStatusMessage) withObject:nil afterDelay:2.0];
    }else if(distance < 150){
        [self showAppStatusMessage:@"Too Close, Step Back for Better Accuracy"];
        [self performSelector:@selector(hideAppStatusMessage) withObject:nil afterDelay:2.0];
    } else {
        float ppm = (-5.835894677)*(1/(1000*1000))*(distance*distance*distance);
        float ppmA = ppm + ((2.734474885)*(1/1000)*(distance*distance));
        float ppmB = ppmA - ((4.464448062)*(1/10)*distance) + 28.90183873 ;

        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        [defaults setFloat:ppmB forKey:@"PPM"];
        [defaults setFloat:distance forKey:@"distance"];

        [[self navigationController] pushViewController:[DiagnosisViewController createWithImage:_colorImageView.image] animated:YES];
    }
}

@end
