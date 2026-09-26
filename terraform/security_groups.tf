# ==============================================================================
# GRUPOS DE SEGURIDAD Y REGLAS DE CORTAFUEGOS (OPENSTACK NEUTRON)
# Principio rector: Defensa en profundidad y mínimos privilegios.
# Se autorizan exclusivamente los flujos estrictamente necesarios entre capas.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. GRUPO DE SEGURIDAD: DMZ (Balanceador / WAF)
# Rol: Filtrado perimetral del tráfico público entrante.
# Justificación: Al ser el único componente con exposición web hacia Internet,
# se limitan sus puertos a HTTP/HTTPS estándar. Ningún otro puerto
# (como SSH o puertos de base de datos) queda expuesto en esta interfaz pública.
# ------------------------------------------------------------------------------
resource "openstack_networking_secgroup_v2" "secgroup_lb" {
  name        = "${var.project_prefix}-sg-lb"
  description = "Reglas perimetrales para el balanceador/WAF"
}

# Regla: Permite tráfico HTTP no seguro (puerto 80) desde cualquier origen
# Justificación: Necesario para recibir peticiones iniciales de usuarios y forzar
# la redirección automática hacia HTTPS (301 Redirect) en Nginx.
resource "openstack_networking_secgroup_rule_v2" "lb_http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.secgroup_lb.id
}

# Regla: Permite tráfico HTTPS seguro (puerto 443) desde cualquier origen
# Justificación: Es la vía principal de navegación cifrada (TLS/SSL) que procesará
# el motor WAF (ModSecurity) antes de remitir las peticiones a la capa de aplicación.
resource "openstack_networking_secgroup_rule_v2" "lb_https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.secgroup_lb.id
}

# ------------------------------------------------------------------------------
# 2. GRUPO DE SEGURIDAD: BASTION HOST (Jumpbox de Administración)
# Rol: Control de acceso remoto administrativo hacia la infraestructura.
# Justificación: Actúa como único punto de entrada SSH para los operadores.
# Ninguna otra máquina admite conexiones SSH directas desde el exterior.
# ------------------------------------------------------------------------------
resource "openstack_networking_secgroup_v2" "secgroup_bastion" {
  name        = "${var.project_prefix}-sg-bastion"
  description = "Acceso seguro de administracion SSH"
}

# Regla: Permite acceso SSH (puerto 22) desde el exterior
# Justificación técnica: Permite la conexión inicial de los evaluadores y administradores.
# En producción se acota a la IP fija corporativa; aquí se combina con autenticación
# exclusiva por clave asimétrica y Fail2ban dentro del SO para mitigar ataques de fuerza bruta.
resource "openstack_networking_secgroup_rule_v2" "bastion_ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0" # Se puede limitar a la IP del centro/alumno
  security_group_id = openstack_networking_secgroup_v2.secgroup_bastion.id
}

# ------------------------------------------------------------------------------
# 3. GRUPO DE SEGURIDAD: COMUNICACIONES INTERNAS (App, Data y Gestión)
# Rol: Regula las interconexiones horizontales y verticales entre capas internas.
# Justificación: Garantiza que un compromiso en la capa DMZ o Web no otorgue
# acceso indiscriminado al resto de los servidores de la infraestructura.
# ------------------------------------------------------------------------------
resource "openstack_networking_secgroup_v2" "secgroup_internal" {
  name        = "${var.project_prefix}-sg-internal"
  description = "Comunicaciones internas entre capas y SSH desde mgmt-net"
}

# Regla: Acceso administrativo SSH interno (puerto 22)
# Justificación: Permite conectar por SSH a cualquier máquina interna (LB, App Nodes, DB)
# EXCLUSIVAMENTE si el origen es la subred de gestión mgmt-net (10.10.99.0/24).
# Impide que los nodos de la app o de internet intenten conexiones SSH entre sí.
resource "openstack_networking_secgroup_rule_v2" "internal_ssh_from_mgmt" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = openstack_networking_subnet_v2.mgmt_subnet.cidr
  security_group_id = openstack_networking_secgroup_v2.secgroup_internal.id
}

# Regla: Tráfico web interno (puerto 8080) hacia los nodos de Aplicación
# Justificación: Los servidores de aplicación solo admiten peticiones HTTP si provienen
# del rango de la subred DMZ (10.10.10.0/24), asegurando que ninguna petición web
# pueda saltarse la inspección previa del WAF ni del balanceador perimetral.
resource "openstack_networking_secgroup_rule_v2" "app_http_from_dmz" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8080
  port_range_max    = 8080
  remote_ip_prefix  = openstack_networking_subnet_v2.dmz_subnet.cidr
  security_group_id = openstack_networking_secgroup_v2.secgroup_internal.id
}

# Regla: Tráfico de base de datos PostgreSQL (puerto 5432) hacia la capa Data
# Justificación: Aislamiento crítico de persistencia. El servidor de base de datos solo
# acepta tráfico TCP en el puerto 5432 si procede estrictamente de la red de datos
# (10.10.30.0/24): los app-nodes hablan con la BD por su interfaz data-net
# (10.10.30.11/.12), la única ruta hasta la IP de escucha 10.10.30.50.
# Bloquea accesos directos desde la DMZ, el balanceador, la red de aplicacion
# (10.10.20.0/24) y el exterior.
resource "openstack_networking_secgroup_rule_v2" "db_from_app" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 5432
  port_range_max    = 5432
  remote_ip_prefix  = openstack_networking_subnet_v2.data_subnet.cidr
  security_group_id = openstack_networking_secgroup_v2.secgroup_internal.id
}