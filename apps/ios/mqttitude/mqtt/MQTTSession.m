//
// MQTTSession.m
// MQtt Client
// 
// Copyright (c) 2011, 2013, 2lemetry LLC
// 
// All rights reserved. This program and the accompanying materials
// are made available under the terms of the Eclipse Public License v1.0
// which accompanies this distribution, and is available at
// http://www.eclipse.org/legal/epl-v10.html
// 
// Contributors:
//    Kyle Roche - initial API and implementation and/or initial documentation
// 

#import "MQTTSession.h"
#import "MQttTxFlow.h"
#import <CFNetwork/CFSocketStream.h>

@interface MQTTSession()

@property (nonatomic) MQTTSessionStatus status;
@property (strong, nonatomic) NSString *clientId;
@property (nonatomic) UInt16 keepAliveInterval;
@property (strong, nonatomic) MQTTMessage *connectMessage;
@property (strong, nonatomic) NSRunLoop *runLoop;
@property (strong, nonatomic) NSString *runLoopMode;
@property (strong, nonatomic) NSTimer *keepAliveTimer;
@property (strong, nonatomic) MQTTEncoder *encoder;
@property (strong, nonatomic) MQTTDecoder *decoder;
@property (nonatomic) UInt16 txMsgId;
@property (strong, nonatomic) NSMutableDictionary *txFlows;
@property (strong, nonatomic) NSMutableDictionary *rxFlows;
@property (strong, nonatomic) NSMutableArray *queue;

@end

@implementation MQTTSession
#define TIMEOUT 60

- (id)initWithClientId:(NSString *)clientId
              userName:(NSString *)userName
              password:(NSString *)password
             keepAlive:(UInt16)keepAliveInterval
          cleanSession:(BOOL)cleanSessionFlag
             willTopic:(NSString *)willTopic
               willMsg:(NSData *)willMsg
               willQoS:(UInt8)willQoS
        willRetainFlag:(BOOL)willRetainFlag
               runLoop:(NSRunLoop *)runLoop
               forMode:(NSString *)runLoopMode
{
    self = [super init];
    
    self.clientId = clientId;
    self.keepAliveInterval = keepAliveInterval;
    self.runLoop = runLoop;
    self.runLoopMode = runLoopMode;
   
    self.queue = [NSMutableArray array];
    self.txMsgId = 1;
    self.txFlows = [[NSMutableDictionary alloc] init];
    self.rxFlows = [[NSMutableDictionary alloc] init];
    
    self.connectMessage = [MQTTMessage connectMessageWithClientId:clientId
                                                         userName:userName
                                                         password:password
                                                        keepAlive:keepAliveInterval
                                                     cleanSession:cleanSessionFlag
                                                        willTopic:willTopic
                                                          willMsg:willMsg
                                                          willQoS:willQoS
                                                       willRetain:willRetainFlag];


    return self;
}

- (void)connectToHost:(NSString*)host port:(UInt32)port usingSSL:(BOOL)usingSSL {

    self.status = MQTTSessionStatusCreated;

    CFReadStreamRef readStream;
    CFWriteStreamRef writeStream;

    CFStreamCreatePairWithSocketToHost(NULL, (__bridge CFStringRef)host, port, &readStream, &writeStream);
    
    CFReadStreamSetProperty(readStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);
    CFWriteStreamSetProperty(writeStream, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue);

    if (usingSSL) {
        const void *keys[] = { kCFStreamSSLLevel,
                               kCFStreamSSLPeerName };

        const void *vals[] = { kCFStreamSocketSecurityLevelNegotiatedSSL,
                               kCFNull };
        
        CFDictionaryRef sslSettings = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 2,
                                                         &kCFTypeDictionaryKeyCallBacks,
                                                         &kCFTypeDictionaryValueCallBacks);

        CFReadStreamSetProperty(readStream, kCFStreamPropertySSLSettings, sslSettings);
        CFWriteStreamSetProperty(writeStream, kCFStreamPropertySSLSettings, sslSettings);
        
        CFRelease(sslSettings);
    }

    self.encoder = [[MQTTEncoder alloc] initWithStream:(__bridge NSOutputStream*)writeStream
                                          runLoop:self.runLoop
                                      runLoopMode:self.runLoopMode];

    self.decoder = [[MQTTDecoder alloc] initWithStream:(__bridge NSInputStream*)readStream
                                          runLoop:self.runLoop
                                      runLoopMode:self.runLoopMode];

    self.encoder.delegate = self;
    self.decoder.delegate = self;
    
    [self.encoder open];
    [self.decoder open];
}

