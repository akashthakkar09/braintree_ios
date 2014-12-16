#import "BTThreeDSecureViewController.h"
#import "BTClient+Testing.h"
#import "KIFUITestActor+BTWebView.h"

@interface BTThreeDSecureViewController_AcceptanceSpecHelper : NSObject

@property (nonatomic, strong) BTClient *client;
@property (nonatomic, strong) BTThreeDSecureViewController *threeDSecureViewController;
@property (nonatomic, strong) id mockDelegate;
@property (nonatomic, strong) BTThreeDSecureLookup *lookup;

@end

@implementation BTThreeDSecureViewController_AcceptanceSpecHelper

+ (instancetype)helper {
    BTThreeDSecureViewController_AcceptanceSpecHelper *helper = [[self alloc] init];
    waitUntil(^(DoneCallback done) {
        [BTClient testClientWithConfiguration:@{ BTClientTestConfigurationKeyMerchantIdentifier:@"integration_merchant_id",
                                                 BTClientTestConfigurationKeyPublicKey:@"integration_public_key",
                                                 BTClientTestConfigurationKeyCustomer:@YES,
                                                 BTClientTestConfigurationKeyClientTokenVersion: @2,
                                                 BTClientTestConfigurationKeyMerchantAccountIdentifier: @"three_d_secure_merchant_account", }
                                   completion:^(BTClient *client) {
                                       helper.client = client;
                                       done();
                                   }];
    });

    return helper;
}

- (void)lookupCard:(NSString *)number completion:(void (^)(NSString *originalNonce, BTThreeDSecureLookup *lookup, NSString *lookupNonce))completion {
    BTClientCardRequest *request = [[BTClientCardRequest alloc] init];
    request.number = number;
    request.expirationMonth = @"12";
    request.expirationYear = @"2020";
    request.shouldValidate = YES;
    
    [self.client saveCardWithRequest:request
                             success:^(BTPaymentMethod *card) {
                                 [self.client lookupNonceForThreeDSecure:card.nonce
                                                       transactionAmount:[NSDecimalNumber decimalNumberWithString:@"1"]
                                                                 success:^(BTThreeDSecureLookup *threeDSecureLookup, NSString *nonce) {
                                                                     completion(card.nonce, threeDSecureLookup, nonce);
                                                                 } failure:nil];
                             } failure:^(__unused NSError *error) {
                                 completion(nil, nil, nil);
                             }];
}

- (void)fetchThreeDSecureVerificationInfo:(NSString *)nonce completion:(void (^)(NSDictionary *response))completion {
    [self.client fetchNonceThreeDSecureVerificationInfo:nonce
                                                success:^(NSDictionary *threeDSecureInfo){
                                                    completion(threeDSecureInfo);
                                                } failure:^(__unused NSError *error){
                                                    completion(nil);
                                                }];
}

- (void)lookupNumber:(NSString *)number
               andDo:(void (^)(BTThreeDSecureViewController *threeDSecureViewController))testBlock
     didAuthenticate:(void (^)(BTThreeDSecureViewController *threeDSecureViewController, BTThreeDSecureLookup *lookup, NSString *nonce, void (^completion)(BTThreeDSecureViewControllerCompletionStatus status)))authenticateBlock
           didFinish:(void (^)(BTThreeDSecureViewController *threeDSecureViewController))finishBlock {

    waitUntil(^(DoneCallback done) {
        [self lookupCard:number
              completion:^(NSString *originalNonce, BTThreeDSecureLookup *threeDSecureLookup, NSString *lookupNonce){
                  self.lookup = threeDSecureLookup;
                  done();
              }];
    });

    self.threeDSecureViewController = [[BTThreeDSecureViewController alloc] initWithLookup:self.lookup];

    // Setup mock delegate for receiving completion messages
    self.mockDelegate = [OCMockObject mockForProtocol:@protocol(BTThreeDSecureViewControllerDelegate)];

    if (authenticateBlock) {
        id delegateReceivesDidAuthenticateStub = [self.mockDelegate stub];
        [delegateReceivesDidAuthenticateStub andDo:^(NSInvocation *invocation) {
            NSString *nonce;
            void (^completionBlock)(BTThreeDSecureViewControllerCompletionStatus);
            BTThreeDSecureViewController *viewController;

            // threeDSecureViewController:(2) didAuthenticateNonce:(3) completion:(4)
            [invocation getArgument:&viewController atIndex:2];
            [invocation getArgument:&nonce atIndex:3];
            [invocation getArgument:&completionBlock atIndex:4];

            authenticateBlock(viewController, self.lookup, nonce, completionBlock);
        }];

        [delegateReceivesDidAuthenticateStub threeDSecureViewController:self.threeDSecureViewController
                                                   didAuthenticateNonce:[OCMArg isNotNil]
                                                             completion:OCMOCK_ANY];
    }

    if (finishBlock) {
        id delegateReceivesDidFinishStub = [self.mockDelegate stub];

        [delegateReceivesDidFinishStub andDo:^(NSInvocation *invocation) {
            BTThreeDSecureViewController *viewController;

            [invocation getArgument:&viewController atIndex:2];

            finishBlock(viewController);
        }];

        [delegateReceivesDidFinishStub threeDSecureViewControllerDidFinish:self.threeDSecureViewController];
    }

    self.threeDSecureViewController.delegate = self.mockDelegate;

    if (testBlock) {
        testBlock(self.threeDSecureViewController);
    }
}

