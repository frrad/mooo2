# Reproducible Wine-boxing pipeline for the reference KakaoTalk client.
# See docs/boxing.md and DESIGN.md (§10 Hosting the reference, §13 Roadmap step 1).

# --- Pins (change only via `make rebaseline` / a reviewed bump) -----------------
KAKAO_URL  ?= https://app-pc.kakaocdn.net/talk/win32/x64/KakaoTalk_Setup.exe
INSTALLER  ?= vendor/KakaoTalk_Setup.exe
IMAGE      ?= mooo2-kakao-box
# KakaoTalk x64 + WineHQ are x86-64/i386 only; box runs amd64 (QEMU-emulated on arm64).
PLATFORM   ?= linux/amd64

# Pick the available sha-256 tool (sha256sum on Linux, shasum on macOS).
SHATOOL := $(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo "shasum -a 256")

.PHONY: help fetch verify rebaseline build run inject-spike net-spike shell clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	 | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

$(INSTALLER):
	@mkdir -p vendor
	curl -fL --retry 3 --retry-delay 2 -o $@ "$(KAKAO_URL)"

fetch: $(INSTALLER) verify ## Download the pinned installer (if missing) and verify it

verify: ## Verify the downloaded installer against SHA256SUMS
	@$(SHATOOL) -c SHA256SUMS && echo "installer verified against SHA256SUMS" \
	 || { echo; echo "CHECKSUM MISMATCH. Upstream likely shipped a new build."; \
	      echo "This is a deliberate re-baseline event (DESIGN §9). Run: make rebaseline"; \
	      exit 1; }

rebaseline: ## Re-download and REWRITE SHA256SUMS to accept a new upstream build
	@mkdir -p vendor
	curl -fL --retry 3 --retry-delay 2 -o $(INSTALLER) "$(KAKAO_URL)"
	@$(SHATOOL) $(INSTALLER) > SHA256SUMS
	@echo "Rewrote SHA256SUMS:"; cat SHA256SUMS
	@echo "Review and commit SHA256SUMS; re-baseline any grey-box taps (DESIGN §12)."

build: fetch ## Build the boxed container image (installs the client under Wine)
	docker build --platform=$(PLATFORM) -t $(IMAGE) .

run: ## Run the launch spike headlessly (DESIGN §13.1 pass/fail signal)
	docker run --rm --platform=$(PLATFORM) $(IMAGE)

inject-spike: ## Run Spike A: prove an injected DLL loads into the client (docs/inject-spike.md)
	docker run --rm --platform=$(PLATFORM) $(IMAGE) /usr/local/bin/verify-inject.sh

net-spike: ## Launch behind default-deny egress; check blocking is logged and fan-out works
	docker run --rm --platform=$(PLATFORM) --cap-add NET_ADMIN -u 0 $(IMAGE) /usr/local/bin/verify-net.sh

shell: ## Open an interactive shell in the image for debugging the prefix
	docker run --rm -it --platform=$(PLATFORM) $(IMAGE) /bin/bash

clean: ## Remove the downloaded installer
	rm -f $(INSTALLER)