- (void) subscribeToTopic:(NSString*)topic
                  atLevel:(UInt8)qosLevel {
    [self send:[MQTTMessage subscribeMessageWithMessageId:[self nextMsgId]
                                                    topic:topic
                                                      qos:qosLevel]];
}

- (void)unsubscribeTopic:(NSString*)theTopic {
    [self send:[MQTTMessage unsubscribeMessageWithMessageId:[self nextMsgId]
                                                      topic:theTopic]];
}

- (UInt16)publishData:(NSData*)data
            onTopic:(NSString*)topic
             retain:(BOOL)retainFlag
                qos:(NSInteger)qos
{
    UInt16 msgId = [self nextMsgId];
    MQTTMessage *msg = [MQTTMessage publishMessageWithData:data
                                                   onTopic:topic
                                                       qos:qos
                                                     msgId:qos ? msgId : 0
                                                retainFlag:retainFlag
                                                   dupFlag:FALSE];
    if (qos) {
        MQttTxFlow *flow = [[MQttTxFlow alloc] init];
        flow.msg = msg;
        flow.deadline = [NSDate dateWithTimeIntervalSinceNow:TIMEOUT];
        [self.txFlows setObject:flow forKey:[NSNumber numberWithUnsignedInt:msgId]];
    }
    [self send:msg];
    
    return qos ? msgId : 0;
}

- (void)close
{
    if (self.status == MQTTSessionStatusConnected) {
#ifdef DEBUG
        NSLog(@"MQTTSession disconnecting");
#endif
        self.status = MQTTSessionStatusDisconnecting;
        [self send:[MQTTMessage disconnectMessage]];
    } else {
        [self closeInternal];
    }
}

- (void)closeInternal
{
#ifdef DEBUG
    NSLog(@"MQTTSession closeInternal");
#endif 
    
    /*
    if (self.encoder) {
        [self.encoder close];
        self.encoder = nil;
    }
    if (self.decoder) {
        [self.decoder close];
        self.decoder = nil;
    }
    */
    if (self.keepAliveTimer) {
        [self.keepAliveTimer invalidate];
        self.keepAliveTimer = nil;
    }
    self.status = MQTTSessionStatusClosed;
    [self.delegate handleEvent:self event:MQTTSessionEventConnectionClosed error:nil];

}


- (void)keepAlive:(NSTimer *)timer
{
#ifdef DEBUG
    NSLog(@"MQTTSession keepAlive %@ @%.0f", self.clientId, [[NSDate date] timeIntervalSince1970]);
#endif
    if ([self.encoder status] == MQTTEncoderStatusReady) {
        MQTTMessage *msg = [MQTTMessage pingreqMessage];
        [self.encoder encodeMessage:msg];
    }
    
    for (NSNumber *msgId in [self.txFlows allKeys]) {
        MQttTxFlow *flow = [self.txFlows objectForKey:msgId];
        if ([flow.deadline compare:[NSDate date]] == NSOrderedAscending) {
            MQTTMessage *msg = [flow msg];
            flow.deadline = [NSDate dateWithTimeIntervalSinceNow:TIMEOUT];
            [msg setDupFlag];
            [self send:msg];
        }
    }
}

- (void)encoder:(MQTTEncoder*)sender handleEvent:(MQTTEncoderEvent)eventCode error:(NSError *)error
{
    switch (eventCode) {
        case MQTTEncoderEventReady:
            switch (self.status) {
                case MQTTSessionStatusCreated:
                    [sender encodeMessage:self.connectMessage];
                    self.status = MQTTSessionStatusConnecting;
                    break;
                case MQTTSessionStatusConnecting:
                    break;
                case MQTTSessionStatusConnected:
                    if ([self.queue count] > 0) {
                        MQTTMessage *msg = [self.queue objectAtIndex:0];
                        [self.queue removeObjectAtIndex:0];
                        [self.encoder encodeMessage:msg];
                    }
                    break;
                case MQTTSessionStatusDisconnecting:
#ifdef DEBUG
                    NSLog(@"MQTTSession disconnect sent");
#endif
                    [self closeInternal];
                    break;
                case MQTTSessionStatusClosed:
                    break;
                case MQTTSessionStatusError:
                    break;
            }
            break;
        case MQTTEncoderEventErrorOccurred:
            [self error:MQTTSessionEventConnectionError error:error];
            break;
    }
}

