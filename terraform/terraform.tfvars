# Configuración del despliegue. Se versiona en git (no contiene secretos).

# --- Operación --------------------------------------------------------------
# true: workers encendidos (competencia). false: apagados, 1 worker en la principal.
workers_running = true
worker_count    = 2

# "ALL" mientras se preparan los concursos. El día de la competencia, el número
# del concurso (necesario para el ranking). Terraform reinicia CMS al cambiarlo.
contest_id = "ALL"

# Commit de cms-dev/cms (rama main, 1.6.dev0). Solo afecta a máquinas nuevas.
cms_ref = "bcf7a88f1d2ab35d9469dc7e2e185e1452d78e5e"

# --- AWS --------------------------------------------------------------------
# ssh_public_key_path = "~/.ssh/id_ed25519.pub"
# ssh_allowed_cidrs   = ["0.0.0.0/0"]

# --- Dominio y HTTPS --------------------------------------------------------
domain             = "olimpiada-informatica.cl"
cloudflare_zone_id = "TODO"
subdomains = {
  contest = "cms"
  admin   = "cms-admin"
  ranking = "ranking"
}
letsencrypt_email = "TODO"
# true mientras se prueba (destroy/apply frecuentes): evita el límite de Let's Encrypt
letsencrypt_staging = true
