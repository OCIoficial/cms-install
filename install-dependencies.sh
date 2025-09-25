#! /usr/bin/bash

set -ex

# Install dependencies
sudo apt-get update && sudo apt-get upgrade -y

apt install -y build-essential openjdk-17-jdk-headless fp-compiler \
    postgresql-client \
    python3.12 python3.12-dev python3-pip python3-venv \
    libpq-dev libcups2-dev libyaml-dev libffi-dev \
    shared-mime-info cppreference-doc-en-html zip curl

# Isolate from upstream package repository
echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/isolate.asc] http://www.ucw.cz/isolate/debian/ noble-isolate main' >/etc/apt/sources.list.d/isolate.list
curl https://www.ucw.cz/isolate/debian/signing-key.asc >/etc/apt/keyrings/isolate.asc
apt update && apt install isolate

