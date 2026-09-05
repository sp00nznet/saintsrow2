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
| 13. First boot | Enter the recompiled CRT | ✅ — title banner, GCM, video out |
| 14. cellSpurs NIDs | 6 missing handlers implemented | ✅ — 0 unresolved, no crash |
| 15. Task attribute ABI | descriptor form (`SPURS_TASKATTR_DESC`) | ✅ — fields were garbage |
| 16. SPURS queue init | real BE `CellSyncLFQueue` lines in guest memory | ✅ |
| 17. SPURS queue push | `cellSpursQueuePushBody` pointer protocol | ⏳ current — the last gate |
| 18. Graphics | RSX → D3D12 | 🟡 window + 3 display buffers, 0 packets |
| 19. Audio / input | cellAudio + cellPad | ⬜ |
| 20. Playable | | ⬜ |

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

**Phase 14 — the six cellSpurs NIDs, identified rather than guessed**

ps3recomp computes each HLE NID **from the handler's own name** with the
firmware hash, so a handler is only reachable if it is named exactly right.
That turns naming into something checkable: `compute_nid(name)` either equals
the NID the title imports, or it does not. Five of the six fell out immediately:

| NID | Name | `compute_nid` |
|---|---|---|
| `0x9034E538` | `cellSpursTaskGetContextSaveAreaSize` | ✅ matches |
| `0x8F122EF8` | `cellSpursTasksetAttributeSetTasksetSize` | ✅ matches |
| `0xE5443BE7` | `cellSpursQueueAttachLv2EventQueue` | ✅ matches |
| `0x011EE38B` | `_cellSpursLFQueueInitialize` | ✅ matches |
| `0x1656D49F` | `cellSpursLFQueueAttachLv2EventQueue` | ✅ matches |
| `0x7CB33C2E` | **`cellSpursTaskGetReadOnlyAreaPattern`** | ✅ found by search |

The sixth was in no name table we had. Rather than guess, every `cellSpurs*`
identifier in RPCS3's module source was hashed and compared — exactly one name
out of 142 produced `0x7CB33C2E`. (RPCS3 is GPL and ps3recomp is MIT, so it was
used only to confirm names and argument counts — facts about Sony's interface —
and every implementation here is written from scratch.)

> **The crash line was lying.** It reported
> `last HLE NID 0x9034E538 (_cellSpursQueueInitialize)`, which sent the first
> look at the wrong function entirely: `_cellSpursQueueInitialize` is NID
> `0x082BFB09` and has been implemented since LBP. The printout pairs an
> unresolved NID number with the last *named* handler it saw.

**The ABI came off the call site, not from a header.** `func_009F56E0` builds
every taskset, and its import calls annotate themselves once the stub addresses
are mapped back through `imports.json`:

```
009F5750  _cellSpursTasksetAttributeInitialize
009F5760  cellSpursTasksetAttributeSetName
009F5770  cellSpursTasksetAttributeSetTasksetSize      <- was missing
009F578C  cellSpursCreateTasksetWithAttribute
009F583C  _cellSpursQueueInitialize
009F5848  cellSpursQueueAttachLv2EventQueue            <- was missing
009F5864  cellSpursTaskGetReadOnlyAreaPattern          <- was missing
009F5898  cellSpursTaskGetContextSaveAreaSize          <- was missing (the crash)
009F58F4  _cellSpursTaskAttributeInitialize
```

For the context-save call the registers settle the signature outright:

```
009F5744:  addi  r25, r1, 144      ; r25 = sp+0x90
...
009F5878:  addi  r3, r1, 112       ; r3  = sp+0x70   -> u32* size_out
009F587C:  or    r4, r25, r25      ; r4  = sp+0x90   -> the LS pattern
009F5888:  andc  r9, r10, r9       ; pattern = default & ~readOnly
009F5894:  std   r0, 0x90(r1)      ;   ...built right here, into sp+0x90
009F5898:  bl    cellSpursTaskGetContextSaveAreaSize
009F58A0:  lwz   r11, 0x70(r1)     ; read the size back out of r3
009F58AC:  subf  r0, r11, r0       ; r0 = 0x2D400 - size
009F58B4:  blt   cr7, 0x9F5960     ; too big -> bail
009F58EC:  stw   r11, 0x84(r1)     ; else store size next to the pattern ptr
```

