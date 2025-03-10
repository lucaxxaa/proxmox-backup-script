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
    ls -lah "$NFS_STORAGE" > /dev/null 2>&1
    sleep 10
}

# Funzione per verificare e creare lo storage NFS in Proxmox
create_nfs_storage() {
    echo "🔍 Controllo se lo storage NFS ($NFS_STORAGE) è già configurato su Proxmox..."
    # Risveglia lo storage prima della creazione
    wake_nfs

    if ! pvesm status | grep -q "proxmox-bk"; then
        echo "⚙️ Lo storage NFS non è presente, lo stiamo creando..."
        pvesm add nfs proxmox-bk --server "$NFS_SERVER" --export "$NFS_EXPORT" --options vers=3 --content backup,iso
        echo "✅ Storage NFS creato con successo!"
    else
        echo "✅ Lo storage NFS è già presente."
    fi
}

# Funzione per installare pacchetti necessari, incluse le dipendenze Python tramite apt
install_packages() {
    echo "📦 Installazione pacchetti necessari..."
    apt update && apt upgrade -y
    apt install -y postfix python3 python3-pip mosquitto-clients crowdsec crowdsec-firewall-bouncer systemd nfs-common iptables ipset python3-paho-mqtt python3-requests
    echo "✅ Pacchetti installati!"

    # Abilita il bouncer per bloccare gli IP malevoli
    systemctl enable crowdsec
    systemctl enable crowdsec-firewall-bouncer
    systemctl start crowdsec
    systemctl start crowdsec-firewall-bouncer
    echo "✅ CrowdSec e il firewall bouncer sono attivati!"
}

# Funzione per creare il backup
backup() {
    echo "📦 Creazione del backup in corso..."
    
    mkdir -p "$BACKUP_DIR/config" "$BACKUP_DIR/scripts" "$BACKUP_DIR/cron" "$BACKUP_DIR/systemd" "$BACKUP_DIR/firewall"

    # Backup di Postfix
    cp -r /etc/postfix "$BACKUP_DIR/config/"
    cp -r /etc/aliases "$BACKUP_DIR/config/"
    cp -r /etc/ssl/certs/Entrust_Root_Certification_Authority.pem "$BACKUP_DIR/config/"
    cp /etc/postfix/sasl_passwd "$BACKUP_DIR/config/" 2>/dev/null
    cp /etc/postfix/sasl_passwd.db "$BACKUP_DIR/config/" 2>/dev/null

    # Backup degli script personalizzati in /usr/local/bin/
    cp -r /usr/local/bin/* "$BACKUP_DIR/scripts/"

    # Backup del crontab
    crontab -l > "$BACKUP_DIR/cron/root_crontab"

    # Backup del servizio systemd
    cp /etc/systemd/system/iniziomieiscript.service "$BACKUP_DIR/systemd/"

    # Backup di iptables
    iptables-save > "$BACKUP_DIR/firewall/iptables.rules"

    # Backup delle blacklist di CrowdSec
    cscli decisions export -o json > "$BACKUP_DIR/firewall/crowdsec-decisions.json"

    # Backup della configurazione di CrowdSec
    cp -r /etc/crowdsec/ "$BACKUP_DIR/firewall/crowdsec-config/"

    # Creazione dell'archivio compresso con la data
    tar -czvf "$BACKUP_PATH_LOCAL" -C /root backup_completo
    echo "✅ Backup creato: $BACKUP_PATH_LOCAL"

    # Copia su NFS dopo il wake-up
    wake_nfs
    cp "$BACKUP_PATH_LOCAL" "$NFS_STORAGE/"
    echo "✅ Backup copiato su NFS: $NFS_STORAGE/$BACKUP_FILE"
}

# Funzione per trovare il file di backup più recente
find_latest_backup() {
    LATEST_BACKUP=$(ls -t "$NFS_STORAGE"/backup_scrpt_servizi_*.tar.gz 2>/dev/null | head -n1)
    if [ -z "$LATEST_BACKUP" ]; then
        echo "❌ Nessun file di backup trovato in $NFS_STORAGE"
        exit 1
    fi
    echo "✅ File di backup più recente trovato: $LATEST_BACKUP"
}

# Funzione per ripristinare il backup
restore() {
    echo "♻️ Inizio procedura di ripristino..."
    
    # Installazione pacchetti necessari
    install_packages

    # Creazione automatica dello storage NFS in Proxmox se non esiste
    create_nfs_storage

    # Trova il file di backup più recente
    find_latest_backup

    # Estrai il backup dalla posizione NFS
    tar -xzvf "$LATEST_BACKUP" -C /

    # Ripristino Postfix
    cp -r "$BACKUP_DIR/config/postfix" /etc/
    cp -r "$BACKUP_DIR/config/aliases" /etc/
    cp -r "$BACKUP_DIR/config/Entrust_Root_Certification_Authority.pem" /etc/ssl/certs/
    cp "$BACKUP_DIR/config/sasl_passwd" /etc/postfix/ 2>/dev/null
    cp "$BACKUP_DIR/config/sasl_passwd.db" /etc/postfix/ 2>/dev/null
    postmap /etc/postfix/sasl_passwd 2>/dev/null
    systemctl restart postfix

    # Ripristino iptables
    iptables-restore < "$BACKUP_DIR/firewall/iptables.rules"

    # Ripristino delle blacklist di CrowdSec
    cscli decisions import -f "$BACKUP_DIR/firewall/crowdsec-decisions.json"

    # Ripristino della configurazione di CrowdSec
    cp -r "$BACKUP_DIR/firewall/crowdsec-config/" /etc/crowdsec/
    systemctl restart crowdsec
    systemctl restart crowdsec-firewall-bouncer

    # Ripristino degli script personalizzati in /usr/local/bin/
    if [ -d "$BACKUP_DIR/scripts" ]; then
        cp -r "$BACKUP_DIR/scripts/." /usr/local/bin/
        # Imposta i permessi eseguibili solo sui file .sh e .py presenti
        find /usr/local/bin -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} \;
        find /usr/local/bin -maxdepth 1 -type f -name "*.py" -exec chmod +x {} \;
    else
        echo "❌ Directory degli script non trovata in $BACKUP_DIR/scripts"
    fi

    # Ripristino del crontab
    crontab "$BACKUP_DIR/cron/root_crontab"

    # Ripristino del servizio systemd
    if [ -f "$BACKUP_DIR/systemd/iniziomieiscript.service" ]; then
        cp "$BACKUP_DIR/systemd/iniziomieiscript.service" /etc/systemd/system/
        systemctl daemon-reload
        systemctl enable iniziomieiscript.service
        systemctl start iniziomieiscript.service
    else
        echo "❌ File di servizio iniziomieiscript.service non trovato in $BACKUP_DIR/systemd"
    fi

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
