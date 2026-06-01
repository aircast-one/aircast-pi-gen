FLUENT_BIT_IMAGE := fluent/fluent-bit:latest
FLUENT_BIT_FILES_DIR := stage3/02-install-aircast/files

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
