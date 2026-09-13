#!/usr/bin/env python3
"""Compile and execute real-emitter synthetic instructions; never reads a DOL/ISO."""
# SPDX-License-Identifier: GPL-2.0-or-later
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace

PORT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PORT / "recomp"))
from emit import Emitter
from gekko import decode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cxx", default=os.environ.get("CXX", "clang++"))
    parser.add_argument("--sanitize", action="store_true")
    args = parser.parse_args()
    emitter = Emitter(None, None, {}, {}, {})
    info = SimpleNamespace(func=SimpleNamespace(addr=0x80004000))
    words = {
        "mulli": (7 << 26) | (3 << 21) | (4 << 16) | 0x8000,
        "mullw": (31 << 26) | (3 << 21) | (4 << 16) | (5 << 11) | (235 << 1) | 1,
        "mulhw": (31 << 26) | (3 << 21) | (4 << 16) | (5 << 11) | (75 << 1),
        "sraw": (31 << 26) | (4 << 21) | (3 << 16) | (5 << 11) | (792 << 1),
        "srawi": (31 << 26) | (4 << 21) | (3 << 16) | (31 << 11) | (824 << 1),
        "rlwinm": (21 << 26) | (4 << 21) | (3 << 16) | (31 << 1),
        "rlwimi": (20 << 26) | (4 << 21) | (3 << 16) | (8 << 11) | (8 << 6) | (15 << 1),
        "fnmadds": (59 << 26) | (3 << 21) | (4 << 16) | (5 << 11) | (6 << 6) | (31 << 1),
        "ps_nmsub": (4 << 26) | (4 << 21) | (4 << 16) | (5 << 11) | (6 << 6) | (30 << 1),
        "ps_add": (4 << 26) | (4 << 21) | (4 << 16) | (5 << 11) | (21 << 1),
        "fadd": (63 << 26) | (3 << 21) | (4 << 16) | (5 << 11) | (21 << 1),
    }
    functions = []
    for name, word in words.items():
        insn = decode(info.func.addr, word)
        if insn is None or insn.op != name:
            raise AssertionError(f"synthetic {name} decoded as {insn}")
        body = emitter.emit_insn(info, 0, insn)
        functions.append(f"void op_{name}(ppc::Context& c) {{ {body} }}")
    source = r'''
#include "ppc.h"
#include <cstdio>
static unsigned failures = 0, checks = 0;
static void eq(const char* name, uint64_t got, uint64_t expected) {
  ++checks;
  if (got != expected) {
    ++failures;
    std::fprintf(stderr, "%s: %016llx != %016llx\n", name,
      (unsigned long long)got, (unsigned long long)expected);
  }
}
'''
    source += "\n".join(functions)
    source += r'''
int main() {
  ppc::ScopedGuestFpEnvironment fp(2);
  ppc::Context c{};
  c.r[4] = 0x7fffffff; op_mulli(c); eq("mulli modular overflow", c.r[3], 0x8000);
  c.r[4] = 0x80000000; c.r[5] = 0xffffffff; op_mullw(c);
  eq("mullw modular overflow", c.r[3], 0x80000000); eq("mullw Rc", c.cr[0], 8);
  op_mulhw(c); eq("mulhw", c.r[3], 0);
  c.r[4] = 0x81234567;
  for (uint32_t n = 0; n < 128; ++n) {
    c.r[5] = n; op_sraw(c);
    const int64_t signed_value = -2128394905LL;
    const int64_t divisor = INT64_C(1) << (n & 31);
    const uint32_t result = n & 32 ? 0xffffffffu :
      uint32_t(signed_value / divisor - (signed_value % divisor ? 1 : 0));
    eq("emitted sraw", c.r[3], result);
  }
  op_srawi(c); eq("emitted srawi 31", c.r[3], 0xffffffff);
  op_rlwinm(c); eq("emitted rotate zero", c.r[3], 0x81234567);
  c.r[3] = 0xaabbccdd; c.r[4] = 0x11223344; op_rlwimi(c);
  eq("emitted rotate insert", c.r[3], 0xaa33ccdd);
  c.f[4].ps0 = 1; c.f[6].ps0 = 1; c.f[5].ps0 = 0x1p-24;
  op_fnmadds(c);
  eq("emitted fnmadds RN before negate", c.f[3].u0, 0xbff0000020000000);
  eq("emitted fnmadds duplicated lane", c.f[3].u1, 0xbff0000020000000);
  c.f[4].ps0 = 1; c.f[4].ps1 = -1; c.f[6].ps0 = 1; c.f[6].ps1 = 1;
  c.f[5].ps0 = -0x1p-24; c.f[5].ps1 = 0x1p-24;
  op_ps_nmsub(c);
  eq("emitted aliased paired nmsub lane0", c.f[4].u0, 0xbff0000020000000);
  eq("emitted aliased paired nmsub lane1", c.f[4].u1, 0x3ff0000000000000);
  c.f[4].ps0 = 1; c.f[4].ps1 = -1;
  c.f[5].ps0 = 0x1p-24; c.f[5].ps1 = -0x1p-24; op_ps_add(c);
  eq("emitted aliased paired add lane0", c.f[4].u0, 0x3ff0000020000000);
  eq("emitted aliased paired add lane1", c.f[4].u1, 0xbff0000000000000);
  c.f[4].ps0 = 1; c.f[5].ps0 = 0x1p-53; op_fadd(c);
  eq("emitted double add RN", c.f[3].u0, 0x3ff0000000000001);
  std::printf("Emitted PPC snippets: %u checks, %u failures\n", checks, failures);
  return failures ? 1 : 0;
}
'''
    with tempfile.TemporaryDirectory(prefix="melee-emitted-numeric-") as work:
        fixture = Path(work) / "numeric_fixture.cpp"
        executable = Path(work) / "numeric_fixture"
        fixture.write_text(source)
        command = [args.cxx, "-std=c++17", "-O2", "-fno-fast-math", "-ffp-model=strict",
                   "-ffp-contract=off", "-Wall", "-Wextra", "-Werror",
                   "-I", str(PORT / "runtime/ppc"), str(fixture),
                   str(PORT / "runtime/ppc/numeric.cpp"), "-o", str(executable)]
        if args.sanitize:
            command += ["-fsanitize=undefined,float-cast-overflow", "-fno-sanitize-recover=all"]
        subprocess.run(command, check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
