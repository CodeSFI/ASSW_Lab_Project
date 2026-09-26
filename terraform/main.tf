# ==============================================================================
# CONFIGURACIÓN DEL PROVEEDOR Y FUENTES DE DATOS (DATA SOURCES)
# ==============================================================================

# ------------------------------------------------------------------------------
# Configuración global: fija proveedor y versiones para un despliegue reproducible.
# ------------------------------------------------------------------------------
terraform {
  required_providers {
    # Plugin oficial para interactuar con las APIs de OpenStack (Compute, Neutron, Glance, etc.)
    openstack = {
      source = "terraform-provider-openstack/openstack"
      # Exige una versión mínima del proveedor para garantizar compatibilidad con las APIs modernas
      version = ">= 3.2.0"
    }
  }
}

# ------------------------------------------------------------------------------
# Proveedor parametrizado con variables sensibles (valor real en terraform.tfvars,
# ignorado por Git). Admite Application Credentials o usuario/contraseña.
# ------------------------------------------------------------------------------
provider "openstack" {
  auth_url = var.os_auth_url

  # Application Credentials take priority if provided
  application_credential_id     = var.os_application_credential_id != "" ? var.os_application_credential_id : null
  application_credential_secret = var.os_application_credential_secret != "" ? var.os_application_credential_secret : null

  # Fallback to username/password
  user_name           = var.os_application_credential_id != "" ? null : var.os_user_name
  password            = var.os_application_credential_id != "" ? null : var.os_password
  tenant_name         = var.os_application_credential_id != "" ? null : var.os_project_name
  user_domain_name    = var.os_application_credential_id != "" ? null : var.os_user_domain_name
  project_domain_name = var.os_application_credential_id != "" ? null : var.os_project_domain_name
  region              = var.os_region
}

# ------------------------------------------------------------------------------
# Data Source: red externa (por nombre, sin UUIDs fijos).
# ------------------------------------------------------------------------------
data "openstack_networking_network_v2" "external_network" {
  # Nombre definido mediante variable (ej. "ext-net" o "public") para evitar valores fijos
  name = var.external_network_name
}

# ------------------------------------------------------------------------------
# Data Source: imagen base (por nombre; most_recent selecciona la última revisión).
# ------------------------------------------------------------------------------
data "openstack_images_image_v2" "base_image" {
  name = var.image_name
  # En caso de haber varias revisiones de la misma imagen, selecciona la más reciente
  most_recent = true
}

# ------------------------------------------------------------------------------
# Data Source: flavor (tamaño de VM parametrizado desde variables).
# ------------------------------------------------------------------------------
data "openstack_compute_flavor_v2" "default_flavor" {
  name = var.flavor_name
}