//
//  GetPublicKeysOperation.m
//  surespot
//
//  Created by Adam on 10/20/13.
//  Copyright (c) 2013 surespot. All rights reserved.
//

#import "GetPublicKeysOperation.h"
#import "NetworkManager.h"
#import "EncryptionController.h"
#import "IdentityController.h"
#import "NSData+Base64.h"
#import "NSData+SRB64Additions.h"

#import "CocoaLumberjack.h"


#ifdef DEBUG
static const DDLogLevel ddLogLevel = DDLogLevelInfo;
#else
static const DDLogLevel ddLogLevel = DDLogLevelOff;
#endif


@interface GetPublicKeysOperation()
@property (nonatomic, strong) NSString * ourUsername;
@property (nonatomic, strong) NSString * theirUsername;
@property (nonatomic, strong) NSString * version;
@property (nonatomic) BOOL isExecuting;
@property (nonatomic) BOOL isFinished;
@end




@implementation GetPublicKeysOperation

-(id) initWithUsername: (NSString *) theirUsername ourUsername: (NSString *) ourUsername version: (NSString *) version completionCallback:(void(^)(PublicKeys *))  callback {
    if (self = [super init]) {
        self.callback = callback;
        self.ourUsername = ourUsername;
        self.theirUsername = theirUsername;
        self.version = version;
        
        _isExecuting = NO;
        _isFinished = NO;
    }
    return self;
}

