
# Instalación de CMS en AWS

Este repositorio contiene scripts e instrucciones para instalar [cms](https://github.com/cms-dev/cms) en AWS.

## Introducción

En la configuración típica de la OCI usamos tres instancias de EC2

* Una instancia `t2.large` es designada como la máquina principal y corre la base de datos y la mayoría de los servicios de CMS.
* Dos instancias `t2.small` corren cada una solo un worker.

Las instancias corriendo los workers tienen que tener acceso de red a la máquina principal para poder acceder a la base de datos y a los servicios de cms.

## Configurar red

### oci-main

| IP Version | Type       | Protocol | Port range | Source         | Description         |
|------------|------------|----------|------------|----------------|---------------------|
| IPv4       | SSH        | TCP      | 22         | 0.0.0.0/0      | SSH                 |
| IPv4       | Custom TCP | TCP      | 8888       | 0.0.0.0/0      | Contest Web Service |
| IPv4       | Custom TCP | TCP      | 8889       | 0.0.0.0/0      | Admin Web Service   |
| IPv4       | ALL TCP    | TCP      | 0 - 65535  | `<oci-worker>` |                     |

### oci-worker

| IP Version | Type       | Protocol | Port range | Source         | Description         |
|------------|------------|----------|------------|----------------|---------------------|
| IPv4       | SSH        | TCP      | 22         | 0.0.0.0/0      | SSH                 |
| IPv4       | ALL TCP    | TCP      | 0 - 65535  | `<oci-main>`   |                     |


## Crear instancias EC2 en AWS

Para evitar gastos innecesarios, típicamente levantamos primero la instancia principal `t2.large` para configurar el contest y luego más cerca de la competencia levantamos los dos workers.
Crear la instancia principal en la consola de AWS con la siguiente configuración

* **Name and tags**
  * oci-principal
* **Application and OS Images (Amazon Machine Image)**
  * Amazon Machine Image (AMI): `Ubuntu Server 22.04 LTS (HVM), SSD Volume Type`
  * Architecture: `64-bit(x86)`
* **Key pair(login)**
  * Seleccionar un par de llaves al que tengas acceso, históricamente hemos usamos `ociadmin`.
* **Instance Type**
  * Instance Type: `t2.large`
* **Network Setting**
  * Seleccionar la opción `Allow SSH traffic from: Anywhere`
* **Configure Storage**
  * 1x `16` GB `gp2`

## Instalar CMS

## Configurar Postgres


## Correr CMS

* Correr log service en screen
* Copiar conf.yaml.sample to conf.yaml y modificar
* Correr cms-tools restart

```yaml
# We call "local" the the main host that runs the database
# and all the core services. cms-tools is expected to
# run in this host.
local:
    # This ip should be reachable by all remote hosts.
    # One should avoid using a public ip here so services
    # are not exposed unnecesarily outside of the local network.
    ip: 172.31.94.183

    # Number of workers that will run in the local host.
    # It is recommended to run workers only on remote hosts.
    workers: 1

    # Make sure the database can accept connections from all the remote hosts.
    # You need to make two changes for that:
    # 1) Edit postgresql.conf to listen in the internal/local address, e.g.,
    #    if the internal/local address of is 192.168.0.2, one should add the following:
    #    listen_addreses = '127.0.0.1,192.168.0.2'
    # 2) Edit pg_hba.conf to accept login requests from the remote hosts, e.g.,
    #    if all remote host are in the 192.168.0.0/24 subnet one should add a line
    #    like so:
    #    host cmsdb cmsuser 196.168.0.0/24 md5
    db:
        name: cmsdb
        username: cmsuser
        password: Oci2021!

# The list of remote hosts running workers
remote: []
# remote:
#     -
#       # This ip should be reachable by the local host.
#       ip: 172.31.15.133
#
#       # Number of workers running in the host
#       workers: 1
#
#       # Username used to connect via ssh to the host to
#       # run commands and copy files. It is recommended that
#       # every remote has the public key of the local host,
#       # otherwise you'll need to type the password for every
#       # host when running commands.
#       username: ociadmin
#     -
#       #This ip should be reachable by the local host.
#       ip: 172.31.5.213
#
#       # Number of workers running in the host
#       workers: 1
#
#       # Username used to connect via ssh to the host to
#       # run commands and copy files. It is recommended that
#       # every remote has the public key of the local host,
#       # otherwise you'll need to type the password for every
#       # host when running commands.
#       username: ociadmin
rankings:
    - "http://scoreboard:123scoreboard321@localhost:8890/"
```