So `cellSpursTaskGetContextSaveAreaSize(u32* size_out, const LsPattern*)`, and
the caller masks the *read-only* blocks out first because those can be reloaded
from the ELF instead of saved. Local store is 256 KB across a 128-bit pattern,
so one bit is 2 KB; the save area is the register file plus every block the task
may dirty.

`cellSpursTaskGetReadOnlyAreaPattern` is implemented for real rather than
stubbed: it parses the SPU ELF the title hands it and marks the blocks covered
by non-writable `PT_LOAD` segments. The runtime already walks SPU program
headers for `spu_elf_load_to_ls`, so this reuses that shape. It works on the
title's actual images — `elf=0x00D9A180` in the log is extracted image #0 at its
guest address, and `0x00DA0B80` is image #1:

```
[cellSpurs] TaskGetReadOnlyAreaPattern(elf=0x00D9A180) -> 03FFC00000000000 0000000000000000
[cellSpurs] TaskGetReadOnlyAreaPattern(elf=0x00DA0B80) -> 03FFFFFFFF800000 0000000000000000
[cellSpurs] TaskGetContextSaveAreaSize(ls=00000000007FFFFF FFFFFFFFFFFFFFFF, 87 blocks) -> 180224 (0x2C000)
[cellSpurs] TasksetAttributeSetTasksetSize(size=10496)
[cellSpurs] QueueAttachLv2EventQueue(q=0x032B2980)
[cellSpurs] _LFQueueInitialize(owner=0x4059D400 q=0x4059FD00 buf=0x4059FD80 size=32 depth=512 dir=3)
```

**Result: zero unresolved NIDs, zero crashes.** Boot now clears taskset and
queue construction and goes on to bind **15 RSX tiled surfaces**
(`cellGcmSetTile` + `cellGcmBindTile`) — render-target setup — while running 29
more SPU jobs and 13 event-flag wakes.

**Phase 15 — new frontier: SPU task scheduling**

```
[spu_workload] task 3 (taskset 0x4059D400) sleeping 6s in WAIT_SIGNAL
[HOTREAD] spinning on 0x032B0F10 (=0x40A40000) guest cia=0x00000000 lr=0x00A1A4EC
```

16 tasks are parked in `WAIT_SIGNAL` and the PPU spins on a word inside the
taskset at `0x032B0F10` waiting for one of them to move it. Nothing is missing
or unimplemented now — this is the SPURS task *scheduler* handshake, the same
class of problem the existing runtime comments describe for other titles.

**Phase 15 — localising the WAIT_SIGNAL park**

Three experiments, in increasing order of what they proved.

**1. `LBP_WS_DRAIN=2` — confirmed the deadlock class for free.** The runtime
already carries an opt-in escape that resumes a task parked with no signal.
Turning it on:

| | baseline | `WS_DRAIN=2` |
|---|---:|---:|
| SPU jobs returning `rc=0` | 30 | **46** |
| Ring-buffer spins (`HOTREAD`) | 4 | **0** |

The PPU's producer spin cleared completely, which proves the parked consumers
were what stalled it. But it converts a deadlock into a **livelock**: task 5
enters `WAIT_SIGNAL` 90 times, each time resuming, doing `ran=0ms` of work, and
re-parking. Waking the task is not enough — it has nothing to consume.

**2. `RSX_LIVE_DRAW=1` — the renderer is ready and waiting.**

```
[rsx] backend init OK -- window open
[rsx] live-draw engine up (D3D12); GDI present suppressed
[live-draw] display buffer 0 = loc0:0x00AE0000 pitch=5120 1280x720
[live-draw] display buffer 1 = loc0:0x00000000 pitch=5120 1280x720
[live-draw] display buffer 2 = loc0:0x00384000 pitch=5120 1280x720
[live-draw] frame 1 packets[seen=0 queued=0] ...
```

