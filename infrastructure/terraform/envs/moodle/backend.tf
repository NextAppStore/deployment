terraform {
  required_version = ">= 1.5.0"

  backend "local" {
    path = "/var/lib/tf-state/moodle/terraform.tfstate"
  }

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4"
    }
  }
}
