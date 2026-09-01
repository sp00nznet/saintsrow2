# Progress Log — Saints Row 2 (BLUS30201)

## Phase overview

| Phase | Description | Status |
|---|---|---|
| 0. Recon | Locate the disc dump, confirm region/title | ✅ |
| 1. Extract | 7z → `PS3_GAME/USRDIR` | ✅ |
| 2. Decrypt | `EBOOT.BIN` (SELF) → `EBOOT.elf` | ✅ |
| 3. Analysis | ELF structure, entry, code bound | ✅ |
| 4. Find functions | OPD + prologue + leaf + call/branch passes | ✅ — 40,235 |
| 5. NID resolve | `lib.stub` tables → library/function names | ✅ — 17 libs, 247 funcs |
| 6. Coverage triage | NIDs vs. ps3recomp's HLE table | ✅ — 164/247 (66%) |
| 7. Lift | `ppu_lifter` → C++ | ✅ — 57,715 functions, 14 chunks |
| 8. HLE table | `gen_hle_nids --all` | ✅ — 1,056 handlers |
| 9. SPU extract | Embedded SPU ELFs out of the EBOOT | ✅ — 11 images |
| 10. Boot harness | CMake on the shared ps3recomp harness | ✅ written |
| 11. Build & link | clang-cl / Ninja | ✅ — `sr2.exe` links |
| 12. SPU lift | 11 images → C | ✅ — 7,995 functions, 13 MB |
| 13. First boot | Enter the recompiled CRT | ⏳ current |
| 14. Graphics | RSX → D3D12 | ⬜ |
| 15. Audio / input | cellAudio + cellPad | ⬜ |
| 16. Playable | | ⬜ |

## Detailed log

### 2026-09-01 — Kickoff: disc to lifted C++ in one session

**Phase 0-1 — Recon and extraction (COMPLETE)**

Input was a single 6.8 GB 7z of a USA disc dump (`Saints Row 2 (USA) (En,Fr)`).
Extracted to `disc/` — 29 files, 6.3 GB. `PARAM.SFO` confirms:

| | |
|---|---|
| `TITLE` | Saints Row 2 |
| `TITLE_ID` | `BLUS30201` |
| `CATEGORY` | `DG` (disc game) |
| `APP_VER` | 01.00 |
| `PS3_SYSTEM_VER` | 02.4100 |

