variable "ssh_public_key" {
  description = "SSH public key for the runner VM's deploy keypair. Operator-supplied (e.g. via TF_VAR_ssh_public_key) — no CI pipeline can derive this one, since the runner is what CI runs on."
  type        = string
}

variable "github_repo" {
  description = "GitHub \"owner/repo\" the runner registers itself against."
  type        = string
  default     = "NextAppStore/deployment"
}

variable "github_runner_token" {
  description = <<-EOT
    A short-lived (~1h) GitHub Actions runner registration token, minted
    just before `terraform apply` via:
      gh api -X POST repos/NextAppStore/deployment/actions/runners/registration-token --jq .token
    Never stored in state beyond this apply's user_data rendering; not an
    org/repo secret and not reusable after expiry or first use.
  EOT
  type        = string
  sensitive   = true
}

variable "github_runner_version" {
  description = "actions/runner release version (without the leading v) baked into cloud-init."
  type        = string
  default     = "2.319.1"
}

variable "runner_labels" {
  description = "Extra labels attached to the runner in addition to the implicit self-hosted/OS/arch ones."
  type        = string
  default     = "staging-deploy"
}
