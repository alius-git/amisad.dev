#!/bin/bash
# AmisAd POC - create the amisad database and load the skeleton schema.
# TODO: open listen_addresses/pg_hba for in-cluster pods (mirror text-to-sql db script).
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")
POC="$REAL_HOME/git/yuruna/project/poc"

sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='amisad'" | grep -q 1 || \
    sudo -u postgres createdb amisad
sudo -u postgres psql -d amisad -f "$POC/db/schema.sql"
echo "AmisAd database ready"