FLUENT_BIT_IMAGE := fluent/fluent-bit:latest
FLUENT_BIT_FILES_DIR := stage3/02-install-aircast/files

.PHONY: test
test: lint-stage-scripts test-fluent-bit

.PHONY: lint-stage-scripts
lint-stage-scripts:
	@echo "Validating stage sub-script naming..."
	@bad=$$(find stage* -mindepth 2 -maxdepth 2 -type f -name '*.sh' 2>/dev/null \
		| while IFS= read -r f; do \
			base=$$(basename "$$f"); \
			echo "$$base" | grep -qE '^[0-9]{2}-run(-chroot)?\.sh$$' || echo "$$f"; \
		done); \
	if [ -n "$$bad" ]; then \
		echo "ERROR: pi-gen silently skips scripts whose names do not match NN-run.sh or NN-run-chroot.sh."; \
		echo "Offenders:"; \
		echo "$$bad" | sed 's/^/  - /'; \
		exit 1; \
	fi
	@echo "All stage sub-scripts have valid names."

.PHONY: test-fluent-bit
test-fluent-bit:
	@echo "Validating Fluent Bit config..."
	@docker run --rm \
		-v $(PWD)/$(FLUENT_BIT_FILES_DIR)/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro \
		-v $(PWD)/$(FLUENT_BIT_FILES_DIR)/fluent-bit-parsers.conf:/fluent-bit/etc/parsers.conf:ro \
		-e LOKI_HOST=test.example.com \
		-e LOKI_USERNAME=test \
		-e LOKI_PASSWORD=test \
		-e DEVICE_ID=test-device \
		-e DEVICE_NAME=test \
		-e ENVIRONMENT=development \
		-e VERSION=test \
		-e HOST=test \
		$(FLUENT_BIT_IMAGE) \
		--dry-run -c /fluent-bit/etc/fluent-bit.conf