- (void)decoder:(MQTTDecoder*)sender handleEvent:(MQTTDecoderEvent)eventCode error:(NSError *)error
{
    MQTTSessionEvent event;
    switch (eventCode) {
        case MQTTDecoderEventConnectionClosed:
            event = MQTTSessionEventConnectionClosed;
            break;
        case MQTTDecoderEventConnectionError:
            event = MQTTSessionEventConnectionError;
            break;
        case MQTTDecoderEventProtocolError:
            event = MQTTSessionEventProtocolError;
            break;
    }
    [self error:event error:error];
}

- (void)decoder:(MQTTDecoder*)sender newMessage:(MQTTMessage*)msg
{
    switch (self.status) {
        case MQTTSessionStatusConnecting:
            switch ([msg type]) {
                case MQTTConnack:
                    if ([[msg data] length] != 2) {
                        [self error:MQTTSessionEventProtocolError
                              error:[NSError errorWithDomain:@"MQTT"
                                                        code:-2
                                                    userInfo:@{NSLocalizedDescriptionKey : @"MQTT protocol CONNACK expected"}]];
                    }
                    else {
                        const UInt8 *bytes = [[msg data] bytes];
                        if (bytes[1] == 0) {
                            self.status = MQTTSessionStatusConnected;
                            self.keepAliveTimer = [NSTimer timerWithTimeInterval:self.keepAliveInterval
                                                                          target:self
                                                                        selector:@selector(keepAlive:)
                                                                        userInfo:nil
                                                                         repeats:YES];
                            [self.runLoop addTimer:self.keepAliveTimer forMode:self.runLoopMode];
                            [self.delegate handleEvent:self event:MQTTSessionEventConnected error:nil];
                        }
                        else {
                            NSString *errorDescription;
                            switch (bytes[1]) {
                                case 1:
                                    errorDescription = @"MQTT CONNACK: unacceptable protocol version";
                                    break;
                                case 2:
                                    errorDescription = @"MQTT CONNACK: identifier rejected";
                                    break;
                                case 3:
                                    errorDescription = @"MQTT CONNACK: server unavailable";
                                    break;
                                case 4:
                                    errorDescription = @"MQTT CONNACK: bad user name or password";
                                    break;
                                case 5:
                                    errorDescription = @"MQTT CONNACK: not authorized";
                                    break;
                                default:
                                    errorDescription = @"MQTT CONNACK: reserved for future use";
                                    break;
                            }

                            [self error:MQTTSessionEventConnectionRefused error:[NSError errorWithDomain:@"MQTT"
                                                                                                    code:bytes[1]
                                                                                                userInfo:@{NSLocalizedDescriptionKey : errorDescription}]];
                        }
                    }
                    break;
                default:
                    [self error:MQTTSessionEventProtocolError
                          error:[NSError errorWithDomain:@"MQTT"
                                                    code:-1
                                                userInfo:@{NSLocalizedDescriptionKey : @"MQTT protocol no CONNACK"}]];
                    break;
            }
            break;
        case MQTTSessionStatusConnected:
            switch ([msg type]) {
                case MQTTPublish:
                    [self handlePublish:msg];
                    break;
                case MQTTPuback:
                    [self handlePuback:msg];
                    break;
                case MQTTPubrec:
                    [self handlePubrec:msg];
                    break;
                case MQTTPubrel:
                    [self handlePubrel:msg];
                    break;
                case MQTTPubcomp:
                    [self handlePubcomp:msg];
                    break;
                default:
                    return;
            }
            break;
        default:
            break;
    }
}

- (void)handlePublish:(MQTTMessage*)msg
{
    NSData *data = [msg data];
    if ([data length] < 2) {
        return;
    }
    UInt8 const *bytes = [data bytes];
    UInt16 topicLength = 256 * bytes[0] + bytes[1];
    if ([data length] < 2 + topicLength) {
        return;
    }
    NSData *topicData = [data subdataWithRange:NSMakeRange(2, topicLength)];
    NSString *topic = [[NSString alloc] initWithData:topicData
                                            encoding:NSUTF8StringEncoding];
    NSRange range = NSMakeRange(2 + topicLength, [data length] - topicLength - 2);
    data = [data subdataWithRange:range];
    if ([msg qos] == 0) {
        [self.delegate newMessage:self data:data onTopic:topic];
    }
    else {
        if ([data length] < 2) {
            return;
        }
        bytes = [data bytes];
        UInt16 msgId = 256 * bytes[0] + bytes[1];
        if (msgId == 0) {
            return;
        }
        data = [data subdataWithRange:NSMakeRange(2, [data length] - 2)];
        if ([msg qos] == 1) {
            [self.delegate newMessage:self data:data onTopic:topic];
            [self send:[MQTTMessage pubackMessageWithMessageId:msgId]];
        }
        else {
            NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:
                data, @"data", topic, @"topic", nil];
            [self.rxFlows setObject:dict forKey:[NSNumber numberWithUnsignedInt:msgId]];
            [self send:[MQTTMessage pubrecMessageWithMessageId:msgId]];
        }
    }
}

