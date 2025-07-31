AVM_PORCH_BASE_URL := git::https://github.com/Azure/avm-terraform-governance//porch-configs
AVM_PORCH_REF := main

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  pre-commit          - Run pre-commit checks. Formates files and generates documentation."
	@echo "  pr-check            - Run PR checks. Checks that pre-commit has been run and runs linters."
	@echo "  test-examples       - Test examples. Will orchestrate terraform plan/apply/destroy and check for idempotent configuration. Set \`AVM_EXAMPLE\` to the example directory name to run a single example."
	@echo "  tf-test-unit        - Run Terraform unit tests, if they exist in \`tests/unit\`."
	@echo "  tf-test-integration - Run Terraform integration tests, if they exist in \`tests/integration\`."

.PHONY: migrate
migrate:
	@echo "This is a no-op. This repo has already been migrated."

.PHONY: pre-commit
pre-commit:
	@echo "Running pre-commit..."
	porch run ${TUI} -f "$(AVM_PORCH_BASE_URL)/pre-commit.porch.yaml?ref=$(AVM_PORCH_REF)"

.PHONY: pr-check
pr-check:
	@echo "Running PR check..."
	porch run ${TUI} -f "$(AVM_PORCH_BASE_URL)/pr-check.porch.yaml?ref=$(AVM_PORCH_REF)"

.PHONY: test-examples
test-examples:
	@echo "Testing examples..."
	porch run ${TUI} -f "$(AVM_PORCH_BASE_URL)/test-examples.porch.yaml?ref=$(AVM_PORCH_REF)"

.PHONY: tf-test-unit
tf-test-unit:
	@echo "Running terraform unit test..."
	AVM_TEST_TYPE="unit" porch run ${TUI} -f "$(AVM_PORCH_BASE_URL)/terraform-test.porch.yaml?ref=$(AVM_PORCH_REF)"

.PHONY: tf-test-integration
tf-test-integration:
	@echo "Running terraform integration test..."
	AVM_TEST_TYPE="integration" porch run ${TUI} -f "$(AVM_PORCH_BASE_URL)/terraform-test.porch.yaml?ref=$(AVM_PORCH_REF)"

.PHONY: globalsetup
globalsetup:
	@echo "Running global setup..."
	porch run ${TUI} -f "$(AVM_PORCH_BASE_URL)/global-setup.porch.yaml?ref=$(AVM_PORCH_REF)"

.PHONY: globalteardown
globalteardown:
	@echo "Running global teardown..."
	porch run ${TUI} -f "$(AVM_PORCH_BASE_URL)/global-teardown.porch.yaml?ref=$(AVM_PORCH_REF)"
