#!/bin/bash -e

# Refresh apt package lists to ensure we have the latest package versions
# This is critical when using cached stages, as Debian mirrors update packages
# and old versions become unavailable (404 errors)
apt-get update