A D3D12 window opens and the title registers **three 1280x720 display buffers**
— but `packets[seen=0]`. The renderer is not the blocker; it is downstream of
the SPU pipeline and simply never gets a command stream.

**3. The task attribute ABI was wrong for this title — and that was a real bug.**

The task-creation log was carrying nonsense in plain sight:

```
_cellSpursTaskAttributeInitialize(eaElf=0x00D9A180 ctx=0x0FEFF078
                                  szctx=267382952 lsp=0x00000000 arg=0x0FEFF0A8)
```

`szctx=267382952` is `0x0FEFF0A8` — a **stack address**, not a size — and
`lsPattern` is null. The runtime's own comments state that a task with a
zero/garbage argument or an lsPattern that does not cover its stack is refused
by the SPU task library and parks in `WAIT_SIGNAL` forever. That is precisely
the symptom.

The cause is a third caller shape. `_cellSpursTaskAttributeInitialize` is
normally read as eight arguments with `eaContext`/`sizeContext`/`lsPattern` in
r7/r8/r9. Saints Row 2 passes a **descriptor** instead:

```
009F58D0  addi r7, r1, 128     ; r7 = sp+0x80 -> descriptor
009F58D4  addi r8, r1, 176     ; r8 = sp+0xB0 -> CellSpursTaskArgument
009F58E8  stw  r9,  0x80(r1)   ;   [0] context EA
009F58EC  stw  r11, 0x84(r1)   ;   [1] context size (from GetContextSaveAreaSize)
009F58F0  stw  r25, 0x88(r1)   ;   [2] CellSpursTaskLsPattern*
```

So r8 — read as `sizeContext` — is the argument pointer, and r9 was never
written at all. Added as `SPURS_TASKATTR_DESC=1`, **off by default** so the
existing R8-form stays right for You Don't Know Jack and Jackbox. With it on,
every field is real for the first time:

```
TaskAttr DESC-form: desc=0x0FEFF078 -> ctx=0x405A3D80 size=227328
                    lsp=0x0FEFF098 arg=0x0FEFF0A8
```

`ctx` is a genuine buffer in the title's IO allocation, `size` a genuine size,
and `lsp` a genuine pattern pointer where it had been null. SPU jobs completing
went 30 → 45 and ring spins 4 → 2.

> This also retires the previous entry's worry about the 227,328-byte context
> save area: the title accepts that value here and builds the attribute with it,
> so the `0x2D400` comparison seen earlier guards a different path. The size
> computed by our `cellSpursTaskGetContextSaveAreaSize` is being used as-is.

**The remaining gate, stated precisely.** Tasks are now created correctly and
still park immediately, because nothing ever signals them:

```
QueuePushBody calls in a boot: 9
cellSpursSendSignal calls:     0
```

The title pushes work into a SPURS queue and expects the SPURS kernel to wake
the task blocked on that taskset. `cellSpursQueuePushBody` is a logging stub
that writes nothing and wakes nobody, so the consumer has neither data nor a
signal. The wake primitive already exists — `cellSpursSendSignal` sets the
`CSTS_SIGNALLED` bitset the `WAIT_SIGNAL` handler blocks on — so the wake half
is a small change. The data half needs the real `CellSpursQueue` ring layout,
which is **not** in RPCS3 (unimplemented there too) and is read on the SPU side
by Sony's own library code compiled into the title's SPU image. Guessing that
layout would write garbage into guest memory that recompiled SPU code then
consumes, so it needs to be recovered from the SPU image rather than invented.

**Phase 16 — reading the consumer, and making the queues real**

The way to stop guessing about the queue was to read the consumer. Task 5 runs
SPU image 1 and calls `WAIT_SIGNAL` from LS `0x12B80`; disassembling around
there shows exactly how it talks to the PPU:

```
00012AE4  il    $r63, 128
00012AE8  wrch  MFC_LSA,  $r63        ; local store 0x80
00012AF0  wrch  MFC_EAH,  $r65
00012AF8  wrch  MFC_EAL,  $r64        ; ...against a main-memory EA
00012AFC  wrch  MFC_Size, $r63        ; 128 bytes
00012B0C  wrch  MFC_Cmd,  $r12        ; 0xB4 = PUTLLC
00012B10  rdch  $r11, MFC_RdAtomicStat
00012B14  brnz  $r11, 0x128B8         ; contended -> retry
```

