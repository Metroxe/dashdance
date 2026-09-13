// SPDX-License-Identifier: GPL-2.0-or-later
#include "slippi_login.h"
#include "slippi_http_apple.h"
#include <nlohmann/json.hpp>
#include <filesystem>
#include <fstream>

namespace slippi::login {
namespace {
using json = nlohmann::json;
// The Slippi project's Firebase web key. Firebase web keys identify the project rather than
// authenticate a caller (the Launcher ships the same one); access is governed server-side.
constexpr const char* kFirebaseKey = "AIzaSyAuQqc_wgqcUu3FqrICEPZ9Av_hPxMR_i4";
constexpr const char* kIdentityToolkit = "https://identitytoolkit.googleapis.com/v1/accounts:";
constexpr const char* kGraphQL = "https://internal.slippi.gg/graphql";
constexpr const char* kUserAgent = "iSlippi";
constexpr const char* kUserQuery =
    "query getUserKeyQuery($fbUid: String) { getUser(fbUid: $fbUid) { fbUid displayName connectCode { code } private { playKey } } "
    "getLatestDolphin { version } }";

std::string firebase_message(const std::string& code) {
  if (code.rfind("INVALID_LOGIN_CREDENTIALS", 0) == 0 || code.rfind("INVALID_PASSWORD", 0) == 0 || code.rfind("EMAIL_NOT_FOUND", 0) == 0)
    return "Wrong email or password.";
  if (code.rfind("USER_DISABLED", 0) == 0) return "This account has been disabled.";
  if (code.rfind("TOO_MANY_ATTEMPTS", 0) == 0) return "Too many attempts; try again later.";
  if (code.rfind("INVALID_EMAIL", 0) == 0) return "That is not a valid email address.";
  return "Sign-in failed: " + code;
}

bool post_json(const std::string& url, const std::string& headers, const json& body, json& reply, std::string& error) {
  int status = 0;
  std::string response, transport;
  if (!report::apple_http("POST", url, headers, body.dump(), kUserAgent, &status, &response, &transport)) {
    error = "No connection: " + transport;
    return false;
  }
  try { reply = json::parse(response); } catch (const std::exception&) { reply = json::object(); }
  if (status < 200 || status >= 300) {
    std::string code;
    if (auto it = reply.find("error"); it != reply.end() && it->is_object()) code = it->value("message", "");
    error = code.empty() ? "Server error (" + std::to_string(status) + ")" : code;
    return false;
  }
  return true;
}
}  // namespace

bool sign_in(const std::string& email, const std::string& password, Account& out, std::string& error) {
  json reply;
  const std::string sign_in_url = std::string(kIdentityToolkit) + "signInWithPassword?key=" + kFirebaseKey;
  if (!post_json(sign_in_url, "Content-Type: application/json", {{"email", email}, {"password", password}, {"returnSecureToken", true}}, reply, error)) {
    if (error.rfind("No connection", 0) != 0 && error.rfind("Server error", 0) != 0) error = firebase_message(error);
    return false;
  }
  const std::string token = reply.value("idToken", ""), uid = reply.value("localId", "");
  if (token.empty() || uid.empty()) { error = "Sign-in failed: no session token."; return false; }

  json user;
  if (!post_json(kGraphQL, "Content-Type: application/json\r\nAuthorization: Bearer " + token,
                 {{"query", kUserQuery}, {"variables", {{"fbUid", uid}}}}, user, error)) {
    error = "Signed in, but Slippi's account service did not answer: " + error;
    return false;
  }
  auto object_at = [](const json& j, const char* key) -> const json* {
    if (!j.is_object()) return nullptr;
    auto it = j.find(key);
    return it != j.end() && it->is_object() ? &*it : nullptr;
  };
  const json* data = object_at(user, "data");
  const json* u = data ? object_at(*data, "getUser") : nullptr;
  if (!u) { error = "Signed in, but this account has no Slippi profile yet. Finish setting it up at slippi.gg."; return false; }
  out.uid = uid;
  out.display_name = u->value("displayName", "");
  if (const json* code = object_at(*u, "connectCode")) out.connect_code = code->value("code", "");
  if (const json* priv = object_at(*u, "private")) out.play_key = priv->value("playKey", "");
  if (const json* dolphin = object_at(*data, "getLatestDolphin")) out.latest_version = dolphin->value("version", "");
  if (!out.valid()) { error = "This account has no connect code yet. Pick one at slippi.gg, then sign in again."; return false; }
  return true;
}

bool send_password_reset(const std::string& email, std::string& error) {
  json reply;
  const std::string url = std::string(kIdentityToolkit) + "sendOobCode?key=" + kFirebaseKey;
  if (!post_json(url, "Content-Type: application/json", {{"requestType", "PASSWORD_RESET"}, {"email", email}}, reply, error)) {
    if (error.rfind("No connection", 0) != 0 && error.rfind("Server error", 0) != 0) error = firebase_message(error);
    return false;
  }
  return true;
}

bool read_user_file(const std::string& dir, Account& out) {
  std::ifstream f(dir + "/user.json");
  if (!f) return false;
  try {
    json j = json::parse(f);
    out.uid = j.value("uid", ""); out.play_key = j.value("playKey", ""); out.connect_code = j.value("connectCode", "");
    out.display_name = j.value("displayName", ""); out.latest_version = j.value("latestVersion", "");
  } catch (const std::exception&) { return false; }
  return out.valid();
}

bool write_user_file(const std::string& dir, const Account& a, std::string& error) {
  std::error_code ec;
  std::filesystem::create_directories(dir, ec);
  json j = {{"uid", a.uid}, {"playKey", a.play_key}, {"connectCode", a.connect_code}, {"displayName", a.display_name}, {"latestVersion", a.latest_version}};
  std::ofstream f(dir + "/user.json", std::ios::trunc);
  if (!f) { error = "Cannot write " + dir + "/user.json"; return false; }
  f << j.dump(2) << "\n";
  f.close();
  if (!f) { error = "Cannot write " + dir + "/user.json"; return false; }
  return true;
}

void remove_user_file(const std::string& dir) {
  std::error_code ec;
  std::filesystem::remove(dir + "/user.json", ec);
}
}  // namespace slippi::login
