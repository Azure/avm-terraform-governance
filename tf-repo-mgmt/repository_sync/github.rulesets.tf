resource "github_repository_ruleset" "main" {
  name        = "Azure Verified Modules"
  repository  = data.github_repository.this.name
  target      = "branch"
  enforcement = "active"

  dynamic "bypass_actors" {
    for_each = contains(local.preview_ruleset_bypass_for_app_repos, data.github_repository.this.name) ? [1] : []
    content {
      actor_id    = local.github_avm_app_id
      actor_type  = "Integration"
      bypass_mode = "always"
    }
  }

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    creation                = true
    deletion                = true
    required_linear_history = true
    non_fast_forward        = true

    pull_request {
      dismiss_stale_reviews_on_push     = true
      require_code_owner_review         = true
      required_approving_review_count   = var.is_protected_repo ? 1 : 0
      require_last_push_approval        = var.is_protected_repo
      required_review_thread_resolution = true
    }
  }
}

resource "github_repository_ruleset" "tag_deny_version_without_v" {
  name        = "No version tags without 'v' prefix"
  repository  = data.github_repository.this.name
  target      = "tag"
  enforcement = "active"

  rules {
    creation = true
    update   = true
  }

  conditions {
    ref_name {
      include = ["refs/tags/[0123456789]*"]
      exclude = []
    }
  }
}

resource "github_repository_ruleset" "tag_prevent_delete_version_tags" {
  name        = "Must not delete/update version tags"
  repository  = data.github_repository.this.name
  target      = "tag"
  enforcement = "active"

  rules {
    update           = true
    deletion         = true
    non_fast_forward = true
  }


  conditions {
    ref_name {
      include = ["refs/tags/v[0123456789]*"]
      exclude = []
    }
  }
}