A **GETLLAR/PUTLLC lock-line atomic on a 128-byte line in main memory.** So the
bytes in guest memory *are* the interface between the recompiled PPU code and
the recompiled SPU code, and they have to be the genuine big-endian
`CellSyncLFQueue` line:

```
0x00 pop1   0x10 size   0x18 buffer(u64)  0x24 direction  0x2C init   0x70 eaSignal
0x08 push1  0x14 depth  0x20 bs[4]        0x28 v1         0x30 push2  0x50 pop2
```

Two independent checks that this is the right structure: the title passes
`q=0x4059FD00` with `buffer=0x4059FD80`, and `q=0x032B2980` with
`buffer=0x032B2A00` — **both exactly 0x80 apart**, a buffer starting right after
a 128-byte header.

> **A trap worth recording.** `libs/sync/cellSync.c` already has a
> `CellSyncLFQueue` and delegating to it looks like the obvious lazy win. It is
> the wrong move: that one is a **host-native** struct — `atomic_uint` fields and
> a 64-bit host `buffer` pointer. It is perfectly fine for a queue whose both
> ends are HLE, and actively harmful here, because writing it into guest memory
> hands recompiled SPU code a host pointer where a 32-bit big-endian EA belongs.
> Reusing it would have been worse than the no-op stub it replaced.

So `_cellSpursLFQueueInitialize` and `_cellSpursQueueInitialize` were both
rewritten to build the real line: zero the 128 bytes, then set `size`, `depth`,
`buffer`, `direction`, the `init` flag and `eaSignal`, and clear the element
buffer. Only fields the arguments determine outright — the `bs[]`/`v1` slot
state machine is left zero rather than invented.

**Phase 17 — the probe that says what is left**

With both queues properly initialised, `LBP_WS_DRAIN=2` was used again purely as
a *probe*: force the parked tasks awake and see whether they now do work against
a valid queue.

```
66 wakes, every single one ran=0ms
```

That is the answer, and it is a clean negative result. The tasks are not stuck
on corruption any more and they are not failing to wake — **they park because
the queue is genuinely empty**, and they are right to. Across the session:

| run | SPU jobs `rc=0` | ring spins | queue pushes |
|---|---:|---:|---:|
| six NIDs implemented | 30 | 4 | 9 |
| + `SPURS_TASKATTR_DESC` | 45 | 3 | 9 |
| + real LFQueue line | 53 | 4 | 9 |
| + real Queue line | 46 | 2 | 9 |

(Job counts vary run to run — these are timing-dependent, not a clean monotonic
climb — but the direction is consistent and no run crashes.)

The `9` never moves, and that column is the whole story:
`cellSpursQueuePushBody` is still a logging stub. The producer says "pushed"
nine times and writes nothing, so the consumer correctly finds nothing.

**Phase 18 — reading the protocol off the running SPU**

Static register-tracing through SPU code was going slowly, so the protocol was
recovered *empirically* instead. The runtime already has `SPU_ATOM_EA=<hex>`,
which filters every SPU atomic to one 128-byte line and dumps the line before
and after each one. Pointing it at each queue in turn gives the transitions
directly, with no guesswork.

**Result 1 — the initialiser is verified correct.** Two different SPU routines,
on two different queues, read back exactly the fields written in Phase 16:

| | LFQueue `0x4059FD00` | SpursQueue `0x032B2980` |
|---|---|---|
| `+0x10` size | `0x20` (32) | `0x10` (16) |
| `+0x14` depth | `0x200` (512) | `0x200` (512) |
| `+0x18/1C` buffer | `0x4059FD80` | `0x032B2A00` |
| `+0x24` direction | 3 (ANY2ANY) | 2 (PPU2SPU) |
| `+0x2C` init | 1 | 1 |

That is no longer an assumed layout — recompiled SPU code is reading those exact
offsets and behaving coherently on them.

