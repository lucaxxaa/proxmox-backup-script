#!/bin/bash

# Percorsi backup
BACKUP_DIR="/root/backup_completo"
NFS_STORAGE="/mnt/pve/proxmox-bk"
NFS_SERVER="192.168.15.195"
NFS_EXPORT="/export/proxmox_bk"
DATA=$(date +%Y-%m-%d)
BACKUP_FILE="backup_scrpt_servizi_$DATA.tar.gz"
BACKUP_PATH_LOCAL="/root/$BACKUP_FILE"

# Funzione per risvegliare lo storage NFS
wake_nfs() {
    echo "🌐 Risveglio dello storage NFS ($NFS_SERVER)..."
    showmount -e $NFS_SERVER > /dev/null 2>&1
    ls -lah $NFS_STORAGE > /dev/null 2>&1
    sleep 10
}

# Funzione per verificare e creare lo storage NFS in Proxmox
create_nfs_storage() {
    echo "🔍 Controllo se lo storage NFS ($NFS_STORAGE) è già configurato su Proxmox..."
    wake_nfs
    if ! pvesm status | grep -q "proxmox-bk"; then
        echo "⚙️ Lo storage NFS non è presente, lo stiamo creando..."
        pvesm add nfs proxmox-bk --server $NFS_SERVER --export $NFS_EXPORT --options vers=3 --content backup,iso
        echo "✅ Storage NFS creato con successo!"
    else
        echo "✅ Lo storage NFS è già presente."
    fi
}

# Funzione per installare pacchetti necessari
install_packages() {
    echo "📦 Installazione pacchetti necessari..."
    apt update && apt upgrade -y
    apt install -y postfix python3 python3-pip mosquitto-clients systemd nfs-common mailutils
    echo "✅ Pacchetti installati!"
    pip3 install paho-mqtt requests smtplib
}

# Funzione per creare il backup
backup() {
    echo "📦 Creazione del backup in corso..."

    # **PULIZIA DELLA DIRECTORY DI BACKUP!**
    rm -rf $BACKUP_DIR

    # Creazione delle directory necessarie per il backup
    mkdir -p $BACKUP_DIR/config
    mkdir -p $BACKUP_DIR/scripts
    mkdir -p $BACKUP_DIR/cron
    mkdir -p $BACKUP_DIR/systemd
    mkdir -p $BACKUP_DIR/root_scripts

    # Backup di Postfix
    cp -r /etc/postfix $BACKUP_DIR/config/
    cp -r /etc/aliases $BACKUP_DIR/config/
    cp -r /etc/ssl/certs/Entrust_Root_Certification_Authority.pem $BACKUP_DIR/config/
    cp /etc/postfix/sasl_passwd $BACKUP_DIR/config/ 2>/dev/null
    cp /etc/postfix/sasl_passwd.db $BACKUP_DIR/config/ 2>/dev/null

    # Backup degli script personalizzati in /usr/local/bin/
    cp -r /usr/local/bin/* $BACKUP_DIR/scripts/

    # Backup dello script Proxmox Health Check in /root/
    cp /root/proxmox_health_check.sh $BACKUP_DIR/root_scripts/

    # Backup del crontab
    crontab -l > $BACKUP_DIR/cron/root_crontab

    # Backup del servizio systemd
    cp /etc/systemd/system/iniziomieiscript.service $BACKUP_DIR/systemd/

    # Creazione dell'archivio compresso con la data
    tar -czvf $BACKUP_PATH_LOCAL -C /root backup_completo
    echo "✅ Backup creato: $BACKUP_PATH_LOCAL"

    # Copia su NFS dopo il wake-up
    wake_nfs
    cp $BACKUP_PATH_LOCAL $NFS_STORAGE/
    echo "✅ Backup copiato su NFS: $NFS_STORAGE/$BACKUP_FILE"
}

# Funzione per trovare il file di backup più recente su NFS
find_latest_backup() {
    echo "🔍 Ricerca dell'ultimo file di backup su NFS..."
    LATEST_BACKUP=$(ls -t $NFS_STORAGE/backup_scrpt_servizi_*.tar.gz 2>/dev/null | head -n 1)
    if [[ -z "$LATEST_BACKUP" ]]; then
        echo "❌ Nessun file di backup trovato su NFS!"
        exit 1
    fi
    echo "📂 Ultimo file di backup trovato: $LATEST_BACKUP"
}

# Funzione per ripristinare il backup
restore() {
    echo "♻️ Inizio procedura di ripristino..."
    
    install_packages
    create_nfs_storage
    find_latest_backup

    # Estrai il backup dalla posizione NFS
    tar -xzvf $LATEST_BACKUP -C /

    # Ripristino Postfix
    cp -r $BACKUP_DIR/config/postfix /etc/
    cp -r $BACKUP_DIR/config/aliases /etc/
    cp -r $BACKUP_DIR/config/Entrust_Root_Certification_Authority.pem /etc/ssl/certs/
    cp $BACKUP_DIR/config/sasl_passwd /etc/postfix/ 2>/dev/null
    cp $BACKUP_DIR/config/sasl_passwd.db /etc/postfix/ 2>/dev/null
    postmap /etc/postfix/sasl_passwd 2>/dev/null
    systemctl restart postfix

    # Ripristino degli script personalizzati in /usr/local/bin/
    cp -r $BACKUP_DIR/scripts/* /usr/local/bin/
    chmod +x /usr/local/bin/*.sh
    chmod +x /usr/local/bin/*.py

    # Ripristino dello script Proxmox Health Check
    cp $BACKUP_DIR/root_scripts/proxmox_health_check.sh /root/
    chmod +x /root/proxmox_health_check.sh

    # Ripristino del crontab e aggiunta di Proxmox Health Check
    crontab $BACKUP_DIR/cron/root_crontab
    (crontab -l ; echo "0 * * * * /root/proxmox_health_check.sh") | sort -u | crontab -

    # Ripristino del servizio systemd
    cp $BACKUP_DIR/systemd/iniziomieiscript.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable iniziomieiscript.service
    systemctl start iniziomieiscript.service

    echo "✅ Ripristino completato!"
}

# Menu interattivo
echo "🔧 Seleziona un'operazione:"
echo "1️⃣  Eseguire il backup"
echo "2️⃣  Ripristinare il backup con aggiornamento e installazione pacchetti"
echo "3️⃣  Uscire"
read -p "➡️  Inserisci il numero della scelta: " scelta

case $scelta in
    1) backup ;;
    2) restore ;;
    3) echo "❌ Operazione annullata." && exit 0 ;;
    *) echo "⚠️ Scelta non valida!" && exit 1 ;;
esac
