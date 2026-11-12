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
      role          = role
      region        = var.region
      assets_bucket = aws_s3_bucket.assets.id
      cms_ref       = var.cms_ref
      main_ip       = local.main_ip
      vpc_cidr      = local.vpc_cidr
      aws_cli_key   = trimspace(file("${path.module}/aws-cli.asc"))
    })
  }
}

# El user_data, la AMI y la llave solo se usan al crear una instancia, por eso
# ignore_changes: cambiarlos después no debe recrear máquinas (para eso:
# terraform apply -replace=...).

# ---------------------------------------------------------------------------
# Máquina principal: Postgres, servicios de CMS, ranking, nginx
# ---------------------------------------------------------------------------

resource "aws_instance" "main" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.main_instance_type
  subnet_id              = aws_subnet.cms.id
  private_ip             = local.main_ip
  vpc_security_group_ids = [aws_security_group.main.id, aws_security_group.cluster.id]
  key_name               = aws_key_pair.admin.key_name
  iam_instance_profile   = aws_iam_instance_profile.host["main"].name
  user_data              = local.user_data["main"]

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
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

# ---------------------------------------------------------------------------
# Workers: solo ejecutan soluciones. Se apagan cuando no hay competencia.
# ---------------------------------------------------------------------------

resource "aws_instance" "worker" {
  count                  = var.worker_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.worker_instance_type
  subnet_id              = aws_subnet.cms.id
  private_ip             = local.worker_ips[count.index]
  vpc_security_group_ids = [aws_security_group.cluster.id]
  key_name               = aws_key_pair.admin.key_name
  iam_instance_profile   = aws_iam_instance_profile.host["worker"].name
  user_data              = local.user_data["worker"]

  root_block_device {
    volume_type = "gp3"
    volume_size = 12
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
