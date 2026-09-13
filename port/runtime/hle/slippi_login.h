// Native Slippi sign-in: the same Firebase email/password flow the Slippi Launcher uses,
// then the play key from Slippi's GraphQL backend, written as user.json for the game.
// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <string>

namespace slippi::login {
struct Account {
  std::string uid, display_name, connect_code, play_key, latest_version;
  bool valid() const { return !uid.empty() && !play_key.empty() && !connect_code.empty(); }
};
// Blocking network calls; run off the UI thread. `error` is user-facing.
bool sign_in(const std::string& email, const std::string& password, Account& out, std::string& error);
bool send_password_reset(const std::string& email, std::string& error);
bool read_user_file(const std::string& dir, Account& out);
bool write_user_file(const std::string& dir, const Account& account, std::string& error);
void remove_user_file(const std::string& dir);
}  // namespace slippi::login
