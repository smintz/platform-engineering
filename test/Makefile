test:
	protoconf mod tidy
	protoconf compile .
	$(MAKE) workflows

# GitHub only reads .github/workflows at the repository root, so the workflow the compiler
# writes under outputs/ is installed there. Generated: edit core_test.mpconf, not the yaml.
workflows:
	mkdir -p ../.github/workflows
	cp outputs/core_test/.github/workflows/*.yaml ../.github/workflows/

.PHONY: test workflows