@end

SpecBegin(BTThreeDSecureViewController_Acceptance)

describe(@"3D Secure View Controller", ^{
    __block BTThreeDSecureViewController_AcceptanceSpecHelper *helper;
    beforeEach(^{
        helper = [BTThreeDSecureViewController_AcceptanceSpecHelper helper];
    });

    context(@"developer perspective", ^{
        it(@"calls didAuthenticate with the nonce received during lookup", ^{
            __block BOOL calledDidAuthenticate = NO;
            [helper lookupNumber:@"4000000000000002"
                           andDo:^(BTThreeDSecureViewController *threeDSecureViewController) {
                               [system presentViewController:threeDSecureViewController withinNavigationControllerWithNavigationBarClass:nil toolbarClass:nil configurationBlock:nil];

                               [tester waitForViewWithAccessibilityLabel:@"Please submit your Verified by Visa password." traits:UIAccessibilityTraitStaticText];
                               [tester tapUIWebviewXPathElement:@"//input[@name=\"external.field.password\"]"];

                               [tester enterTextIntoCurrentFirstResponder:@"1234"];
                               [tester tapViewWithAccessibilityLabel:@"Submit"];
                           } didAuthenticate:^(BTThreeDSecureViewController *threeDSecureViewController, BTThreeDSecureLookup *lookup, NSString *nonce, void (^completion)(BTThreeDSecureViewControllerCompletionStatus)) {
                               calledDidAuthenticate = YES;
                               expect(nonce).to.beANonce();
                           } didFinish:nil];

            [system runBlock:^KIFTestStepResult(NSError *__autoreleasing *error) {
                KIFTestWaitCondition(calledDidAuthenticate, error, @"Did not call didAuthenticate");
                return KIFTestStepResultSuccess;
            }];
        });

        it(@"calls didFinish only after didAuthenticate calls its completion with success", ^{
            __block BOOL calledDidAuthenticate = NO;
            __block BOOL calledDidFinish = NO;
            [helper lookupNumber:@"4000000000000002"
                           andDo:^(BTThreeDSecureViewController *threeDSecureViewController) {
                               [system presentViewController:threeDSecureViewController withinNavigationControllerWithNavigationBarClass:nil toolbarClass:nil configurationBlock:nil];

                               [tester waitForViewWithAccessibilityLabel:@"Please submit your Verified by Visa password." traits:UIAccessibilityTraitStaticText];
                               [tester tapUIWebviewXPathElement:@"//input[@name=\"external.field.password\"]"];

                               [tester enterTextIntoCurrentFirstResponder:@"1234"];
                               [tester tapViewWithAccessibilityLabel:@"Submit"];
                           } didAuthenticate:^(BTThreeDSecureViewController *threeDSecureViewController, BTThreeDSecureLookup *lookup, NSString *nonce, void (^completion)(BTThreeDSecureViewControllerCompletionStatus)) {
                               calledDidAuthenticate = YES;
                               expect(calledDidFinish).to.beFalsy();
                               completion(BTThreeDSecureViewControllerCompletionStatusSuccess);
                           } didFinish:^(BTThreeDSecureViewController *threeDSecureViewController) {
                               calledDidFinish = YES;
                               expect(calledDidAuthenticate).to.beTruthy();
                           }];

            [system runBlock:^KIFTestStepResult(NSError *__autoreleasing *error) {
                KIFTestWaitCondition(calledDidAuthenticate, error, @"Did not call didAuthenticate");
                KIFTestWaitCondition(calledDidFinish, error, @"Did not call didFinish");
                return KIFTestStepResultSuccess;
            }];
        });

        it(@"calls didFinish only after didAuthenticate calls its completion with failure", ^{
            __block BOOL calledDidAuthenticate = NO;
            __block BOOL calledDidFinish = NO;
            [helper lookupNumber:@"4000000000000002"
                           andDo:^(BTThreeDSecureViewController *threeDSecureViewController) {
                               [system presentViewController:threeDSecureViewController withinNavigationControllerWithNavigationBarClass:nil toolbarClass:nil configurationBlock:nil];

                               [tester waitForViewWithAccessibilityLabel:@"Please submit your Verified by Visa password." traits:UIAccessibilityTraitStaticText];
                               [tester tapUIWebviewXPathElement:@"//input[@name=\"external.field.password\"]"];

                               [tester enterTextIntoCurrentFirstResponder:@"1234"];
                               [tester tapViewWithAccessibilityLabel:@"Submit"];
                           } didAuthenticate:^(BTThreeDSecureViewController *threeDSecureViewController, BTThreeDSecureLookup *lookup, NSString *nonce, void (^completion)(BTThreeDSecureViewControllerCompletionStatus)) {
                               calledDidAuthenticate = YES;
                               expect(calledDidFinish).to.beFalsy();
                               completion(BTThreeDSecureViewControllerCompletionStatusFailure);
                           } didFinish:^(BTThreeDSecureViewController *threeDSecureViewController) {
                               calledDidFinish = YES;
                               expect(calledDidAuthenticate).to.beTruthy();
                           }];

            [system runBlock:^KIFTestStepResult(NSError *__autoreleasing *error) {
                KIFTestWaitCondition(calledDidAuthenticate, error, @"Did not call didAuthenticate");
                KIFTestWaitCondition(calledDidFinish, error, @"Did not call didFinish");
                return KIFTestStepResultSuccess;
            }];
        });
    });

    describe(@"user flows - (enrolled, authenticated, signature verified)", ^{
        context(@"cardholder enrolled, successful authentication, successful signature verification - Y,Y,Y", ^{
            it(@"successfully authenticates a user when they enter their password", ^{
                __block BOOL checkedNonce = NO;
                [helper lookupNumber:@"4000000000000002"
                               andDo:^(BTThreeDSecureViewController *threeDSecureViewController) {
                                   [system presentViewController:threeDSecureViewController withinNavigationControllerWithNavigationBarClass:nil toolbarClass:nil configurationBlock:nil];

                                   [tester waitForViewWithAccessibilityLabel:@"Please submit your Verified by Visa password." traits:UIAccessibilityTraitStaticText];
                                   [tester tapUIWebviewXPathElement:@"//input[@name=\"external.field.password\"]"];

                                   [tester enterTextIntoCurrentFirstResponder:@"1234"];
                                   [tester tapViewWithAccessibilityLabel:@"Submit"];
                               } didAuthenticate:^(BTThreeDSecureViewController *threeDSecureViewController, BTThreeDSecureLookup *lookup, NSString *nonce, void (^completion)(BTThreeDSecureViewControllerCompletionStatus)) {
                                   [helper fetchThreeDSecureVerificationInfo:nonce
                                                                  completion:^(NSDictionary *response) {
                                                                      expect(response[@"reportStatus"]).to.equal(@"authenticate_successful");
                                                                      checkedNonce = YES;
                                                                  }];
                               } didFinish:nil];

                [system runBlock:^KIFTestStepResult(NSError *__autoreleasing *error) {
                    KIFTestWaitCondition(checkedNonce, error, @"Did not check nonce");
                    return KIFTestStepResultSuccess;
                }];
            });
        });

        context(@"issuer not enrolled - N", ^{
            it(@"bypasses the entire authentication experience", ^{
                [helper lookupNumber:@"4000000000000051"
                               andDo:^(BTThreeDSecureViewController *threeDSecureViewController) {
                                   expect(threeDSecureViewController).to.beNil();
                               } didAuthenticate:nil didFinish:nil];
            });
        });

        context(@"simulated cardinal error on lookup - error", ^{
            it(@"bypasses the entire authentication experience", ^{
                [helper lookupNumber:@"4000000000000077"
                               andDo:^(BTThreeDSecureViewController *threeDSecureViewController) {
                                   expect(threeDSecureViewController).to.beNil();
                               } didAuthenticate:nil didFinish:nil];
            });
        });

        context(@"User enters incorrect password - Y,N,Y", ^{
            it(@"it presents the failure to the user and fails to authenticate the nonce", ^{
                __block BOOL checkedNonce;

                [helper lookupNumber:@"4000000000000028"
                               andDo:^(BTThreeDSecureViewController *threeDSecureViewController) {

                                   [system presentViewController:threeDSecureViewController withinNavigationControllerWithNavigationBarClass:nil toolbarClass:nil configurationBlock:nil];


                                   [tester waitForViewWithAccessibilityLabel:@"Please submit your Verified by Visa password." traits:UIAccessibilityTraitStaticText];
                                   [tester tapUIWebviewXPathElement:@"//input[@name=\"external.field.password\"]"];
                                   [tester enterTextIntoCurrentFirstResponder:@"bad"];
                                   [tester tapViewWithAccessibilityLabel:@"Submit"];
                                   [tester waitForViewWithAccessibilityLabel:@"Account Authentication Blocked"];
                                   [tester tapViewWithAccessibilityLabel:@"Continue"];
                               } didAuthenticate:^(BTThreeDSecureViewController *threeDSecureViewController, BTThreeDSecureLookup *lookup, NSString *nonce, void (^completion)(BTThreeDSecureViewControllerCompletionStatus status)) {
                                   [helper fetchThreeDSecureVerificationInfo:nonce
                                                                  completion:^(NSDictionary *response) {
                                                                      expect(response[@"reportStatus"]).to.equal(@"authenticate_failed");
                                                                      checkedNonce = YES;
                                                                  }];
                               } didFinish:nil];

                [system runBlock:^KIFTestStepResult(NSError *__autoreleasing *error) {
                    KIFTestWaitCondition(checkedNonce, error, @"Did not check nonce");
                    return KIFTestStepResultSuccess;
                }];
            });
        });

        context(@"User attempted to enter a password - Y,A,Y", ^{
            it(@"displays a loading indication to the user and successfully authenticates the nonce", ^{
                __block BOOL checkedNonce;

                [helper lookupNumber:@"4000000000000101"
                               andDo:^(BTThreeDSecureViewController *threeDSecureViewController) {
                                   [system presentViewController:threeDSecureViewController withinNavigationControllerWithNavigationBarClass:nil toolbarClass:nil configurationBlock:nil];
                               } didAuthenticate:^(BTThreeDSecureViewController *threeDSecureViewController, BTThreeDSecureLookup *lookup, NSString *nonce, void (^completion)(BTThreeDSecureViewControllerCompletionStatus status)) {
                                   [helper fetchThreeDSecureVerificationInfo:nonce
                                                                  completion:^(NSDictionary *response) {
                                                                      expect(response[@"reportStatus"]).to.equal(@"authenticate_successful_issuer_not_participating");
                                                                      checkedNonce = YES;
                                                                  }];
                               } didFinish:nil];
                
                [system runBlock:^KIFTestStepResult(NSError *__autoreleasing *error) {
                    KIFTestWaitCondition(checkedNonce, error, @"Did not check nonce");
                    return KIFTestStepResultSuccess;
                }];
            });
        });
        
        context(@"Signature verification fails - Y,Y,N", ^{
            it(@"accepts a password but resuts in an failed verification", ^{
                __block BOOL checkedNonce = NO;
                [helper lookupNumber:@"4000000000000010"
                               andDo:^(BTThreeDSecureViewController *threeDSecureViewController) {
                                   [system presentViewController:threeDSecureViewController withinNavigationControllerWithNavigationBarClass:nil toolbarClass:nil configurationBlock:nil];

                                   [tester waitForViewWithAccessibilityLabel:@"Please submit your Verified by Visa password." traits:UIAccessibilityTraitStaticText];
                                   [tester tapUIWebviewXPathElement:@"//input[@name=\"external.field.password\"]"];

                                   [tester enterTextIntoCurrentFirstResponder:@"1234"];
                                   [tester tapViewWithAccessibilityLabel:@"Submit"];
                               } didAuthenticate:^(BTThreeDSecureViewController *threeDSecureViewController, BTThreeDSecureLookup *lookup, NSString *nonce, void (^completion)(BTThreeDSecureViewControllerCompletionStatus)) {
                                   [helper fetchThreeDSecureVerificationInfo:nonce
                                                                  completion:^(NSDictionary *response) {
                                                                      expect(response[@"reportStatus"]).to.equal(@"authenticate_signature_verification_failed");
                                                                      checkedNonce = YES;
                                                                  }];
                               } didFinish:nil];

                [system runBlock:^KIFTestStepResult(NSError *__autoreleasing *error) {
                    KIFTestWaitCondition(checkedNonce, error, @"Did not check nonce");
                    return KIFTestStepResultSuccess;
                }];
            });
        });

        context(@"Issuer is down - Y,U", ^{
            it(@"displays an error to the user and semi-successfully authenticates the nonce", ^{
                __block BOOL checkedNonce = NO;
                [helper lookupNumber:@"4000000000000036"
                               andDo:^(BTThreeDSecureViewController *threeDSecureViewController) {
                                   [system presentViewController:threeDSecureViewController withinNavigationControllerWithNavigationBarClass:nil toolbarClass:nil configurationBlock:nil];

                                   [tester waitForViewWithAccessibilityLabel:@"System Error" traits:UIAccessibilityTraitStaticText];
                                   [tester tapViewWithAccessibilityLabel:@"Continue"];
                               } didAuthenticate:^(BTThreeDSecureViewController *threeDSecureViewController, BTThreeDSecureLookup *lookup, NSString *nonce, void (^completion)(BTThreeDSecureViewControllerCompletionStatus)) {
                                   [helper fetchThreeDSecureVerificationInfo:nonce
                                                                  completion:^(NSDictionary *response) {
                                                                      expect(response[@"reportStatus"]).to.equal(@"authenticate_unable_to_authenticate");
                                                                      checkedNonce = YES;
                                                                  }];
                               } didFinish:nil];
                
                [system runBlock:^KIFTestStepResult(NSError *__autoreleasing *error) {
                    KIFTestWaitCondition(checkedNonce, error, @"Did not check nonce");
                    return KIFTestStepResultSuccess;
                }];
            });
        });

        context(@"Early termination due to cardinal error - Y, Error", ^{
            it(@"accepts a password but fails to authenticate the nonce", ^{
                __block BOOL checkedNonce = NO;
                [helper lookupNumber:@"4000000000000093"
                               andDo:^(BTThreeDSecureViewController *threeDSecureViewController) {
                                   [system presentViewController:threeDSecureViewController withinNavigationControllerWithNavigationBarClass:nil toolbarClass:nil configurationBlock:nil];

                                   [tester waitForViewWithAccessibilityLabel:@"Please submit your Verified by Visa password." traits:UIAccessibilityTraitStaticText];
                                   [tester tapUIWebviewXPathElement:@"//input[@name=\"external.field.password\"]"];

                                   [tester enterTextIntoCurrentFirstResponder:@"1234"];
                                   [tester tapViewWithAccessibilityLabel:@"Submit"];
                               } didAuthenticate:^(BTThreeDSecureViewController *threeDSecureViewController, BTThreeDSecureLookup *lookup, NSString *nonce, void (^completion)(BTThreeDSecureViewControllerCompletionStatus)) {
                                   [helper fetchThreeDSecureVerificationInfo:nonce
                                                                  completion:^(NSDictionary *response) {
                                                                      expect(response[@"reportStatus"]).to.equal(@"authenticate_signature_verification_failed");
                                                                      checkedNonce = YES;
                                                                  }];
                               } didFinish:nil];
                
                [system runBlock:^KIFTestStepResult(NSError *__autoreleasing *error) {
                    KIFTestWaitCondition(checkedNonce, error, @"Did not check nonce");
                    return KIFTestStepResultSuccess;
                }];
            });
        });
    });
});

SpecEnd