- (void)handlePuback:(MQTTMessage*)msg
{
    if ([[msg data] length] != 2) {
        return;
    }
    UInt8 const *bytes = [[msg data] bytes];
    NSNumber *msgId = [NSNumber numberWithUnsignedInt:(256 * bytes[0] + bytes[1])];
    if ([msgId unsignedIntValue] == 0) {
        return;
    }
    MQttTxFlow *flow = [self.txFlows objectForKey:msgId];
    if (flow == nil) {
        return;
    }

    if ([[flow msg] type] != MQTTPublish || [[flow msg] qos] != 1) {
        return;
    }

    [self.txFlows removeObjectForKey:msgId];
    [self.delegate messageDelivered:self msgID:[msgId unsignedIntValue]];
}

- (void)handlePubrec:(MQTTMessage*)msg
{
    if ([[msg data] length] != 2) {
        return;
    }
    UInt8 const *bytes = [[msg data] bytes];
    NSNumber *msgId = [NSNumber numberWithUnsignedInt:(256 * bytes[0] + bytes[1])];
    if ([msgId unsignedIntValue] == 0) {
        return;
    }
    MQttTxFlow *flow = [self.txFlows objectForKey:msgId];
    if (flow == nil) {
        return;
    }
    msg = [flow msg];
    if ([msg type] != MQTTPublish || [msg qos] != 2) {
        return;
    }
    msg = [MQTTMessage pubrelMessageWithMessageId:[msgId unsignedIntValue]];
    flow.msg = msg;
    flow.deadline = [NSDate dateWithTimeIntervalSinceNow:TIMEOUT];

    [self send:msg];
}

- (void)handlePubrel:(MQTTMessage*)msg
{
    if ([[msg data] length] != 2) {
        return;
    }
    UInt8 const *bytes = [[msg data] bytes];
    NSNumber *msgId = [NSNumber numberWithUnsignedInt:(256 * bytes[0] + bytes[1])];
    if ([msgId unsignedIntValue] == 0) {
        return;
    }
    NSDictionary *dict = [self.rxFlows objectForKey:msgId];
    if (dict != nil) {
        [self.delegate newMessage:self
                             data:[dict valueForKey:@"data"]
                          onTopic:[dict valueForKey:@"topic"]];
        [self.rxFlows removeObjectForKey:msgId];
    }
    [self send:[MQTTMessage pubcompMessageWithMessageId:[msgId unsignedIntegerValue]]];
}

- (void)handlePubcomp:(MQTTMessage*)msg {
    if ([[msg data] length] != 2) {
        return;
    }
    UInt8 const *bytes = [[msg data] bytes];
    NSNumber *msgId = [NSNumber numberWithUnsignedInt:(256 * bytes[0] + bytes[1])];
    if ([msgId unsignedIntValue] == 0) {
        return;
    }
    MQttTxFlow *flow = [self.txFlows objectForKey:msgId];
    if (flow == nil || [[flow msg] type] != MQTTPubrel) {
        return;
    }

    [self.txFlows removeObjectForKey:msgId];
    [self.delegate messageDelivered:self msgID:[msgId unsignedIntValue]];
}

- (void)error:(MQTTSessionEvent)eventCode error:(NSError *)error {
    
    self.status = MQTTSessionStatusError;
    [self closeInternal];
    
    [self.delegate handleEvent:self event:eventCode error:error];
}

- (void)send:(MQTTMessage*)msg {
    if ([self.encoder status] == MQTTEncoderStatusReady) {
        [self.encoder encodeMessage:msg];
    }
    else {
        [self.queue addObject:msg];
    }
}

- (UInt16)nextMsgId {
    self.txMsgId++;
    while (self.txMsgId == 0 || [self.txFlows objectForKey:[NSNumber numberWithUnsignedInt:self.txMsgId]] != nil) {
        self.txMsgId++;
    }
    return self.txMsgId;
}

@end
