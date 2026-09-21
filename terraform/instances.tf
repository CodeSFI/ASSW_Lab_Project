# ==============================================================================
# DEFINICIÓN DE INSTANCIAS (MÁQUINAS VIRTUALES) EN OPENSTACK
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. VM: Balanceador / WAF (DMZ)
# Rol: Punto de entrada único del tráfico web desde Internet.
# Justificación: Al ser el único nodo expuesto a los usuarios, centraliza la
# terminación TLS (cifrado SSL) y la inspección WAF, evitando que las peticiones
# maliciosas alcancen las capas internas.
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
  # Nombre contextualizado con prefijo para evitar colisiones
  name        = "${var.project_prefix}-lb-proxy-01"

  # Asocia la imagen base del SO (referenciada dinámicamente en main.tf para no usar IDs estáticos)
  image_id    = data.openstack_images_image_v2.base_image.id

  # Sabor/recursos de hardware (vCPUs/RAM) parametrizado para evitar agotar cuotas
  flavor_id   = data.openstack_compute_flavor_v2.default_flavor.id

  # Clave SSH pública inyectada por cloud-init para acceso administrativo inicial
  key_pair    = var.keypair_name

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
# Rol: Puerta de enlace segura para administradores y despliegues con Ansible.
# Justificación: Ninguna máquina interna tiene IP pública ni puerto SSH expuesto;
# todo el mantenimiento debe saltar obligatoriamente por esta máquina endurecida.
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
  # Nombre representativo del rol de operaciones con prefijo parametrizado
  name        = "${var.project_prefix}-bastion-ops-01"
  image_id    = data.openstack_images_image_v2.base_image.id
  flavor_id   = data.openstack_compute_flavor_v2.default_flavor.id
  key_pair    = var.keypair_name

  # Conectado únicamente a la red de gestión (10.10.99.0/24); desde aquí enruta
  # el tráfico administrativo hacia el resto de las máquinas
  network {
    port = openstack_networking_port_v2.port_bastion_mgmt.id
  }
}

# ------------------------------------------------------------------------------
# 3. VM: Nodo de Aplicación 01 (Capa Privada Replicada)
# Rol: Primer servidor de lógica de negocio (mock HTTP de la tienda online).
# Justificación: Instancia desacoplada para alta disponibilidad. Tiene acceso a
# la red de datos privada para hablar directamente con la base de datos sin
# exponer ese tráfico al balanceador ni a Internet.
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
  name        = "${var.project_prefix}-app-node-01"
  image_id    = data.openstack_images_image_v2.base_image.id
  flavor_id   = data.openstack_compute_flavor_v2.default_flavor.id
  key_pair    = var.keypair_name

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
# Rol: Segundo servidor de lógica de negocio (réplica para balanceo de carga).
# Justificación: Replica la configuración del nodo 01 garantizando que el clúster
# tolere la caída de un servidor de backend sin interrumpir el servicio.
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
  name        = "${var.project_prefix}-app-node-02"
  image_id    = data.openstack_images_image_v2.base_image.id
  flavor_id   = data.openstack_compute_flavor_v2.default_flavor.id
  key_pair    = var.keypair_name

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
# Rol: Servidor de persistencia de datos (PostgreSQL) y tareas de backup.
# Justificación: Reside en 'data_net' (10.10.30.0/24), una red cerrada sin router/gateway
# a Internet, compartida únicamente con los app_nodes. Esto elimina el riesgo
# de exfiltración directa de datos y blinda el puerto 5432.
# ------------------------------------------------------------------------------
# Puerto en red de datos (comunicación exclusiva con app-node-01 y app-node-02)
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
  name        = "${var.project_prefix}-db-core-01"
  image_id    = data.openstack_images_image_v2.base_image.id
  flavor_id   = data.openstack_compute_flavor_v2.default_flavor.id
  key_pair    = var.keypair_name

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
# ASIGNACIÓN DE IP FLOTANTE PREEXISTENTE PARAMETRIZADA (BASTIÓN)
# Principio de defensa en profundidad y optimización de cuota:
# Se consulta la IP flotante ya reservada en Horizon mediante el parámetro
# 'bastion_floating_ip'. Esto evita realizar peticiones POST de reserva a Neutron,
# previniendo errores de OverQuota.
# ==============================================================================

# Consulta el DataSource de la IP existente indicada en la variable
data "openstack_networking_floatingip_v2" "fip_bastion" {
  address = var.bastion_floating_ip
}

# Asocia la IP pública al puerto de la interfaz de gestión del Bastión
resource "openstack_networking_floatingip_associate_v2" "fip_bastion_assoc" {
  floating_ip = data.openstack_networking_floatingip_v2.fip_bastion.address
  port_id     = openstack_networking_port_v2.port_bastion_mgmt.id
}