# Proyecto de Infraestructura: Plataforma de Comercio Electrónico Segura y Resiliente (E-commerce DMZ)

**Máster en Ingeniería Web — Universidad de Oviedo**  
**Asignatura:** Administración Segura de Servidores Web (v1.6 "L-62 Princesa de Asturias")  
**Grupo:** 3 personas  
**Entorno de despliegue objetivo:** OpenStack  

---

## 1. Descripción y Alcance del Proyecto

### 1.1. Contexto Empresarial
El proyecto diseña e implementa la infraestructura de servidores y redes para una plataforma ficticia de comercio electrónico (*Cantábrico Retail S.L.*). La organización gestiona transacciones y datos sensibles de clientes, lo que exige disponibilidad continua, protección perimetral activa contra ataques web comunes y aislamiento estricto de la capa de persistencia.

### 1.2. Objetivo Técnico
El núcleo del proyecto no radica en el desarrollo de software —el cual se implementa como un *mock* funcional ligero—, sino en la construcción de una arquitectura multicapa en **OpenStack** gobernada por el principio de **defensa en profundidad**, con segmentación estricta de redes, bastionado de sistemas y automatización completa del ciclo de vida.

Se descarta el uso exclusivo de contenedores tipo Docker Compose (considerado insuficiente en el enunciado) y se opta por una solución basada en **5 Máquinas Virtuales interconectadas mediante redes virtuales y routers independientes**.

---

## 2. Topología y Especificación de la Arquitectura

### 2.1. Segmentación de Redes (OpenStack Neutron)

1. **Red DMZ (`dmz-net` - `10.10.10.0/24`):**
   * Conectada al Router perimetral con salida directa a Internet.
   * Aloja la única instancia expuesta al tráfico web general mediante IP flotante.
2. **Red de Aplicación (`app-net` - `10.10.20.0/24`):**
   * Red privada interna conectada al Router mediante SNAT (permite salida para descargas y dependencias, pero sin acceso entrante directo desde Internet).
   * Aloja los nodos de procesamiento web.
3. **Red de Datos (`data-net` - `10.10.30.0/24`):**
   * Red completamente aislada. No dispone de *gateway* hacia el exterior ni IP flotante.
   * Solo alcanzable desde la red de aplicación en el puerto de base de datos (`5432`).
4. **Red de Gestión OOB (`mgmt-net` - `10.10.99.0/24`):**
   * Canal secundario de administración que enlaza el servidor bastión con las interfaces de control de todas las instancias internas.

```text
                             INTERNET
                                │
                      [ IP Flotante Pública ]
                                │
        ┌───────────────────────┴────────────────────────┐
        │                                                │
   [Puerto 443]                                    [Puerto 2222 / VPN]
        │                                                │
┌───────▼──────────────────────────┐      ┌──────────────▼──────────────────────────┐
│ dmz-net (10.10.10.0/24)          │      │ mgmt-net (10.10.99.0/24)                │
│ lb-proxy-cantabrico-01           │      │ bastion-ops-cantabrico                  │
│ • Nginx + ModSecurity (WAF)      │      │ • SSH Hardening (claves asimétricas)    │
│ • Terminación TLS + Rate Limit   │      │ • Fail2ban                              │
└───────┬──────────────────────────┘      └──────────────┬──────────────────────────┘
        │                                                │
        │ (HTTP/8080 balanceado)                         │ (Acceso SSH / Ansible)
        │                                                │
┌───────▼────────────────────────────────────────────────▼──────────────────────────┐
│ app-net (10.10.20.0/24)                                                           │
│ ├── srv-ecommerce-app01 (Mock API / HTTP ligero)                                  │
│ └── srv-ecommerce-app02 (Mock API / HTTP ligero)                                  │
└───────┬────────────────────────────────────────────────┬──────────────────────────┘
        │                                                │
        │ (TCP/5432 autenticado)                         │ (Acceso SSH / Ansible)
        │                                                │
┌───────▼────────────────────────────────────────────────▼──────────────────────────┐
│ data-net (10.10.30.0/24 - Aislada sin salida a Internet)                           │
│ └── srv-db-core01 (PostgreSQL + Backups automáticos cifrados GPG)                 │
└───────────────────────────────────────────────────────────────────────────────────┘
```

