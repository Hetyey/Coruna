#ifndef SPTM_BYPASS_H
#define SPTM_BYPASS_H

#include <stdint.h>
#include <mach/mach.h>

int agx_userclient_setup_test(void);
int agx_kcache_locate_iogpu_test(void);
int agx_kcache_pattern1_test(void);
int agx_broad_bypass(void);
int agx_get_discriminator_result(void);
int agx_rerun_final_test(void);

int sptm_kwrite_test(mach_port_t entry_port);
int sptm_kread32_pa(uint64_t target_pa, uint32_t *out);
int sptm_kwrite32_pa(uint64_t target_pa, uint32_t value);

int  sptm_window_is_installed(void);
void sptm_window_mark_uninstalled(void);
int  sptm_window_unhook_info(uint64_t *l1_pa, uint64_t *free_off, uint64_t *l1tab_kva, uint64_t *hook_val);

#endif
