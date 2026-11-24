terraform {
  required_version = ">= 1.10, < 2.0"
  # Same S3 state bucket as every platform (vms/azure/<name>/terraform.tfstate).
  backend "s3" {}
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Credentials and subscription come from ARM_* (OIDC in GitHub Actions or an operator certificate
# locally). The resource providers are registered once per subscription.
provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
}

data "azurerm_client_config" "current" {}

locals {
  platform      = jsondecode(file("${path.module}/platform.json"))
  os            = local.platform.os[var.os]
  windows       = local.os.family == "windows"
  sizes         = jsondecode(file("${path.module}/sizes.json"))
  instance_type = var.instance_type != "" ? var.instance_type : local.sizes[local.os.family][var.size]
  # Inventory from before image versions were recorded is the OS's first (original) release.
  image_version = coalesce(var.image_version, local.os.versions[0])
  # Every resource of one VM lives in its own resource group with fixed names, so recovery
  # (adopt.sh) and teardown find them without guessing.
  resource_group = "cf-vm-${var.name}"
  resource_name  = "cf-${var.name}"
  tags = merge(var.cloud_tags, var.request_id == "" ? {} : { "cf:request-id" = var.request_id }, {
    "cf:poc"  = "true"
    "cf:vm"   = var.name
    "cf:team" = var.team
  })
  # Each release has its own definition, so latest can never cross releases.
  image_name = local.os.galleryImages[local.image_version]
  image_id   = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/cf-images/providers/Microsoft.Compute/galleries/cfimages/images/${local.image_name}"
}

resource "azurerm_resource_group" "vm" {
  name     = local.resource_group
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "vm" {
  name                = local.resource_name
  resource_group_name = azurerm_resource_group.vm.name
  location            = azurerm_resource_group.vm.location
  address_space       = ["10.80.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "vm" {
  name                 = local.resource_name
  resource_group_name  = azurerm_resource_group.vm.name
  virtual_network_name = azurerm_virtual_network.vm.name
  address_prefixes     = ["10.80.1.0/24"]
}

resource "azurerm_network_security_group" "vm" {
  name                = local.resource_name
  resource_group_name = azurerm_resource_group.vm.name
  location            = azurerm_resource_group.vm.location
  security_rule {
    name                       = "ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  tags = local.tags
}

# Static: the address survives stop (deallocate) and resize.
resource "azurerm_public_ip" "vm" {
  name                = local.resource_name
  resource_group_name = azurerm_resource_group.vm.name
  location            = azurerm_resource_group.vm.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "vm" {
  name                = local.resource_name
  resource_group_name = azurerm_resource_group.vm.name
  location            = azurerm_resource_group.vm.location
  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
  tags = local.tags
}

resource "azurerm_network_interface_security_group_association" "vm" {
  network_interface_id      = azurerm_network_interface.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# Azure requires an admin key (Linux) or password (Windows). Logins use the SSH CA only: the fry
# `access` stage turns off authorized_keys on Linux, and on Windows sets the password the IDP shows
# the team (Secrets Manager compute-factory/vm/<name>), so these launch credentials stop working.
resource "tls_private_key" "admin" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "random_password" "admin" {
  count            = local.windows ? 1 : 0
  length           = 24
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
  override_special = "!#()*+,-.:=?@[]_{}~"
}

moved {
  from = azurerm_linux_virtual_machine.vm
  to   = azurerm_linux_virtual_machine.vm[0]
}

resource "azurerm_linux_virtual_machine" "vm" {
  count                           = local.windows ? 0 : 1
  name                            = local.resource_name
  resource_group_name             = azurerm_resource_group.vm.name
  location                        = azurerm_resource_group.vm.location
  size                            = local.instance_type
  admin_username                  = local.os.sshUser
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.vm.id]
  source_image_id                 = local.image_id
  admin_ssh_key {
    username   = local.os.sshUser
    public_key = tls_private_key.admin.public_key_openssh
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
  tags = merge(local.tags, { "cf:requested-by" = var.requested_by })
  lifecycle {
    # Creation-time choices: a newer bake or a re-created key after adoption must not replace the VM.
    ignore_changes = [source_image_id, admin_ssh_key]
  }
}

resource "azurerm_windows_virtual_machine" "vm" {
  count               = local.windows ? 1 : 0
  name                = local.resource_name
  resource_group_name = azurerm_resource_group.vm.name
  location            = azurerm_resource_group.vm.location
  # Windows computer names are at most 15 characters; baseline sets the same name.
  computer_name         = trimsuffix(substr(var.name, 0, 15), "-")
  size                  = local.instance_type
  admin_username        = local.os.sshUser
  admin_password        = random_password.admin[0].result
  network_interface_ids = [azurerm_network_interface.vm.id]
  source_image_id       = local.image_id
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
  tags = merge(local.tags, { "cf:requested-by" = var.requested_by })
  lifecycle {
    # Creation-time choices; the access stage owns the password after launch.
    ignore_changes = [source_image_id, admin_password]
  }
}
