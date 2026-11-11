# Genera la configuración de CMS y la sube a S3. Las instancias la bajan al
# iniciar los servicios (cms-sync-config), así que cambiarla NO recrea máquinas.

locals {
  # IPs privadas fijas: CMS identifica el rol de cada máquina por su IP en cms.toml
  main_ip    = cidrhost(var.subnet_cidr, 10)
  worker_ips = [for i in range(var.worker_count) : cidrhost(var.subnet_cidr, 11 + i)]

  main_workers = coalesce(var.main_workers, var.workers_running ? 0 : 1)

  # Workers de CMS: los de la principal + los remotos si están encendidos
  cms_workers = concat(
    [for i in range(local.main_workers) : [local.main_ip, 26000 + i]],
    var.workers_running ? [for ip in local.worker_ips : [ip, 26000]] : [],
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
    contest = local.domains.contest
    admin   = local.domains.admin
    ranking = local.domains.ranking
  })

  # Datos que los scripts de la principal leen y que pueden cambiar después de crearla
  cluster_env = <<-EOT
    WORKER_IPS="${join(" ", local.worker_ips)}"
    DOMAINS="${join(" ", values(local.domains))}"
    LE_EMAIL="${var.letsencrypt_email}"
    LE_STAGING="${var.letsencrypt_staging}"
    ADMIN_USERNAME="${var.admin_username}"
  EOT
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

resource "random_password" "ranking" {
  length  = 24
  special = false
}

resource "random_id" "secret_key" {
  byte_length = 16
}

# Llave para SSH desde la principal a los workers
resource "tls_private_key" "workers" {
  algorithm = "ED25519"
}

check "cms_has_workers" {
  assert {
    condition     = length(local.cms_workers) > 0
    error_message = "La configuración no tiene workers de CMS: con workers_running = false, main_workers no puede ser 0."
  }
}
