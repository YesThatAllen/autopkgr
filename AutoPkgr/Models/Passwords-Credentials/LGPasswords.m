//
//  LGPasswords.m
//  AutoPkgr
//
//  Created by Eldon Ahrold on 2/14/15.
//  Copyright 2015 The Linde Group, Inc.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "LGPasswords.h"
#import "LGAutoPkgrHelperConnection.h"
#import "LGAutoPkgr.h"

#import <AHKeychain/AHKeychain.h>

@implementation LGPasswords

NSString *appKeychainPath()
{
    return [@"~/Library/Keychains/AutoPkgr.keychain" stringByExpandingTildeInPath];
}

+ (void)lockKeychain
{
    NSString *appKeychain = @"AutoPkgr.keychain";
    [[[AHKeychain alloc] initWithKeychain:appKeychain] lock];
}

+ (void)getPasswordForAccount:(NSString *)account
                      service:(NSString *)service
                        label:(NSString *)label
                        reply:(void (^)(NSString *, NSError *))reply
{
    [[self class] getKeychain:^(AHKeychain *keychain) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            if (keychain && (keychain.keychainStatus == errSecSuccess)) {
                NSError *error = nil;
                AHKeychainItem *item = [self keychainItemForAccount:account
                                                            service:service
                                                              label:label];

                [keychain getItem:item error:&error];
                reply(item.password, error);
            } else {
                reply(nil, [LGError errorWithCode:kLGErrorKeychainAccess]);
            }
        }];
    }];
}

+ (void)getPasswordForAccount:(NSString *)account
                        reply:(void (^)(NSString *, NSError *))reply
{
    NSString *label = [kLGApplicationName stringByAppendingString:@" Email Password"];
    NSString *service = kLGAutoPkgrPreferenceDomain;
    [self getPasswordForAccount:account service:service label:label reply:reply];
};

+ (void)savePassword:(NSString *)password
          forAccount:(NSString *)account
               reply:(void (^)(NSError *))reply
{
    NSString *label = [kLGApplicationName stringByAppendingString:@" Email Password"];
    NSString *service = kLGAutoPkgrPreferenceDomain;
    [self savePassword:password forAccount:account service:service label:label reply:reply];
}

+ (void)savePassword:(NSString *)password
          forAccount:(NSString *)account
             service:(NSString *)service
               label:(NSString *)label
               reply:(void (^)(NSError *))reply
{
    [[self class] getKeychain:^(AHKeychain *keychain) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{

            if (keychain.keychainStatus == errSecSuccess) {
                NSError *error = nil;
                AHKeychainItem *item = [self keychainItemForAccount:account
                                                            service:service
                                                              label:label];

                if (password.length == 0) {
                    [keychain deleteItem:item error:&error];
                    reply(error);
                } else {
                    item.password = password;
                    [keychain saveItem:item error:&error];
                    reply(error);
                }
                [keychain lock];
            } else {
                reply([NSError errorWithDomain:kLGApplicationName code:keychain.keychainStatus userInfo:@{NSLocalizedDescriptionKey : keychain.statusDescription}]);
            }
        }];
    }];
}
#pragma mark - Migration method
+ (void)migrateKeychainIfNeeded:(void (^)(NSString *password, NSError *error))reply;
{
    NSString *upgradeTriedKey = @"KeychainUpgrade_1_2_1_Tried";

    BOOL upgradeTried = [[LGDefaults standardUserDefaults] boolForKey:upgradeTriedKey];
    BOOL keychainExists = [[NSFileManager defaultManager] fileExistsAtPath:appKeychainPath()];

    // Only try to upgrade once if the keychain exists.
    if (!upgradeTried && keychainExists) {
        NSString *oldPass = [LGHostInfo macSerialNumber];
        AHKeychain *keychain = [AHKeychain keychainAtPath:appKeychainPath()];
        [keychain lock];

        if ([keychain unlockWithPassword:oldPass]) {
            // If we successfully unlock the keychain with the old password
            // it needs migration.

            [self getKeychainKey:^(NSString *key, NSError *error) {
                if(!error){
                    if([keychain changeKeychainPassword:oldPass to:key error:&error]){
                        NSString *account = [[LGDefaults standardUserDefaults] SMTPUsername];

                        NSLog(@"Successfully migrated keychain.");

                        NSString *label = [kLGApplicationName stringByAppendingString:@" Email Password"];
                        NSString *service = kLGAutoPkgrPreferenceDomain;

                        AHKeychainItem *item = [self keychainItemForAccount:account service:service label:label];

                        if ([keychain getItem:item error:&error]) {
                            reply(item.password, error);
                        }
                    }
                } else {
                    reply(nil, error);
                }
            }];
        }
    }
    [[LGDefaults standardUserDefaults] setBool:YES forKey:upgradeTriedKey];
}

+ (void)resetKeychainPrompt:(void (^)(NSError *))reply
{
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        NSString *messageText = @"Error accessing the AutoPkgr keychain";
        NSString *infoText = @"There was a problem accessing the application's keychain and it needs to be recreated.\n\nThis only relates to AutoPkgr's keychain and will not modify or alter any other keychains.";

        NSAlert *alert = [NSAlert alertWithMessageText:messageText
                                         defaultButton:@"Continue"
                                       alternateButton:@"Cancel"
                                           otherButton:nil
                             informativeTextWithFormat:@"%@", infoText];

        NSInteger button = [alert runModal];
        if (button == NSAlertDefaultReturn) {
            NSError *error = nil;
            if ([[AHKeychain keychainAtPath:appKeychainPath()] deleteKeychain:&error]) {
                DLog(@"Removed old keychain...");
            } else {
                NSLog(@"There was a problem removing your old keychain.");
            }
            reply(error);
        }
    }];
}

#pragma mark - Private
+ (AHKeychain *)appKeychain:(NSString *)key
{
    AHKeychain *keychain = nil;

    NSString *appKeychain = @"AutoPkgr.keychain";

    if (![[NSFileManager defaultManager] fileExistsAtPath:appKeychainPath()]) {
        keychain = [[AHKeychain alloc] initCreatingNewKeychain:appKeychain password:key];
    } else {
        keychain = [[AHKeychain alloc] initWithKeychain:appKeychain];
        if (![keychain unlockWithPassword:key]) {
            DLog(@"[%d] %@", keychain.keychainStatus, keychain.statusDescription);
        }
    }
    return keychain;
}

+ (AHKeychainItem *)keychainItemForAccount:(NSString *)account
                                   service:(NSString *)service
                                     label:(NSString *)label
{
    AHKeychainItem *item = [[AHKeychainItem alloc] init];
    item.account = account;
    item.service = service;
    if (label) {
        item.label = label;
    }
    return item;
}

+ (void)getKeychain:(void (^)(AHKeychain *))reply
{
    [[self class] getKeychainKey:^(NSString *key, NSError *error) {
        if (!error && key) {
            AHKeychain *keychain = [self appKeychain:key];
            if(keychain){
                reply(keychain);
            } else {
                reply(nil);
            }
        } else {
            DLog(@"%@", error.localizedDescription);
            reply(nil);
        }
    }];
}

+ (void)getKeychainKey:(void (^)(NSString *, NSError *))reply
{
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        LGAutoPkgrHelperConnection *helperConnection = [[LGAutoPkgrHelperConnection alloc] init];

        [helperConnection connectionError:^(NSError *error) {
            reply(nil, error);
        }];

        [helperConnection.remoteObjectProxy getKeychainKey:^(NSString *key, NSError *error) {
            reply(key, error);
            [helperConnection closeConnection];
        }];
    }];
}

@end
