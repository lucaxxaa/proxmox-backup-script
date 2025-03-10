#!/bin/bash

# Percorsi backup
BACKUP_DIR="/root/backup_completo"
NFS_STORAGE="/mnt/pve/proxmox-bk"
NFS_SERVER="192.168.15.195"
NFS_EXPORT="/export/proxmox_bk"
DATA=$(date +%Y-%m-%d)
BACKUP_FILE="backup_scrpt_servizi_$DATA.tar.gz"
BACKUP_PATH_LOCAL="/root/$BACKUP_FILE"

wake_nfs() {
    showmount -e "$NFS_SERVER" > /dev/null 2>&1
    ls "$NFS_STORAGE" > /dev/null 2>&1
    sleep 10
}

create_nfs_storage() {
    wake_nfs
    if ! pvesm status | grep -q "proxmox-bk"; then
        pvesm add nfs proxmox-bk --server "$NFS_SERVER" --export "$NFS_EXPORT" --options vers=3 --content backup,iso
    fi
}

install_packages() {
    apt update && apt upgrade -y
    apt install -y postfix python3 python3-pip mosquitto-clients systemd nfs-common python3-paho-mqtt python3-requests libsasl2-modules
}

backup() {
    mkdir -p "$BACKUP_DIR/config" "$BACKUP_DIR/scripts" "$BACKUP_DIR/cron" "$BACKUP_DIR/systemd"

    cp -r /etc/postfix "$BACKUP_DIR/config/"
    cp /etc/aliases "$BACKUP_DIR/config/"
    cp -P /etc/ssl/certs/ca-certificates.crt "$BACKUP_DIR/config/"
    cp /etc/postfix/sasl_passwd* "$BACKUP_DIR/config/" 2>/dev/null

    cp -r /usr/local/bin/* "$BACKUP_DIR/scripts/"
    crontab -l > "$BACKUP_DIR/cron/root_crontab"
    cp /etc/systemd/system/iniziomieiscript.service "$BACKUP_DIR/systemd/"

    tar -czvf "$BACKUP_PATH_LOCAL" -C /root backup_completo
    wake_nfs
    cp "$BACKUP_PATH_LOCAL" "$NFS_STORAGE/"
}

find_latest_backup() {
    LATEST_BACKUP=$(ls -t "$NFS_STORAGE"/backup_scrpt_servizi_*.tar.gz 2>/dev/null | head -n1)
    if [ -z "$LATEST_BACKUP" ]; then
        echo "Nessun backup trovato."
        exit 1
    fi
}

restore() {
    install_packages
    create_nfs_storage
    find_latest_backup

    rm -rf "$BACKUP_DIR"/*
tar -xzvf "$LATEST_BACKUP" -C /root

    cp -r "$BACKUP_DIR/config/postfix" /etc/
    cp "$BACKUP_DIR/config/aliases" /etc/
    cp -P "$BACKUP_DIR/config/ca-certificates.crt" /etc/ssl/certs/
    cp "$BACKUP_DIR/config/sasl_passwd" /etc/postfix/ 2>/dev/null
    cp "$BACKUP_DIR/config/sasl_passwd.db" /etc/postfix/ 2>/dev/null
    postmap /etc/postfix/sasl_passwd 2>/dev/null
    systemctl restart postfix

    cp -r "$BACKUP_DIR/scripts/." /usr/local/bin/
    find /usr/local/bin -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) -exec chmod +x {} \;

    crontab "$BACKUP_DIR/cron/root_crontab"

    cp "$BACKUP_DIR/systemd/iniziomieiscript.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable iniziomieiscript.service
    systemctl start iniziomieiscript.service

    echo "✅ Ripristino completato!"
}

echo "1) Backup  2) Ripristino  3) Esci"
read -p "Scelta: " scelta

case $scelta in
    1) backup ;;
    2) restore ;;
    3) exit 0 ;;
    *) echo "Scelta non valida" && exit 1 ;;
esac
