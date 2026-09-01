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

**Phase 13 — First boot (REACHED)**

The first run walked straight into the classic `0x39800000` wall:

```
[ppu] bctr to NULL from func_0003B728+0x7C5A r12(opd)=0x00CB0A6C
      opd[0]=0x39800000 -- returning with r3 untouched
```

`0x39800000` is not an address, it is the instruction `li r12,0` — the first
word of every import trampoline. **Every one of the 247 entries in
`imports.json` had that same value in its `stub` field**, so `--hle-stubs` had
no addresses to match and rewrote nothing; all 247 imports kept their literal
trampolines, which dereference an import pointer table the recompilation never
fills. Cause was not in this repo: `gen_imports.py` in the shared checkout was
fixed four minutes *after* the file was generated, and the stale output had been
carried forward. Regenerated → 247 distinct trampoline addresses, all 247 lift
to `ps3_hle_call(nid)`, 57,745 → **57,762 functions** (the stub split adds 17).

Second run, with `PS3_VFS_ROOT` corrected to the disc root (it had been pointed
at `PS3_GAME/USRDIR`, so `cellGame` could not find `PARAM.SFO` one level up and
fell back to title id `BLES00000`):

```
[cellGame] title id from PARAM.SFO: 'BLUS30201'
[crt] sys_initialize_tls: block 0x0E000000, r13=0x0E007000

*** Saints Row 2 for PLAYSTATION 3 Start ***
Total PS3 Memory: 256.00MB  Available: 192.00MB  Used: 64.00MB

[cellSysmodule] LoadModule(id=0x000E 'CELL_SYSMODULE_FS')
Executable = "/dev_bdvd/PS3_GAME/USRDIR/EBOOT.BIN"
gAppHome   = "/dev_bdvd/PS3_GAME/USRDIR"
[HLE] _cellGcmInitBody(cmdSize=0x200000, ioSize=0x8D00000, ioAddr=0x40000000)
RSXLocal:256MB (0xc0000000-cfffffff), GCM DL:2048KB, RSXHost:141MB
[cellVideoOut] GetResolution(id=2) -> 1280x720
[cellVideoOut] Configure: resId=2, format=0, aspect=0, pitch=5120
[fs] open '/dev_bdvd/PS3_GAME/USRDIR/packfiles/ps3/shaders.vpp_ps3' -> fd 3
[fs] open '/dev_bdvd/PS3_GAME/USRDIR/packfiles/ps3/startup.vpp_ps3' -> fd 3
```

**The title's own startup banner, its own memory accounting, its own RSX and
video-out configuration, and its own packfiles being opened and read.** That is
the engine running, not the harness. It then builds its SPU side — 17 event
flags initialised and attached to LV2 event queues, 5 `cellSpursCreateTask`
calls, 2 `RunJobChain` chains — and stops:

```
[spu_workload] async dispatch MISS fp=0x22189973609C767C size=27044
[cellSpurs] EventFlagWait BLOCKED tid=11972 24s on pattern 0x0003
            -- waiting for an SPU workload to cellSpursEventFlagSet it
```

`size=27044` is **exactly** the size of extracted SPU image #0
(`spu_0000_at_00D8A180.elf`). The lifted code was in the executable; it simply
was not registered, so `cellSpurs` could not find it, so nothing ever set the
event flag the main thread waits on.

**Phase 12 redone — SPU workload registry**

Replaced the hand-rolled per-image lift loop with the toolkit's own
`build_spu_workloads.py`, which lifts each image under its own C symbol prefix
(all 11 otherwise define `spu_func_*` and `spu_recomp_register` and collide at
link) and emits the registry mapping each image's FNV-1a-64 content fingerprint
to its lifted entry, plus a constructor that registers them at startup.

The generated fingerprint for image #0 is `0x22189973609C767C` — a byte-exact
match for the one the dispatcher reported as a MISS.

| image | fingerprint | entry |
|---|---|---|
| spu_0000 | `0x22189973609C767C` | `spu_func_00003078` |
| spu_0001 | `0xBC6E4A2AF9D88C1C` | `spu_func_00003078` |
| spu_0002 | `0x529E8F5BE2425919` | `spu_func_00003080` |
| spu_0003 | `0x776A04B99AA4F916` | `spu_func_00003080` |
| spu_0004 | `0x10A9679DE2147722` | `spu_func_00003080` |
| spu_0005 | `0xB343E631610AECAF` | `spu_func_00003080` |
| spu_0006 | `0xDCB331A33665F929` | `spu_func_00000100` |
| spu_0007 | `0x541F122A9F1541DC` | `spu_func_00000098` |
| spu_0008 | `0x682F681FADF7EBC5` | `spu_func_00000090` |
| spu_0009 | `0x06CACFC7EF7D422A` | `spu_func_00000090` |
| spu_0010 | `0xAFE45A90ED0E2128` | `spu_func_00000090` |

