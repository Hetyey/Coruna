TARGET := iphone:clang:16.5:17.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = SPTMTest

SPTMTest_FILES = main.m SPTMTestViewController.m \
	entry1_src/kread_bootstrap.m \
	entry1_src/kernel_primitives.m \
	entry1_src/sptm_bypass.m \
	entry1_src/agx_doorbell_fallback.m \
	entry1_src/stabilize.m

SPTMTest_FRAMEWORKS = UIKit IOKit Metal
SPTMTest_CFLAGS = -Wno-everything
SPTMTest_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

after-package::
	@APP_DIR=".theos/_/Applications/$(APPLICATION_NAME).app"; \
	if [ ! -d "$$APP_DIR" ]; then \
		echo "[tipa] ERROR: $$APP_DIR not found"; exit 1; \
	fi; \
	LAST=$$(ls packages/$(APPLICATION_NAME)-*.tipa 2>/dev/null \
		| sed -E 's|.*/$(APPLICATION_NAME)-([0-9]+)\.tipa|\1|' \
		| sort -n | tail -n1); \
	NEXT=$$(( $${LAST:-0} + 1 )); \
	OUT="packages/$(APPLICATION_NAME)-$$NEXT.tipa"; \
	rm -rf Payload; \
	mkdir -p Payload; \
	cp -R "$$APP_DIR" Payload/; \
	zip -qr9 "$$OUT" Payload; \
	rm -rf Payload; \
	rm -f packages/*.deb; \
	echo "[tipa] $$OUT (removed .deb)"
