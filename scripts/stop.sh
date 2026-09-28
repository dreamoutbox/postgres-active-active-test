#!/bin/bash
# stop.sh
# Stops the cluster and tears down volumes and data directories.
set -euo pipefail


docker compose down -v
sudo rm -rf data/
