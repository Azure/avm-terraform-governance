# Enables Dependabot alerts on the repository. This is a prerequisite for
# Dependabot security updates (below) and requires the dependency graph, which
# is enabled by default for public repositories.
resource "github_repository_vulnerability_alerts" "this" {
  count      = var.repository_creation_mode_enabled ? 0 : 1
  repository = github_repository.this.name
  enabled    = true
}

# Enables Dependabot security updates so that GitHub will automatically open
# pull requests to upgrade dependencies with known vulnerabilities.
#
# Docs: https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/configuring-dependabot-security-updates
resource "github_repository_dependabot_security_updates" "this" {
  count      = var.repository_creation_mode_enabled ? 0 : 1
  repository = github_repository.this.name
  enabled    = true

  depends_on = [github_repository_vulnerability_alerts.this]
}
