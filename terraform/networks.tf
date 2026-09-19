# ==============================================================================
# DEFINICIÓN DE REDES VIRTUALES, SUBREDES Y ENRUTAMIENTO (OPENSTACK NEUTRON)
# ==============================================================================

# ------------------------------------------------------------------------------
# ROUTER PERIMETRAL (Salida e Interconexión a Internet con SNAT)
# Rol: Gateway predeterminado para las subredes internas con salida exterior.
# Justificación: Permite conectar las redes virtuales privadas con la red pública
# del centro de datos[cite: 1]. Al asignarle 'external_network_id', OpenStack habilita
# automáticamente SNAT (traducción de direcciones de red), permitiendo que las
# instancias internas salgan a Internet para actualizar paquetes sin necesidad
# de tener una IP pública asignada directamente[cite: 1].
# ------------------------------------------------------------------------------
resource "openstack_networking_router_v2" "edge_router" {
  # Nombre descriptivo que incorpora el prefijo del proyecto para evitar colisiones[cite: 1]
  name                = "${var.project_prefix}-edge-router"
  admin_state_up      = true
  # Vinculación dinámica con la red externa obtenida mediante data source en main.tf[cite: 1]
  external_network_id = data.openstack_networking_network_v2.external_network.id
}

# ==============================================================================
# 1. RED DMZ (Zona Desmilitarizada / Perímetro)
# Rol: Alojamiento del balanceador de carga y cortafuegos de aplicación (WAF)[cite: 1].
# Justificación: Al ser la única capa donde se asociará una IP flotante para servicio
# público, actúa como barrera de contención perimetral, separando las peticiones
# web directas de la lógica interna del negocio[cite: 1].
# ==============================================================================
resource "openstack_networking_network_v2" "dmz_net" {
  name           = "${var.project_prefix}-dmz-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "dmz_subnet" {
  name            = "${var.project_prefix}-dmz-subnet"
  network_id      = openstack_networking_network_v2.dmz_net.id
  # Rango de direccionamiento privado clase C dedicado al perímetro
  cidr            = "10.10.10.0/24"
  ip_version      = 4
  # Servidores DNS para resolución de nombres de dependencias externas
  dns_nameservers = ["1.1.1.1", "8.8.8.8"]
}

# Conexión de la subred DMZ al router para permitir tráfico bidireccional mediante IP flotante
resource "openstack_networking_router_interface_v2" "router_dmz" {
  router_id = openstack_networking_router_v2.edge_router.id
  subnet_id = openstack_networking_subnet_v2.dmz_subnet.id
}

# ==============================================================================
# 2. RED DE GESTIÓN (MGMT / Out-Of-Band)
# Rol: Canal exclusivo para tareas de administración, bastionado y Ansible[cite: 1].
# Justificación: Establece un plano de control aislado[cite: 1]. Todas las VMs del clúster
# poseen una interfaz secundaria en esta red para permitir que el Bastión ejecute
# los playbooks sin exponer los puertos de administración (SSH 22) a las redes
# de datos o de aplicación pública[cite: 1].
# ==============================================================================
resource "openstack_networking_network_v2" "mgmt_net" {
  name           = "${var.project_prefix}-mgmt-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "mgmt_subnet" {
  name            = "${var.project_prefix}-mgmt-subnet"
  network_id      = openstack_networking_network_v2.mgmt_net.id
  cidr            = "10.10.99.0/24"
  ip_version      = 4
  dns_nameservers = ["1.1.1.1", "8.8.8.8"]
}

# Conexión al router necesaria para que el Bastión pueda recibir la IP flotante de administración[cite: 1]
resource "openstack_networking_router_interface_v2" "router_mgmt" {
  router_id = openstack_networking_router_v2.edge_router.id
  subnet_id = openstack_networking_subnet_v2.mgmt_subnet.id
}

# ==============================================================================
# 3. RED DE APLICACIÓN (APP / Lógica de Negocio)
# Rol: Alojamiento de los nodos de procesamiento web (servidores mock)[cite: 1].
# Justificación: Se mantiene en una red privada sin exposición pública[cite: 1]. Se conecta
# al router exclusivamente para permitir tráfico de salida (egress) vía SNAT (por
# ejemplo, instalación de paquetes de seguridad del SO), pero no posee puertas de entrada
# desde Internet[cite: 1]. Solo acepta peticiones internas enrutadas desde la DMZ[cite: 1].
# ==============================================================================
resource "openstack_networking_network_v2" "app_net" {
  name           = "${var.project_prefix}-app-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "app_subnet" {
  name            = "${var.project_prefix}-app-subnet"
  network_id      = openstack_networking_network_v2.app_net.id
  cidr            = "10.10.20.0/24"
  ip_version      = 4
  dns_nameservers = ["1.1.1.1", "8.8.8.8"]
}

# Conexión al router para habilitar navegación de salida hacia repositorios de software
resource "openstack_networking_router_interface_v2" "router_app" {
  router_id = openstack_networking_router_v2.edge_router.id
  subnet_id = openstack_networking_subnet_v2.app_subnet.id
}

# ==============================================================================
# 4. RED DE DATOS (DATA / Persistencia Aislada)
# Rol: Alojamiento del servidor de bases de datos relacional (PostgreSQL)[cite: 1].
# Justificación técnica de seguridad: Esta subred NO se conecta al router virtual
# (se omite 'openstack_networking_router_interface_v2')[cite: 1].
# Al declarar 'no_gateway = true', Neutron no configura puerta de enlace predeterminada[cite: 1].
# Esto garantiza aislamiento estricto: la base de datos no puede acceder a Internet ni
# puede ser alcanzada desde fuera, eliminando el riesgo de exfiltración directa de datos[cite: 1].
# ==============================================================================
resource "openstack_networking_network_v2" "data_net" {
  name           = "${var.project_prefix}-data-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "data_subnet" {
  name       = "${var.project_prefix}-data-subnet"
  network_id = openstack_networking_network_v2.data_net.id
  cidr       = "10.10.30.0/24"
  ip_version = 4
  # Sin default gateway: no hay ruta por defecto hacia ningún router externo[cite: 1]
  no_gateway = true
}