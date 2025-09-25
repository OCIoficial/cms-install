#! /usr/bin/bash

set -ex

DBNAME=cmsdb
DBUSER=cmsuser

# Install postgresql
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y postgresql

# Get IP
DEV=$(ip route show default | awk '/default/ {print $5}')
IP=$(ip addr show $DEV | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)
if [[ -z "$IP" ]]; then
  echo "Error: IP is empty. Exiting."
  exit 1
fi

# Configure postgres to accept connections from remote hosts
CONFIG_FILE=$(sudo su - postgres -c "psql -t -P format=unaligned -c 'show config_file';")
HBA_FILE=$(sudo su - postgres -c "psql -t -P format=unaligned -c 'show hba_file';")

if [[ -z "$CONFIG_FILE" || -z "$HBA_FILE" ]]; then
  echo "Error: either CONFIG_FILE or HBA_FILE are empty. Exiting."
  exit 1
fi

# Listen in localhost and the private ip address
sudo sed -i "s/^#.*listen_addresses.*/listen_addresses = '172.0.0.1,$IP'/" $CONFIG_FILE
# Allow connections with user and password from any address
echo "host $DBNAME $DBUSER 0.0.0.0/0 md5" | sudo tee -a $HBA_FILE

# Configure DB for CMS (https://cms.readthedocs.io/en/latest/Running%20CMS.html#configuring-the-db)
sudo su - postgres -c "createuser --username=postgres --pwprompt $DBUSER"
sudo su - postgres -c "createdb --username=postgres --owner=$DBUSER $DBNAME"
sudo su - postgres -c "psql --username=postgres --dbname=$DBNAME --command='ALTER SCHEMA public OWNER TO $DBUSER'"
sudo su - postgres -c "psql --username=postgres --dbname=$DBNAME --command='GRANT SELECT ON pg_largeobject TO $DBUSER'"

# Restart postgres
sudo systemctl restart postgresql.service
