# ==============================================================================
# DEFINICIÓN DE INSTANCIAS (MÁQUINAS VIRTUALES) EN OPENSTACK
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. VM: Balanceador / WAF (DMZ)
# Único nodo expuesto a Internet: centraliza terminación TLS e inspección WAF.
# ------------------------------------------------------------------------------
# Puerto explícito en la red DMZ con IP estática
resource "openstack_networking_port_v2" "port_lb_dmz" {
  name           = "${var.project_prefix}-port-lb-dmz"
  network_id     = openstack_networking_network_v2.dmz_net.id
  admin_state_up = true
  security_group_ids = [
    openstack_networking_secgroup_v2.secgroup_lb.id
  ]

  # Asignación determinista de IP en la DMZ para enrutamiento predecible
  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.dmz_subnet.id
    ip_address = "10.10.10.10"
  }
}

# Puerto explícito en la red de gestión para tareas de administración
resource "openstack_networking_port_v2" "port_lb_mgmt" {
  name           = "${var.project_prefix}-port-lb-mgmt"
  network_id     = openstack_networking_network_v2.mgmt_net.id
  admin_state_up = true
  security_group_ids = [
    openstack_networking_secgroup_v2.secgroup_internal.id
  ]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.mgmt_subnet.id
    ip_address = "10.10.99.10"
  }
}

resource "openstack_compute_instance_v2" "lb_proxy" {
  # Timeout de creacion ampliado: el cluster del lab tarda mas de 1h en provisionar.
  timeouts {
    create = "2h"
    update = "2h"
  }

  # Nombre contextualizado con prefijo para evitar colisiones
  name = "${var.project_prefix}-lb-proxy-01"

  # Asocia la imagen base del SO (referenciada dinámicamente en main.tf para no usar IDs estáticos)
  image_id = data.openstack_images_image_v2.base_image.id

  # Sabor/recursos de hardware (vCPUs/RAM) parametrizado para evitar agotar cuotas
  flavor_id = data.openstack_compute_flavor_v2.default_flavor.id

  # Clave SSH pública inyectada por cloud-init para acceso administrativo inicial
  key_pair = var.keypair_name

  # Interfaz 1: Red DMZ pública (10.10.10.0/24) por donde recibe el tráfico balanceado
  network {
    port = openstack_networking_port_v2.port_lb_dmz.id
  }

  # Interfaz 2: Red de Gestión (10.10.99.0/24) para tareas de provisión interna vía Ansible
  network {
    port = openstack_networking_port_v2.port_lb_mgmt.id
  }
}

# ------------------------------------------------------------------------------
# 2. VM: Bastion Host (Gestión / Out-of-Band)
# Único punto de entrada SSH: toda la administración salta obligatoriamente por él.
# ------------------------------------------------------------------------------
# Puerto explícito en la red MGMT con IP estática para recibir la IP flotante
resource "openstack_networking_port_v2" "port_bastion_mgmt" {
  name           = "${var.project_prefix}-port-bastion-mgmt"
  network_id     = openstack_networking_network_v2.mgmt_net.id
  admin_state_up = true
  security_group_ids = [
    openstack_networking_secgroup_v2.secgroup_bastion.id,
    openstack_networking_secgroup_v2.secgroup_internal.id
  ]

  # IP fija de gestión asignada de forma determinista al bastión
  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.mgmt_subnet.id
    ip_address = "10.10.99.20"
  }
}

resource "openstack_compute_instance_v2" "bastion" {
  # Timeout de creacion ampliado: el cluster del lab tarda mas de 1h en provisionar.
  timeouts {
    create = "2h"
    update = "2h"
  }

  # Nombre representativo del rol de operaciones con prefijo parametrizado
  name      = "${var.project_prefix}-bastion-ops-01"
  image_id  = data.openstack_images_image_v2.base_image.id
  flavor_id = data.openstack_compute_flavor_v2.default_flavor.id
  key_pair  = var.keypair_name

  # Conectado únicamente a la red de gestión (10.10.99.0/24); desde aquí enruta
  # el tráfico administrativo hacia el resto de las máquinas
  network {
    port = openstack_networking_port_v2.port_bastion_mgmt.id
  }
}

# ------------------------------------------------------------------------------
# 3. VM: Nodo de Aplicación 01 (Capa Privada Replicada)
# Nodo mock a alta disponibilidad; habla con la DB por la red de datos privada.
# ------------------------------------------------------------------------------
# Puerto en red de aplicación (comunicación con el balanceador)
resource "openstack_networking_port_v2" "port_app1_net" {
  name           = "${var.project_prefix}-port-app-net-01"
  network_id     = openstack_networking_network_v2.app_net.id
  admin_state_up = true
  security_group_ids = [
    openstack_networking_secgroup_v2.secgroup_internal.id
  ]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.app_subnet.id
    ip_address = "10.10.20.11"
  }
}

# Puerto en red de datos privada (enlace directo exclusivo con la DB)
resource "openstack_networking_port_v2" "port_app1_data" {
  name           = "${var.project_prefix}-port-app-data-01"
  network_id     = openstack_networking_network_v2.data_net.id
  admin_state_up = true
  security_group_ids = [
    openstack_networking_secgroup_v2.secgroup_internal.id
  ]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.data_subnet.id
    ip_address = "10.10.30.11"
  }
}

