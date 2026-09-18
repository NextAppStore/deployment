# moodle-deploy: SSH (22) for Ansible/operator access, HTTP (80) / HTTPS
# (443) for the host nginx reverse-proxy in front of the Moodle container.
resource "openstack_networking_secgroup_v2" "moodle_deploy" {
  name        = "moodle-deploy"
  description = "SSH + HTTP/HTTPS ingress for the Moodle Docker VM (nginx reverse proxy + Ansible)"
}

resource "openstack_networking_secgroup_rule_v2" "ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.moodle_deploy.id
}

resource "openstack_networking_secgroup_rule_v2" "http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.moodle_deploy.id
}

resource "openstack_networking_secgroup_rule_v2" "https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.moodle_deploy.id
}

# DHBWV6 hands out a real routable IPv6 address (no floating IP / IPv4 is
# NAT'd and not reachable from outside), so SSH/HTTP/HTTPS need IPv6
# ingress rules too, not just the IPv4 ones above.
resource "openstack_networking_secgroup_rule_v2" "ssh_v6" {
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.moodle_deploy.id
}

resource "openstack_networking_secgroup_rule_v2" "http_v6" {
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.moodle_deploy.id
}

resource "openstack_networking_secgroup_rule_v2" "https_v6" {
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "::/0"
  security_group_id = openstack_networking_secgroup_v2.moodle_deploy.id
}

module "vm" {
  source = "../../modules/openstack_vm"

  name         = "moodle-docker"
  image        = "Ubuntu 24.04"
  flavor       = "gp1.large"
  public_key   = var.ssh_public_key
  network_name = "DHBWV6"

  # DHBWV6 hands out a routable fixed IPv6 address directly (IPv4 on this
  # network is NAT'd and not reachable from outside), so no floating IP is
  # needed — deploy reaches the VM over its fixed IPv6 (requires the
  # operator to be on DHBW's network / VPN).
  assign_floating_ip = false

  security_groups = ["default", openstack_networking_secgroup_v2.moodle_deploy.name]

  docker_data_volume_size_gb = 0

  metadata = {
    env  = "moodle"
    role = "docker"
  }
}

output "vm_ip" {
  value = module.vm.vm_ip
}
