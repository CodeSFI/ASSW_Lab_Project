# ==============================================================================
# Redes virtuales, subredes y enrutamiento (Neutron)
# ==============================================================================

# Router perimetral: gateway de las subredes internas con salida a Internet
# (SNAT automático gracias a external_network_id) y soporte de IPs flotantes.
resource "openstack_networking_router_v2" "edge_router" {
  name                = "${var.project_prefix}-edge-router"
  admin_state_up      = true
  external_network_id = data.openstack_networking_network_v2.external_network.id
}

# 1. DMZ (10.10.10.0/24): aloja el balanceador/WAF, única capa con IP flotante
# pública y exposición web.
resource "openstack_networking_network_v2" "dmz_net" {
  name           = "${var.project_prefix}-dmz-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "dmz_subnet" {
  name            = "${var.project_prefix}-dmz-subnet"
  network_id      = openstack_networking_network_v2.dmz_net.id
  cidr            = "10.10.10.0/24"
  ip_version      = 4
  dns_nameservers = ["1.1.1.1", "8.8.8.8"]
}

# Conecta la DMZ al router (tráfico bidireccional e IP flotante).
resource "openstack_networking_router_interface_v2" "router_dmz" {
  router_id = openstack_networking_router_v2.edge_router.id
  subnet_id = openstack_networking_subnet_v2.dmz_subnet.id
}

# 2. Red de gestión (10.10.99.0/24): plano de control aislado. Todas las VMs
# tienen interfaz aquí para que el bastión administre el clúster por SSH.
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

# Necesaria para que el bastión reciba su IP flotante de administración.
resource "openstack_networking_router_interface_v2" "router_mgmt" {
  router_id = openstack_networking_router_v2.edge_router.id
  subnet_id = openstack_networking_subnet_v2.mgmt_subnet.id
}

# 3. Red de aplicación (10.10.20.0/24): nodos mock, sin exposición pública;
# solo salida egress vía SNAT (por ejemplo, instalación de paquetes).
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

# Conecta al router solo para habilitar salida a repositorios de paquetes.
resource "openstack_networking_router_interface_v2" "router_app" {
  router_id = openstack_networking_router_v2.edge_router.id
  subnet_id = openstack_networking_subnet_v2.app_subnet.id
}

# 4. Red de datos (10.10.30.0/24): enlace exclusivo Apps <-> DB.
# Aislada del router (sin interfaz) y con no_gateway = true: ni el router ni
# el balanceador pueden encaminar tráfico hacia este segmento.
resource "openstack_networking_network_v2" "data_net" {
  name           = "${var.project_prefix}-data-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "data_subnet" {
  name       = "${var.project_prefix}-data-subnet"
  network_id = openstack_networking_network_v2.data_net.id
  cidr       = "10.10.30.0/24"
  ip_version = 4
  no_gateway = true
}