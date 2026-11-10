// Simulator-free contract tests for the private DTUHID wire types and failures.
// Include the implementation so tests do not expand WandEngine's public API.
#import "../Sources/WandEngine/WNDDTUHID.m"

static void Require(BOOL value, const char *message) {
  if (!value) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
@interface RecordingChannel : WNDDTUChannel
@property(nonatomic, strong) xpc_object_t last;
@property(nonatomic) NSUInteger sends;
@end
@implementation RecordingChannel
- (NSString *)send:(const char *)type payload:(xpc_object_t)payload {
  self.last = Envelope(self.service, type, payload, NO);
  self.sends++;
  return nil;
}
@end

int main(void) { @autoreleasepool {
  WNDDTUHID *hid = [[WNDDTUHID alloc] initWithDevice:(id)[NSNull null]];
  RecordingChannel *digitizer = [RecordingChannel new]; digitizer.service = DigitizerService;
  [hid setValue:digitizer forKey:@"digitizer"];

  Require([hid touch:CGPointMake(0.25, 0.75) second:NULL phase:1] == nil, "single contact sent");
  xpc_object_t p = xpc_dictionary_get_value(digitizer.last, "payload");
  Require(!strcmp(xpc_dictionary_get_string(digitizer.last, "messageType"), "IndigoDigitizerEvent"), "touch message discriminator");
  Require(!xpc_dictionary_get_bool(digitizer.last, "isBarrier"), "real input is not a probe");
  Require(!strcmp(xpc_dictionary_get_string(digitizer.last, "featureIdentifier"), DigitizerService.UTF8String), "digitizer service routing");
  Require(xpc_get_type(xpc_dictionary_get_value(p, "eventType")) == XPC_TYPE_UINT64, "phases must be unsigned, not signed/string");
  Require(xpc_dictionary_get_uint64(p, "eventType") == 0, "down starts contact");
  Require(xpc_dictionary_get_value(p, "pointTwo") == NULL, "single touch must omit second point");
  xpc_object_t first = xpc_dictionary_get_value(p, "pointOne");
  Require(xpc_get_type(xpc_dictionary_get_value(first, "x")) == XPC_TYPE_DOUBLE, "coordinates must be doubles");
  Require(xpc_dictionary_get_double(first, "x") == 0.25 && xpc_dictionary_get_double(first, "y") == 0.75, "normalized coordinates preserved");
  CGPoint second = CGPointMake(0.8, 0.2);
  [hid touch:CGPointMake(0.2, 0.8) second:&second phase:6];
  p = xpc_dictionary_get_value(digitizer.last, "payload");
  Require(xpc_dictionary_get_uint64(p, "eventType") == 1, "move continues contact");
  Require(xpc_dictionary_get_double(xpc_dictionary_get_value(p, "pointTwo"), "x") == 0.8, "multitouch preserves second finger");
  [hid touch:CGPointZero second:NULL phase:2];
  Require(xpc_dictionary_get_uint64(xpc_dictionary_get_value(digitizer.last, "payload"), "eventType") == 2, "up ends contact");

  [hid key:4 down:YES]; p = xpc_dictionary_get_value(digitizer.last, "payload");
  Require(xpc_dictionary_get_uint64(p, "usageCode") == 4 && xpc_dictionary_get_uint64(p, "state") == 1, "keyboard down uses one-based state");
  [hid key:4 down:NO];
  Require(xpc_dictionary_get_uint64(xpc_dictionary_get_value(digitizer.last, "payload"), "state") == 2, "keyboard up is state 2");

  [hid crown:-5 phase:1]; p = xpc_dictionary_get_value(digitizer.last, "payload");
  Require(!strcmp(xpc_dictionary_get_string(digitizer.last, "featureIdentifier"), DigitizerService.UTF8String), "crown shares the proven digitizer connection");
  Require(xpc_dictionary_get_double(xpc_dictionary_get_value(p, "point"), "y") == -5, "crown delta sign preserved on y axis");
  Require(xpc_dictionary_get_uint64(p, "phase") == 1 && xpc_dictionary_get_uint64(p, "target") == 0, "crown began and digital crown target");
  [hid crown:0 phase:4];
  Require(xpc_dictionary_get_uint64(xpc_dictionary_get_value(digitizer.last, "payload"), "phase") == 4, "crown ended phase is 4, not 3");

  NSUInteger sent = digitizer.sends;
  digitizer.failure = @"interrupted during gesture";
  Require([[hid touch:CGPointZero second:NULL phase:6] isEqual:digitizer.failure], "interrupted contact fails loudly");
  Require([[hid key:4 down:YES] isEqual:digitizer.failure], "interrupted connection refuses later input");
  Require(digitizer.sends == sent, "no ambiguous input replay or send after interruption");
  Require([hid.failure isEqual:digitizer.failure], "asynchronous channel errors remain observable");
  puts("PASS: DTUHID wire types, touch phases, multitouch, keyboard, Crown routing, interrupted-input refusal");
}}
