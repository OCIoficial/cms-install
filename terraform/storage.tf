# Bucket con los scripts, imágenes del ranking, configuración y secretos que
# bajan las instancias. Lo crea y lo borra Terraform.

resource "aws_s3_bucket" "assets" {
  bucket_prefix = "cms-assets-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

locals {
  scripts_dir = "${path.module}/../scripts"
  ranking_dir = "${path.module}/../ranking"
  # Cambia si cambia cualquier archivo de scripts/ (ver cms_contest en commands.tf)
  scripts_hash = sha256(join(",", [
    for f in sort(fileset(local.scripts_dir, "**")) : "${f}=${filemd5("${local.scripts_dir}/${f}")}"
  ]))
}

resource "aws_s3_object" "scripts" {
  for_each = fileset(local.scripts_dir, "**")
  bucket   = aws_s3_bucket.assets.id
  key      = "scripts/${each.value}"
  source   = "${local.scripts_dir}/${each.value}"
  etag     = filemd5("${local.scripts_dir}/${each.value}")
}

resource "aws_s3_object" "ranking" {
  for_each     = fileset(local.ranking_dir, "**/*.png")
  bucket       = aws_s3_bucket.assets.id
  key          = "ranking/${each.value}"
  source       = "${local.ranking_dir}/${each.value}"
  etag         = filemd5("${local.ranking_dir}/${each.value}")
  content_type = "image/png"
}

resource "aws_s3_object" "config" {
  for_each = {
    "config/cms.toml"         = local.cms_toml
    "config/cms_ranking.toml" = local.cms_ranking_toml
    "config/cms.nginx"        = local.cms_nginx
    "config/cluster.env"      = local.cluster_env
  }
  bucket  = aws_s3_bucket.assets.id
  key     = each.key
  content = each.value
}

resource "aws_s3_object" "secrets" {
  for_each = {
    "secrets/db_password"    = random_password.db.result
    "secrets/admin_password" = random_password.admin.result
    "secrets/worker_ssh_key" = tls_private_key.workers.private_key_openssh
    "secrets/cloudflare.ini" = "dns_cloudflare_api_token = ${var.cloudflare_certbot_token}\n"
  }
  bucket  = aws_s3_bucket.assets.id
  key     = each.key
  content = each.value
}
