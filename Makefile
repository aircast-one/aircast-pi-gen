.PHONY: test
test: lint-stage-scripts

.PHONY: lint-stage-scripts
lint-stage-scripts:
	@echo "Validating stage sub-script naming..."
	@bad=$$(find stage* export-image -mindepth 2 -maxdepth 2 -type f -name '*.sh' 2>/dev/null \
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
