# Portable PPC numeric contract and measured boundary

The canonical `FpProfile::ReferenceSlippi` profile is the default on arm64 and x86.
`UnlockedJit64` retains the original foundation's x86 FMA and FTZ+DAZ behavior as an
explicit diagnostic comparison. It is not a supported synchronization profile.

The return-value rules are adapted from Reference Slippi commit
`41a7a3a110ed52999486ae1901c8fbb9a63d4f13`:

- `Source/Core/Core/PowerPC/Interpreter/Interpreter_FPUtils.h`: single rounding,
  subnormal normalization before Force25Bit, NaN operand priority, load/store conversion.
- `Source/Core/Core/PowerPC/Interpreter/Interpreter_FloatingPoint.cpp` and
  `Interpreter_Paired.cpp`: rounding before negation, NaN sign preservation,
  integer saturation and the negative-zero conversion marker.
- `Source/Core/Common/FloatUtils.cpp`: exact table-based `fres` and `frsqrte` values.
- `Source/Core/Common/{Arm,x64}FPURoundMode.cpp`: rounding-mode mappings and the
  distinction between input and output subnormal flushing.

Sources retain GPL-2.0-or-later notices. No emulator runtime, CPU JIT, or reference
PowerPC state is linked into the application. The optional estimate differential
links the unchanged `FloatUtils.cpp` into a separate developer-only executable.

## Execution requirements

Every guest-executing thread must construct `ppc::ScopedGuestFpEnvironment` at its
outer entry. FPSCR writes update that thread's rounding mode using
`update_fp_environment`. Scope exit restores the complete host environment and
the prior thread-local guest state, including exception unwinding.

Compile numeric helpers and generated guest code with Clang
`-fno-fast-math -ffp-model=strict -ffp-contract=off`. The test script uses these
flags directly. Dynamic RN must not be optimized away. Explicit ARM `fmadd` and
x86 FMA intrinsics (when enabled) remain fused; other hosts use the correctly
fused library operation rather than a multiply/add approximation.

Reference NI keeps host input subnormals enabled and flushes result subnormals in
the numeric helpers. This avoids depending on optional ARM FEAT_AFP. Single
conversions implement the pre-rounding flush quirk. Store conversion follows the
reference bit-transfer rule separately from arithmetic narrowing.

## Measured 2026-09-12

Native Apple arm64, Apple Clang, macOS. These are synthetic CPU tests, not game runs.

| Test | Result |
| --- | --- |
| Actual `numeric.cpp` helpers, `-O2` | 3,053 checks, zero failures |
| Same helpers, ASan/UBSan/float-cast-overflow | 3,053 checks, zero findings |
| Same helper corpus, x86-64 under Rosetta | 3,053 checks, zero failures |
| Real decoder/emitter synthetic instruction snippets, UBSan | 142 checks, zero findings |
| Actual dispatch/interpreter/PSQ/module telemetry with inert host fixtures, ASan/UBSan | 315 checks, zero findings |
| Unchanged pinned `FloatUtils.cpp` estimate differential | 786,848 comparisons, zero differences |

The helper corpus covers all four RN modes, signed zero, signaling/quiet NaNs,
NaN operand ordering, scalar and single-result FMA, NI input/output distinctions,
subnormal single rounding, Force25Bit, load/store bit conversions, `fctiw`
saturation/negative-zero markers, table goldens, rotates and arithmetic shifts.
Four concurrent threads verify rounding isolation and scope restoration.

The snippet test calls the real decoder and emitter with synthetic instruction
words, compiles the output, and executes it. It covers unsigned `mulli`/`mullw`
overflow, `mulhw`, `sraw` counts 0 through 127, `srawi`, zero-count rotate, rotate
insert, scalar FMA, and paired operations with overlapping input/output registers.

The dispatch test verifies strict mode rejects a missing AOT target before any
instruction read; diagnostic mode alone executes synthetic memory. It checks
entry/exit and nested native-call/branch transfers, changed instruction words,
PC sequence hashes, module metadata, and actual PSQ load/store helpers.

The estimate differential first qualifies its oracle with exact finite and NaN
goldens. It covers every estimate interval and exponent parity, low-bit endpoints,
subnormal/NaN bit positions, and 262,144 fixed-seed binary64 inputs. This measured
corpus is not exhaustive binary64 equivalence.

