# ==============================================================================
# Grupos de seguridad y reglas de cortafuegos (Neutron)
# Principio: defensa en profundidad y mínimos privilegios: solo se autorizan
# los flujos estrictamente necesarios entre capas.
# ==============================================================================

# 1. Grupo DMZ (balanceador/WAF): expone únicamente HTTP/HTTPS; ningún otro
# puerto queda abierto en la interfaz pública.
resource "openstack_networking_secgroup_v2" "secgroup_lb" {
  name        = "${var.project_prefix}-sg-lb"
  description = "Reglas perimetrales para el balanceador/WAF"
}

# HTTP (80) desde cualquier origen: recoge peticiones y redirige a HTTPS.
resource "openstack_networking_secgroup_rule_v2" "lb_http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.secgroup_lb.id
}

# HTTPS (443) desde cualquier origen: navegación cifrada inspeccionada por el WAF.
resource "openstack_networking_secgroup_rule_v2" "lb_https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.secgroup_lb.id
}

# 2. Grupo bastión: único punto de entrada SSH desde el exterior.
resource "openstack_networking_secgroup_v2" "secgroup_bastion" {
  name        = "${var.project_prefix}-sg-bastion"
  description = "Acceso seguro de administracion SSH"
}

# SSH (22) desde 0.0.0.0/0 en el lab; en producción se acota a IPs concretas
# y se combina con autenticación por clave y Fail2ban.
resource "openstack_networking_secgroup_rule_v2" "bastion_ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0" # Se puede limitar a la IP del centro/alumno
  security_group_id = openstack_networking_secgroup_v2.secgroup_bastion.id
}

# 3. Grupo de comunicaciones internas: regula las interconexiones entre capas
# para que un compromiso en una de ellas no abra acceso al resto.
resource "openstack_networking_secgroup_v2" "secgroup_internal" {
  name        = "${var.project_prefix}-sg-internal"
  description = "Comunicaciones internas entre capas y SSH desde mgmt-net"
}

# SSH (22) interno solo desde la subred de gestión (10.10.99.0/24).
resource "openstack_networking_secgroup_rule_v2" "internal_ssh_from_mgmt" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = openstack_networking_subnet_v2.mgmt_subnet.cidr
  security_group_id = openstack_networking_secgroup_v2.secgroup_internal.id
}

# HTTP (8080) a los nodos de aplicación solo desde la DMZ (10.10.10.0/24),
# asegurando que todo tráfico web pasa por el balanceador/WAF.
resource "openstack_networking_secgroup_rule_v2" "app_http_from_dmz" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8080
  port_range_max    = 8080
  remote_ip_prefix  = openstack_networking_subnet_v2.dmz_subnet.cidr
  security_group_id = openstack_networking_secgroup_v2.secgroup_internal.id
}

# PostgreSQL (5432): la DB solo acepta tráfico desde la capa de aplicación.
# NOTA: el flujo real Apps <-> DB viaja por data-net (10.10.30.0/24); si se
# conecta la aplicación a PostgreSQL, ajustar remote_ip_prefix a data_subnet.cidr.
resource "openstack_networking_secgroup_rule_v2" "db_from_app" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 5432
  port_range_max    = 5432
  remote_ip_prefix  = openstack_networking_subnet_v2.app_subnet.cidr
  security_group_id = openstack_networking_secgroup_v2.secgroup_internal.id
}