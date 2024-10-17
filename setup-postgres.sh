#! /usr/bin/bash

set -e

# Install postgresql
sudo apt-get install -y postgresql

# Configure DB for CMS (https://cms.readthedocs.io/en/latest/Running%20CMS.html#configuring-the-db)
DB=cmsdb
USER=cmsuser
sudo su - postgres -c "createuser --username=postgres --pwprompt $USER"
sudo su - postgres -c "createdb --username=postgres --owner=$USER $DB"
sudo su - postgres -c "psql --username=postgres --dbname=$DB --command='ALTER SCHEMA public OWNER TO $USER'"
sudo su - postgres -c "psql --username=postgres --dbname=$DB --command='GRANT SELECT ON pg_largeobject TO $USER'"

# Configure postgres to accept connections from remote hosts
CONFIG_FILE=$(sudo su - postgres -c "psql -t -P format=unaligned -c 'show config_file';")
HBA_FILE=$(sudo su - postgres -c "psql -t -P format=unaligned -c 'show hba_file';")
IP=$(ip addr show eth0 | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)

sed -i "s/^#.*listen_addresses.*/listen_addresses = '172.0.0.1,$IP'/" $CONFIG_FILE
echo "host\t$DB\t$USER\t0.0.0.0/0\tmd5\n" | sudo tee -a $HBA_FILE

# Restart postgres
sudo systemctl restart postgresql.service
