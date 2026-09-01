/* spu_workloads.c -- register the one SPURS job image that is NOT in the EBOOT.
 *
 * The other 11 images ship as real SPU ELFs inside EBOOT.elf and are handled
 * entirely by tools/build_spu_workloads.py, which emits
 * src/spu_gen/sr2_spu_workloads.c with its own constructor. This one is
 * different: the title assembles a 201,984-byte job image in main memory at
 * runtime, so extract_spu_images.py cannot see it. The only place its bytes
 * exist is the moment cellSpurs hands it to the job dispatcher, so it has to be
 * captured from a live run:
 *
 *   SPU_DUMP_MISS=spu_dump ./build/sr2 game/EBOOT.elf
 *
 * which writes spu_dump/spujob_4333827302318B21_201984.bin. tools/relift.sh
 * lifts it under the "spujob_" symbol prefix when that file is present.
 *
 * The fingerprint below is the one the dispatcher printed for it. If a capture
 * ever yields a different fingerprint, update it here to match -- a mismatch is
 * silent, it just shows up as another "dispatch MISS" and a thread blocked in
 * cellSpursEventFlagWait.
 */
#include "spu_workload.h"

extern void spu_begin_image(int image_id);

extern void spujob_spu_func_00000000(spu_context*);
extern void spujob_spu_recomp_register(void);

void sr2_spu_register_captured(void)
{
    /* Job images load at local store 0 and are entered at their first
     * instruction, so --base 0 keeps the lifted addresses equal to the
     * link-time ones and func_00000000 is the entry. Image ids 1..11 belong to
     * the generated registry, so this one takes 12. */
    spu_begin_image(12); spujob_spu_recomp_register();
    spu_workload_register_img(0x4333827302318B21ULL, spujob_spu_func_00000000,
                              12, "spurs_jobchain_runtime");
}

__attribute__((constructor)) static void sr2_spu_register_captured_ctor(void)
{
    sr2_spu_register_captured();
}
