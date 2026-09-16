# github-runner: SSH (22) only. The runner has no inbound service of its
# own — it polls GitHub outbound for jobs — so unlike appstore-deploy it
# does not need 80/443 ingress.
resource "openstack_networking_secgroup_v2" "github_runner" {
  name        = "github-runner"
  description = "SSH ingress only for the self-hosted GitHub Actions runner VM"
}

resource "openstack_networking_secgroup_rule_v2" "ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.github_runner.id
}

resource "openstack_networking_secgroup_rule_v2" "ssh_v6" {
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.github_runner.id
}

module "vm" {
  source = "../../modules/openstack_vm"

  name         = "github-runner"
  image        = "Ubuntu 24.04"
  flavor       = "gp1.medium"
  public_key   = var.ssh_public_key
  network_name = "DHBWV6"

  # Same reasoning as staging: DHBWV6 hands out a routable fixed IPv6
  # address directly, so no floating IP is needed for outbound-only traffic
  # plus VPN-reachable SSH.
  assign_floating_ip = false

  security_groups = ["default", openstack_networking_secgroup_v2.github_runner.name]

  docker_data_volume_size_gb = 0

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    github_repo           = var.github_repo
    github_runner_token   = var.github_runner_token
    github_runner_version = var.github_runner_version
    runner_labels         = var.runner_labels
  })

  metadata = {
    env  = "runner"
    role = "github-actions-runner"
  }
}

output "vm_ip" {
  value = module.vm.vm_ip
}