-(void) start {
    [self willChangeValueForKey:@"isExecuting"];
    _isExecuting = YES;
    [self didChangeValueForKey:@"isExecuting"];
    
    NSInteger currentVersion = [_version integerValue];
    NSInteger wantedVersion = currentVersion;
    
    PublicKeys * keys = nil;
    PublicKeys * validatedKeys = nil;
    NSInteger validatedKeyVersion = 0;
    
    NSMutableDictionary * dhKeys = [[NSMutableDictionary alloc] init];
    NSMutableDictionary * dsaKeys = [[NSMutableDictionary alloc] init];
    NSMutableDictionary * resultKeys = [[NSMutableDictionary alloc] init];
    
    while (currentVersion > 0) {
        NSString * sCurrentVersion = [@(currentVersion) stringValue];
        keys = [[IdentityController sharedInstance] loadPublicKeysOurUsername: _ourUsername theirUsername: _theirUsername version:  sCurrentVersion];
        if (keys) {
            validatedKeys = keys;
            validatedKeyVersion = currentVersion;
            break;
        }
        currentVersion--;
    }
    
    
    if (validatedKeys && wantedVersion == validatedKeyVersion) {
        DDLogInfo(@"Loaded public keys from disk for user: %@, version: %@", _theirUsername, _version);
        [self finish:keys];
        return;
    }
    
    [[[NetworkManager sharedInstance] getNetworkController:_ourUsername]
     getPublicKeys2ForUsername: self.theirUsername
     andVersion: [@(validatedKeyVersion+1) stringValue]
     successBlock:^(NSURLSessionTask *request, id JSON) {
         
         
         if (JSON) {
             //we return on the main thread and this shit's expensive so do it in background
             dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                 
                 for (NSInteger i=0;i < [JSON count]; i++) {
                     NSDictionary * jsonKeys = [JSON objectAtIndex:i];
                     NSString * sReadVersion = [jsonKeys objectForKey:@"version"];
                     
                     NSString * spubECDSA = [jsonKeys objectForKey:@"dsaPub"];
                     ECDSAPublicKey * dsaPub = [EncryptionController recreateDsaPublicKey:spubECDSA];
                     [dsaKeys setObject:[NSValue valueWithPointer:dsaPub] forKey:sReadVersion];
                     
                     NSString * spubECDH = [jsonKeys objectForKey:@"dhPub"];
                     ECDHPublicKey * dhPub = [EncryptionController recreateDhPublicKey:spubECDH];
                     [dhKeys setObject:[NSValue valueWithPointer:dhPub] forKey:sReadVersion];
                     
                     [resultKeys setObject:jsonKeys forKey:sReadVersion];
                 }
                 
                 NSDictionary * wantedKey = [resultKeys objectForKey:_version];
                 if ([wantedKey objectForKey:@"clientSig2"]) {
                     DDLogInfo(@"validating username: %@, version: %@, keys using v3 code", _theirUsername, _version);
                     
                     ECDSAPublicKey * previousDsaKey = nil;
                     if (validatedKeys) {
                         previousDsaKey = [validatedKeys dsaPubKey];
                     }
                     else {
                         [[dsaKeys objectForKey:@"1"] getValue:&previousDsaKey];
                     }
                     
                     ECDHPublicKey * dhPub;
                     ECDSAPublicKey * dsaPub;
                     
                     NSString * sDhPub = nil;
                     NSString * sDsaPub = nil;
                     
                     
                     for (NSInteger validatingVersion = validatedKeyVersion + 1;validatingVersion <= wantedVersion; validatingVersion++) {
                         NSString * sValidatingVersion = [@(validatingVersion) stringValue];
                         
                         NSDictionary * jsonKey = [resultKeys objectForKey: sValidatingVersion];
                         [[dhKeys objectForKey:sValidatingVersion] getValue:&dhPub];
                         [[dsaKeys objectForKey:sValidatingVersion] getValue:&dsaPub];
                         
                         sDhPub = [[EncryptionController encodeDHPublicKeyData:dhPub] SR_stringByBase64Encoding];
                         sDsaPub = [[EncryptionController encodeDSAPublicKeyData:dsaPub] SR_stringByBase64Encoding];
                         
                         BOOL verified = [EncryptionController verifySigUsingKey:[EncryptionController serverPublicKey] signature:[NSData dataFromBase64String:[jsonKey objectForKey:@"serverSig2"]] username:_theirUsername version:validatingVersion dhPubKey:sDhPub dsaPubKey:sDsaPub];
                         
                         if (!verified) {
                             DDLogWarn(@"server signature check failed");
                             [self finish:nil];
                             return;
                         }
                         
                         verified = [EncryptionController verifySigUsingKey:previousDsaKey signature:[NSData dataFromBase64String:[jsonKey objectForKey:@"clientSig2"]] username:_theirUsername version:validatingVersion dhPubKey:sDhPub dsaPubKey:sDsaPub];
                         if (!verified) {
                             DDLogWarn(@"client signature check failed");
                             [self finish:nil];
                             return;
                         }
                         
                         [[IdentityController sharedInstance] savePublicKeys: jsonKey ourUsername: _ourUsername theirUsername:_theirUsername version: sValidatingVersion];
                         [[dsaKeys objectForKey: sValidatingVersion] getValue:&previousDsaKey];
                     }
                     
                     
                     PublicKeys* pk = [[PublicKeys alloc] init];
                     pk.dhPubKey = dhPub;
                     pk.dsaPubKey = dsaPub;
                     pk.version = _version;
                     pk.lastModified = [NSDate date];
                     
                     [self finish:pk];
                     
                 }
                 else {
                     
                     if ([wantedKey objectForKey:@"clientSig"]) {
                         
                         DDLogInfo(@"validating username: %@, version: %@, keys using v2 code", _theirUsername, _version);
                         
                         ECDSAPublicKey * previousDsaKey = nil;
                         if (validatedKeys) {
                             previousDsaKey = [validatedKeys dsaPubKey];
                         }
                         else {
                             [[dsaKeys objectForKey:@"1"] getValue:&previousDsaKey];
                         }
                         
                         NSString * sDhPub = nil;
                         NSString * sDsaPub = nil;
                         
                         for (NSInteger validatingVersion = validatedKeyVersion + 1;validatingVersion <= wantedVersion; validatingVersion++) {
                             NSString * sValidatingVersion = [@(validatingVersion) stringValue];
                             NSDictionary * jsonKey = [resultKeys objectForKey: sValidatingVersion];
                             sDhPub = [jsonKey objectForKey:@"dhPub"];
                             sDsaPub = [jsonKey objectForKey:@"dsaPub"];
                             
                             BOOL verified = [EncryptionController verifySigUsingKey:[EncryptionController serverPublicKey] signature:[NSData dataFromBase64String:[jsonKey objectForKey:@"serverSig"]] username:_theirUsername version:validatingVersion dhPubKey:sDhPub dsaPubKey:sDsaPub];
                             
                             if (!verified) {
                                 DDLogWarn(@"server signature check failed");
                                 [self finish:nil];
                                 return;
                             }
                             
                             verified = [EncryptionController verifySigUsingKey:previousDsaKey signature:[NSData dataFromBase64String:[jsonKey objectForKey:@"clientSig"]] username:_theirUsername version:validatingVersion dhPubKey:sDhPub dsaPubKey:sDsaPub];
                             if (!verified) {
                                 DDLogWarn(@"client signature check failed");
                                 [self finish:nil];
                                 return;
                             }
                             
                             [[IdentityController sharedInstance] savePublicKeys: jsonKey ourUsername: _ourUsername theirUsername: _theirUsername version: sValidatingVersion];
                             [[dsaKeys objectForKey: sValidatingVersion] getValue:&previousDsaKey];
                         }
                         
                         ECDHPublicKey * dhPub;
                         [[dhKeys objectForKey:_version] getValue:&dhPub];
                         ECDSAPublicKey * dsaPub;
                         [[dsaKeys objectForKey:_version] getValue:&dsaPub];
                         
                         PublicKeys* pk = [[PublicKeys alloc] init];
                         pk.dhPubKey = dhPub;
                         pk.dsaPubKey = dsaPub;
                         pk.version = _version;
                         pk.lastModified = [NSDate date];
                         
                         [self finish:pk];
                         
                     }
                     else {
                         DDLogInfo(@"validating username: %@, version: %@, keys using v1 code", _theirUsername, _version);
                         [self finish:[self getPublicKeysForUsername:_theirUsername version:_version jsonKeys:wantedKey]];
                         return;
                     }
                 }
             });
             
         }
         else {
             [self finish:nil];
         }
         
     } failureBlock:^(NSURLSessionTask *operation, NSError *Error) {
         
         DDLogVerbose(@"response failure: %@",  Error);
         [self finish:nil];
         
     }];
    
    
}


