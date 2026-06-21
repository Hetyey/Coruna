# Coruna
Coruna Kernel exploit and PPL/SPTM bypass reverse-engineered and reimplemented in Objective-C

Tested on iPhone 13 iOS 17.0

offsets are mostly hardcoded

Not everything is binary-faithful as there were things that just didn't work (by default, an A15/17.0 device goes down the fallback path, which leads to a narrow primitive (it is also implemented: agx_doorbell_fallback.m), so I implemented the iOS 17.1+ path but a custom delivery had to be invented.

`sptm_bypass.log` contains output from a test run on my device.

The bypass mechanism: redirect the GPU firmware "power thread", run a ROP chain that hibernates, swaps in a fake TTBR1, and rides the `__arm_arch_resume_uat` raw-TTBR-load bug to a broad physical write

The binary delivers ROP as a single malformed fence/stamp GPU job:
1. Build the variant-B ROP records (fake thread-state + gadget chain) in a kernel-owned GPU-shared buffer.
2. Submit them as a fence/stamp op: WITH a stolen IOGPU port via `IOConnectCallMethod(uc, 0x1A, …)` (`sub_193C0`), or WITHOUT a port by physically mapping the GFX job list and inserting the job directly.
3. On completion the GFX firmware executes the stamp = a 32-bit write to `power_thread+0x49`, overwriting bytes 1-4 of the saved-context pointer at `power_thread+0x48` so it points at the fake ROP context.
4. Next time the RTKit scheduler runs the power thread, it restores PC/SP/GPRs from `*(power_thread+0x48)` = fake context -> ROP -> `hibernate_uat` -> overwrite the hibernation ctx's TTBR1 -> `resume_uat` raw-loads the fake TTBR1 -> GFX µPPL defeated -> self-ref AP PTE -> arbitrary physical write.

For my device the fence/stamp job was accepted (`IOConnectCallMethod(0x1A)` returned `KERN_SUCCESS`) but the GFX firmware never processed it. (I have theories, but I'm not 100% certain of the reason)

So I deliver the same `power_thread+0x48` redirect a different way (marked as "CUSTOM" in sptm_bypass.m):
1. Drive a continuous Metal workload on my own GPU queue, so the kext keeps a serviced channel resident for it and kicks its doorbell on every commit (I don't seem to be able to ring the firmware doorbell directly, so I piggyback on Metal's normal submit path)
2. Inject an op-0x0f arbitrary-write record into that channel's ring, it drains on the next commit and writes `power_thread+0x48`.
3. Pulse that workload between active and idle
