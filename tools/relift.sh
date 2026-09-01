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
python "$PS3RECOMP/tools/extract_spu_images.py" game/EBOOT.elf -o spu_dump
for img in spu_dump/spu_*.elf; do
    pfx="spu$(basename "$img" | sed 's/spu_\([0-9]*\)_.*/\1/')"
    python "$PS3RECOMP/tools/find_spu_functions.py" "$img" \
        --out "spu_dump/${pfx}_funcs.json"
    rm -rf "src/spu_gen/$pfx" && mkdir -p "src/spu_gen/$pfx"
    python "$PS3RECOMP/tools/spu_lifter.py" "$img" \
        --functions "spu_dump/${pfx}_funcs.json" \
        --symbol-prefix "${pfx}_" -o "src/spu_gen/$pfx"
done
