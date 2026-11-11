# Registros DNS en Cloudflare apuntando a la IP fija de la principal. Solo se
# manejan estos registros; el resto de la zona no se toca.

resource "cloudflare_dns_record" "cms" {
  for_each = local.domains
  zone_id  = var.cloudflare_zone_id
  name     = each.value
  type     = "A"
  content  = aws_eip.main.public_ip
  ttl      = 60
  proxied  = false # DNS only: la IP real de los participantes debe llegar a CMS
  comment  = "CMS (Terraform)"
}