**Result 2 — the pop-waiter protocol, from five real transitions.** On the
LFQueue, five consumer tasks each ran one GETLLAR/PUTLLC pair
(`pc=0x07D4C` → `0x080C8`). Diffing before/after:

| # | `u16 @ +0x04` (`pop1.m_h3`) | other write |
|---|---|---|
| 1 | 0 → 1 | — (wrote `hs1[0]=0`, already zero) |
| 2 | 1 → 2 | `u16 @ +0x34` (`m_hs1[1]`) = **2** |
| 3 | 2 → 3 | `u16 @ +0x36` (`m_hs1[2]`) = **1** |
| 4 | 3 → 4 | `u16 @ +0x38` (`m_hs1[3]`) = **3** |
| 5 | 4 → 5 | `u16 @ +0x3A` (`m_hs1[4]`) = **4** |

Operation *N* sets `m_h3 = N` and writes `m_hs1[N-1]`. The recorded values are
`0, 2, 1, 3, 4` — the five task ids, in the order they blocked. So:

- **`pop1.m_h3` (`+0x04`) is the count of blocked consumers**, and
- **`m_hs1[]` (from `+0x32`, one u16 each) is the queue of their task ids.**

Each consumer takes a ticket and parks its id in the slot that ticket names.
That is exactly the structure a producer needs in order to know *who* to wake.

**Result 3 — the consumer on the pushed-to queue is identified.** All 8
`cellSpursQueuePushBody` calls target `0x032B2980`, and the only SPU code that
touches that line is image 2 (task 5) at `pc=0x128B8` (GETLLAR) → `0x12AA0`
(PUTLLC), called from `lr=0x12390`. Its single mutation before parking:

```
+0x20: 00000000 -> 01050000      (m_bs[0]=0x01, m_bs[1]=0x05)
```

`m_bs[]` was deliberately left zeroed by the initialiser, and the consumer
populates it itself — so leaving it alone was the right call.

**Phase 19 — decoding the pop routine's empty-queue path**

With the routine bounded (`0x128B8`-`0x12AA0`, image 2, task 5), its
empty-queue branch at `0x12A44` decodes cleanly. Stripped of the SPU's
branchless `selb`/`ceq` padding, it does this:

```
lqa     $r7,  0xA0        ; LS 0xA0 = queue+0x20   (line was DMA'd to LS 0x80)
rotqbyi $r4,  $r7, 13     ; byte at queue+0x2D  -> cursor n
clgtbi  $r47, $r4, 14     ; n > 14 ?
brhnz   $r46, 0x12C2C     ;   -> error path
ahi     $r61, $r4, 1      ; n+1
cbd     $r57, $r1, 0      ; mask: insert a byte at position 0
andi    $r60, $r61, 255
cbx     $r54, $r1, $r60   ; mask: insert a byte at position (n+1)&15
shufb   $r53, $r61, $r7,  $r57   ; queue+0x20[0]       = n+1
shufb   $r51, $r88, $r53, $r54   ; queue+0x20[(n+1)&15] = r88
stqa    $r51, 0xA0        ; write the group back
...                       ; the same again for the group at queue+0x40,
stqa    $r2,  0xC0        ;   whose cursor byte is queue+0x4D
```

`cbd`/`cbx` build byte-insertion masks and `shufb` applies them, so this is
two single-byte writes into the 16-byte group at `queue+0x20`. Checked against
the observed transition, it matches exactly: the cursor byte started at 0, so
`n+1 = 1` went into byte 0 and `r88` went into byte 1 —

```
+0x20: 00000000 -> 01050000
```

and the runtime trace shows `r88 = 5`, which is **task 5, the consumer that was
registering itself**. So each 16-byte group is a small waiter ring:

| byte | meaning |
|---|---|
| `[0]` | count / head |
| `[1..12]` | waiter ids |
| `[13]` | cursor (`queue+0x2D`, `queue+0x4D`) |

with the `n > 14` guard bounding it to the group. (The parallel group at
`queue+0x40` is written by the same routine; it did not show up in the diff
only because `SPU_ATOM_FULL` dumps the first 64 bytes.)

**This is the wake list a producer needs.** A PPU push can now read
`queue+0x20` to find which task ids are blocked on this queue, and drive
`CSTS_SIGNALLED` for them.

