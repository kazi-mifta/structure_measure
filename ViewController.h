/*
  This file is part of the Structure SDK.
  Copyright © 2019 Occipital, Inc. All rights reserved.
  http://structure.io
*/

#import <UIKit/UIKit.h>
#import <Structure/Structure.h>
#import <Structure/STCaptureSession.h>
@interface ViewController : UIViewController <STCaptureSessionDelegate>

+ (instancetype) viewController;

@end
