output "vm_ip" {
  description = "Address used to reach the VM: the floating IP when allocated, otherwise the fixed IPv6 on the project network (IPv4 is NAT'd/not routed)."
  value = var.assign_floating_ip ? (
    openstack_networking_floatingip_v2.fip[0].address
    ) : (
    openstack_compute_instance_v2.vm.network[0].fixed_ip_v6
  )
}

output "vm_name" {
  value = openstack_compute_instance_v2.vm.name
}

output "key_pair_name" {
  value = openstack_compute_keypair_v2.deploy.name
}