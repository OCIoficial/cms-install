# ---------------------------------------------------------------------------
# Operación: lo que se cambia durante la temporada
# ---------------------------------------------------------------------------

variable "workers_running" {
  description = "true: workers encendidos (competencia). false: workers apagados y un worker corre en la principal (preparación)."
  type        = bool
}

variable "contest_id" {
  description = "Concurso al que se asocia CMS (necesario para el ranking). ALL mientras se preparan los concursos."
  type        = string
  default     = "ALL"

  validation {
    condition     = can(regex("^(ALL|[0-9]+)$", var.contest_id))
    error_message = "contest_id debe ser \"ALL\" o el número del concurso."
  }
}

variable "main_running" {
  description = "false apaga la máquina principal (se conservan disco y datos)."
  type        = bool
  default     = true
}

variable "worker_count" {
  description = "Cantidad de máquinas worker."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 0 && var.worker_count <= 50
    error_message = "worker_count debe estar entre 0 y 50."
  }
}

variable "main_workers" {
  description = "Workers de CMS en la máquina principal. null = automático (0 si workers_running, 1 si no)."
  type        = number
  default     = null
}

variable "cms_ref" {
  description = "Commit de cms-dev/cms a instalar. Solo afecta a instancias nuevas."
  type        = string
}

# ---------------------------------------------------------------------------
# Dominio y HTTPS
# ---------------------------------------------------------------------------

variable "domain" {
  description = "Zona de Cloudflare."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID de la zona en Cloudflare (Overview de la zona, columna derecha). Va en secrets.auto.tfvars."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id debe ser el Zone ID de Cloudflare (32 caracteres hexadecimales), en secrets.auto.tfvars. Ver README, sección Credenciales."
  }
}

variable "subdomains" {
  description = "Subdominios para cada servicio web."
  type = object({
    contest = string
    admin   = string
    ranking = string
  })
}

variable "letsencrypt_email" {
  description = "Correo para avisos de Let's Encrypt. Va en secrets.auto.tfvars."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.letsencrypt_email))
    error_message = "letsencrypt_email debe ser un correo válido, en secrets.auto.tfvars. Ver README, sección Credenciales."
  }
}

variable "letsencrypt_staging" {
  description = "true usa certificados de prueba (no válidos en el navegador, sin límite de emisión). Usar en pruebas."
  type        = bool
  default     = false
}

# Los tokens van en terraform/secrets.auto.tfvars (no se versiona). Ver README, "Credenciales".
variable "cloudflare_api_token" {
  description = "Token de Cloudflare (DNS edit) con que Terraform crea los registros DNS. null: se usa CLOUDFLARE_API_TOKEN del entorno."
  type        = string
  sensitive   = true
  default     = null
}

variable "cloudflare_certbot_token" {
  description = "Token de Cloudflare (DNS edit) que usa certbot en la principal."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# AWS
# ---------------------------------------------------------------------------

variable "aws_profile" {
  description = "Perfil de la AWS CLI (aws configure sso) con que Terraform se conecta a AWS. null: se usa AWS_PROFILE o las credenciales del entorno."
  type        = string
  default     = "oci-admin"
}

variable "region" {
  description = "Región de AWS."
  type        = string
  default     = "us-east-2"
}

variable "ssh_public_key_path" {
  description = "Llave pública SSH con la que te conectarás a la principal."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_allowed_cidrs" {
  description = "Redes desde las que se permite SSH a la principal."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "main_instance_type" {
  type    = string
  default = "t3.large"
}

variable "worker_instance_type" {
  type    = string
  default = "c7i.large"
}

variable "main_disk_gb" {
  type    = number
  default = 20
}

variable "worker_disk_gb" {
  type    = number
  default = 12
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "admin_username" {
  description = "Usuario del AdminWebServer que se crea al inicio."
  type        = string
  default     = "admin"
}
