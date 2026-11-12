# CMS en AWS

Despliegue de [CMS](https://github.com/cms-dev/cms) para la OCI en AWS con Terraform. Un solo `terraform apply` crea la red, las máquinas, el DNS en Cloudflare y el certificado HTTPS. Al primer arranque, las máquinas instalan y configuran CMS sin pasos manuales.

## Paso a paso

### Primera vez

1. Instalar [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.10, AWS CLI v2 y jq (en Arch: `pacman -S terraform aws-cli-v2 jq`).
2. Configurar las [credenciales](#credenciales) y crear `terraform/secrets.auto.tfvars`.
3. Si tu llave pública SSH no es `~/.ssh/id_ed25519.pub`, definir `ssh_public_key_path` en `terraform/terraform.tfvars`.
4. Crear todo:
   ```bash
   cd terraform
   terraform init
   terraform apply
   ```
   El `apply` espera a que termine la instalación en la principal (unos 15 minutos) y falla si la instalación falló.
5. Entrar al [panel de administración](#panel-de-administración).
6. Apagar los workers mientras se prepara el concurso: en `terraform.tfvars` poner `workers_running = false` y hacer `terraform apply`.

Desde aquí se preparan los concursos en el panel de administración. Los envíos se evalúan con un worker que corre en la máquina principal.

### Antes de la competencia (≈1 hora antes)

1. En `terraform.tfvars`:
   - `workers_running = true`
   - `contest_id = "<número>"`: el id del concurso en el panel de administración. Activa el ranking.
   - `letsencrypt_staging = false`, si aún estaba en `true`.
2. `terraform apply`. Enciende los workers, reinicia CMS con la configuración nueva (los envíos los evalúan los workers) y, si cambió `letsencrypt_staging`, obtiene el certificado real.
3. Si el ranking tiene datos de pruebas: `ssh ubuntu@<ip> sudo cms-ranking-reset`.
4. Hacer un envío de prueba y revisar en el panel de administración que lo evaluó un worker remoto.

Después de la competencia: `workers_running = false` y `terraform apply`.

Al terminar la temporada: respaldar (`cms-backup` en la principal y `scp ubuntu@<ip>:cms-backups/*.tar.gz .`) y luego `terraform destroy`.

> Cuando cambia `contest_id` o la configuración de CMS (por ejemplo `workers_running`), `terraform apply` reinicia CMS en todas las máquinas. Evitar hacerlo durante una competencia.

## Panel de administración

En el primer arranque se crea el usuario `admin` con una contraseña generada al azar por Terraform. Desde `terraform/`:

```bash
terraform output urls                  # URL del panel (admin)
terraform output -raw admin_password   # contraseña del usuario admin
```

Para agregar más administradores (mejor uno por persona): desde la sección **Admins** del panel, o en la principal con `~/cms/bin/cmsAddAdmin <usuario> -p <contraseña>`.

## Credenciales

Terraform usa el perfil `oci-admin` de la AWS CLI (variable `aws_profile`) y lee los datos de Cloudflare y el correo de Let's Encrypt de `terraform/secrets.auto.tfvars`. Terraform carga ese archivo solo, y está en `.gitignore`, así que no se versiona. Crearlo así:

```hcl
cloudflare_zone_id       = "..."      # Zone ID de olimpiada-informatica.cl
cloudflare_api_token     = "cfut_..." # token cms-terraform
cloudflare_certbot_token = "cfut_..." # token cms-certbot
letsencrypt_email        = "..."      # correo para los avisos de vencimiento del certificado
```

### AWS

No usar el usuario root. Se usa un usuario de IAM Identity Center (gratis) con credenciales temporales:

1. Como root, en la consola: **IAM Identity Center → Enable** (región US East (Ohio), con AWS Organizations).
2. **Users → Add user** con tu correo. Acepta la invitación que llega por correo y define contraseña y MFA.
3. **Permission sets → Create → Predefined → AdministratorAccess** (sesión de 8 h o más).
4. **AWS accounts →** marcar la cuenta **→ Assign users or groups →** tu usuario con `AdministratorAccess`.
5. En tu máquina:
   ```bash
   aws configure sso   # Start URL: la "AWS access portal URL" del dashboard de Identity Center
                       # SSO region y default region: us-east-2
                       # Profile name: oci-admin (si usas otro, definir aws_profile en terraform.tfvars)
   ```
6. Cuando la sesión expire: `aws sso login --profile oci-admin`.

### Cloudflare

Se necesitan dos tokens con el mismo permiso: editar el DNS de `olimpiada-informatica.cl`, y nada más. Uno es para Terraform y otro para certbot, que queda guardado en la principal. Para crear cada uno ([documentación](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)):

1. En el dashboard de Cloudflare: **My Profile → API Tokens → Create Token**.
2. En la plantilla **Edit zone DNS**, **Use template**.
3. **Token name:** `cms-terraform`.
4. **Policies:** la plantilla trae una política, *Edit Zone policy*. Al abrirla:
   - En la regla de recursos, elegir **Include · Specific zone · `olimpiada-informatica.cl`**.
   - En los permisos, cada categoría muestra un contador, como `0/28`. Solo debe tener uno marcado la de DNS, con *Edit* (o *Write*), como viene en la plantilla. No marcar nada más.
5. **Token expiration** y **Client IP address filtering:** dejar vacíos. Si el token de certbot vence, la renovación del certificado falla sin aviso.
6. **Continue to summary.** Debe mostrar un solo permiso, DNS Edit (o Write), y solo en `olimpiada-informatica.cl`. Si no, **Back** y corregir.
7. **Create Token** y copiar el valor en `terraform/secrets.auto.tfvars`. Empieza con `cfut_` y se muestra una sola vez.

Un token ya creado se puede editar desde la lista de **API Tokens**, con los mismos campos de los pasos 4 y 5. Para comprobar que funciona:

```bash
curl -s -H "Authorization: Bearer cfut_..." \
  https://api.cloudflare.com/client/v4/user/tokens/verify   # debe decir "status": "active"
```

Los tokens de **My Profile** dependen de tu usuario: si sales de la cuenta de Cloudflare, dejan de funcionar. Si la cuenta tiene varios miembros, conviene crearlos en **Manage Account → Account API Tokens**, con la misma configuración. El permiso y la zona deben quedar iguales: *Zone · DNS · Edit*, solo en `olimpiada-informatica.cl`. Para crearlos hay que ser *Super Administrator* de la cuenta o tener permiso para crear tokens de cuenta. Estos tokens se verifican en `https://api.cloudflare.com/client/v4/accounts/<account_id>/tokens/verify`.

| Token | Variable | Uso |
|---|---|---|
| `cms-terraform` | `cloudflare_api_token` | Terraform crea y borra los registros DNS. Solo vive en tu máquina. |
| `cms-certbot` | `cloudflare_certbot_token` | Terraform lo copia a la principal para obtener y renovar el certificado HTTPS. |

El `cloudflare_zone_id` está en la página **Overview** de la zona, en la columna derecha.

## Arquitectura

```
Internet ── 443 ──► cms-main (t3.large, IP fija, DNS en Cloudflare)
                      nginx → ContestWebServer / AdminWebServer / Ranking
                      PostgreSQL y el resto de los servicios de CMS
                      │  red privada 10.20.1.0/24
                      ├── worker-1 (c7i.large, 10.20.1.11)
                      └── worker-2 (c7i.large, 10.20.1.12)
```

- **Terraform** (`terraform/`) crea una VPC propia, los security groups, las máquinas, un bucket S3 con scripts y configuración, los secretos (contraseñas generadas al azar) y los registros DNS. `terraform destroy` borra todo eso, incluidos los datos de CMS.
- **Workers apagados por defecto.** Con `workers_running = false` quedan detenidos y solo se paga su disco. Un worker de CMS corre en la principal para poder probar. Con `true` se encienden y la principal deja de evaluar. Tienen IPs privadas fijas, así que la configuración no cambia al apagarlos y encenderlos.
- **Configuración.** Terraform genera `cms.toml` y lo sube a S3. Cada máquina lo baja al iniciar los servicios de CMS (`cms-sync-config`), así que cambiar la configuración no recrea máquinas.
- **Primer arranque.** Cada máquina baja `scripts/` desde S3 y ejecuta `setup-main.sh` o `setup-worker.sh`: dependencias, isolate, CMS en `/home/ubuntu/cms` y servicios systemd. En la principal también PostgreSQL, el administrador y nginx. Si la máquina se apaga a medias, la instalación sigue en el próximo arranque. Log: `/var/log/cloud-init-output.log`.
- **HTTPS.** Al final del `apply`, Terraform ejecuta `cms-https` en la principal: certificado de Let's Encrypt con verificación DNS en Cloudflare. Queda fuera del primer arranque para que un error de certbot se pueda reintentar con otro `apply`.
- **Servicios** (systemd): `cms-log` y `cms-ranking` en la principal, y `cms-resource` en todas las máquinas. Este último levanta los servicios de CMS que le corresponden a cada máquina según su IP.
- **Acceso.** SSH a la principal con tu llave (`ssh_public_key_path`) o por SSM (`terraform output ssm_main`). A los workers, pasando por la principal: `ssh -J ubuntu@<ip> ubuntu@10.20.1.11` (el comando de cada uno está en `terraform output workers`).

### Comandos en la principal

| Comando | Qué hace |
|---|---|
| `sudo cms-contest <id\|ALL>` | Baja la configuración, asocia CMS al concurso y reinicia CMS en la principal. Terraform lo ejecuta solo al cambiar `contest_id` o la configuración, y después reinicia CMS en los workers encendidos (por SSM). |
| `sudo cms-update-scripts` | Baja `scripts/` desde S3 e instala comandos y servicios. Corre solo al arrancar y antes de cada comando que Terraform ejecuta en una máquina. |
| `sudo cms-ranking-reset` | Borra los datos del ranking y los vuelve a cargar desde CMS. |
| `sudo cms-https <correo> <true\|false> <dominio>...` | Obtiene o cambia el certificado HTTPS (`true`: certificado de prueba). Terraform lo ejecuta al crear o recrear la principal y al cambiar los subdominios, el correo o `letsencrypt_staging`. |
| `cms-backup` | Exporta los concursos a `~/cms-backups/`. Bajarlos con `scp` antes de `terraform destroy`. |
| `journalctl -u cms-resource -f` | Logs de CMS. Los logs detallados están en `~/cms/log/`. |

## Prueba local

`test/run.sh` prueba el despliegue sin AWS, en VMs de Incus con las mismas IPs y el mismo `user_data` que en EC2. Terraform real genera la configuración contra [moto](https://github.com/getmoto/moto), que simula S3. Prueba la principal y un worker en los cambios de un despliegue real: worker creado apagado con la instalación a medias, cambio de `scripts/`, preparación ↔ competencia, un `contest_id` específico y un `apply` sin cambios. Encender y apagar el worker y los comandos que Terraform ejecuta por SSM se imitan con incus. No prueba IAM, security groups, SSM ni HTTPS. Requiere `incus`, `terraform`, `aws` y `uv`. `test/run.sh clean` borra todo.

## Versión de CMS

Se instala la rama `main` de CMS (1.6.dev0), fijada a un commit en `cms_ref` de `terraform.tfvars`. La última release, v1.5.1, usa el formato de configuración antiguo (`cms.conf`). Todas las máquinas deben tener el mismo commit. Como `cms_ref` solo se usa al crear una máquina, para actualizar CMS hay que recrearlas: `cms-backup` y bajar el respaldo con `scp`, cambiar `cms_ref`, `terraform apply -replace=aws_instance.main -replace='aws_instance.worker[0]' ...` y restaurar con `cmsDumpImporter`.

## Notas

- `workers_running` se cambia en `terraform.tfvars`, no con `-var`. Si no, un `terraform apply` posterior sin el `-var` apagaría los workers.
- Mientras se hacen pruebas de `destroy`/`apply`, usar `letsencrypt_staging = true`. Let's Encrypt emite como máximo 5 certificados por semana para los mismos dominios.
- El estado de Terraform queda en `terraform/terraform.tfstate`, solo en el computador de quien hizo el `apply`. No se versiona porque contiene las contraseñas. Si se pierde, Terraform ya no puede modificar ni borrar lo que creó; respaldarlo y pasárselo a quien vaya a administrar el despliegue.
- Respaldar CMS (`cms-backup` + `scp`) al terminar cada competencia y antes de cambiar `cms_ref` o hacer `destroy`.
- Cambios en `scripts/` llegan a las máquinas existentes con `terraform apply` (`cms-update-scripts`), y CMS se reinicia. Los scripts de instalación (`setup-*.sh`, `install-*.sh`) solo corren en máquinas nuevas.