### 2.2. Inventario de Máquinas Virtuales (5 Instancias)

Para optimizar la cuota de OpenStack, se emplearán sabores ligeros (`m1.tiny` / `m1.small`):

| Nombre de Instancia | Rol / Función | Redes Asignadas | Exposición Externa |
| :--- | :--- | :--- | :--- |
| `lb-proxy-cantabrico-01` | Balanceador Nginx + WAF ModSecurity | `dmz-net`, `mgmt-net` | Sí (IP Flotante: 80, 443) |
| `bastion-ops-cantabrico` | Pasarela de administración segura | `dmz-net` (o ext), `mgmt-net` | Sí (IP Flotante: puerto 2222) |
| `srv-ecommerce-app01` | Nodo de aplicación 1 (Mock API) | `app-net`, `mgmt-net` | No (Solo privada) |
| `srv-ecommerce-app02` | Nodo de aplicación 2 (Mock API) | `app-net`, `mgmt-net` | No (Solo privada) |
| `srv-db-core01` | Base de datos PostgreSQL + Backups | `data-net`, `mgmt-net` | No (Red aislada) |

*Nota de buenas prácticas:* Se utilizan identificadores de servicio reales (`sysadmin_cantabrico`, `svc_nginx`, `db_ecommerce`) eliminando cuentas genéricas como `user`, `admin` o `ubuntu`.

---

## 3. Pilares de Seguridad Implementados

1. **Firewalls de Red (Security Groups de OpenStack):**
   * Reglas de entrada y salida mínimas y específicas para cada interfaz de red.
   * La base de datos solo admite conexiones en el puerto 5432 provenientes de las IPs de `srv-ecommerce-app01` y `app02`.
2. **Web Application Firewall (WAF) & Rate Limiting:**
   * ModSecurity integrado en Nginx con el conjunto de reglas OWASP Core Rule Set (CRS) para interceptar SQLi, XSS y escaneos automáticos.
   * Regulación de tasa de peticiones (*rate limiting*) para mitigar abusos y denegaciones de servicio.
3. **Bastionado de Acceso Administrativo (Bastion Host):**
   * Deshabilitación del acceso como `root` y de autenticación por contraseña.
   * Conexión obligatoria por clave asimétrica (Ed25519/RSA), cambio de puerto estándar SSH y configuración de Fail2ban.
4. **Gestión de Secretos:**
   * Ningún certificado privado, clave SSH o credencial de base de datos se expone en texto claro. Se empleará **Ansible Vault** con variables parametrizables.
5. **Copias de Seguridad Cifradas:**
   * Script automatizado periódico que realiza un volcado de la base de datos, lo cifra simétricamente con GPG y lo custodia localmente en un volumen reservado.

---

## 4. Planificación del Trabajo y Asignación de Roles (3 Personas)

El proyecto asume una carga estimada de ~24 horas conjuntas (~8 horas por alumno):

```text
Gantt simplificado (4 Fases):
[Fase 1: Diseño e IaC Base] ──────► [Fase 2: Provisión y Configuración] ──────► [Fase 3: Seguridad y Pruebas] ──────► [Fase 4: Documentación]
```

### Integrante 1: Infraestructura Base, Redes y Bastión (IaC & Perímetro OOB)
* **Semana 1:**
  * Creación de los manifiestos Terraform / scripts de orquestación OpenStack para levantar routers, subredes (`dmz-net`, `app-net`, `data-net`, `mgmt-net`) e interfaces.
  * Definición de grupos de seguridad (*Security Groups*) de mínimos privilegios en OpenStack.
* **Semana 2:**
  * Despliegue de la instancia `bastion-ops-cantabrico`.
  * Configuración de SSH Hardening (puerto modificado, bloqueo de contraseñas, Fail2ban).
  * Configuración de `ProxyJump` en SSH/Ansible para permitir el salto de gestión al resto de la infraestructura interna.
* **Semana 3:**
  * Pruebas de conectividad y aislamiento de red. Revisión de variables y parametrización de IPs.

### Integrante 2: Perímetro, WAF y Alta Disponibilidad Web
* **Semana 1:**
  * Creación del rol de Ansible para el nodo perimetral `lb-proxy-cantabrico-01`.
  * Instalación y configuración de Nginx como proxy inverso y balanceador de carga hacia los nodos de la aplicación.
