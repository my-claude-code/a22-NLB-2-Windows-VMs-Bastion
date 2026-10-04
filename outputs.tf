output "lb_public_ip" {
  description = "Browse to http://<ip> — each refresh may land on a different server"
  value       = azurerm_public_ip.lb.ip_address
}

output "vm_private_ips" {
  description = "Private IPs of the VMs (connect through Bastion in the Azure portal)"
  value       = { for k, v in local.vms : v.name => azurerm_network_interface.vm[k].private_ip_address }
}

output "bastion_name" {
  description = "Portal -> VM -> Connect -> Bastion"
  value       = azurerm_bastion_host.bastion.name
}
