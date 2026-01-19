resource "github_actions_variable" "copilot_firewall_allow_list" {
  variable_name = var.github_copilot_agent_firewall_allow_list_variable_name
  repository    = github_repository.this.name
  value         = join(",", var.github_copilot_agent_firewall_allow_list)
}