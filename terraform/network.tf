locals {
  # Rango privado de la VPC. Es arbitrario (la VPC no se conecta a otras redes),
  # pero test/run.sh usa las mismas IPs.
  vpc_cidr    = "10.20.0.0/16"
  subnet_cidr = "10.20.1.0/24"
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "cms" {
  cidr_block           = local.vpc_cidr
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
  cidr_block              = local.subnet_cidr
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

# Todas las máquinas: se conectan libremente entre ellas (servicios de CMS,
# Postgres, SSH) y salen a internet. Nada entra desde fuera de la VPC.
resource "aws_security_group" "cluster" {
  name_prefix = "cms-cluster-"
  description = "CMS hosts"
  vpc_id      = aws_vpc.cms.id
  tags        = { Name = "cms-cluster" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cluster" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "CMS services, Postgres and SSH between hosts"
  ip_protocol                  = "tcp"
  from_port                    = 0
  to_port                      = 65535
  referenced_security_group_id = aws_security_group.cluster.id
}

resource "aws_vpc_security_group_egress_rule" "cluster" {
  security_group_id = aws_security_group.cluster.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Solo la principal: web pública (nginx) y SSH restringido
resource "aws_security_group" "main" {
  name_prefix = "cms-main-"
  description = "CMS main host"
  vpc_id      = aws_vpc.cms.id
  tags        = { Name = "cms-main" }

  lifecycle {
    create_before_destroy = true
  }
}

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
