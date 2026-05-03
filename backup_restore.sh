#!/bin/bash

# Percorsi backup
BACKUP_DIR="/root/backup_completo"
NFS_STORAGE="/mnt/pve/proxmox-bk"
NFS_SERVER="192.168.2.105"
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
    echo "Installazione dipendenze in corso..."
    apt update && apt upgrade -y
    apt install -y postfix python3 python3-pip mosquitto-clients systemd nfs-common python3-paho-mqtt python3-requests iptables ipset
}

backup() {
    echo "Inizio backup delle configurazioni..."
    
    # Auto-pulizia della directory temporanea
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR/config" "$BACKUP_DIR/scripts" "$BACKUP_DIR/cron" "$BACKUP_DIR/systemd"

    # --- CORE PROXMOX ---
    cp /etc/network/interfaces "$BACKUP_DIR/config/"
    cp /etc/pve/storage.cfg "$BACKUP_DIR/config/" 2>/dev/null

    # --- SICUREZZA ---
    iptables-save > "$BACKUP_DIR/config/iptables.rules"

    # --- POSTFIX E CERTIFICATI ---
    cp -r /etc/postfix "$BACKUP_DIR/config/"
    cp /etc/aliases "$BACKUP_DIR/config/"
    cp -P /etc/ssl/certs/Entrust_Root_Certification_Authority.pem "$BACKUP_DIR/config/"
    cp /etc/postfix/sasl_passwd* "$BACKUP_DIR/config/" 2>/dev/null

    # --- SCRIPT E AUTOMAZIONI ---
    cp -r /usr/local/bin/* "$BACKUP_DIR/scripts/" 2>/dev/null
    crontab -l > "$BACKUP_DIR/cron/root_crontab" 2>/dev/null
    cp /etc/systemd/system/iniziomieiscript.service "$BACKUP_DIR/systemd/" 2>/dev/null

    # --- CREAZIONE E INVIO ARCHIVIO ---
    tar -czvf "$BACKUP_PATH_LOCAL" -C /root backup_completo
    wake_nfs
    cp "$BACKUP_PATH_LOCAL" "$NFS_STORAGE/"
    echo "✅ Backup completato e salvato su NFS (RPi4: 192.168.2.105)."
}

find_latest_backup() {
    LATEST_BACKUP=$(ls -t "$NFS_STORAGE"/backup_scrpt_servizi_*.tar.gz 2>/dev/null | head -n1)
    if [ -z "$LATEST_BACKUP" ]; then
        echo "❌ Nessun backup trovato su NFS."
        exit 1
    fi
    echo "Ultimo backup trovato: $LATEST_BACKUP"
}

restore() {
    echo "Avvio procedura di Disaster Recovery..."
    install_packages
    create_nfs_storage
    find_latest_backup

    tar -xzvf "$LATEST_BACKUP" -C /root

    # --- RIPRISTINO CORE PROXMOX ---
    cp "$BACKUP_DIR/config/interfaces" /etc/network/
    cp "$BACKUP_DIR/config/storage.cfg" /etc/pve/ 2>/dev/null

    # --- RIPRISTINO SICUREZZA ---
    iptables-restore < "$BACKUP_DIR/config/iptables.rules"

    # --- RIPRISTINO POSTFIX ---
    cp -r "$BACKUP_DIR/config/postfix" /etc/
    cp "$BACKUP_DIR/config/aliases" /etc/
    cp -P "$BACKUP_DIR/config/Entrust_Root_Certification_Authority.pem" /etc/ssl/certs/
    cp "$BACKUP_DIR/config/sasl_passwd" /etc/postfix/ 2>/dev/null
    cp "$BACKUP_DIR/config/sasl_passwd.db" /etc/postfix/ 2>/dev/null
    postmap /etc/postfix/sasl_passwd 2>/dev/null
    systemctl restart postfix

    # --- RIPRISTINO SCRIPT E AUTOMAZIONI ---
    cp -r "$BACKUP_DIR/scripts/." /usr/local/bin/
    find /usr/local/bin -maxdepth 1 -type f \( -name "*.sh" -o -name "*.py" \) -exec chmod +x {} \;
    crontab "$BACKUP_DIR/cron/root_crontab" 2>/dev/null

    cp "$BACKUP_DIR/systemd/iniziomieiscript.service" /etc/systemd/system/ 2>/dev/null
    systemctl daemon-reload
    systemctl enable iniziomieiscript.service
    systemctl start iniziomieiscript.service

    echo "✅ Ripristino configurazioni completato!"
    echo "⚠️ RIAVVIA IL SERVER ORA PER APPLICARE LE CONFIGURAZIONI DI RETE (vmbr0, vmbr1, vmbr2). ⚠️"
}

echo "1) Backup  2) Ripristino  3) Esci"
read -p "Scelta: " scelta

case $scelta in
    1) backup ;;
    2) restore ;;
    3) exit 0 ;;
    *) echo "Scelta non valida" && exit 1 ;;
esac
