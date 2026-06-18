#!/bin/bash -e

on_chroot << EOF
chown -R ${FIRST_USER_NAME}:${FIRST_USER_NAME} /home/${FIRST_USER_NAME}
su - ${FIRST_USER_NAME} -c 'sh -c "\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'
chsh -s /bin/zsh ${FIRST_USER_NAME}
EOF
