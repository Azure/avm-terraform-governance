# Retry Flaky Example

This example deliberately fails its first `terraform apply` with a simulated Azure capacity
error, then succeeds on the following attempt.

It exists to exercise the retry steps in
[`test-examples.porch.yaml`](../../../../porch-configs/test-examples.porch.yaml): the first
apply matches the retryable error list and exits `90`, which gates
`Terraform Destroy and Retry (1)`. That step destroys, redeploys from scratch, and succeeds.
Without it the retry path is never executed in CI, because the mock modules never hit real
capacity failures.

Do not copy this example into a module repository.
