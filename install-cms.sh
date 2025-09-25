#! /usr/bin/bash

set -ex

# Clone and install cms
INSTALL_DIR=$HOME/cms
git clone https://github.com/cms-dev/cms.git --recursive
cd cms || exit
./install.py --dir=$INSTALL_DIR cms
echo "PATH=$INSTALL_DIR/bin:$PATH" >> $HOME/.bashrc
