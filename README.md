# CMS en AWS

Despliegue de [CMS](https://github.com/cms-dev/cms) para la OCI en AWS con Terraform. Un solo `terraform apply` crea la red, las máquinas, el DNS en Cloudflare y el certificado HTTPS. Al primer arranque, las máquinas instalan y configuran CMS sin pasos manuales.

## Paso a paso

### Primera vez

1. Instalar [Terraform](https://developer.hashicorp.com/terraform/install) ≥ 1.10, AWS CLI v2, jq y Node.js con npm (en Arch: `pacman -S terraform aws-cli-v2 jq nodejs npm`). Node se usa para compilar el [importador de usuarios](#importar-usuarios) en cada `terraform plan`/`apply`.
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
   - `ranking_public = true`, si el ranking debe verse sin contraseña durante la competencia (ver [Ranking](#ranking)).
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

## Ranking

El ranking (`terraform output urls`) pide usuario y contraseña, para que no se vean los nombres de los problemas ni los participantes mientras se prepara el concurso:

```bash
terraform output -raw ranking_password   # usuario: oci
```

Para abrirlo, `ranking_public = true` en `terraform.tfvars` y `terraform apply`; para volver a protegerlo, `false` (el valor por defecto). El cambio solo recarga nginx (con `cms-https`): no reinicia CMS. CMS le manda los datos al ranking directamente, sin pasar por nginx, así que la contraseña no lo afecta.

Esta contraseña es solo para ver. La que usa CMS para escribir en el ranking es otra y no se entrega.

## Importar usuarios

En `https://<admin>/import-users/` (el mismo dominio del panel de administración) hay una página para crear usuarios en lote y asociarlos a un concurso con su región. Usa la sesión del panel: hay que entrar primero al panel con un administrador que tenga todos los permisos.

1. En Google Sheets, seleccionar las celdas (con o sin la fila de títulos), `Ctrl+C`, y `Ctrl+V` en la página.
2. Arrastrar cada columna al campo que corresponde: *Username*, *First name*, *Last name*, *Password*, *Email* y *Region*. Las columnas sin asignar se ignoran. Si la primera fila son títulos, marcar *First row is a header*.
3. Elegir el concurso, o ninguno para solo crear usuarios.
4. Revisar la vista previa. Los errores se corrigen en la planilla y se vuelve a pegar (las columnas asignadas se mantienen). *Import* escribe todo en una sola transacción: si una fila tiene error, no se importa nada.

Reglas:

- **Usuario nuevo:** necesita nombre, apellido y contraseña. Las contraseñas no se generan: vienen en la planilla y quedan en texto plano (visibles en el panel). Nombres y apellidos se normalizan (espacios y mayúscula inicial: `"  MARÍA  JOSÉ "` → `María José`). El username se usa tal cual y solo puede tener letras, dígitos, `_` y `-`.
- **Usuario que ya existe:** no se modifica. Si la fila trae nombre, apellido, contraseña o correo, deben coincidir con los de CMS; si no, es un error. Así las mismas filas sirven para agregar a otro concurso a usuarios ya creados.
- **Región:** el equipo del usuario en el concurso, que el ranking muestra con su bandera. Acepta el código (`biobio`), el nombre (`Biobío`, `Región del Biobío`) o una ciudad (`Concepción`), sin importar tildes ni mayúsculas. Las regiones están en `import-users/data/teams.csv` (con los mismos códigos que `ranking/flags/`) y las ciudades en `import-users/data/cities.csv`; para agregar una ciudad, editar ese archivo y hacer `terraform apply`. Una región vacía deja al usuario sin equipo. Sin concurso, la región se ignora.
- **Ya está en el concurso:** se actualiza su región.

Si CMS está asociado al concurso (`contest_id`), el ranking se actualiza al importar.

El código está en `import-users/`: el backend en Python (`server/`, corre con el Python de CMS en el servicio `cms-import-users`) y el frontend en Svelte (`frontend/`). Terraform ejecuta `import-users/build.sh` en cada plan, que compila el frontend (con `npm ci` si cambiaron las dependencias), y sube el resultado a S3 como `import-users.zip`. Cuando cambia, el `apply` lo instala en la principal con `cms-import-users-update`, sin reiniciar CMS. Pruebas: `python3 import-users/server/test_rules.py` y, en `import-users/frontend/`, `npm test` y `npm run check`.

## Subir problemas

`tools/cms-task-push` sube a CMS un concurso preparado con [ocimatic](https://github.com/OCIoficial/ocimatic): crea las tareas (o reemplaza sus casos), envía las soluciones del concurso, fija el límite de tiempo de cada tarea con los tiempos medidos en los workers y revisa que cada solución dé lo esperado en cada subtarea. Se usa antes de la competencia, cuando todavía no hay envíos de participantes.

1. Crear el concurso en el panel de administración (nombre, fechas, lenguajes). El script solo le agrega tareas.
2. Encender los workers (`workers_running = true` y `terraform apply`). Con los workers apagados evalúa la principal, sus tiempos no sirven y el script se niega a seguir.
3. En la carpeta del concurso de ocimatic:
   ```bash
   ocimatic run-testplan && ocimatic gen-expected && ocimatic export-cms
   ```
   Deja `cms-export.zip` en la raíz del concurso, con todas las tareas.
4. Desde este repo:
   ```bash
   tools/cms-task-push ~/oci/2026/2026-11-Regional --contest <id>
   ```
   Tarda varios minutos y muestra el avance y, al final, un reporte por tarea:
   ```
   == suma: límite 0.5 s, OK
     solución          st1  st2  tiempo
     correct/suma.cpp  OK   OK   0.002s
     partial/mal.cpp   OK   WA   0.002s
   ```
   La importación corre en la principal como servicio de systemd: si se corta la conexión o haces Ctrl-C, sigue. `tools/cms-task-push --attach` vuelve a mostrar su log (o el de la última, si ya terminó). Solo corre una a la vez.

Cómo funciona (`scripts/cms_task/`, en la principal con `sudo cms-task start|attach`):

- **Tareas.** Las que no existen se crean; las que existen reciben un dataset nuevo, que reemplaza al antiguo al final. Quedan en el orden del problemset (`priority` de ocimatic) y antes de las demás tareas del concurso. Una tarea que ya está en otro concurso es un error.
- **Configuración.** Batch con entrada y salida estándar, `GroupMin` con los puntajes del enunciado, todos los casos públicos, 256 MiB, feedback completo y puntaje por subtarea (`max_subtask`). Si la tarea tiene checker (`managers/checker.cpp`), se compila en la principal (`g++ -static -I managers`) y se usa como comparador; si tiene `grader.cpp`, se sube con los headers de `managers/`.
- **Envíos.** Los hace el usuario `tester`, con una participación oculta (no sale en el ranking) y sin restricciones, que el script crea. Lenguajes: C++20, Python 3 y Java; Rust no, porque los workers no tienen `rustc`.
- **Límite de tiempo.** Primero se evalúan las soluciones correctas que cuentan para el límite (las que no son Python, salvo `@ocimatic::include-in-stats`) con un límite de 10 s. El límite es el de ocimatic, `ceil(max * 4) / 2` sobre su tiempo de CPU máximo. Con ese límite se reevalúan y se envían las demás.
- **Todo o nada.** Si una solución no da lo esperado, algo no compila o un caso lo evaluó la principal, se borran las tareas y los datasets creados y el concurso queda como estaba. Si todo calza, se activan los datasets nuevos, se borran los antiguos (con sus evaluaciones) y los envíos de `tester` de importaciones anteriores, y se avisa al ranking.

`ocimatic export-cms` y este script comparten el formato del zip (`format_version` en `contest.json`); si no coinciden, el script lo dice. Pruebas sin CMS: `python3 -m unittest discover -s scripts/cms_task -t scripts`.

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
- **Servicios** (systemd): `cms-log`, `cms-ranking` y `cms-import-users` en la principal, y `cms-resource` en todas las máquinas. Este último levanta los servicios de CMS que le corresponden a cada máquina según su IP.
- **Acceso.** SSH a la principal con tu llave (`ssh_public_key_path`) o por SSM (`terraform output ssm_main`). A los workers, pasando por la principal: `ssh -J ubuntu@<ip> ubuntu@10.20.1.11` (el comando de cada uno está en `terraform output workers`).

### Comandos en la principal

| Comando | Qué hace |
|---|---|
| `sudo cms-contest <id\|ALL>` | Baja la configuración, asocia CMS al concurso y reinicia CMS en la principal. Terraform lo ejecuta solo al cambiar `contest_id` o la configuración, y después reinicia CMS en los workers encendidos (por SSM). |
| `sudo cms-update-scripts` | Baja `scripts/` desde S3 e instala comandos y servicios. Corre solo al arrancar y antes de cada comando que Terraform ejecuta en una máquina. |
| `sudo cms-ranking-reset` | Borra los datos del ranking y los vuelve a cargar desde CMS. |
| `sudo cms-https <correo> <true\|false> <dominio>...` | Baja la configuración de nginx y la contraseña del ranking, y obtiene o cambia el certificado HTTPS (`true`: certificado de prueba). Terraform lo ejecuta al crear o recrear la principal y al cambiar los subdominios, el correo, `letsencrypt_staging` o `ranking_public`. |
| `cms-backup` | Exporta los concursos a `~/cms-backups/`. Bajarlos con `scp` antes de `terraform destroy`. |
| `sudo cms-task start <zip> --contest <id>` | [Sube un concurso de ocimatic](#subir-problemas) y muestra el log; `sudo cms-task attach` vuelve a mostrarlo. Lo usa `tools/cms-task-push`. |
| `sudo cms-import-users-update` | Baja el [importador de usuarios](#importar-usuarios) desde S3 y lo reinicia. Terraform lo ejecuta cuando cambia `import-users/` o se recrea la principal. |
| `journalctl -u cms-resource -f` | Logs de CMS. Los logs detallados están en `~/cms/log/`. |

## Prueba local

`test/run.sh` prueba el despliegue sin AWS, en VMs de Incus con las mismas IPs y el mismo `user_data` que en EC2. Terraform real genera la configuración contra [moto](https://github.com/getmoto/moto), que simula S3. Prueba la principal y un worker en los cambios de un despliegue real: worker creado apagado con la instalación a medias, cambio de `scripts/`, preparación ↔ competencia, un `contest_id` específico y un `apply` sin cambios. Encender y apagar el worker y los comandos que Terraform ejecuta por SSM se imitan con incus. También prueba el importador de usuarios: entra al panel con curl, importa un usuario al concurso y revisa la base de datos y el ranking. Y `cms-task` con el concurso de `test/cms-task/` (una tarea con checker): que se niegue con los workers apagados, que importe y mida con el worker, que una segunda importación reemplace el dataset y que una importación con un resultado inesperado falle sin cambiar nada (logs en `test/.work/cms-task-*.log`). No prueba IAM, security groups, SSM ni HTTPS. Requiere `incus`, `terraform`, `aws`, `uv`, `node` y `npm`. `test/run.sh clean` borra todo.

## Versión de CMS

Se instala la rama `main` de CMS (1.6.dev0), fijada a un commit en `cms_ref` de `terraform.tfvars`. La última release, v1.5.1, usa el formato de configuración antiguo (`cms.conf`). Todas las máquinas deben tener el mismo commit. Como `cms_ref` solo se usa al crear una máquina, para actualizar CMS hay que recrearlas: `cms-backup` y bajar el respaldo con `scp`, cambiar `cms_ref`, `terraform apply -replace=aws_instance.main -replace='aws_instance.worker[0]' ...` y restaurar con `cmsDumpImporter`.

## Notas

- `workers_running` se cambia en `terraform.tfvars`, no con `-var`. Si no, un `terraform apply` posterior sin el `-var` apagaría los workers.
- Mientras se hacen pruebas de `destroy`/`apply`, usar `letsencrypt_staging = true`. Let's Encrypt emite como máximo 5 certificados por semana para los mismos dominios.
- El estado de Terraform queda en `terraform/terraform.tfstate`, solo en el computador de quien hizo el `apply`. No se versiona porque contiene las contraseñas. Si se pierde, Terraform ya no puede modificar ni borrar lo que creó; respaldarlo y pasárselo a quien vaya a administrar el despliegue.
- Respaldar CMS (`cms-backup` + `scp`) al terminar cada competencia y antes de cambiar `cms_ref` o hacer `destroy`.
- Cambios en `scripts/` llegan a las máquinas existentes con `terraform apply` (`cms-update-scripts`), y CMS se reinicia. Los scripts de instalación (`setup-*.sh`, `install-*.sh`) solo corren en máquinas nuevas.