## Reproduction

Run from the checkout root; use a fresh output directory for executables:

```sh
clang++ -std=c++17 -O2 -fno-fast-math -ffp-model=strict -ffp-contract=off \
  -Wall -Wextra -Werror -I port/runtime/ppc \
  port/tests/ppc_numeric_test.cpp port/runtime/ppc/numeric.cpp -o /tmp/ppc_numeric_test
/tmp/ppc_numeric_test
python3 port/tests/test_generator_numeric.py --sanitize
```

For sanitizer helper/dispatch builds add
`-fsanitize=address,undefined,float-cast-overflow -fno-sanitize-recover=all`.
Dispatch sources are `ppc_dispatch_test.cpp`, `numeric.cpp`, `ppc_runtime.cpp`, and
`interp.cpp`, with include directories `port/tests/fixtures`, `port/runtime/ppc`,
and `port/runtime/host`. The fixture header must precede any generated game header.

The developer-only oracle command requires C++20 and an independently verified
checkout of the pinned reference; it is a manual optional test, not an application
dependency:

```sh
clang++ -std=c++20 -O2 -fno-fast-math -ffp-model=strict -ffp-contract=off \
  -I port/runtime/ppc -I "$PPC_REFERENCE_DIR/Source/Core" \
  port/tests/ppc_estimate_differential.cpp port/runtime/ppc/numeric.cpp \
  "$PPC_REFERENCE_DIR/Source/Core/Common/FloatUtils.cpp" -o /tmp/ppc_estimates
/tmp/ppc_estimates
```

## Explicit gaps

These tests establish sampled return values, not complete PowerPC/Slippi parity.
FPSCR sticky exception flags, FPRF, FR/FI, enabled guest exceptions, and CR1 effects
remain incomplete in the foundation. The canonical profile name printed at startup
states this limitation. Full hardware/Slippi single-precision FMA corner cases,
all data-dependent generated paths, Windows/MSVC execution, physical Intel
execution, and full frame-state equivalence remain unproven.

Integer-quantized PSQ NaN conversion stops explicitly: the reference interpreter's
NaN-to-integer C++ cast is not a defined portable oracle. No arbitrary ARM/x86
saturation rule is substituted. Normal integer PSQ clamps/scales are tested.

Strict AOT is the runtime default. Diagnostic interpretation must be enabled
explicitly by the host. Missing-target samples are bounded to 32, PC samples to
128, transfer samples to 128, and module identities to 128. Aggregate counters and
FNV-1a sequence hashes continue after samples fill; overflow counts are visits,
not unique-address counts. PC visits include a faulting instruction, whereas
`interpreted_instructions` counts successfully completed steps. A fatal instruction
has no successful exit event. FNV hashes are diagnostics, not cryptographic proof.

`record_loaded_module` accepts a host-supplied SHA-256 over a named loaded byte
range. Digest syntax validation is not content verification. Host loader wiring
and serialized launch manifests must be validated by their integration owner;
the CPU test only proves record retention. Relocation or subsequent code changes
require corresponding provenance and PC-word evidence. Runtime summaries print
the bounded records, and `aot_diagnostics()` exposes the same data to manifests.

Loaded modules retain distinct `(complete name, address, size, normalized SHA-256)`
identities in first-appearance order. A verified identical load increments that
identity's `loads` and updates `last_event`; `first_event` remains fixed. Changed
hashes, names, sizes, or addresses retain separate identities, including when
content later returns to an earlier identity. Missing hashes or truncated names
never deduplicate. Event IDs start at one. `loaded_module_records` counts every
load event, so `sum(identity.loads) + unrecorded_modules == loaded_module_records`.
The 128-identity cap expands the former 16-entry table while bounding snapshot
memory. Existing identities still count duplicates after capacity is reached;
unmatched events then increment the explicit dropped-event counter. Acceptance
must reject dropped provenance rather than treating the samples as complete.
The added telemetry regression first failed against the append-only 16-entry
implementation (9 failures), then passed with deduplication. It checks identical
and uppercase-digest reloads, changed content/range/name, return to earlier
contents, unknown digests, truncated names, full-capacity behavior, counting
known identities after capacity is full, event ordering, and event reconciliation.
