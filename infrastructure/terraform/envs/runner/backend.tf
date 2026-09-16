terraform {
  required_version = ">= 1.5.0"

  # Local state, kept on the operator's machine that runs `terraform apply`
  # for this env. This is the bootstrapping VM the staging workflow's
  # `runs-on: self-hosted` job executes on, so (unlike staging) it cannot
  # apply itself from GitHub Actions — it must be created once from a
  # laptop/VPN-connected machine. See README.md for the one-time setup.
  backend "local" {
    path = "/var/lib/tf-state/runner/terraform.tfstate"
  }

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
  }
}