* **Semana 2:**
  * Integración de ModSecurity con OWASP CRS.
  * Generación y configuración de certificados TLS y directivas de endurecimiento SSL (ciphers seguros, cabeceras HSTS).
  * Implementación de políticas de *Rate Limiting*.
* **Semana 3:**
  * Verificación de balanceo de tráfico ante caídas de nodos (*health-checks*).
  * Pruebas de bloqueo de vectores OWASP (inyecciones SQL simuladas mediante `curl`).

### Integrante 3: Capa Interna, Base de Datos, Backups y Secretos
* **Semana 1:**
  * Implementación de los nodos `srv-ecommerce-app01` y `app02` con un servidor web ligero (*mock* en Nginx o Python) que devuelva el estado del servicio y el identificador del host.
  * Integración de `group_vars/vault.yml` con Ansible Vault para el manejo de credenciales.
* **Semana 2:**
  * Despliegue automatizado de PostgreSQL en `srv-db-core01` escuchando únicamente en la interfaz de `data-net`.
  * Creación del script de backup periódico con cifrado GPG mediante un cron/timer de systemd.
* **Semana 3:**
  * Orquestación del playbook principal (`site.yml`) que coordina el despliegue de todo el conjunto.
  * Pruebas de restauración y verificación del cifrado de backups.

### Tareas Conjuntas (Fase Final)
* Ejecución de pruebas de penetración y auditoría básica (validación de aislamiento).
* Elaboración de la memoria y la presentación autoexplicativa en PDF/PowerPoint.
* Redacción del archivo `README.md` final con instrucciones de despliegue paso a paso para el profesor.

---

## 5. Estructura Prevista del Repositorio de Código

```text
ecommerce-secure-infra/
├── terraform/                      # Aprovisionamiento en OpenStack (Persona 1)
│   ├── main.tf
│   ├── networks.tf
│   ├── security_groups.tf
│   ├── instances.tf
│   ├── variables.tf
│   └── terraform.tfvars.example    # Plantilla de variables sin secretos
├── ansible/                        # Configuración y Software (Personas 2 y 3)
│   ├── ansible.cfg                 # Configuración de salto vía Bastion
│   ├── inventory.ini               # IPs internas del entorno
│   ├── site.yml                    # Playbook maestro de provisión
│   ├── group_vars/
│   │   ├── all.yml                 # Variables no sensibles (puertos, rutas)
│   │   └── vault.yml               # Variables cifradas con Ansible Vault
│   └── roles/
│       ├── common/                 # Actualizaciones base, usuarios reales
│       ├── bastion/                # SSH hardening, Fail2ban
│       ├── perimeter_lb/           # Nginx, TLS, ModSecurity WAF
│       ├── app_node/               # Despliegue del mock de aplicación
│       └── database/               # PostgreSQL, scripts de backup cifrado
├── scripts/
│   ├── deploy.sh                   # Script de ejecución general automatizado
│   └── test_security.sh            # Pruebas de validación (WAF, aislamiento)
├── docs/
│   └── presentacion_proyecto.pdf   # Diapositivas autoexplicativas
└── README.md                       # Manual de reproducibilidad para el evaluador
```

---

## 6. Procedimiento de Ejecución y Reproducibilidad

El evaluador podrá reproducir todo el despliegue siguiendo estos pasos:

1. **Definir credenciales y variables del entorno:**
   ```bash
   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
   # Ajustar ID de red externa y floating IP pool según el tenant de OpenStack
   ```
2. **Levantar la infraestructura (Terraform):**
   ```bash
   cd terraform
   terraform init
   terraform apply -auto-approve
   ```
3. **Aprovisionar servicios y seguridad (Ansible):**
   ```bash
   cd ../ansible
   ansible-playbook -i inventory.ini site.yml --ask-vault-pass
   ```
4. **Verificar el funcionamiento:**
   * Acceso web al balanceador (`https://<IP_FLOTANTE_LB>/`).
   * Ejecución de `scripts/test_security.sh` para verificar el bloqueo de ataques y la inaccesibilidad de la base de datos desde el exterior.