// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#include "slippi_http_apple.h"
#include <dispatch/dispatch.h>

namespace slippi::report {
bool apple_http(const char* method, const std::string& url, const std::string& headers, const std::string& body,
                const char* user_agent, int* status, std::string* response, std::string* error) {
  @autoreleasepool {
    NSURL* target = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
    if (!target) { if (error) *error = "invalid URL"; return false; }
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:target];
    request.HTTPMethod = [NSString stringWithUTF8String:method];
    request.timeoutInterval = 30.0;
    [request setValue:[NSString stringWithUTF8String:user_agent] forHTTPHeaderField:@"User-Agent"];
    size_t pos = 0;
    while (pos < headers.size()) {
      size_t end = headers.find("\r\n", pos);
      if (end == std::string::npos) end = headers.size();
      const std::string line = headers.substr(pos, end - pos);
      pos = end + 2;
      const size_t colon = line.find(':');
      if (colon == std::string::npos) continue;
      std::string name = line.substr(0, colon), value = line.substr(colon + 1);
      while (!value.empty() && value.front() == ' ') value.erase(value.begin());
      [request setValue:[NSString stringWithUTF8String:value.c_str()] forHTTPHeaderField:[NSString stringWithUTF8String:name.c_str()]];
    }
    if (!body.empty()) request.HTTPBody = [NSData dataWithBytes:body.data() length:body.size()];
    NSURLSessionConfiguration* configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 30.0;
    NSURLSession* session = [NSURLSession sessionWithConfiguration:configuration];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSData* received = nil;
    __block NSHTTPURLResponse* http_response = nil;
    __block NSError* failure = nil;
    NSURLSessionDataTask* task = [session dataTaskWithRequest:request
        completionHandler:^(NSData* data, NSURLResponse* urlResponse, NSError* taskError) {
          received = data;
          http_response = [urlResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse*)urlResponse : nil;
          failure = taskError;
          dispatch_semaphore_signal(done);
        }];
    [task resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];
    if (failure) { if (error) *error = failure.localizedDescription.UTF8String; return false; }
    if (status) *status = http_response ? (int)http_response.statusCode : 0;
    if (response) response->assign((const char*)received.bytes, received.length);
    return true;
  }
}
}  // namespace slippi::report