**Phase 20 — a push probe, and what the consumer did with it**

The data half was never going to fall out of static reading, so it was probed
instead. `cellSpursQueuePushBody` got a deliberately *self-revealing*
implementation behind `SPURS_QUEUE_PUSH=1` (off by default): push into a
candidate slot, wake any registered waiter, log everything — on the theory that
the consumer's own DMA would name the correct slot whether or not the guess was
right. It did better than that.

**The producer came unstuck.** The title had pushed exactly 8 times and stopped
in every previous run. With the probe it pushes **12 and keeps going**, and the
PPU ring spin drops from 2 to 1. Something downstream of the push was gating the
producer, and it no longer is.

**`+0x0C` is a fill count, not an index.** The first run caught the consumer
doing this:

```
PUTLLC pc=0x12D2C   +0x0C: 00020000 -> 00010000     (u16: 2 -> 1)
```

The probe had pushed twice and incremented `+0x0C` twice; the consumer
**decremented it**. So `+0x0C` counts elements currently queued, and the
consumer really is consuming what the probe enqueues. That is the first
observed push/pop interaction in this port.

**`+0x00` is a synchronisation word, and the producer is meant to be in it.**
With the probe running, the atomics settle into a perfectly regular ping-pong
between two call sites in the same image:

| pc | transition |
|---|---|
| `0x12AA0` (wait side) | `0 → -1`, `1 → -2`, `2 → -3`, `3 → -4` |
| `0x12D2C` (signal side) | `-1 → 1`, `-2 → 2`, `-3 → 3` |

Negative magnitude reads as "N consumers waiting", positive as "N items
available" — a counting handshake. It never terminates because the probe never
touches `+0x00`: on hardware the *producer* is the other party. That is the next
concrete thing to implement.

**A mistake of mine, caught by the same trace.** One transition read:

```
PUTLLC pc=0x12AA0   +0x24: 00000002 -> 00000200 ; +0x2C: 00000001 -> 00000100
```

Both values moved up by exactly one byte — the signature of the
`shlqbyi <group>, 1` at `0x12A0C`, i.e. the SPU shifting the **whole 16-byte
group at `+0x20..+0x2F`** left by a byte as it dequeues. `0x02` and `0x01` are
the `direction` and `init` values the Phase 16 initialiser writes at `+0x24` and
`+0x2C`.

So those two fields do **not** live there in this structure, and the initialiser
has been writing them into the middle of the SPU's own state group. The fields
that were positively confirmed — `size` `+0x10`, `depth` `+0x14`, `buffer`
`+0x18` — are all below `+0x20` and remain good; it is only the two inside the
group that were misplaced. (The first cut of the probe had the same bug from the
other side, shifting 15 bytes across `0x21..0x2F` and walking over the same two
fields. Both are fixed: the probe now touches only `0x21..0x23`.)

**Phase 21 — two pointer models tried, both wrong**

Both follow-ups from Phase 20 were tested and **both failed**. Recording them
because eliminating a plausible model is worth as much as the time it saves the
next attempt.

**(a) Producer claims `+0x00` as a grant.** Mirroring the observed
`0x12D2C` transition (`v<0 ? -v : v+1`) on every push. The prediction was that
the handshake would settle. It did the opposite — the magnitude ran away:

```
sync=-58->58 ... sync=195->196 ... sync=284->285 ... sync=-383->383
```

383 within a handful of pushes. So `|v|` is **not** a waiter count; it behaves
like a monotonically climbing ticket, and the SPU is busy-spinning rounds rather
than waiting on a semaphore. Metrics were flat against the previous run
(jobs 38 vs 39, spins 1 vs 1, BindTile 15 vs 13).

**(b) Producer advances `+0x04` as its own tail.** Better grounded: the consumer
normalises both words with

```
cgti $rf, $rv, -1 ; nor $rc, $rv, $rv ; selb $rn, $rc, $rv, $rf
```

— "if v >= 0 use v else use ~v", a pointer with a flag parked in the sign bit —
then differences the two (`0x12914`..`0x129D0`) to decide empty. That reads like
a head/tail pair with `+0x00` the consumer's side and `+0x04` the producer's.
Advancing `+0x04` sign-normalised changed nothing either.