-(PublicKeys *) getPublicKeysForUsername: (NSString *) username version: (NSString *) version jsonKeys: (NSDictionary *) JSON {
    
    if (JSON) {
        NSString * version = [JSON objectForKey:@"version"];
        if (![_version isEqualToString:version]) {
            DDLogWarn(@"public key versions do not match");
            return nil;
        }
        
        
        DDLogInfo(@"verifying public keys for %@", _theirUsername);
        BOOL verified = [[IdentityController sharedInstance  ] verifyPublicKeys: JSON];
        
        if (!verified) {
            DDLogWarn(@"could not verify public keys!");
            return nil;
        }
        else {
            DDLogInfo(@"public keys verified against server signature");
            
            //recreate public keys
            NSDictionary * jsonKeys = JSON;
            
            NSString * spubDH = [jsonKeys objectForKey:@"dhPub"];
            NSString * spubDSA = [jsonKeys objectForKey:@"dsaPub"];
            
            ECDHPublicKey * dhPub = [EncryptionController recreateDhPublicKey:spubDH];
            ECDHPublicKey * dsaPub = [EncryptionController recreateDsaPublicKey:spubDSA];
            
            PublicKeys* pk = [[PublicKeys alloc] init];
            pk.dhPubKey = dhPub;
            pk.dsaPubKey = dsaPub;
            pk.version = _version;
            pk.lastModified = [NSDate date];
            
            //save keys to disk
            [[IdentityController sharedInstance] savePublicKeys: JSON ourUsername: _ourUsername theirUsername: _theirUsername version:  _version];
            
            DDLogVerbose(@"get public keys calling callback");
            return pk;
        }
    }
    
    return nil;
}

- (void)finish: (PublicKeys *) publicKeys
{
    
    [self willChangeValueForKey:@"isExecuting"];
    [self willChangeValueForKey:@"isFinished"];
    
    _isExecuting = NO;
    _isFinished = YES;
    
    [self didChangeValueForKey:@"isExecuting"];
    [self didChangeValueForKey:@"isFinished"];
    
    _callback(publicKeys);
    _callback = nil;
}


- (BOOL)isConcurrent
{
    return YES;
}

@end
