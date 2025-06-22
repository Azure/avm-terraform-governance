PORCH_BASE_URL := git::https://github.com/Azure/avm-terraform-governance//porch-configs
PORCH_REF := main

.PHONY: help
help:
	@echo "please use 'make <target>'"

.PHONY: pre-commit
pre-commit:
	@echo "Running pre-commit..."
	porch run ${TUI} -f "$(PORCH_BASE_URL)/pre-commit.porch.yaml?ref=$(PORCH_REF)"

.PHONY: pr-check
pr-check:
	@echo "Running PR check..."
	porch run ${TUI} -f "$(PORCH_BASE_URL)/pr-check.porch.yaml?ref=$(PORCH_REF)"

.PHONY: test-examples
test-examples:
	@echo "Testing examples..."
	porch run ${TUI} -f "$(PORCH_BASE_URL)/test-examples.porch.yaml?ref=$(PORCH_REF)"

.PHONY: tf-test-unit
tf-test-unit:
	@echo "Running terraform unit test..."
	TEST_TYPE="unit" porch run ${TUI} -f "$(PORCH_BASE_URL)/terraform-test.porch.yaml?ref=$(PORCH_REF)"

.PHONY: tf-test-integration
tf-test-integration:
	@echo "Running terraform integration test..."
	TEST_TYPE="integration" porch run ${TUI} -f "$(PORCH_BASE_URL)/terraform-test.porch.yaml?ref=$(PORCH_REF)"