**The measurement that would settle it has never once fired.** Across every
configuration tried — with and without pushes, both pointer models, `WS_DRAIN`
on and off — the consumer has **never issued a single DMA into the element
buffer** (`0x032B2A00`..`0x032B4A00`). Its DMA targets are consistently
elsewhere (`0x0309B200`, `0x03403500`, `0x040600xxx`, and two single reads at
`0x032B2890`/`0x032B0EF0` that sit just *below* the queue and taskset). Until
that read appears, no pointer model can be confirmed, and guessing further just
writes plausible-looking values into a structure recompiled SPU code consumes.

So both guesses were reverted. What the probe now writes is exactly the part
with evidence behind it: the element bytes, the `+0x0C` fill count the consumer
was **observed** decrementing, and the waiter wake. Both pointers are read for
the log and otherwise left alone. That state keeps the Phase 20 win — the
producer still pushes 12 where it used to stop at 8, and the ring spin stays at
1 instead of 2.

**Phase 22 — deriving the ring instead of guessing it**

Working the consumer's decision at `0x12914`-`0x129D0` backwards through its
dataflow, rather than trying models at runtime:

```
r11 = normalise(W0)          W0 = queue+0x00
r2  = normalise(W1)          W1 = queue+0x04
r60 = W3                     W3 = queue+0x0C
      normalise(v) == cgti/nor/selb == (v >= 0 ? v : ~v)

r81 = r2 - r11
r79 = (r2 + r60) - (r11 - r60)  =  r2 - r11 + 2*r60
r68 = (r11 > r2) ? r79 : r81    =  (r2 - r11) mod 2*r60
ceqi r77, r68, 0                -> THE EMPTY TEST

r14 = (r60 > r11) ? r11 : r11 - r60   =  index mod r60     (0x129A8..0x129B8)
```

So it is an ordinary ring buffer: **`W0` is the pop index, `W1` the push index,
indices run modulo `2*W3`, and the slot is `index mod W3`** — the standard
scheme that keeps "full" distinguishable from "empty". `W3` is the depth.

**And that was the bug.** The Phase 16 initialiser left `queue+0x0C` at **zero**,
so `r60 = 0` and the whole computation degenerates: occupancy is `(W1-W0) mod 0`
and the slot is `index mod 0`. With both indices at zero the empty test is
trivially true — which is exactly why the consumer parked every single time and
never read the element buffer, no matter what any producer wrote. Fixed in both
initialisers.

**A correction to Phase 21.** The `+0x00` sequence called a "runaway ticket"
there is nothing of the kind. Applying the normalise function the consumer
itself uses:

| raw | `0 → -1 → 1 → -2 → 2 → -3 → 3` |
|---|---|
| normalised | `0, 0, 1, 1, 2, 2, 3` |

The sign bit is a **parked flag** and the index underneath advances cleanly.
`0x12AA0` sets the flag without moving the index (`v -> ~v`); `0x12D2C` clears it
and advances by one. The consumer was popping all along. The producer's own log
agrees — after four pushes it reads `sync=4/4`, a pop index that has tracked the
push index exactly.

**The `+0x24`/`+0x2C` pollution is gone.** With those writes removed the trace
shows both words sitting at zero and staying there, instead of marching a byte
per dequeue through the SPU's state group. Jobs completing went 39 -> 45 and
tiles bound returned to 15.

**Phase 23 — the next real problem: a lost-update race**

With the line dumped either side of each atomic, successive stores show word 1
(`+0x04`) holding `1, 1, 2` — the SPU writing the push index back itself. That
is expected: `PUTLLC` commits the **whole 128-byte line**, every word of it.

The producer, though, writes `+0x04` with a plain `vm_write32`. A push that
lands between the consumer's `GETLLAR` and its `PUTLLC` is therefore silently
discarded when the SPU commits its stale copy of the line. The producer is not
participating in the lock-line protocol at all, and on a queue whose entire
point is cross-processor atomicity that cannot work.

