// SPDX-License-Identifier: GPL-2.0-or-later
#include "file_identity.h"
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>
#include <unistd.h>

static void require(bool ok, const char* what) {
  if (!ok) { std::fprintf(stderr, "%s\n", what); std::exit(1); }
}
int main() {
  std::string temporary = (std::filesystem::temp_directory_path() / "melee-identity-test-XXXXXX").string();
  std::vector<char> path(temporary.begin(), temporary.end()); path.push_back(0);
  int fd = ::mkstemp(path.data()); require(fd >= 0, "create isolated identity test file");
  require(::write(fd, "abc", 3) == 3, "write known test vector"); ::close(fd);
  std::string hash, error;
  require(host::file_sha1(path.data(), hash, error), error.c_str());
  require(hash == "a9993e364706816aba3e25717850c26c9cd0d89d", "streaming SHA-1 vector");
  require(host::file_sha256(path.data(), hash, error), error.c_str());
  require(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "streaming SHA-256 vector");
  host::FileArtifact artifact;
  const auto directory = std::filesystem::path(path.data()).parent_path();
  require(host::closed_file_artifact(directory.string(), path.data(), true, artifact, error) && artifact.present && artifact.bytes == 3,
          "closed replay or log artifact identity");
  require(artifact.sha256 == hash, "artifact digest matches the known content");
  require(host::closed_file_artifact(directory.string(), "", true, artifact, error) && !artifact.present, "no-replay result is explicit absence");
  require(host::closed_file_artifact(directory.string(), "/does-not-exist/unclosed.slp", false, artifact, error) && !artifact.present,
          "fatal/unclosed replay is not read or presented as finalized");
  require(!host::closed_file_artifact("/", path.data(), true, artifact, error), "artifact cannot escape its isolated directory");
  std::filesystem::remove(path.data());
  require(!host::file_sha1(path.data(), hash, error), "missing identity input rejected");
  std::string executable;
  require(host::executable_path(executable, error) && std::filesystem::is_regular_file(executable), "actual executable identity path");
}
