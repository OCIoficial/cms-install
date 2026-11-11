data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "cms" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  tags                 = { Name = "cms" }
}

resource "aws_internet_gateway" "cms" {
  vpc_id = aws_vpc.cms.id
  tags   = { Name = "cms" }
}

# Una subred pública. Los workers tienen IP pública solo para salir a internet
# (apt, pip); su security group no acepta conexiones desde fuera de la VPC.
resource "aws_subnet" "cms" {
  vpc_id                  = aws_vpc.cms.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "cms" }
}

resource "aws_route_table" "cms" {
  vpc_id = aws_vpc.cms.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.cms.id
  }

  tags = { Name = "cms" }
}

resource "aws_route_table_association" "cms" {
  subnet_id      = aws_subnet.cms.id
  route_table_id = aws_route_table.cms.id
}

# ---------------------------------------------------------------------------
# Security groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "main" {
  name_prefix = "cms-main-"
  description = "CMS main host"
  vpc_id      = aws_vpc.cms.id
  tags        = { Name = "cms-main" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "worker" {
  name_prefix = "cms-worker-"
  description = "CMS workers"
  vpc_id      = aws_vpc.cms.id
  tags        = { Name = "cms-worker" }

  lifecycle {
    create_before_destroy = true
  }
}

# Principal: web pública (nginx), SSH restringido y todo TCP desde los workers
resource "aws_vpc_security_group_ingress_rule" "main_web" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.main.id
  description       = "nginx"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "main_ssh" {
  for_each          = toset(var.ssh_allowed_cidrs)
  security_group_id = aws_security_group.main.id
  description       = "SSH"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "main_from_workers" {
  security_group_id            = aws_security_group.main.id
  description                  = "CMS services and Postgres from workers"
  ip_protocol                  = "tcp"
  from_port                    = 0
  to_port                      = 65535
  referenced_security_group_id = aws_security_group.worker.id
}

# Workers: solo aceptan conexiones desde la principal (CMS y SSH)
resource "aws_vpc_security_group_ingress_rule" "worker_from_main" {
  security_group_id            = aws_security_group.worker.id
  description                  = "CMS services and SSH from main"
  ip_protocol                  = "tcp"
  from_port                    = 0
  to_port                      = 65535
  referenced_security_group_id = aws_security_group.main.id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each          = { main = aws_security_group.main.id, worker = aws_security_group.worker.id }
  security_group_id = each.value
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
