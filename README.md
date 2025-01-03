
# Instalación de CMS en AWS

Este repositorio contiene scripts e instrucciones para instalar [cms](https://github.com/cms-dev/cms) en AWS.

## Introducción

En la configuración típica de la OCI usamos tres instancias de EC2

* Una instancia `t2.large` es designada como la máquina principal y corre la base de datos y la mayoría de los servicios de CMS.
* Dos instancias `t2.small` corren cada una solo un worker.

Las instancias corriendo los workers tienen que tener acceso de red a la máquina principal para poder acceder a la base de datos y a los servicios de cms.

## Configurar red

Para configurar la red necesitamos dos security groups con las siguientes configuraciones. (*nota* el AWS de la OCI ya tiene estos security groups creados)

### oci-main

Este es el security group que se asignará a la maquina principal. Notar que el main host debe poder recibir todo tipo de conexión desde los workers entre los puertos 0 y 65535. Además debe poder recibir conexiones desde fuera de la red (pública) en los puertos 22, 80, 443, 8890, 8888 y 8889.

| IP Version | Type       | Protocol | Port range | Source         | Description         |
|------------|------------|----------|------------|----------------|---------------------|
| IPv4       | HTTPS      | TCP      | 443        | 0.0.0.0/0      |                     |
| IPv4       | HTTP       | TCP      | 80         | 0.0.0.0/0      |                     |
| IPv4       | SSH        | TCP      | 22         | 0.0.0.0/0      | SSH                 |
| IPv4       | Custom TCP | TCP      | 8890       | 0.0.0.0/0      | Ranking Web Service |
| IPv4       | Custom TCP | TCP      | 8888       | 0.0.0.0/0      | Contest Web Service |
| IPv4       | Custom TCP | TCP      | 8889       | 0.0.0.0/0      | Admin Web Service   |
| IPv4       | ALL TCP    | TCP      | 0 - 65535  | `<oci-worker>` |                     |

### oci-worker

Este es el security group que debe ser asignado a los workers. Los workers deben poder recibir conexiones desde la máquina principal entre los puertos 0 - 65535. Tambien es conveniente poder recibir conexiones ssh al puerto 22 desde el main host.

| IP Version | Type       | Protocol | Port range | Source         | Description         |
|------------|------------|----------|------------|----------------|---------------------|
| IPv4       | SSH        | TCP      | 22         | `<oci-main>`   | SSH                 |
| IPv4       | ALL TCP    | TCP      | 0 - 65535  | `<oci-main>`   |                     |


## Crear instancias EC2 en AWS

Para evitar gastos innecesarios, típicamente levantamos primero la instancia principal `t2.large` para configurar el contest y luego más cerca de la competencia levantamos los dos workers.
Crear la instancia principal en la consola de AWS con la siguiente configuración

### Máquina principal

* **Name and tags**
  * oci-main
* **Application and OS Images (Amazon Machine Image)**
  * Amazon Machine Image (AMI): `Ubuntu Server 22.04 LTS (HVM), SSD Volume Type`
  * Architecture: `64-bit(x86)`
  * *Nota*: hay una AMI guardada con que tiene ya instalado el CMS de la OCI 2022. Puedes seleccionarla en "browse more AMIs"
* **Instance Type**
  * Instance Type: `t2.large`
* **Key pair(login)**
  * Seleccionar un par de llaves al que tengas acceso, o crea uno nuevo. Históricamente hemos usamos `ociadmin`.
* **Network Setting**
  * Seleccionar "Select existing security group" y luego busca `oci-main`
* **Configure Storage**
  * 1x `16` GB `gp2`.

### Máquina para worker

* **Name and tags**
  * oci-worker-1 o oci-worker-2
* **Application and OS Images (Amazon Machine Image)**
  * Amazon Machine Image (AMI): `Ubuntu Server 22.04 LTS (HVM), SSD Volume Type`
  * Architecture: `64-bit(x86)`
  * *Nota*: Puedes usar la misma AMI que para la máquina principal
* **Instance Type**
  * Instance Type: `t2.small`
* **Key pair(login)**
  * Seleccionar un par de llaves al que tengas acceso, o crea uno nuevo. Históricamente hemos usamos `ociadmin`.
* **Network Setting**
  * Seleccionar "Select existing security group" y luego busca `oci-worker`
* **Configure Storage**
  * 1x `8` GB `gp2`.
 
## Instalar CMS

Si no seleccionaste la AMI y estás configurando una máquina desde cero debes instalar CMS y todas sus dependencias. CMS debe ser instado en todas las máquinas (la principal y los workers). 

```bash
$ git clone https://github.com/OCIoficial/cms-install
$ cd cms-install
$ ./install-cms.sh
```

### Logo

Copiar el logo de la oci para que aparesca en el ranking web ser

```bash
sudo cp cms-install/logo.png /usr/local/lib/python3.8/dist-packages/cms-1.5.dev0-py3.8.egg/cmsranking/static/img/logo.png
```

## Configurar máquina principal

### Instalar y configurar Postgres

Una vez conectado a la maquina principal clonar este repositorio. Luego correr el script `setup-postgres`. Esto instalará postgres y lo configurará para que pueda ser accedido desde los workers. Adicionalmente, creará una base de datos para cms. Puedes modificar el script para cambiar el usuario y nombre de la base de datos. Por defecto estos son `cmsdb` y `cmsuser`. Durante la creación de la base de datos el script preguntará por una contraseña. Debes recordar esta contraseña para configurar cms.

```bash
$ git clone https://github.com/OCIoficial/cms-install
$ cd cms-install
$ ./setup-postgres
```

### Configurar CMS

* Preparar python para hacer un virtual env
   ```bash
   sudo apt install python3.8-venv
   python3 -m venv oci
   source oci/bin/activate
   python -m pip install --upgrade pip
   ```
* Clonar el repositorio `tools` e instalar el paquete `oci-server-tools` que contiene algunos scripts utiles para trabajar en el server. Asegurarse de estar en el virtual env creado en el paso anterior para que no interfiera con los paquetes del sistema de los que CMS depende. El sccript `cms-tools` contiene algunos comandos para configurar y controlar todos los hosts (main y workers) desde el main host.
   ```bash
   git clone https://github.com/OCIoficial/tools
   pip install -e tools/oci-server-tools
   ```
* Genenar `conf.yaml` con `cms-tools` y modificarlo con los datos de los host. El yaml contiene comentarios. Debes usar las credenciales creadas para la base de datos en el paso anterior. Puedes dejar la cantidad de hosts que actuarán como workers en cero por ahora ya que no son necesarios para subir los problemas.
   ```bash
   cms-tools init-conf
   vim conf.yaml
   ```
* Copiar `cms.conf` a los hosts. Cada vez que hagas modificaciones a `conf.yaml` debes generar y copiar `cms.conf`.
   ```bash
   cms-tools copy-cms-conf
   ```
* Inicializar base de datos en CMS. Si la configuración de la base de datos en el paso anterior fue exitosa este comando debiese ejecutarse sin problemas. En caso contrario deberás asegurarte que la base de datos este configurada correctamente.
  ```bash
  cmsInitDB
  ```
   
### Levantar CMS

* Iniciar el `LogService`. Esto crea una sessión de `screen` y corre el `LogService` en esta. Es necesario tener el log service corriendo antes de levantar otros servicios.
   ```bash
   cms-tools restart-log-service
   ```
* Iniciar el `ResourceService` en todos los hosts. El resource service se encarga de monitorear todos los servicios de cms. Dada la configuración de `cms.conf` que copiamos a todos los hosts, el resource service se encargará que los hosts corran los servicios necesarios. Una vez iniciado el `ResourceService` debieses ser capaz de ingresar a la consola de administración web en la ip del main host en el puerto 8889.
  ```bash
  cms-tools restart-resource-service
  ```
* Para ingresar a la consola de administración web debes primero crear una cuenta.
  ```bash
  cmsAddAdmin <username> -p <password>
  ```
* En este momento debiese estar todo lo necesario para crear un contest y subir los problemas.

## Configurar subdominios de olimpiada-informatica.cl

### Configurar nginx

* En la máquina principal instalar y habilitar nginx
  ```bash
  sudo apt-get install nginx
  sudo systemctl enable --now nginx.service
  ```
* Copiar `cms.nginx` a `sites-enabled` y modificar el archivo con los subdominios deseados. Este archivo contiene la configuración para redirigir el tráfico HTTP al ContestWebServer, al AdminWebServer y al RankingWebServer. No olvidar reiniciar nginx después de hacer cambios.
  ```bash
  sudo cp cms-install/cms.nginx /etc/nginx/sites-enabled
  sudo vim /etc/nginx/sites-enabled/cms.nginx
  sudo systemctl restart nginx.service
  ```

### Crear entradas en Cloudflare

Agregar entradas al DNS apuntando a la IP publica del main host con los subdominios deseados. Preocuparse de dejar desmarcada la opción proxy, es decir, que la entrada sea `DNS only`.

### Configurar HTTPS

Puedes usar cerbot para generar un certificado y configurar nginx para redirigir el tráfico HTTPS.

* Intalar certbot
  ```bash
  sudo snap install --classic certbot
  sudo ln -s /snap/bin/certbot /usr/bin/certbot
  ```
* Generar certificados y configurar ngix para rederigir el tráfico https. Ejecuta el comando y luego sigue las instrucciones. El script lee los servidores habilitados en nginx y te pregunta cual dominio quieres configurar.
  ```bash
  sudo certbot --nginx
  ```
  
Para mas detalles puedes revisar las instrucciones en la página de certbot [aquí](https://certbot.eff.org/instructions?ws=nginx&os=pip) 
