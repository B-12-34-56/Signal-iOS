//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import <SignalServiceKit/TSOutgoingMessage.h>

NS_ASSUME_NONNULL_BEGIN

/// Outgoing message we send to the contact we want to activate payments.
/// NOT rendered in chat; a separate TSInfoMessage is created for that purpose.
@interface OWSPaymentActivationRequestMessage : TSOutgoingMessage

- (instancetype)initOutgoingMessageWithBuilder:(TSOutgoingMessageBuilder *)outgoingMessageBuilder
                                   transaction:(SDSAnyReadTransaction *)transaction NS_UNAVAILABLE;

- (instancetype)initWithThread:(TSThread *)thread transaction:(SDSAnyReadTransaction *)transaction;

- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run
// `sds_codegen.sh`.


// --- CODE GENERATION MARKER

@end

NS_ASSUME_NONNULL_END
