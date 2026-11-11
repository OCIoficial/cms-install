#! /usr/bin/bash
# Instala CMS en $HOME/cms. Correr como el usuario `ubuntu` (SIN sudo), después
# de install-dependencies.sh y de agregar el usuario al grupo `isolate`.
#
# La versión se define con CMS_REF (commit de cms-dev/cms). Terraform la pasa
# desde la variable `cms_ref`. Ver README, sección "Versión de CMS".

set -ex

if [[ $EUID -eq 0 ]]; then
  echo "Error: no correr este script como root. CMS debe quedar en /home/ubuntu/cms."
  exit 1
fi

: "${CMS_REF:?Definir CMS_REF}"

SRC_DIR=$HOME/cms-src
INSTALL_DIR=$HOME/cms

# Un clon interrumpido se descarta y se vuelve a clonar
if [[ -d $SRC_DIR ]] && ! git -C "$SRC_DIR" rev-parse --verify -q HEAD >/dev/null; then
  rm -rf "$SRC_DIR"
fi
if [[ ! -d $SRC_DIR ]]; then
  git clone https://github.com/cms-dev/cms.git "$SRC_DIR"
fi
cd "$SRC_DIR"
git fetch origin
git checkout "$CMS_REF"

./install.py --dir="$INSTALL_DIR" cms

# Activar el entorno virtual de CMS en cada login, para tener cmsXxx en el PATH
if ! grep -q "$INSTALL_DIR/bin/activate" "$HOME/.profile"; then
  echo "source $INSTALL_DIR/bin/activate" >> "$HOME/.profile"
fi
