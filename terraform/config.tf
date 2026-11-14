# Genera la configuración de CMS y la sube a S3. Las instancias la bajan al
# iniciar los servicios (cms-sync-config), así que cambiarla NO recrea máquinas.

locals {
  # IPs privadas fijas: CMS identifica el rol de cada máquina por su IP en cms.toml
  main_ip    = cidrhost(local.subnet_cidr, 10)
  worker_ips = [for i in range(var.worker_count) : cidrhost(local.subnet_cidr, 11 + i)]

  # Workers de CMS: los remotos si están encendidos; si no, uno en la principal
  cms_workers = (var.workers_running && var.worker_count > 0
    ? [for ip in local.worker_ips : [ip, 26000]]
    : [[local.main_ip, 26000]]
  )

  domains = { for k, sub in var.subdomains : k => "${sub}.${var.domain}" }

  cms_toml = templatefile("${path.module}/templates/cms.toml.tftpl", {
    main_ip           = local.main_ip
    resource_services = jsonencode([for ip in concat([local.main_ip], local.worker_ips) : [ip, 28000]])
    workers           = jsonencode(local.cms_workers)
    db_password       = random_password.db.result
    secret_key        = random_id.secret_key.hex
    ranking_password  = random_password.ranking.result
  })

  cms_ranking_toml = templatefile("${path.module}/templates/cms_ranking.toml.tftpl", {
    ranking_password = random_password.ranking.result
  })

  cms_nginx = templatefile("${path.module}/templates/cms.nginx.tftpl", {
    contest        = local.domains.contest
    admin          = local.domains.admin
    ranking        = local.domains.ranking
    ranking_public = var.ranking_public
  })

  # Usuario y contraseña para ver el ranking (nginx, si ranking_public = false).
  # En texto plano ({PLAIN}, que nginx acepta): bcrypt() da otro hash en cada plan,
  # y cada apply volvería a instalar nginx. La contraseña ya está igual de expuesta
  # en el estado de Terraform y en S3.
  ranking_htpasswd = "oci:{PLAIN}${random_password.ranking_view.result}\n"
}

# ---------------------------------------------------------------------------
# Secretos
# ---------------------------------------------------------------------------

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "random_password" "admin" {
  length  = 20
  special = false
}

# La que usa el ProxyService para escribir en el ranking (cms.toml)
resource "random_password" "ranking" {
  length  = 24
  special = false
}

# La que se entrega para ver el ranking cuando no es público (ranking_public)
resource "random_password" "ranking_view" {
  length  = 16
  special = false
}

resource "random_id" "secret_key" {
  byte_length = 16
}
