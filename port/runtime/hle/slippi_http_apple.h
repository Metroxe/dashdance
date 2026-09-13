// Synchronous HTTPS request through NSURLSession, shared by macOS, iOS and visionOS.
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <string>
namespace slippi::report {
// `headers` are CRLF-separated "Name: value" lines. Returns false on a transport
// error (with `error` filled); HTTP status codes are reported through `status`.
bool apple_http(const char* method, const std::string& url, const std::string& headers, const std::string& body,
                const char* user_agent, int* status, std::string* response, std::string* error);
}  // namespace slippi::report
