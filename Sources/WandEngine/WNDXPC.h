// Shared simulator XPC connection recipe documented by Meta idb (MIT).
// See THIRD_PARTY_NOTICES. Caller installs handlers and resumes the connection.
#import "WNDPrivateAPI.h"
#import <xpc/xpc.h>
#import <dlfcn.h>

static inline xpc_connection_t WNDCreateConnection(id<WNDSimDevice> device, NSString *service,
                                                  dispatch_queue_t queue, NSError **error) {
  typedef xpc_endpoint_t (*EndpointFn)(mach_port_t, uint64_t, uint64_t) __attribute__((ns_returns_retained));
  typedef void (*EnableFn)(xpc_connection_t);
  EndpointFn endpointFromPort = (EndpointFn)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
  EnableFn enable = (EnableFn)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
  NSString *failure = nil;
  if (!endpointFromPort || !enable) failure = @"Simulator XPC symbols unavailable";
  if (!failure) {
    mach_port_t port = [device lookup:service error:error];
    if (port == MACH_PORT_NULL) return nil;
    xpc_endpoint_t endpoint = endpointFromPort(port, 0, 0); // consumes lookup's send right
    xpc_connection_t connection = endpoint ? xpc_connection_create_from_endpoint(endpoint) : nil;
    if (connection) {
      enable(connection);
      xpc_connection_set_target_queue(connection, queue);
      return connection;
    }
    failure = @"Simulator XPC endpoint creation failed";
  }
  if (error) *error = [NSError errorWithDomain:@"wand.xpc" code:1 userInfo:@{NSLocalizedDescriptionKey:failure}];
  return nil;
}
