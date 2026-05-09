.PHONY: test-all spec-validate deploy-check

# Run every iSales repo's test suite in sequence; pass extra pytest args
# via PYTEST_ARGS (e.g. `make test-all PYTEST_ARGS="-k modem"`).
test-all:
	bash scripts/test_all.sh $(PYTEST_ARGS)

# Validate every spec + every active change against the OpenSpec workflow.
spec-validate:
	openspec validate --specs
	openspec validate --changes

# Static checks for the deploy/ tree:
#   - shellcheck on all bash scripts
#   - env-template variable lists vs each service repo's README
deploy-check:
	@command -v shellcheck >/dev/null || { echo "shellcheck not installed (brew install shellcheck or apt install shellcheck)"; exit 1; }
	cd deploy/scripts && shellcheck -x _lib.sh provision.sh install.sh migrate.sh deploy.sh rollback.sh backup_pg.sh backup_redis.sh
	python3 deploy/scripts/check_env_consistency.py