The payload is 24 `.vpp_ps3` packfiles (Volition's package format) plus 11 Bink
videos. The two big ones dominate: `ps3_audio_sacks.vpp_ps3` at 3.2 GB and
`chunk_geom.vpp_ps3` at 1.9 GB — i.e. **80% of the disc is streamed audio and
world geometry**, which is data, not code. Good sign for a recomp.

**Phase 2 — Decrypt (COMPLETE)**

`EBOOT.BIN` is a retail SELF, SCE header version 2, plaintext ELF header at file
offset `0x90`. `rpcs3 --decrypt` handled it on the first attempt with no RAP or
klicensee needed → `game/EBOOT.elf`, 15,825,384 B.

**Phase 3 — ELF analysis (COMPLETE)**

```
ELF64, big-endian, machine 0x15 (PPC64), type ET_EXEC, osabi 0x66
entry   0xEC6A08
PT_LOAD 0x10000  filesz 0xE8E8C8  flags R-X   (text + rodata, shared segment)
PT_LOAD 0xEA0000 filesz 0x84C24   memsz 0x26AA088  (data + 38 MB BSS)
32 section headers, 8 program headers
```

The important number is **`0xCB0C2C`** — the end of the last `SHF_EXECINSTR`
section. Everything from there to `0xE8E8C8` is `.rodata` living in the *same*
R-X segment, which is the standard PS3 EBOOT layout and the thing that made the
You Don't Know Jack lift explode to 5.2 GB before that project added
`--code-end`. Applied here from the start.

**Phase 4 — Function discovery (COMPLETE)**

`find_functions.py` on the full binary:

```
opd scan:           12,799 descriptor code addresses
disassembled:       3,815,986 instructions
prologue pass:       9,180
leaf pass:          21,433
seed pass:          30,859   (+9,534 seeded, -108 slivers)
extent pass:        13,469 grown over basic blocks
call-target pass:   39,015   (+8,156 bl targets no other pass found)
branch-target pass: 40,574
overlap clipping:      727 ranges trimmed
```

Then clipped at `--code-end`: **339 of those starts were at `.rodata` addresses**
— exactly the failure mode above, caught before the lifter could quadratically
re-emit them. **40,235 functions** kept.

For scale: 40,235 functions from 12,799 OPD descriptors means roughly **3.1
functions per exported descriptor**, i.e. most of the binary is static/internal
code the descriptor table never mentions. That ratio matches the sibling ports.

**Phase 5 — Imports (COMPLETE)**

`prx_analyzer.py` and `gen_imports.py` agree: **17 libraries, 247 NIDs, 234 named
(94%)**. The 13 unnamed are unknowns in `sys_fs`/`sys_net`/`sysPrxForUser`.

| NIDs | Library | | NIDs | Library |
|---:|---|---|---:|---|
| 42 | `cellSpurs` | | 10 | `cellHttp` |
| 30 | `sceNp` | | 10 | `cellAudio` |
| 26 | `cellSysutil` | | 6 | `cellNetCtl` |
| 26 | `sysPrxForUser` | | 4 | `cellSync` |
| 23 | `sys_net` | | 3 | `cellSysmodule` |
| 21 | `sys_fs` | | 1 | `cellHttpUtil` |
| 18 | `cellGcmSys` | | 1 | `cellRtc` |
| 15 | `cellMic` | | 1 | `sceNp2` |
| 10 | `sys_io` | | | |

Two things stand out. First, **`cellSpurs` is the single largest import** at 42
functions — this title leans on the SPUs hard, which the 11 embedded SPU images
corroborate. Second, **there is no `cellSail`, no `cellAdec`, no `cellPamf`**:
the Bink videos are decoded by the engine's own RAD Game Tools code, not by
Sony's media libraries, so the FMV path is lifted rather than stubbed.

**Phase 6 — Coverage triage (COMPLETE)**

Cross-checked all 247 NIDs against the 1,056-handler table
`gen_hle_nids.py --all` produces from ps3recomp's 88 compiled modules:
**164 covered (66%)**, 83 missing:

| Missing | Library | Verdict |
|---:|---|---|
| 21 | `sys_net` | stub — offline |
| 15 | `sceNp` | stub — offline |
| 14 | `sysPrxForUser` | **must implement** — CRT/TLS/threads, boot-critical |
| 11 | `cellSpurs` | **must implement** — SPU dispatch |
| 7 | `sys_fs` | **must implement** — packfile loading |
| 5 | `cellMic` | stub — voice chat |
| 3 | `cellGcmSys` | **must implement** — RSX |
| 2 | `cellHttp`, 2 `cellSysutil`, 1 each `sys_io`/`cellAudio`/`sceNp2` | mixed |

So the real work is **~38 boot-critical NIDs**, not 83. Everything else is
online plumbing an offline port never calls.

**Phase 7 — Lift (COMPLETE)**

```
ppu_lifter.py game/EBOOT.elf \
    --functions analysis/functions.json \
    --code-end 0xCB0C2C \
    --hle-stubs imports.json \
    -o src/recomp
```

**57,715 functions lifted, 25,980 unique call targets, 14 chunks, 611 MB, 84
seconds.** The 57,715 is 40,235 detected plus jump-table cases and mid-function
tail-entry wrappers.

`--hle-stubs` rewrote all 247 import trampolines into `ps3_hle_call(nid)` up
front, so the `0x39800000` wall (a direct `bl` running the literal stub whose
pointer table the recomp never fills) never gets built in the first place.

Chunk sizes are lopsided — `ppu_recomp_001.cpp` alone is 145 MB against ~36 MB
for most others — which is the next thing to watch when the build starts.

**Phases 8-9 — HLE table and SPU images (COMPLETE)**

`gen_hle_nids.py --all` → 1,056 handlers across 88 modules.

`extract_spu_images.py` found **11 embedded SPU ELFs, 702,544 B total**,
clustered at the end of the code segment (`0x00D8A180`–`0x00E8E180`):

| # | Offset | Size |
|---|---|---|
| 0 | `0x00D8A180` | 27,044 |
| 1 | `0x00D90B80` | 73,112 |
| 2 | `0x00DDFB00` | 160,456 |
| 3 | `0x00E14000` | 143,700 |
| 4 | `0x00E37180` | 132,164 |
| 5 | `0x00E57600` | 89,752 |
| 6 | `0x00E6D500` | 60,388 |
| 7 | `0x00E8A980` | 8,860 |
| 8 | `0x00E8CC80` | 1,900 |
| 9 | `0x00E8D400` | 3,416 |
| 10 | `0x00E8E180` | 1,752 |

These are real SPU ELFs in the binary, so they lift directly — no `SPU_DUMP_MISS`
runtime capture like the Simpsons port needed.

**Phase 10 — Boot harness (WRITTEN)**

`CMakeLists.txt` on the shared ps3recomp harness: `boot_main.cpp` +
`ppu_loader` + `ppu_hle` + `ppu_sysprx` + `ppu_fs`, linked against the prebuilt
`ps3recomp_runtime.lib`, with the lifted tree and generated NID table globbed in.
Nothing title-specific. `tools/relift.sh` regenerates every git-ignored artifact
from a decrypted EBOOT in one command.

**Phase 11 — Build (COMPLETE, then re-done properly)**

The first build **linked on the first attempt** — `sr2.exe`, 126 MB, 21 objects,
zero errors, only `-Wparentheses-equality` noise from the lifter's `bdnz`
idiom. For a 611 MB generated tree that has never been pointed at this title
before, that is not the normal outcome and it was worth being suspicious of.

**War story: the object files that were too small.**

Two objects did not fit:

| chunk | source | object |
|---|---:|---:|
| `ppu_recomp_001` | 145 MB | **34 KB** |
| `ppu_recomp_003` | 63 MB | **6 KB** |
| (every other chunk) | ~36 MB | ~21 MB |

145 MB of C++ does not compile to 34 KB. Counting function definitions
explained it: **chunk 001 contained exactly one function**, `func_000BBE60`,
spanning 2,331,612 lines. The function list said `func_000BBE60` is **156
bytes**. The lifter had emitted it as an 8.6 MB body running from `0x000BBE60`
all the way to `0x00924EE8` — swallowing **21,812 other function starts**, i.e.
two thirds of the entire text segment, into one function. clang then dead-code
eliminated nearly all of it, because none of those blocks were reachable from
the entry, and produced a 34 KB object. It compiled, it linked, and it was
silently wrong.

Root cause, in `ppu_lifter.py`'s jump-table pass: when a `bctr` dispatcher lives
inside a known function, the lifter **extends that function to cover all its
switch cases**, because the cases share an epilogue past the function's first
`blr`. The extension bound is the next function start after `max(cases)`, and
the code comment asserts this "never swallows a following function." It does,
the moment **one case target is a misread table entry**. A single garbage word
that decoded as a case address megabytes downstream dragged the enclosing
function's end with it, and everything in between became interior labels.

Fix (one condition, in the shared toolkit): a switch's cases live inside the
dispatcher's own body, so ignore case targets farther from the dispatcher than
`_MAX_MID_TAIL` (0x6000) when computing the extension — the same span cap the
mid-function tail-entry pass already uses for exactly this class of misread.

Re-lifted with the cap:

| | before | after |
|---|---:|---:|
| Generated source | 611 MB | **416 MB** |
| Chunks | 14 | **11** |
| Functions emitted | 57,715 | **57,745** |
| Lift time | 84 s | **45 s** |
| Largest single function | 2,331,612 lines | **57,761 lines** |
| Functions in the smallest-object chunk | 1 | 103 |

195 MB of source vanished, 30 *more* functions came out (the ones that had been
swallowed now get their own bodies), and the per-chunk function counts flattened
into the 3,000–10,000 range instead of 1.

The remaining shape is expected, not a second bug: chunks 009 and 010 hold few
functions for their size because they are full of ~6,300-line mid-function
tail-entry wrappers into the region around `0xBF2xxx`, each re-emitting its tail
up to the same 0x6000 cap. That duplication is how this lifter handles interior
entry points by design.

**Phase 12 — SPU lift (COMPLETE)**

All 11 embedded images lifted directly from the EBOOT — no runtime capture:

| image | functions | coverage |
|---|---:|---:|
| spu0000 | 345 | 97.1% |
| spu0001 | 836 | 97.3% |
| spu0002 | 1,861 | 93.0% |
| spu0003 | 1,707 | 98.0% |
| spu0004 | 1,475 | 97.6% |
| spu0005 | 853 | 96.5% |
| spu0006 | 777 | 93.2% |
| spu0007 | 79 | 97.4% |
| spu0008 | 16 | 95.5% |
| spu0009 | 37 | 95.1% |
| spu0010 | 9 | 98.5% |

**7,995 SPU functions, 13 MB of C.** Coverage is 93–98% of each `.text`; the
remainder is data and padding embedded in the code section. 3,429 instructions
across the set still lift to `.word` (undecoded SPU opcodes) — those will need
opcode work in `spu_lifter.py` before the affected jobs can actually run.

They compile and link into the executable, but they are **not registered with
the runtime's fingerprint registry yet**, so nothing dispatches to them. That is
the next SPU task.

### Next

1. First boot: run `sr2.exe` against the real EBOOT and see how far the CRT gets.
2. Register the 11 SPU images by fingerprint so `cellSpurs` can dispatch to them.
3. Expect the ~38 boot-critical missing NIDs (`sysPrxForUser` 14, `cellSpurs` 11,
   `sys_fs` 7, `cellGcmSys` 3) to surface roughly in that order.
4. Work through the 3,429 undecoded SPU `.word` instructions.
