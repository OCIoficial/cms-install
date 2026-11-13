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

# scripts/ y ranking/ se suben como un zip cada uno (terraform/.build/, no se
# versiona). Los permisos fijos hacen que el zip salga igual en cualquier
# máquina, así un apply sin cambios no lo vuelve a subir.
data "archive_file" "scripts" {
  type             = "zip"
  source_dir       = "${path.module}/../scripts"
  output_path      = "${path.module}/.build/scripts.zip"
  output_file_mode = "0755"
}

data "archive_file" "ranking" {
  type             = "zip"
  source_dir       = "${path.module}/../ranking"
  output_path      = "${path.module}/.build/ranking.zip"
  output_file_mode = "0644"
}

# Importador de usuarios (import-users/): build.sh compila el frontend con npm
# en cada plan y arma la carpeta que se sube como import-users.zip. Vite genera
# siempre los mismos archivos para el mismo código, así que un apply sin
# cambios no lo vuelve a subir.
data "external" "import_users" {
  program = [abspath("${path.module}/../import-users/build.sh"), abspath("${path.module}/.build/import-users")]
}

data "archive_file" "import_users" {
  type             = "zip"
  source_dir       = data.external.import_users.result.dir
  output_path      = "${path.module}/.build/import-users.zip"
  output_file_mode = "0644"
}

resource "aws_s3_object" "scripts" {
  bucket       = aws_s3_bucket.assets.id
  key          = "scripts.zip"
  source       = data.archive_file.scripts.output_path
  etag         = data.archive_file.scripts.output_md5
  content_type = "application/zip"
}

resource "aws_s3_object" "ranking" {
  bucket       = aws_s3_bucket.assets.id
  key          = "ranking.zip"
  source       = data.archive_file.ranking.output_path
  etag         = data.archive_file.ranking.output_md5
  content_type = "application/zip"
}

resource "aws_s3_object" "import_users" {
  bucket       = aws_s3_bucket.assets.id
  key          = "import-users.zip"
  source       = data.archive_file.import_users.output_path
  etag         = data.archive_file.import_users.output_md5
  content_type = "application/zip"
}

resource "aws_s3_object" "config" {
  for_each = {
    "config/cms.toml"         = local.cms_toml
    "config/cms_ranking.toml" = local.cms_ranking_toml
    "config/cms.nginx"        = local.cms_nginx
  }
  bucket  = aws_s3_bucket.assets.id
  key     = each.key
  content = each.value
}

resource "aws_s3_object" "secrets" {
  for_each = {
    "secrets/db_password"    = random_password.db.result
    "secrets/admin_password" = random_password.admin.result
    "secrets/cloudflare.ini" = "dns_cloudflare_api_token = ${var.cloudflare_certbot_token}\n"
  }
  bucket  = aws_s3_bucket.assets.id
  key     = each.key
  content = each.value
}
