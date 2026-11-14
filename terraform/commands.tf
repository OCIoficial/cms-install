# Comandos que Terraform ejecuta en las máquinas (vía SSM) cuando cambia algo,
# para que no haya que entrar a ellas. Un `terraform apply` sin cambios no
# ejecuta nada.

locals {
  # run-on-instance.sh usa la AWS CLI con el mismo perfil que Terraform
  aws_cli_env = var.aws_profile == null ? {} : { AWS_PROFILE = var.aws_profile }
}

# Asocia CMS al concurso y reinicia CMS en la principal, después de actualizar
# sus scripts. Corre cuando cambia contest_id, la configuración de CMS (p. ej.
# workers_running), algún archivo de scripts/ o se recrea la principal.
resource "terraform_data" "cms_contest" {
  triggers_replace = {
    main_id    = aws_instance.main.id
    contest_id = var.contest_id
    cms_toml   = sha256(local.cms_toml)
    scripts    = data.archive_file.scripts.output_sha256
  }

  provisioner "local-exec" {
    command     = "${path.module}/run-on-instance.sh ${aws_instance.main.id} ${var.region} cms-contest ${var.contest_id}"
    environment = local.aws_cli_env
  }

  # La config y los scripts nuevos tienen que estar en S3 antes de reiniciar
  depends_on = [aws_s3_object.config, aws_s3_object.scripts]
}

# Actualiza los scripts y reinicia CMS en cada worker encendido, después de la
# principal. Corre cada vez que corre cms_contest o se recrea el worker.
resource "terraform_data" "cms_worker_restart" {
  count = var.workers_running ? var.worker_count : 0

  triggers_replace = {
    cms_contest = terraform_data.cms_contest.id
    worker_id   = aws_instance.worker[count.index].id
  }

  provisioner "local-exec" {
    command     = "${path.module}/run-on-instance.sh ${aws_instance.worker[count.index].id} ${var.region} systemctl restart cms-resource.service"
    environment = local.aws_cli_env
  }

  depends_on = [aws_ec2_instance_state.worker]
}

# Obtiene o cambia el certificado HTTPS. Corre cuando cambian los dominios, el
# correo, el modo staging, la configuración de nginx o la contraseña del ranking
# (cms-https las vuelve a bajar) o se recrea la principal (el primer arranque no
# pide certificado).
resource "terraform_data" "cms_https" {
  triggers_replace = {
    main_id = aws_instance.main.id
    args    = "${var.letsencrypt_email} ${var.letsencrypt_staging} ${join(" ", values(local.domains))}"
    nginx   = sha256(local.cms_nginx)
    ranking = sha256(local.ranking_htpasswd)
  }

  provisioner "local-exec" {
    command     = "${path.module}/run-on-instance.sh ${aws_instance.main.id} ${var.region} cms-https ${self.triggers_replace.args}"
    environment = local.aws_cli_env
  }

  depends_on = [aws_s3_object.config, aws_s3_object.secrets, cloudflare_dns_record.cms]
}

# Instala o actualiza el importador de usuarios (/import-users en el dominio del
# admin). Corre cuando cambia import-users/ o se recrea la principal. No
# reinicia CMS.
resource "terraform_data" "import_users" {
  triggers_replace = {
    main_id = aws_instance.main.id
    zip     = data.archive_file.import_users.output_sha256
  }

  provisioner "local-exec" {
    command     = "${path.module}/run-on-instance.sh ${aws_instance.main.id} ${var.region} cms-import-users-update"
    environment = local.aws_cli_env
  }

  depends_on = [aws_s3_object.import_users, aws_s3_object.scripts]
}
