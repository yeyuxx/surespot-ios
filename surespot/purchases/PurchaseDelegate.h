//
//  PurchaseDelegate.h
//  surespot
//
//  Created by Adam on 12/31/13.
//  Copyright (c) 2013 2fours. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <StoreKit/StoreKit.h>

@interface PurchaseDelegate : NSObject<SKProductsRequestDelegate, SKPaymentTransactionObserver>
- (void) purchaseProduct: (NSInteger) productIndex;
+(PurchaseDelegate*)sharedInstance;
@property (nonatomic, assign) BOOL hasVoiceMessaging;
-(void) setHasVoiceMessaging:(BOOL)hasVoiceMessaging;
-(NSString *) getAppStoreReceipt;
-(void) refresh;
-(void) showPurchaseViewForController: (UIViewController *) parentController;
@end