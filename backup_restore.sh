#!/usr/bin/env bash

# ======================
# VARIABILI PRINCIPALI
# ======================
BACKUP_DIR="/root/backup_completo"
NFS_STORAGE="/mnt/pve/proxmox-bk"
NFS_SERVER="192.168.2.105"
NFS_EXPORT="/export/proxmox_bk"
DATA=$(date +%Y-%m-%d)
BACKUP_FILE="backup_scrpt_servizi_$DATA.tar.gz"
BACKUP_PATH_LOCAL="/root/$BACKUP_FILE"

# ======================
# FUNZIONI
# ======================

wake_nfs() {
    ping -c 1 "$NFS_SERVER" > /dev/null 2>&1
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

update_github() {
    # Assicuriamoci di essere nella directory /root, dove risiede lo script
    cd /root || { echo "Directory /root non trovata"; exit 1; }
    git add backup_restore.sh
    git commit -m "Aggiornato backup_restore.sh con le ultime modifiche"
    git push
}

backup() {
    mkdir -p "$BACKUP_DIR/config" "$BACKUP_DIR/scripts" "$BACKUP_DIR/cron" "$BACKUP_DIR/systemd"

    cp -r /etc/postfix "$BACKUP_DIR/config/"
    cp /etc/aliases "$BACKUP_DIR/config/"
    cp -P /etc/ssl/certs/ca-certificates.crt "$BACKUP_DIR/config/"
    cp /etc/postfix/sasl_passwd* "$BACKUP_DIR/config/" 2>/dev/null

    cp -r /usr/local/bin/* "$BACKUP_DIR/scripts/" 2>/dev/null

    # Backup degli script aggiuntivi in /root
    cp /root/proxmox_health_check.sh "$BACKUP_DIR/scripts/" 2>/dev/null
    cp /root/zfs_alert.sh "$BACKUP_DIR/scripts/" 2>/dev/null

    crontab -l > "$BACKUP_DIR/cron/root_crontab"
    cp /etc/systemd/system/iniziomieiscript.service "$BACKUP_DIR/systemd/" 2>/dev/null

    tar -czvf "$BACKUP_PATH_LOCAL" -C /root backup_completo
    wake_nfs
    cp "$BACKUP_PATH_LOCAL" "$NFS_STORAGE/"
    echo "✅ Backup completato: $BACKUP_PATH_LOCAL copiato su $NFS_STORAGE"

    # Aggiornamento del repository GitHub
    update_github
}

find_latest_backup() {
    LATEST_BACKUP=$(ls -t "$NFS_STORAGE"/backup_scrpt_servizi_*.tar.gz 2>/dev/null | head -n1)
    if [ -z "$LATEST_BACKUP" ]; then
        echo "❌ Nessun backup trovato in $NFS_STORAGE."
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

    # Ripristino degli script aggiuntivi in /root
    cp "$BACKUP_DIR/scripts/proxmox_health_check.sh" /root/ 2>/dev/null
    cp "$BACKUP_DIR/scripts/zfs_alert.sh" /root/ 2>/dev/null
    chmod +x /root/proxmox_health_check.sh /root/zfs_alert.sh 2>/dev/null

    crontab "$BACKUP_DIR/cron/root_crontab"

    cp "$BACKUP_DIR/systemd/iniziomieiscript.service" /etc/systemd/system/ 2>/dev/null
    systemctl daemon-reload
    systemctl enable iniziomieiscript.service
    systemctl start iniziomieiscript.service

    echo "✅ Ripristino completato!"
}

configure_networks() {
    echo "Configurazione di vmbr1, vmbr2, vmbr3 (vmbr0 non viene toccata)."
    cp /etc/network/interfaces /etc/network/interfaces.bak_$(date +%Y%m%d_%H%M%S)

    # vmbr1 - bridge con enp2s0 ed enp3s0
    if ! grep -q "iface vmbr1" /etc/network/interfaces; then
        echo "Creazione vmbr1..."
        cat <<EOF >> /etc/network/interfaces

# vmbr1 - bridge con enp2s0 enp3s0
auto vmbr1
iface vmbr1 inet manual
    bridge-ports enp2s0 enp3s0
    bridge-stp off
    bridge-fd 0
EOF
    else
        echo "vmbr1 già presente in /etc/network/interfaces, non tocco."
    fi

    # vmbr2 - bridge con enp4s0
    if ! grep -q "iface vmbr2" /etc/network/interfaces; then
        echo "Creazione vmbr2..."
        cat <<EOF >> /etc/network/interfaces

# vmbr2 - bridge con enp4s0
auto vmbr2
iface vmbr2 inet manual
    bridge-ports enp4s0
    bridge-stp off
    bridge-fd 0
EOF
    else
        echo "vmbr2 già presente in /etc/network/interfaces, non tocco."
    fi

    # vmbr3 - nessuna porta fisica
    if ! grep -q "iface vmbr3" /etc/network/interfaces; then
        echo "Creazione vmbr3..."
        cat <<EOF >> /etc/network/interfaces

# vmbr3 - nessuna porta fisica
auto vmbr3
iface vmbr3 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
    else
        echo "vmbr3 già presente in /etc/network/interfaces, non tocco."
    fi

    echo "Reti aggiunte/aggiornate. Verificare la configurazione e riavviare la rete o il server se necessario."
    echo "Backup di /etc/network/interfaces salvato in /etc/network/interfaces.bak_*"
}

# ======================
# MENU PRINCIPALE
# ======================
echo "1) Backup"
echo "2) Ripristino"
echo "3) Configura reti vmbr (senza toccare vmbr0)"
echo "4) Esci"
read -p "Scelta: " scelta

case $scelta in
    1) backup ;;
    2) restore ;;
    3) configure_networks ;;
    4) exit 0 ;;
    *) echo "Scelta non valida" && exit 1 ;;
esac
