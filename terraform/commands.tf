# Comandos que Terraform ejecuta en la principal (vía SSM) cuando cambia algo,
# para que no haya que entrar a la máquina. Un `terraform apply` sin cambios
# no ejecuta nada.

locals {
  # run-on-main.sh usa la AWS CLI con el mismo perfil que Terraform
  aws_cli_env = var.aws_profile == null ? {} : { AWS_PROFILE = var.aws_profile }
}

# Asocia CMS al concurso y reinicia CMS en todas las máquinas encendidas, después
# de actualizar sus scripts. Corre cuando cambia contest_id, la configuración de
# CMS (p. ej. workers_running), algún archivo de scripts/ o se recrea la principal.
resource "terraform_data" "cms_contest" {
  count = var.main_running ? 1 : 0

  triggers_replace = {
    main_id    = aws_instance.main.id
    contest_id = var.contest_id
    cms_toml   = sha256(local.cms_toml)
    scripts    = data.archive_file.scripts.output_sha256
  }

  provisioner "local-exec" {
    command     = "${path.module}/run-on-main.sh ${aws_instance.main.id} ${var.region} cms-contest ${var.contest_id}"
    environment = local.aws_cli_env
  }

  # La config y los scripts nuevos tienen que estar en S3 y los workers encendidos antes de reiniciar
  depends_on = [aws_s3_object.config, aws_s3_object.scripts, aws_ec2_instance_state.main, aws_ec2_instance_state.worker]
}

# Obtiene o cambia el certificado HTTPS. Corre cuando cambian los dominios, el modo
# staging o se recrea la principal (el primer arranque no pide certificado).
resource "terraform_data" "cms_https" {
  count = var.main_running ? 1 : 0

  triggers_replace = {
    main_id = aws_instance.main.id
    domains = join(" ", values(local.domains))
    email   = var.letsencrypt_email
    staging = var.letsencrypt_staging
  }

  provisioner "local-exec" {
    command     = "${path.module}/run-on-main.sh ${aws_instance.main.id} ${var.region} cms-https"
    environment = local.aws_cli_env
  }

  depends_on = [aws_s3_object.config, aws_ec2_instance_state.main, cloudflare_dns_record.cms]
}
