PORCH_BASE_URL := git::https://github.com/Azure/avm-terraform-governance/main//porch-configs

.PHONY: help
help:
	@echo "please use 'make <target>'"

.PHONY: pre-commit
pre-commit:
	@echo "Running pre-commit..."
	porch run -f "$(PORCH_BASE_URL)/pre-commit.porch.yaml"