# Puerto en red de gestión (para provisión mediante Ansible desde el bastión)
resource "openstack_networking_port_v2" "port_app1_mgmt" {
  name           = "${var.project_prefix}-port-app-mgmt-01"
  network_id     = openstack_networking_network_v2.mgmt_net.id
  admin_state_up = true
  security_group_ids = [
    openstack_networking_secgroup_v2.secgroup_internal.id
  ]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.mgmt_subnet.id
    ip_address = "10.10.99.21"
  }
}

resource "openstack_compute_instance_v2" "app_node_01" {
  # Timeout de creacion ampliado: el cluster del lab tarda mas de 1h en provisionar.
  timeouts {
    create = "2h"
    update = "2h"
  }

  name      = "${var.project_prefix}-app-node-01"
  image_id  = data.openstack_images_image_v2.base_image.id
  flavor_id = data.openstack_compute_flavor_v2.default_flavor.id
  key_pair  = var.keypair_name

  # Interfaz 1: Red de aplicación privada (10.10.20.0/24) para comunicar con el LB
  network {
    port = openstack_networking_port_v2.port_app1_net.id
  }

  # Interfaz 2: Red de datos privada (10.10.30.0/24) exclusiva para consultar la base de datos
  network {
    port = openstack_networking_port_v2.port_app1_data.id
  }

  # Interfaz 3: Red de gestión (10.10.99.0/24) para ejecución de playbooks de Ansible
  network {
    port = openstack_networking_port_v2.port_app1_mgmt.id
  }
}

# ------------------------------------------------------------------------------
# 4. VM: Nodo de Aplicación 02 (Capa Privada Replicada)
# Réplica del nodo 01: el clúster tolera la caída de un backend sin cortar servicio.
# ------------------------------------------------------------------------------
# Puerto en red de aplicación
resource "openstack_networking_port_v2" "port_app2_net" {
  name           = "${var.project_prefix}-port-app-net-02"
  network_id     = openstack_networking_network_v2.app_net.id
  admin_state_up = true
  security_group_ids = [
    openstack_networking_secgroup_v2.secgroup_internal.id
  ]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.app_subnet.id
    ip_address = "10.10.20.12"
  }
}

# Puerto en red de datos privada
resource "openstack_networking_port_v2" "port_app2_data" {
  name           = "${var.project_prefix}-port-app-data-02"
  network_id     = openstack_networking_network_v2.data_net.id
  admin_state_up = true
  security_group_ids = [
    openstack_networking_secgroup_v2.secgroup_internal.id
  ]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.data_subnet.id
    ip_address = "10.10.30.12"
  }
}

# Puerto en red de gestión
resource "openstack_networking_port_v2" "port_app2_mgmt" {
  name           = "${var.project_prefix}-port-app-mgmt-02"
  network_id     = openstack_networking_network_v2.mgmt_net.id
  admin_state_up = true
  security_group_ids = [
    openstack_networking_secgroup_v2.secgroup_internal.id
  ]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.mgmt_subnet.id
    ip_address = "10.10.99.22"
  }
}

resource "openstack_compute_instance_v2" "app_node_02" {
  # Timeout de creacion ampliado: el cluster del lab tarda mas de 1h en provisionar.
  timeouts {
    create = "2h"
    update = "2h"
  }

  name      = "${var.project_prefix}-app-node-02"
  image_id  = data.openstack_images_image_v2.base_image.id
  flavor_id = data.openstack_compute_flavor_v2.default_flavor.id
  key_pair  = var.keypair_name

  # Interfaz 1: Red de aplicación privada (10.10.20.0/24) para comunicar con el LB
  network {
    port = openstack_networking_port_v2.port_app2_net.id
  }

  # Interfaz 2: Red de datos privada (10.10.30.0/24) exclusiva para consultar la base de datos
  network {
    port = openstack_networking_port_v2.port_app2_data.id
  }

  # Interfaz 3: Red de gestión (10.10.99.0/24) para ejecución de playbooks de Ansible
  network {
    port = openstack_networking_port_v2.port_app2_mgmt.id
  }
}

# ------------------------------------------------------------------------------
# 5. VM: Base de Datos (Capa Aislada / Data)
# PostgreSQL en data_net (10.10.30.0/24), red cerrada sin gateway: compartida solo
# con los app_nodes, sin ruta a Internet (ni exfiltración ni 5432 expuesto).
# ------------------------------------------------------------------------------
# Puerto en red de datos (comunicación exclusiva con los app_nodes)
resource "openstack_networking_port_v2" "port_db_data" {
  name           = "${var.project_prefix}-port-db-data"
  network_id     = openstack_networking_network_v2.data_net.id
  admin_state_up = true
  security_group_ids = [
    openstack_networking_secgroup_v2.secgroup_internal.id
  ]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.data_subnet.id
    ip_address = "10.10.30.50"
  }
}

