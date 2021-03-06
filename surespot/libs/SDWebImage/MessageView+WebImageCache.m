/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "MessageView+WebImageCache.h"
#import "objc/runtime.h"
#import "MessageView.h"
#import "SurespotConstants.h"
#import "UIUtils.h"
#import "CocoaLumberjack.h"
#import "NSBundle+FallbackLanguage.h"

#ifdef DEBUG
static const DDLogLevel ddLogLevel = DDLogLevelInfo;
#else
static const DDLogLevel ddLogLevel = DDLogLevelOff;
#endif

static char operationKey;
static char operationArrayKey;

@implementation MessageView (WebCache)



- (void)setMessage:(SurespotMessage *) message
       ourUsername:(NSString *) ourUsername
          progress:(SDWebImageDownloaderProgressBlock)progressBlock
         completed:(SDWebImageCompletedBlock)completedBlock
      retryAttempt:(NSInteger) retryAttempt
{
 
    __weak MessageView *wself = self;
    
    //see if we have unencrypted locally
    NSString * localUrl = message.plainData;
    if (localUrl) {
        [UIUtils getLocalImageFromAssetUrlOrId:localUrl callback:^(id image) {
            if (!wself) return;
            dispatch_main_async_safe(^{
                if (!wself) return;
                
                //do nothing if the message has changed
                if (![wself.message isEqual:message]) {
                    DDLogVerbose(@"cell is pointing to a different message now, not assigning data");
                    return;
                }
                
                if (image)
                {
                    
                    if (message.formattedDate) {
                        wself.messageStatusLabel.text = message.formattedDate;
                    }
                    
                    if ([message.mimeType isEqualToString:MIME_TYPE_IMAGE]) {
                                                 DDLogInfo(@"Using image from local asset; %@", localUrl);
                            wself.uiImageView.image = image;
                            
//                            if ([image size].height > [image size].width) {
                                [wself.uiImageView setContentMode:UIViewContentModeScaleAspectFit];
//                            }
//                            else {
//                                [wself.uiImageView setContentMode:UIViewContentModeScaleAspectFill];
//                            }
                        [wself setNeedsLayout];
                    }
                }
                
            });
        }];
    }
    
    NSURL * url = [NSURL URLWithString:message.data];
    
    if (url) {
        [self cancelCurrentImageLoad];
        DDLogDebug(@"Using image from sdweb for %@", url);
        id<SDWebImageOperation> operation = [SDWebImageManager.sharedManager downloadWithURL: url
                                                                                  mimeType: [message mimeType]
                                                                               ourUsername: ourUsername
                                                                                ourVersion: [message getOurVersion: ourUsername]
                                                                             theirUsername: [message getOtherUser: ourUsername]
                                                                              theirVersion: [message getTheirVersion: ourUsername]
                                                                                        iv: [message iv]
                                                                                    hashed: [message hashed]
                                                                                   options: SDWebImageRetryFailed
                                                                                  progress:progressBlock completed:^(id image, NSString * mimeType, NSError *error, SDImageCacheType cacheType, BOOL finished)
                                           {
                                               if (!wself) return;
                                               dispatch_main_async_safe(^
                                                                        {
                                                                            if (!wself) return;
                                                                            
                                                                            //do nothing if the message has changed
                                                                            if (![wself.message isEqual:message]) {
                                                                                DDLogVerbose(@"cell is pointing to a different message now, not assigning data");
                                                                                return;
                                                                            }
                                                                            if (image)
                                                                            {
                                                                                if ([mimeType isEqualToString:MIME_TYPE_IMAGE]) {
                                                                                    wself.uiImageView.image = image;
                                                                                    
                                                                                    
                                                                            //        if ([image size].height > [image size].width) {
                                                                                        [wself.uiImageView setContentMode:UIViewContentModeScaleAspectFit];
//                                                                                    }
//                                                                                    else {
//                                                                                        [wself.uiImageView setContentMode:UIViewContentModeScaleAspectFill];
//                                                                                    }
                                                                                }
                                                                                if (message.formattedDate) {
                                                                                    wself.messageStatusLabel.text = message.formattedDate;
                                                                                }
                                                                            }
                                                                            else {
                                                                                //retry
                                                                                if (retryAttempt < RETRY_ATTEMPTS) {
                                                                                    double timerInterval = [UIUtils generateIntervalK: retryAttempt maxInterval: RETRY_DELAY];
                                                                                    DDLogInfo(@"no data downloaded, retrying attempt: %ld, in %f seconds", (long)retryAttempt+1, timerInterval);
                                                                                    
                                                                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timerInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                                                                         [self setMessage:message ourUsername: ourUsername progress:progressBlock completed:completedBlock retryAttempt:retryAttempt+1];
                                                                                    });
                                                                                   
                                                                                    return;
                                                                                }
                                                                                else {
                                                                                    wself.messageStatusLabel.text = NSLocalizedString(@"error_downloading_message_data", nil);
                                                                                }
                                                                            }
                                                                            
                                                                            [wself setNeedsLayout];
                                                                            if (completedBlock && finished)
                                                                            {
                                                                                completedBlock(image, mimeType, error, cacheType);
                                                                            }
                                                                        });
                                           }];
        objc_setAssociatedObject(self, &operationKey, operation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}


- (void)cancelCurrentImageLoad
{
    // Cancel in progress downloader from queue
    id<SDWebImageOperation> operation = objc_getAssociatedObject(self, &operationKey);
    if (operation)
    {
        [operation cancel];
        objc_setAssociatedObject(self, &operationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)cancelCurrentArrayLoad
{
    // Cancel in progress downloader from queue
    NSArray *operations = objc_getAssociatedObject(self, &operationArrayKey);
    for (id<SDWebImageOperation> operation in operations)
    {
        if (operation)
        {
            [operation cancel];
        }
    }
    objc_setAssociatedObject(self, &operationArrayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
