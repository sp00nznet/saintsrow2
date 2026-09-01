# Saints Row 2 — Static Recompilation

> Turning the PS3 disc binary of Volition's open-world crime sandbox into a
> native PC executable — no emulator required.

**Saints Row 2** (2008, Volition / THQ) is the entry the series is still judged
by: a full open-world Stilwater, four-player co-op across the whole campaign, and
a character creator that let you build anything you wanted. There *is* a PC
release — and it is famously, permanently broken, a rushed port whose timing was
tied to CPU speed and which has never really been fixed in the years since. The
console versions are the good ones.

This project takes the decrypted PS3 `EBOOT.elf`, lifts every PowerPC function
to C/C++, and links it against [**ps3recomp**](https://github.com/sp00nznet/ps3recomp)
— a set of HLE runtime libraries that replace the Cell/LV2 operating system with
native host implementations. The goal is a standalone Windows executable that
runs the *console* Saints Row 2 natively.

> **You bring your own legally-dumped disc.** No game binaries, packfiles, audio
> or video are included in this repository — only analysis metadata and the
> recompilation harness. Everything under `game/`, `disc/` and `src/recomp/` is
> git-ignored and regenerated from your own copy.

---

## Why this target

Saints Row 2 is a genuinely *large* recomp target — 15.8 MB of executable, an
order of magnitude past the PSN titles this toolchain has been proving itself on
— but its OS surface is remarkably small:

- **17 imported libraries, 247 imported functions.** flOw imported 12 libraries;
  You Don't Know Jack imported 23. A 2008 open-world AAA title sits *between*
  two PSN downloads on OS surface area, because the engine does its own work.
- **66% of those NIDs already have a handler** in ps3recomp's 1,056-entry HLE
  table on day one, with no new code written.
- **Everything missing is either online or exotic.** The 83 uncovered NIDs are
  concentrated in `sys_net` (21), `sceNp` (15) and `cellMic` (5) — matchmaking,
  presence and voice chat, all of which an offline single-player port stubs out.
- **One self-contained EBOOT.** No `.sprx` modules to relocate and stitch in.
- **11 embedded SPU images, 702 KB, shipped as real SPU ELFs** inside the EBOOT
  — so they come straight out of the binary, unlike the Simpsons port whose
  SPURS jobs had to be captured from a live run.

The counterweight: **40,235 functions** and a **611 MB** lifted C++ tree. This is
the biggest thing ps3recomp has been pointed at.

---

## Current Status

**Analysis and lift complete; the build is the current frontier.**

| Metric | Value |
|---|---|
| Title | Saints Row 2 |
| Title ID | **BLUS30201** (USA disc, `En,Fr`) |
| Developer / Publisher | Volition / THQ |
| Binary | `EBOOT.elf` — 15,825,384 B, ELF64 big-endian PowerPC64, `ET_EXEC` |
| Entry | `0xEC6A08` |
| Code segment | PT_LOAD @ `0x10000`, filesz `0xE8E8C8` |
| Executable code ends | `0xCB0C2C` (last `SHF_EXECINSTR` section) |
| `.opd` descriptors | 12,799 |
| Functions detected | **40,235** |
| Functions lifted to C++ | **57,715** (base + jump-table cases + mid-function tail-entry wrappers) |
| Unique call targets | 25,980 |
| Generated source | **611 MB** across 14 chunks |
| Imported libraries | **17** |
| Imported functions | **247** (234 named, 94%) |
| HLE NID coverage | **164 / 247 (66%)** against ps3recomp's current table |
| Embedded SPU images | **11** (702,544 B, real SPU ELFs) |
| Disc payload | 6.3 GB — 24 `.vpp_ps3` packfiles + 11 Bink videos |
| Target | Windows x86-64 |

### Phase progress

| Phase | Status | Notes |
|---|---|---|
| Disc extraction | ✅ **Complete** | 29 files, 6.3 GB; `PS3_GAME/USRDIR` intact |
| SELF decryption | ✅ **Complete** | `EBOOT.BIN` → `EBOOT.elf` via `rpcs3 --decrypt`, first try, no RAP |
| ELF structural analysis | ✅ **Complete** | 8 program headers, 32 sections, entry + code bound resolved |
| Function boundary detection | ✅ **Complete** | 40,574 found → **40,235** after clipping `.rodata` |
| `--code-end` bound | ✅ **Applied** | `0xCB0C2C`; dropped 339 rodata pseudo-functions before they could explode |
| Import / NID extraction | ✅ **Complete** | 247 NIDs across 17 libraries (`imports.json`) |
| Module coverage triage | ✅ **Complete** | 164/247 NIDs covered; the gap is online-only |
| PPU lifting (→ C++) | ✅ **Complete** | 57,715 functions → 14 chunks, 611 MB, in 84 s |
| HLE NID table | ✅ **Complete** | 1,056 handlers / 88 modules (`src/gen/ppu_hle_nids.cpp`) |
| SPU image extraction | ✅ **Complete** | 11 images pulled straight out of the EBOOT |
| Boot harness (CMake) | ✅ **Written** | clang-cl, links prebuilt `ps3recomp_runtime.lib` |
| Build & link | ⏳ **Current frontier** | 611 MB of C++; chunk 001 alone is 145 MB |
| SPU lifting | ⬜ Not started | |
| First boot | ⬜ Not started | |
| Graphics (RSX → D3D12) | ⬜ Not started | harness provides it; needs a running boot first |
| Audio / input | ⬜ Not started | |

Blow-by-blow in [`PROGRESS.md`](PROGRESS.md).

---

## How it lines up with the sibling ports

This is the fifth title on the same harness, and the first AAA-scale one.

| | flOw | Simpsons Arcade | You Don't Know Jack | **Saints Row 2** |
|---|---|---|---|---|
| Release | PSN 2007 | PSN 2012 | Disc 2011 | **Disc 2008** |
| EBOOT | 2.7 MB | 1.6 MB | 5.2 MB | **15.8 MB** |
| Functions lifted | 100k+ | 5,019 | 14,380 | **57,715** |
| Imported libraries | 12 | 20 | 23 | **17** |
| Imported functions | — | 256 | 265 | **247** |
| SPU images | libsre PRX | captured at runtime | 22 embedded | **11 embedded** |
| Status | renders | **playable** | boots to main loop | **lift done** |

The pattern that keeps holding: **OS surface area does not scale with game
size.** A 2008 open-world title imports fewer libraries than a 2011 trivia game,
because everything interesting — the streaming, the physics, the renderer — is
the engine's own code, and the engine's own code is exactly what static
recompilation translates for free.

---

## Pipeline

```
Saints Row 2 (USA).7z
        │  7-Zip
        ▼
disc/PS3_GAME/USRDIR/EBOOT.BIN        (SELF, 15.8 MB, retail NPDRM)
        │  rpcs3 --decrypt
        ▼
game/EBOOT.elf                        (ELF64 BE PPC64, ET_EXEC)
        │  elf_parser.py               → analysis/elf.json
        │  gen_imports.py              → imports.json      (17 libs, 247 NIDs)
        │  find_functions.py           → analysis/functions.json (40,235 fns)
        │  extract_spu_images.py       → spu_dump/         (11 SPU ELFs)
        ▼
        │  ppu_lifter.py --code-end 0xCB0C2C --hle-stubs imports.json
        ▼
src/recomp/ppu_recomp_0NN.cpp         (57,715 functions, 611 MB, 14 chunks)
        │  + src/gen/ppu_hle_nids.cpp  (1,056 HLE handlers)
        │  + ps3recomp_runtime.lib     (LV2/Cell HLE, RSX→D3D12, VFS)
        ▼  clang-cl / Ninja
build/sr2.exe
```

## Build

You need a decrypted `EBOOT.elf` from your own disc, a
[ps3recomp](https://github.com/sp00nznet/ps3recomp) checkout with
`build/ps3recomp_runtime.lib` already built, Python 3, CMake ≥ 3.20, Ninja and
clang-cl.

```sh
# 1. Extract your disc dump, decrypt the EBOOT
7z x "Saints Row 2 (USA) (En,Fr).7z" -odisc
rpcs3 --decrypt "disc/.../PS3_GAME/USRDIR/EBOOT.BIN"      # -> game/EBOOT.elf

# 2. Regenerate everything git-ignored (analysis, lift, HLE table, SPU images)
PS3RECOMP=../ps3recomp ./tools/relift.sh

# 3. Build
cmake -S . -B build -G Ninja \
      -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl
cmake --build build

# 4. Run
PS3_VFS_ROOT="disc/Saints Row 2 (USA) (En,Fr)/PS3_GAME/USRDIR" \
RSX_LIVE_DRAW=1 ./build/sr2 game/EBOOT.elf
```

## Repository layout

```
CMakeLists.txt        # boot harness: lifted code + HLE table + ps3recomp runtime
config.toml           # module policy (hle / stub) per imported library
imports.json          # 247 NIDs across 17 libraries, parsed from lib.stub
analysis/             # ELF + function metadata (regenerated, git-ignored)
src/compat/           # <dirent.h>/<unistd.h> shims for Win32
src/gen/              # generated HLE NID dispatch table
src/recomp/           # generated: 611 MB of lifted PPU code (git-ignored)
src/spu_gen/          # generated: lifted SPU images (git-ignored)
tools/relift.sh       # one command to regenerate all of the above
game/ disc/           # YOUR disc dump and decrypted EBOOT (git-ignored)
```

## Credits

Built on [ps3recomp](https://github.com/sp00nznet/ps3recomp). Same lineage as
[N64Recomp](https://github.com/N64Recomp/N64Recomp),
[UnleashedRecomp](https://github.com/hedge-dev/UnleashedRecomp) and
[XenonRecomp](https://github.com/hedge-dev/XenonRecomp).

Saints Row 2 is © Volition / THQ (now Deep Silver / Plaion). This project ships
no game code or assets and is not affiliated with the rights holders.