### Known gaps at this point
- **The producer must join the reservation protocol.** A PPU-side push has to
  either take part in the GETLLAR/PUTLLC reservation the way the SPU does, or go
  through a runtime path that invalidates an outstanding SPU reservation when
  the PPU writes the line. Until then pushes are racy by construction and any
  further tuning of indices is measuring noise.
- **The consumer has never read the element buffer**, which is the single
  measurement that would validate any push model. The next step is not another
  guess: it is a proper static decode of the compare at `0x12914`-`0x129D0` —
  which exact fields feed the difference, what the wrap term at `+0x0C` does,
  and what the sign flags mean — so that a model can be *derived* rather than
  trialled. Trial-and-error on this structure has now been shown to be a poor
  use of runs.
- **Where `direction` and `init` actually live** needs settling before the
  initialiser can be called correct — `+0x24`/`+0x2C` are inside the SPU's
  group and demonstrably get shifted.
- **Where the element data goes is still open.** The waiter/wake half of the
  push is now understood; the data half — which ring slot an element occupies
  and how the push counter advances — has not been pinned down, and no push
  transition has ever been observed because nothing has ever pushed. The
  remaining decode is the *other* branch of this routine (`0x129DC`, taken when
  the queue is NOT empty), which is where the consumer computes the element
  address it reads from and therefore names the slot the producer must fill.
- **`cellSpursQueuePushBody` is the last stub on the critical path.** The pop
  half is now known (waiter count `+0x04` + id queue from `+0x32`) and the wake
  primitive exists (`CSTS_SIGNALLED`). What is still missing is the push half:
  which counter names the ring slot an element goes into and how it advances.
  Nothing has ever pushed, so no push transition has been *observed* — the trace
  above only shows consumers blocking. The obvious next move is to read the
  `0x128B8`–`0x12AA0` routine now that its exact bounds and its inputs are
  known, since a queue's pop path necessarily encodes where the producer must
  have put the data.
- Writing an element also means driving the `pop1`/`push1`/`push2`/`pop2` packed-u16 pointer
  protocol at offsets 0x00/0x08/0x30/0x50 — the other half of the GETLLAR/PUTLLC
  handshake above, shared with SPU code that already implements its side
  correctly. That protocol has to be recovered from the title's own SPU image
  (its pop path is right there in image 1) rather than guessed or transcribed:
  a wrong pointer update corrupts a queue that recompiled SPU code then consumes,
  and it would fail silently.
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

1. **Implement `cellSpursQueuePushBody`.** Everything around it is now known
   and verified: the 128-byte line layout, the waiter count at `+0x04`, the
   waiter-id queue from `+0x32`, the consumer routine (`0x128B8`-`0x12AA0` in
   image 2), and the `CSTS_SIGNALLED` wake primitive. What remains is the ring
   slot index and how the push counter advances — read it out of the
   `0x128B8`-`0x12AA0` pop path, whose bounds and inputs are now pinned down.
   That is the single remaining gate; the renderer, tasksets, job chains and
   queue lines all already work.
2. A first picture should follow immediately — `RSX_LIVE_DRAW=1` already opens
   the window and has three display buffers registered; it is only missing a
   command stream.
3. Decide whether `SPURS_TASKATTR_DESC` should auto-detect (a `sizeContext` that
   is a guest stack address is self-evidently not a size) rather than stay an
   env var.
4. Work through the undecoded SPU `.word` instructions as they surface.
5. Fill in `DiscGameGetBootDiscInfo()` before anything starts checking it.

> **Shared-runtime note.** The six handlers live in
> `ps3recomp/libs/spurs/cellSpurs.c` + `cellSpurs.h`, which flOw, Simpsons,
> Twisted Metal and You Don't Know Jack all build against. They are **added**
> functions — no existing handler changed — so nothing those ports call behaves
> differently, but the changes are left **uncommitted** in that checkout because
> it already carries unrelated in-flight work (`cellSync.c`, `cellGame.c`,
> `boot_main.cpp`, `sys_fs.c`, `pkg_extract.py`) that is not ours to commit.
> The same applies to the jump-table cap in `tools/ppu_lifter.py`.