# Puerto en red de gestión (mantenimiento y aprovisionamiento vía Ansible)
resource "openstack_networking_port_v2" "port_db_mgmt" {
  name           = "${var.project_prefix}-port-db-mgmt"
  network_id     = openstack_networking_network_v2.mgmt_net.id
  admin_state_up = true
  security_group_ids = [
    openstack_networking_secgroup_v2.secgroup_internal.id
  ]

  fixed_ip {
    subnet_id  = openstack_networking_subnet_v2.mgmt_subnet.id
    ip_address = "10.10.99.50"
  }
}

resource "openstack_compute_instance_v2" "db_core" {
  # Timeout de creacion ampliado: el cluster del lab tarda mas de 1h en provisionar.
  timeouts {
    create = "2h"
    update = "2h"
  }

  name      = "${var.project_prefix}-db-core-01"
  image_id  = data.openstack_images_image_v2.base_image.id
  flavor_id = data.openstack_compute_flavor_v2.default_flavor.id
  key_pair  = var.keypair_name

  # Interfaz 1: Red de datos aislada (10.10.30.0/24) exclusiva con los app_nodes
  network {
    port = openstack_networking_port_v2.port_db_data.id
  }

  # Interfaz 2: Red de gestión (10.10.99.0/24) para mantenimiento y provisión de Ansible
  network {
    port = openstack_networking_port_v2.port_db_mgmt.id
  }
}

# ==============================================================================
# IPs flotantes PREEXISTENTES (ya reservadas en Horizon, parametrizadas por
# variable): se asocian sin solicitar reserva nueva a Neutron (evita OverQuota).
# ==============================================================================

# Asocia la IP pública al puerto de la interfaz de gestión del Bastión
resource "openstack_networking_floatingip_associate_v2" "fip_bastion_assoc" {
  floating_ip = var.bastion_floating_ip
  port_id     = openstack_networking_port_v2.port_bastion_mgmt.id
  # Espera a que la subred MGMT este enrutada al exterior (evita
  # "ExternalGatewayForFloatingIPNotFound" al asociar la FIP demasiado pronto).
  depends_on = [openstack_networking_router_interface_v2.router_mgmt]
}

resource "openstack_networking_floatingip_associate_v2" "fip_lb_assoc" {
  floating_ip = var.lb_floating_ip
  port_id     = openstack_networking_port_v2.port_lb_dmz.id
  # Espera a que la subred DMZ este enrutada al exterior antes de asociar la FIP.
  depends_on = [openstack_networking_router_interface_v2.router_dmz]
}

resource "openstack_networking_floatingip_associate_v2" "fip_lb_assoc" {
  floating_ip = var.lb_floating_ip
  port_id     = openstack_networking_port_v2.port_lb_dmz.id
}

# ==============================================================================
# OUTPUTS DE VERIFICACIÓN DE INSTANCIAS
# ==============================================================================

output "instances_summary" {
  description = "Resumen de todas las VMs creadas con sus IPs principales"
  value = {
    lb_proxy = {
      id      = openstack_compute_instance_v2.lb_proxy.id
      name    = openstack_compute_instance_v2.lb_proxy.name
      status  = openstack_compute_instance_v2.lb_proxy.power_state
      dmz_ip  = "10.10.10.10"
      mgmt_ip = "10.10.99.10"
    }
    bastion = {
      id          = openstack_compute_instance_v2.bastion.id
      name        = openstack_compute_instance_v2.bastion.name
      status      = openstack_compute_instance_v2.bastion.power_state
      mgmt_ip     = "10.10.99.20"
      floating_ip = var.bastion_floating_ip
    }
    app_node_01 = {
      id      = openstack_compute_instance_v2.app_node_01.id
      name    = openstack_compute_instance_v2.app_node_01.name
      status  = openstack_compute_instance_v2.app_node_01.power_state
      app_ip  = "10.10.20.11"
      data_ip = "10.10.30.11"
      mgmt_ip = "10.10.99.21"
    }
    app_node_02 = {
      id      = openstack_compute_instance_v2.app_node_02.id
      name    = openstack_compute_instance_v2.app_node_02.name
      status  = openstack_compute_instance_v2.app_node_02.power_state
      app_ip  = "10.10.20.12"
      data_ip = "10.10.30.12"
      mgmt_ip = "10.10.99.22"
    }
    db_core = {
      id      = openstack_compute_instance_v2.db_core.id
      name    = openstack_compute_instance_v2.db_core.name
      status  = openstack_compute_instance_v2.db_core.power_state
      data_ip = "10.10.30.50"
      mgmt_ip = "10.10.99.50"
    }
  }
}

# Output rápido solo de la IP flotante del bastión (muy útil)
output "bastion_floating_ip" {
  description = "IP pública del Bastión (punto de entrada SSH)"
  value       = var.bastion_floating_ip
}

# Output de todas las IPs de gestión (para Ansible inventory)
output "mgmt_ips" {
  description = "IPs de gestión de todas las máquinas (útiles para Ansible)"
  value = {
    bastion     = "10.10.99.20"
    lb_proxy    = "10.10.99.10"
    app_node_01 = "10.10.99.21"
    app_node_02 = "10.10.99.22"
    db_core     = "10.10.99.50"
  }
}