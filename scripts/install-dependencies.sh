#! /usr/bin/bash
# Instala las dependencias de CMS e isolate (Ubuntu 24.04). Correr como root.

set -ex

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Por si una instalación anterior se interrumpió a mitad de apt
dpkg --configure -a
apt-get update
apt-get upgrade "${APT_OPTS[@]}"

apt-get install "${APT_OPTS[@]}" build-essential openjdk-17-jdk-headless fp-compiler \
    postgresql-client \
    python3.12 python3.12-dev python3-pip python3-venv \
    libpq-dev libyaml-dev libffi-dev \
    shared-mime-info cppreference-doc-en-html zip curl git

# Isolate desde el repositorio de sus autores
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/isolate.asc] http://www.ucw.cz/isolate/debian/ noble-isolate main' >/etc/apt/sources.list.d/isolate.list
curl -fsSL https://www.ucw.cz/isolate/debian/signing-key.asc >/etc/apt/keyrings/isolate.asc
apt-get update
apt-get install "${APT_OPTS[@]}" isolate
systemctl enable --now isolate.service || true

# Revisa la configuración del sistema para que los tiempos de ejecución sean reproducibles
isolate-check-environment || true
