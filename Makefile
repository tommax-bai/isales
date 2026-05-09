.PHONY: test-all spec-validate

# Run every iSales repo's test suite in sequence; pass extra pytest args
# via PYTEST_ARGS (e.g. `make test-all PYTEST_ARGS="-k modem"`).
test-all:
	bash scripts/test_all.sh $(PYTEST_ARGS)

# Validate every spec + every active change against the OpenSpec workflow.
spec-validate:
	openspec validate --specs
	openspec validate --changes
