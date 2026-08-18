#!/bin/bash -e

on_chroot << EOF
apt-get update
apt-get -y dist-upgrade --auto-remove --purge
EOF
