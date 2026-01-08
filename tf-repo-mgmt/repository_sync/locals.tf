locals {
  label_list = csvdecode(file(var.github_labels_source_path))
  labels = { for label in local.label_list : label.Name => {
    name        = trimspace(label.Name)
    color       = label.HEX
    description = strcontains(label.Description, ":") ? trimspace(replace(split(":", split(".", label.Description)[0])[1], "this", "This")) : trimspace(label.Description)
  } }
}
