# ==============================================================================
# VARIABLES DE ACCESO Y AUTENTICACIÓN EN OPENSTACK
# ==============================================================================

variable "os_auth_url" {
  description = "URL del servicio de identidad Keystone v3 de OpenStack"
  type        = string
  default     = "http://156.35.95.9:5000/v3"
}

variable "os_user_name" {
  description = "Identificador / Nombre de usuario en OpenStack"
  type        = string
}

variable "os_password" {
  description = "Contraseña de acceso a OpenStack (marcada como sensible para no volcarla en logs)"
  type        = string
  sensitive   = true
}

variable "os_project_name" {
  description = "Nombre del proyecto o tenant asignado en OpenStack"
  type        = string
}

variable "os_user_domain_name" {
  description = "Dominio de identidad para el usuario en Keystone v3"
  type        = string
  default     = "Default"
}

variable "os_project_domain_name" {
  description = "Dominio de identidad para el proyecto en Keystone v3"
  type        = string
  default     = "Default"
}

variable "os_region" {
  description = "Región de OpenStack donde se aprovisionan los recursos"
  type        = string
  default     = "RegionOne"
}

# ==============================================================================
# VARIABLES DE CONFIGURACIÓN DE LA INFRAESTRUCTURA
# ==============================================================================

variable "external_network_name" {
  description = "Nombre de la red pública/externa de OpenStack para asignar IPs flotantes"
  type        = string
  default     = "public"
}

variable "image_name" {
  description = "Nombre de la imagen base (con soporte de seguridad activo)"
  type        = string
  default     = "Ubuntu-22.04"
}

variable "flavor_name" {
  description = "Sabor/tamaño de las instancias (suficiente para mocks)"
  type        = string
  default     = "ephym_small_2"
}

variable "keypair_name" {
  description = "Nombre del keypair SSH cargado en OpenStack para acceso inicial"
  type        = string
  default     = "Lab_project"
}

variable "project_prefix" {
  description = "Prefijo para los recursos para evitar nombres por defecto"
  type        = string
  default     = "cantabrico"
}