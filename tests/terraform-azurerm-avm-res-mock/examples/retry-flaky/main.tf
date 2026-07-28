provider "azurerm" {
  features {}
}

module "test" {
  source = "../../"

  location                 = "westus3"
  create_example_resources = var.create_example_resources
}

# Fails the first apply with a message that matches the retryable error list in
# test-examples.porch.yaml, then succeeds once the marker exists. The marker is written
# into the example directory, which porch copies to a fresh temp directory for every
# run, so each run fails exactly once and is then recovered by the retry steps.
resource "terraform_data" "simulated_capacity_failure" {
  provisioner "local-exec" {
    command     = <<-EOT
      if [ -f "${path.module}/.avm-retry-marker" ]; then
        echo "Retry marker found, simulated capacity failure cleared."
        exit 0
      fi

      touch "${path.module}/.avm-retry-marker"
      echo "Error: ZonalAllocationFailed. Allocation failed. Simulated capacity failure raised by the retry-flaky example." 1>&2
      exit 1
    EOT
    interpreter = ["/bin/sh", "-c"]
  }
}
