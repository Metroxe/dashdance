// Synthetic protocol fixtures: no socket, profile, HTTP or service activation.
// SPDX-License-Identifier: GPL-2.0-or-later
#include "slippi_matchmaking_protocol.h"
#include <cstdio>

int main() {
  using namespace slippi;
  using nlohmann::json;
  int failures = 0;
  auto check = [&](bool value, const char* message) { if (!value) { ++failures; std::fprintf(stderr, "FAIL: %s\n", message); } };
  UserInfo user;
  user.uid = "fixture-user"; user.play_key = "fixture-key";
  user.display_name = "Fixture"; user.connect_code = "TEST#001";
  Matchmaking::MatchSearchSettings search;
  search.mode = Matchmaking::DIRECT; search.connect_code = std::string("TEST\x81\x94" "002", 9);
  json ticket;
  check(protocol::create_ticket(user, search, "3.6.4", "127.0.0.1:12345", ticket), "owned identity serializes");
  check(ticket["type"] == "create-ticket" && ticket["appVersion"] == "3.6.4" &&
        ticket["search"]["mode"] == 2 && ticket["search"]["connectCode"].size() == 9 &&
        ticket["search"]["connectCode"][4] == 0x81 && ticket["user"]["playKey"] == "fixture-key",
        "ticket preserves source field names and CP932 byte values");
  user.play_key.clear();
  check(!protocol::create_ticket(user, search, "3.6.4", "", ticket) && ticket.is_null(), "no identity produces no ticket");
  std::string error, version;
  check(protocol::ticket_created({{"type", "create-ticket-resp"}}, error), "server queued status is decoded");
  check(!protocol::ticket_created({{"type", "create-ticket-resp"}, {"error", "fixture refusal"}}, error) &&
        error == "fixture refusal", "server refusal is not success");

  json assignment = {{"type", "get-ticket-resp"}, {"matchId", "mode.direct-fixture"}, {"isHost", true}, {"items", 7},
    {"players", json::array({
      {{"uid", "remote"}, {"port", 2}, {"ipAddress", "192.0.2.1:34567"}, {"ipAddressLan", "127.0.0.1:34567"},
       {"rank", {{"rating", 1500.5}, {"updateCount", 10}}}},
      {{"uid", "local"}, {"port", 1}, {"isLocalPlayer", true}, {"ipAddress", "192.0.2.1:23456"}}
    })}};
  protocol::Assignment result;
  check(protocol::assigned_match(assignment, result, error, version), "valid mock assignment is decoded");
  check(result.local_player_index == 0 && result.is_host && result.result.players[1].uid == "remote" &&
        result.result.players[1].ranked_rating == 1500.5f && result.remote_addresses == std::vector<std::string>{"127.0.0.1:34567"} &&
        result.result.items == 7 && result.result.stages.size() == 6, "assignment retains global slots, rank, LAN choice, items and defaults");
  assignment["players"][0]["ipAddress"] = "192.0.2.2:34567";
  assignment["stages"] = json::array({31, 32});
  check(protocol::assigned_match(assignment, result, error, version) && result.remote_addresses[0] == "192.0.2.2:34567" &&
        result.result.stages == std::vector<uint16_t>({31, 32}), "different public address retains external route and assigned stages");
  const auto good = result.result.id;
  assignment["players"][0]["port"] = 1;
  check(!protocol::assigned_match(assignment, result, error, version) && result.result.id == good, "duplicate port cannot publish a partial assignment");
  assignment["players"][0]["port"] = 2;
  assignment["players"][1]["isLocalPlayer"] = false;
  check(!protocol::assigned_match(assignment, result, error, version), "missing local player does not invent an index");
  assignment["players"][1]["isLocalPlayer"] = true;
  assignment["players"][0].erase("ipAddress");
  check(!protocol::assigned_match(assignment, result, error, version), "missing remote address never defaults to an external address");
  check(!protocol::assigned_match({{"type", "get-ticket-resp"}, {"error", "update required"}, {"latestVersion", "test-version"}},
                                 result, error, version) && version == "test-version", "version refusal remains explicit");
  return failures ? 1 : 0;
}