**Phase 12 verified — the SPU side runs**

The runtime-built job was captured in the same run that reported it missing
(`SPU_DUMP_MISS=spu_dump` → `spujob_4333827302318B21_201984.bin`), lifted at
base 0 under the `spujob_` prefix, and registered by hand in
`src/spu_workloads.c` as image 12. With both registries linked in, the block
clears on the first attempt:

```
[spu_workload] dispatch HIT (async) fp=0x22189973609C767C image=1 -> spawning thread
[spurs-job]    dispatch HIT fp=0x4333827302318B21 image=12 job=0x4057C000
[spurs-job]    job 0x4057C000 RETURNED rc=0
[cellSpurs]    chain 0x4059D280: END after 16 job(s)
[cellSpurs]    EventFlagWait WAKE tid=16744 flagEA=0x0350CF80 pattern=0x0003 got=0x0001
```

**32 SPU jobs dispatched and returned `rc=0` across 4 job chains** (of 16, 8, 2
and 1 jobs), producing **16 event-flag wakes** — the exact flag the main thread
had been parked on for 24 s in the previous run. 28 file reads follow, so the
PPU side is consuming what the SPU side produced. Recompiled Cell SPU code is
running and feeding recompiled PPU code.

**Phase 13 — new frontier: cellSpurs tasksets**

Boot now advances past job dispatch into taskset construction and stops there:

```
[cellSpurs] _TasksetAttributeInitialize(rev=1)
[cellSpurs] CreateTaskset() ea=0x032B0F80 spurs=0x03467A80 (real BE layout)
[cellSpurs] _QueueInitialize(taskset=0x032B0F80 q=0x032B2980 buf=0x032B2A00
                             size=16 depth=512 dir=2)
[hle] unresolved NID 0x9034E538

[CRASH] code=0x80000003 rip=00007FF761647D32
[CRASH] last HLE NID 0x9034E538 (_cellSpursQueueInitialize)
[CRASH] guest ctr=0x00000000 lr=0x009F589C r3=0x00000000
```

`0x80000003` is the runtime's unimplemented-NID trap, not a lifter fault: the
title calls `_cellSpursQueueInitialize`, gets no handler, and the guest is left
with `ctr=0` to call through. This is the `cellSpurs` gap the Phase 6 triage
predicted, arriving on schedule.

Six NIDs went unresolved during this boot:

| NID | Known as |
|---|---|
| `0x9034E538` | `_cellSpursQueueInitialize` — **the crash** |
| `0x8F122EF8` | cellSpurs, taskset attribute path |
| `0xE5443BE7` | cellSpurs, queue path |
| `0x7CB33C2E` | unnamed in the NID database |
| `0x011EE38B` | — |
| `0x1656D49F` | — |

Implementing them means editing `libs/spurs/cellSpurs.c` in the **shared**
ps3recomp checkout, which flOw, Simpsons, Twisted Metal and You Don't Know Jack
all build against. Left for a deliberate decision rather than done in passing.

### Known gaps at this point

- **`cellSpurs` queue/taskset NIDs** — the crash above. Six unresolved, and they
  live in the shared runtime rather than in this repo.
- **Only 12.2% of the captured job image decodes as code** (24,724 of 201,984
  bytes). That is expected for a SPURS job *chain* image — most of it is the
  command list and staged data, not instructions — but it means the 509 lifted
  functions are only the visible part, and a job whose real body sits in the
  data region will not have been lifted.
- **`Sony titleId = - , parentalLevel=0`** — `cellSysutil`'s
  `DiscGameGetBootDiscInfo()` returns an empty disc id. Harmless so far.
- **3,429 undecoded SPU `.word` instructions** across the 11 embedded images
  (plus 151 in the captured job); whichever land on a hot path will need opcode
  work in `spu_lifter.py`.

### Next

1. Implement the six unresolved `cellSpurs` NIDs — `_cellSpursQueueInitialize`
   first, since it is the one that crashes. Shared-runtime change; needs a call
   on whether to touch `libs/spurs/cellSpurs.c` for four other ports.
2. `RSX_LIVE_DRAW=1` for a first picture. The SPU side no longer blocks, so the
   renderer is reachable as soon as boot clears the taskset path.
3. Work through the undecoded SPU `.word` instructions as they surface.
4. Fill in `DiscGameGetBootDiscInfo()` before anything starts checking it.
