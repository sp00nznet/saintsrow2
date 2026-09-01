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
| 11. Build & link | clang-cl / Ninja | ⏳ current |
| 12. SPU lift | 11 images → C | ⬜ |
| 13. First boot | Enter the recompiled CRT | ⬜ |
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

### Next

1. Get the 611 MB tree through clang-cl. The 145 MB chunk is the risk.
2. Lift the 11 SPU images.
3. First boot; expect the ~38 boot-critical missing NIDs to surface in order.
