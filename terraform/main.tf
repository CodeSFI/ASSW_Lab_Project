# ==============================================================================
# CONFIGURACIÓN DEL PROVEEDOR Y FUENTES DE DATOS (DATA SOURCES)
# ==============================================================================

# ------------------------------------------------------------------------------
# Bloque de configuración global de Terraform
# Justificación: Fija las dependencias necesarias para asegurar que el despliegue
# sea reproducible en cualquier máquina sin sorpresas de compatibilidad.
# ------------------------------------------------------------------------------
terraform {
  required_providers {
    # Plugin oficial para interactuar con las APIs de OpenStack (Compute, Neutron, Glance, etc.)
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      # Exige una versión mínima del proveedor para garantizar compatibilidad con las APIs modernas
      version = ">= 3.2.0"
    }
  }
}

# ------------------------------------------------------------------------------
# Proveedor de OpenStack parametrizado mediante variables
# Justificación: Al alimentar el bloque con variables declaradas como sensibles,
# no se exponen contraseñas en claro dentro del repositorio. Los valores reales
# se suministran localmente mediante el archivo 'terraform.tfvars' (ignorado por Git).
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
# Data Source: Red Externa
# Rol: Localiza la red pública preexistente en el clúster de OpenStack.
# Justificación: Permite vincular el router perimetral y aprovisionar las IPs 
# flotantes sin forzar un identificador estático (UUID). Facilita que otro evaluador 
# o usuario solo tenga que cambiar el nombre de la red externa en su archivo de variables.
# ------------------------------------------------------------------------------
data "openstack_networking_network_v2" "external_network" {
  # Nombre definido mediante variable (ej. "ext-net" o "public") para evitar valores fijos
  name = var.external_network_name
}

# ------------------------------------------------------------------------------
# Data Source: Imagen Base del Sistema Operativo
# Rol: Consulta el catálogo de Glance para obtener el ID de la imagen del sistema operativo.
# Justificación: Se evita fijar UUIDs literales en el código. Al filtrar por nombre 
# (var.image_name) y activar 'most_recent', se garantiza el uso de una versión 
# actualizada y con soporte de seguridad activo, tal y como exige el proyecto.
# ------------------------------------------------------------------------------
data "openstack_images_image_v2" "base_image" {
  name        = var.image_name
  # En caso de haber varias revisiones de la misma imagen, selecciona la más reciente
  most_recent = true
}

# ------------------------------------------------------------------------------
# Data Source: Sabor de Cómputo (Flavor)
# Rol: Obtiene las especificaciones de hardware virtual (vCPU, RAM, disco).
# Justificación: Desacopla la plantilla de la infraestructura concreta del alumno.
# Permite parametrizar el tamaño de las máquinas desde variables (ej. "m1.tiny" o "m1.small")
# facilitando ajustar el consumo de recursos a la cuota disponible de cada entorno.
# ------------------------------------------------------------------------------
data "openstack_compute_flavor_v2" "default_flavor" {
  name = var.flavor_name
}