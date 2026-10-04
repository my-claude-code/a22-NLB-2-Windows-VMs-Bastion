terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id            = var.subscription_id
  skip_provider_registration = true
}

locals {
  # One entry per VM: Windows Server version -> image SKU
  vms = {
    win2019 = { name = "WinSrv2019", sku = "2019-Datacenter" }
    win2022 = { name = "WinSrv2022", sku = "2022-Datacenter" }
  }
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-nlb-bastion-vms"
  location = var.location
}

# ─── Network ────────────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-nlb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "vms" {
  name                 = "subnet-vms"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# Bastion requires a subnet with exactly this name and at least a /26.
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/26"]
}

# The VMs have no public IPs: RDP only from the Bastion subnet, HTTP from the LB/clients.
resource "azurerm_network_security_group" "vms" {
  name                = "nsg-vms"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "allow-rdp-from-bastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "10.0.2.0/26"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-http"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "vms" {
  subnet_id                 = azurerm_subnet.vms.id
  network_security_group_id = azurerm_network_security_group.vms.id
}

# ─── Bastion ────────────────────────────────────────────────────────────────

resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_bastion_host" "bastion" {
  name                = "bastion-nlb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Basic"

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

# ─── Standard Load Balancer ─────────────────────────────────────────────────

resource "azurerm_public_ip" "lb" {
  name                = "pip-lb"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "lb" {
  name                = "lb-windows"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "lb-frontend"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "pool" {
  name            = "backend-pool"
  loadbalancer_id = azurerm_lb.lb.id
}

resource "azurerm_lb_probe" "http" {
  name                = "probe-http"
  loadbalancer_id     = azurerm_lb.lb.id
  protocol            = "Http"
  port                = 80
  request_path        = "/"
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "http" {
  name                           = "rule-http"
  loadbalancer_id                = azurerm_lb.lb.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "lb-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.pool.id]
  probe_id                       = azurerm_lb_probe.http.id
  disable_outbound_snat          = true
}

# The VMs have no public IPs, so give them outbound internet through the LB frontend.
resource "azurerm_lb_outbound_rule" "outbound" {
  name                    = "outbound-all"
  loadbalancer_id         = azurerm_lb.lb.id
  protocol                = "All"
  backend_address_pool_id = azurerm_lb_backend_address_pool.pool.id

  frontend_ip_configuration {
    name = "lb-frontend"
  }
}

# ─── VMs (2019, 2022) — private IPs only ────────────────────────────────────

resource "azurerm_network_interface" "vm" {
  for_each            = local.vms
  name                = "nic-${each.value.name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.vms.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "vm" {
  for_each                = local.vms
  network_interface_id    = azurerm_network_interface.vm[each.key].id
  ip_configuration_name   = "ipconfig"
  backend_address_pool_id = azurerm_lb_backend_address_pool.pool.id
}

resource "azurerm_windows_virtual_machine" "vm" {
  for_each            = local.vms
  name                = each.value.name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password

  network_interface_ids = [azurerm_network_interface.vm[each.key].id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = each.value.sku
    version   = "latest"
  }
}

# ─── Extensions ───────────────────────────────────────────────────────────

resource "azurerm_virtual_machine_extension" "iis" {
  for_each             = local.vms
  name                 = "iis-setup"
  virtual_machine_id   = azurerm_windows_virtual_machine.vm[each.key].id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = jsonencode({
    commandToExecute = "powershell -ExecutionPolicy Unrestricted -EncodedCommand ${textencodebase64(file("${path.module}/scripts/iis.ps1"), "UTF-16LE")}"
  })

  timeouts {
    create = "30m"
  }
}
