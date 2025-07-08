resource "github_issue_label" "this" {
  for_each = var.labels

  repository  = github_repository.this.name
  name        = each.value.name
  color       = each.value.color
  description = substr(each.value.description, 0, 100)
}
