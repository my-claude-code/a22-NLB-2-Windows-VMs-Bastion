# a22 — 2 Windows Servers behind a Standard Load Balancer, with Bastion

Two Windows Server VMs (2019, 2022) with **private IPs only**, behind an Azure **Standard** Load Balancer. Azure Bastion is used for RDP. A Custom Script Extension installs IIS; the home page shows the server's OS and private IP.

## Architecture

```
rg-nlb-bastion-vms (West Europe)
  vnet-nlb (10.0.0.0/16)
    subnet-vms (10.0.1.0/24)          nsg-vms (RDP from Bastion subnet, HTTP 80)
    AzureBastionSubnet (10.0.2.0/26)  bastion-nlb ── pip-bastion
  lb-windows (Standard) ── pip-lb ── :80 ──► backend pool (private IPs)
       ├── WinSrv2019
       └── WinSrv2022
  LB outbound rule: gives the VMs outbound internet via the LB public IP
```

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# set subscription_id and admin_password
terraform init
terraform apply
```

- Browse to `http://<lb_public_ip>` — shows the OS name, server name and private IP of the server that answered.
- RDP: Azure portal → VM → **Connect** → **Bastion** (user `azureuser` by default).

Providers are not auto-registered (`skip_provider_registration = true`); register them once per subscription:
`az provider register --namespace Microsoft.Compute` (also `Microsoft.Network`, `Microsoft.Storage`).

## Variables

| Variable | Default | Description |
|---|---|---|
| `subscription_id` | — | Azure subscription ID (**required**) |
| `admin_password` | — | VM admin password (**required**, no default) |
| `location` | `West Europe` | Azure region |
| `admin_username` | `azureuser` | VM admin username |
| `vm_size` | `Standard_B2s_v2` | VM size |

## Outputs

| Output | Description |
|---|---|
| `lb_public_ip` | Load balancer public IP |
| `vm_private_ips` | Private IP per VM |
| `bastion_name` | Bastion host name |
