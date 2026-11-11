data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_key_pair" "admin" {
  key_name_prefix = "cms-admin-"
  public_key      = file(pathexpand(var.ssh_public_key_path))
}

locals {
  user_data = {
    for role in ["main", "worker"] : role => templatefile("${path.module}/templates/user-data.sh.tftpl", {
      role              = role
      region            = var.region
      assets_bucket     = aws_s3_bucket.assets.id
      cms_ref           = var.cms_ref
      main_ip           = local.main_ip
      vpc_cidr          = var.vpc_cidr
      worker_ssh_pubkey = trimspace(tls_private_key.workers.public_key_openssh)
      aws_cli_key       = trimspace(file("${path.module}/aws-cli.asc"))
    })
  }

  # El user_data y la AMI solo se usan al crear la instancia. Cambiarlos después
  # no debe reiniciar ni recrear máquinas (para eso: terraform apply -replace=...).
  instance_common = {
    subnet_id = aws_subnet.cms.id
    ami       = data.aws_ami.ubuntu.id
    key_name  = aws_key_pair.admin.key_name
  }
}

# ---------------------------------------------------------------------------
# Máquina principal: Postgres, servicios de CMS, ranking, nginx
# ---------------------------------------------------------------------------

resource "aws_instance" "main" {
  ami                    = local.instance_common.ami
  instance_type          = var.main_instance_type
  subnet_id              = local.instance_common.subnet_id
  private_ip             = local.main_ip
  vpc_security_group_ids = [aws_security_group.main.id]
  key_name               = local.instance_common.key_name
  iam_instance_profile   = aws_iam_instance_profile.host["main"].name
  user_data              = local.user_data["main"]

  root_block_device {
    volume_type = "gp3"
    volume_size = var.main_disk_gb
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = "cms-main" }

  # Los scripts y la config tienen que estar en S3 antes del primer arranque
  depends_on = [aws_s3_object.scripts, aws_s3_object.config, aws_s3_object.secrets, aws_s3_object.ranking]

  lifecycle {
    ignore_changes = [ami, user_data, key_name]
  }
}

resource "aws_eip" "main" {
  domain   = "vpc"
  instance = aws_instance.main.id
  tags     = { Name = "cms-main" }
}

resource "aws_ec2_instance_state" "main" {
  instance_id = aws_instance.main.id
  state       = var.main_running ? "running" : "stopped"
}

# ---------------------------------------------------------------------------
# Workers: solo ejecutan soluciones. Se apagan cuando no hay competencia.
# ---------------------------------------------------------------------------

resource "aws_instance" "worker" {
  count                  = var.worker_count
  ami                    = local.instance_common.ami
  instance_type          = var.worker_instance_type
  subnet_id              = local.instance_common.subnet_id
  private_ip             = local.worker_ips[count.index]
  vpc_security_group_ids = [aws_security_group.worker.id]
  key_name               = local.instance_common.key_name
  iam_instance_profile   = aws_iam_instance_profile.host["worker"].name
  user_data              = local.user_data["worker"]

  root_block_device {
    volume_type = "gp3"
    volume_size = var.worker_disk_gb
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = "cms-worker-${count.index + 1}" }

  depends_on = [aws_s3_object.scripts, aws_s3_object.config]

  lifecycle {
    ignore_changes = [ami, user_data, key_name]
  }
}

resource "aws_ec2_instance_state" "worker" {
  count       = var.worker_count
  instance_id = aws_instance.worker[count.index].id
  state       = var.workers_running ? "running" : "stopped"
}
