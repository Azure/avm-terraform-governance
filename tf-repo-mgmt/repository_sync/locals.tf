locals {
  feature_flags = { for k, v in var.feature_flags : k => contains(v, var.github_repository_name) }

  # This is the suffix to append to the subject claim for the job_workflow_ref claim.
  # It is appended to the subject claim when the repository is in-scope for the preview
  # of the GitHub Actions OIDC subject claim customization feature.
  github_job_workflow_ref_suffix = local.feature_flags.preview_github_actions_oidc_subject_claim_customization ? var.github_job_workflow_ref_suffix : ""
}

locals {
  label_list = csvdecode(file(var.github_labels_source_path))
  labels = { for label in local.label_list : label.Name => {
    name        = label.Name
    color       = label.HEX
    description = strcontains(label.Description, ":") ? trimspace(replace(split(":", split(".", label.Description)[0])[1], "this", "This")) : label.Description
  } }
}
