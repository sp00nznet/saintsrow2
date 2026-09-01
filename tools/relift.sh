#!/bin/sh
# Regenerate everything git-ignored: the lifted PPU tree and the HLE NID table.
# Run from the repo root. PS3RECOMP defaults to the sibling checkout.
set -e
PS3RECOMP="${PS3RECOMP:-../ps3recomp}"

# 0xCB0C2C is the end of the last SHF_EXECINSTR section. Past it is .rodata,
# which shares the R-X PT_LOAD segment on a PS3 EBOOT; without this bound the
# branch-target pass explodes rodata words that happen to decode as `bc` into
# bogus functions (the 5.2 GB lift that bit You Don't Know Jack).
python "$PS3RECOMP/tools/find_functions.py" game/EBOOT.elf --json \
    -o analysis/functions.json
python - <<'PY'
import json
CE = 0xCB0C2C
d = json.load(open('analysis/functions.json'))
fns = d['functions'] if isinstance(d, dict) and 'functions' in d else d
def start(f): s = f['start']; return s if isinstance(s, int) else int(s, 16)
keep = [f for f in fns if start(f) < CE]
print(f'dropped {len(fns)-len(keep)} rodata pseudo-functions, kept {len(keep)}')
json.dump(dict(d, functions=keep) if isinstance(d, dict) and 'functions' in d else keep,
          open('analysis/functions.json', 'w'))
PY

# --hle-stubs rewrites each import trampoline as ps3_hle_call(nid), so a direct
# `bl` to an import dispatches to the HLE handler instead of running the literal
# stub (whose pointer table the recomp never fills) -- the 0x39800000 wall.
rm -rf src/recomp && mkdir -p src/recomp src/gen
python "$PS3RECOMP/tools/ppu_lifter.py" game/EBOOT.elf \
    --functions analysis/functions.json \
    --hle-stubs imports.json \
    --code-end 0xCB0C2C \
    -o src/recomp

python "$PS3RECOMP/tools/gen_hle_nids.py" --all --out src/gen/ppu_hle_nids.cpp

# ---- SPU -------------------------------------------------------------------
# Unlike the Simpsons port, SR2's SPU code IS embedded in the EBOOT as real SPU
# ELFs -- 11 of them, 702 KB -- so they come straight out of the binary.
# build_spu_workloads.py lifts each under its own symbol prefix (they all define
# spu_func_*/spu_recomp_register, so they would otherwise collide) and emits the
# registry that maps each image's FNV-1a-64 content fingerprint to its lifted
# entry. Without that registry cellSpurs logs "dispatch MISS" and the main
# thread blocks forever on an event flag only an SPU workload can set.
python "$PS3RECOMP/tools/extract_spu_images.py" game/EBOOT.elf -o spu_dump
rm -rf src/spu_gen && mkdir -p src/spu_gen
python "$PS3RECOMP/tools/build_spu_workloads.py"     --images spu_dump --lifted src/spu_gen     --out src/spu_gen/sr2_spu_workloads.c     --register-fn sr2_spu_register_all --constructor --title sr2

# One SPURS job (fp 0x4333827302318B21, 201,984 B) is built in main memory at
# runtime and is NOT in the EBOOT, so extract_spu_images.py cannot find it.
# Capture it from a run and re-run this script:
#
#   SPU_DUMP_MISS=spu_dump ./build/sr2 game/EBOOT.elf
#
# src/spu_workloads.c registers it by that fingerprint; without the lift the
# build fails to link, which is the intended loud failure.
JOB=spu_dump/spujob_4333827302318B21_201984.bin
if [ -f "$JOB" ]; then
    python "$PS3RECOMP/tools/find_spu_functions.py" "$JOB" --raw --base 0         --out spu_dump/spujob_funcs.json
    rm -rf src/spu_gen/spujob && mkdir -p src/spu_gen/spujob
    python "$PS3RECOMP/tools/spu_lifter.py" "$JOB" --base 0         --functions spu_dump/spujob_funcs.json         --symbol-prefix "spujob_" -o src/spu_gen/spujob
    # The lifter emits depth-sensitive relative includes; the rest of the tree
    # resolves these via the runtime/spu include path, so match it.
    sed -i 's|"../../runtime/spu/spu_helpers.h"|"spu_helpers.h"|'         src/spu_gen/spujob/spu_recomp.c
    sed -i 's|"../../runtime/spu/spu_context.h"|"spu_context.h"|'         src/spu_gen/spujob/spu_recomp.h
else
    echo "NOTE: $JOB not captured yet -- run with SPU_DUMP_MISS=spu_dump first"
fi
