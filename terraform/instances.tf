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
# Puerto explícito en la red DMZ para vincular de forma determinista la Floating IP
resource "openstack_networking_port_v2" "port_lb_dmz" {
  name           = "${var.project_prefix}-port-lb-dmz"
  network_id     = openstack_networking_network_v2.dmz_net.id
  admin_state_up = true
  security_group_ids = [
    openstack_networking_secgroup_v2.secgroup_lb.id
  ]

  # Asigna una IP fija de la subred DMZ explícitamente para evitar rechazos en Nova
  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.dmz_subnet.id
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
    name = openstack_networking_network_v2.mgmt_net.name
  }

  # Grupos de seguridad (firewall de OpenStack):
  # - secgroup_internal: Permite recibir SSH de mantenimiento exclusivamente desde el bastión
  security_groups = [
    openstack_networking_secgroup_v2.secgroup_internal.name
  ]
}

# ------------------------------------------------------------------------------
# 2. VM: Bastion Host (Gestión / Out-of-Band)
# Rol: Puerta de enlace segura para administradores y despliegues con Ansible.
# Justificación: Ninguna máquina interna tiene IP pública ni puerto SSH expuesto;
# todo el mantenimiento debe saltar obligatoriamente por esta máquina endurecida.
# ------------------------------------------------------------------------------
# Puerto explícito en la red MGMT para recibir la IP flotante de administración
resource "openstack_networking_port_v2" "port_bastion_mgmt" {
  name           = "${var.project_prefix}-port-bastion-mgmt"
  network_id     = openstack_networking_network_v2.mgmt_net.id
  admin_state_up = true
  security_group_ids = [
    openstack_networking_secgroup_v2.secgroup_bastion.id,
    openstack_networking_secgroup_v2.secgroup_internal.id
  ]

  # Asigna una IP fija de la subred de gestión para que Nova pueda enlazar el puerto
  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.mgmt_subnet.id
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
# 3 y 4. VMs: Nodos de Aplicación (Capa Privada Replicada)
# Rol: Servidores de lógica de negocio (mock HTTP de la tienda online).
# Justificación: Se despliegan 2 instancias mediante el meta-argumento 'count'
# para demostrar alta disponibilidad y balanceo de carga real sin IPs públicas.
# ------------------------------------------------------------------------------
resource "openstack_compute_instance_v2" "app_nodes" {
  # Crea 2 instancias idénticas en paralelo
  count       = 2

  # Nombres dinámicos formateados con prefijo
  name        = format("${var.project_prefix}-app-node-%02d", count.index + 1)
  image_id    = data.openstack_images_image_v2.base_image.id
  flavor_id   = data.openstack_compute_flavor_v2.default_flavor.id
  key_pair    = var.keypair_name

  # Solo asigna el grupo interno: solo acepta peticiones HTTP (8080) desde el balanceador
  # y SSH desde el bastión; deniega cualquier intento de acceso directo externo
  security_groups = [
    openstack_networking_secgroup_v2.secgroup_internal.name
  ]

  # Interfaz 1: Red de aplicación privada (10.10.20.0/24) para comunicar con el LB y la DB
  network {
    name = openstack_networking_network_v2.app_net.name
  }

  # Interfaz 2: Red de gestión (10.10.99.0/24) para ejecución de playbooks de Ansible
  network {
    name = openstack_networking_network_v2.mgmt_net.name
  }
}

# ------------------------------------------------------------------------------
# 5. VM: Base de Datos (Capa Aislada / Data)
# Rol: Servidor de persistencia de datos (PostgreSQL) y tareas de backup.
# Justificación: Almacena los datos sensibles; reside en una red sin router/gateway
# a Internet, impidiendo exfiltraciones directas en caso de compromiso web.
# ------------------------------------------------------------------------------
resource "openstack_compute_instance_v2" "db_core" {
  name        = "${var.project_prefix}-db-core-01"
  image_id    = data.openstack_images_image_v2.base_image.id
  flavor_id   = data.openstack_compute_flavor_v2.default_flavor.id
  key_pair    = var.keypair_name

  # Grupo interno: solo responde al puerto 5432 desde la IP de los app_nodes y al 22 del bastión
  security_groups = [
    openstack_networking_secgroup_v2.secgroup_internal.name
  ]

  # Interfaz 1: Red de datos aislada (10.10.30.0/24) sin puerta de enlace hacia el exterior
  network {
    name = openstack_networking_network_v2.data_net.name
  }

  # Interfaz 2: Red de gestión (10.10.99.0/24) para mantenimiento y copias cifradas remotas
  network {
    name = openstack_networking_network_v2.mgmt_net.name
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