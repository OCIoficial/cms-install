#! /usr/bin/bash

set -ex

# Install dependencies
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y build-essential openjdk-17-jdk-headless fp-compiler \
    postgresql-client python3.8 cppreference-doc-en-html \
    cgroup-lite libcap-dev zip
sudo apt-get -y install python3.8-dev libpq-dev libcups2-dev libyaml-dev \
    libffi-dev python3-pip

# Clone and install cms
git clone https://github.com/ioi-2022/cms --recursive
cd cms || exit
sudo python3 prerequisites.py -y install
export SETUPTOOLS_USE_DISTUTILS="stdlib"
sudo --preserve-env=SETUPTOOLS_USE_DISTUTILS pip3 install -r requirements.txt
sudo --preserve-env=SETUPTOOLS_USE_DISTUTILS python3 setup.py install
