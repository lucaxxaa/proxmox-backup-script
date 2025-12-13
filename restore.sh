cat << 'EOF' > /root/DA_CARICARE_SU_GITHUB.sh
#!/bin/bash
# ==========================================
# PROXMOX TOTAL DISASTER RECOVERY v4.0
# (Sonar + IPFire + PiHole + All VMs)
# ==========================================

# --- CONFIGURAZIONE ---
NAS_IP="192.168.2.105"
NAS_PATH="/export/proxmox_bk"
MOUNT_POINT="/mnt/restore_temp"
BACKUP_MASTER="proxmox_config_master.tar.gz"
VM_IPFIRE_ID="105"
CT_PIHOLE_ID="100"
TEMP_IP="192.168.2.222"
# ----------------------

echo "!!! TOTAL SYSTEM RESTORE !!!"
echo "Questo script ripristinerà TUTTO: Rete, Config, IPFire, Pi-hole e tutte le VM."
echo "ATTENZIONE: Richiede tempo (dipende dalla dimensione dei backup)."
read -p "Premi INVIO per iniziare..."

# 1. SETUP INIZIALE
echo ">>> [1/6] Installazione prerequisiti..."
apt update && apt install -y nfs-common python3-paho-mqtt unzip curl iputils-ping

# 2. SONAR (Trova il NAS)
echo ">>> [2/6] Ricerca NAS (Sonar Mode)..."
FOUND_INTERFACE=""
INTERFACES=$(ls /sys/class/net | grep -E 'en|eth')
for IFACE in $INTERFACES; do
    ip addr add $TEMP_IP/24 dev $IFACE 2>/dev/null
    ip link set $IFACE up
    if ping -c 1 -W 1 $NAS_IP >/dev/null 2>&1; then
        echo "✅ NAS trovato su interfaccia: $IFACE"
        FOUND_INTERFACE="$IFACE"
        break
    else
        ip addr del $TEMP_IP/24 dev $IFACE 2>/dev/null
    fi
done

if [ -z "$FOUND_INTERFACE" ]; then
    echo "❌ NAS NON TROVATO! Verifica cavi e alimentazione."
    exit 1
fi

mkdir -p "$MOUNT_POINT"
mount -t nfs "$NAS_IP:$NAS_PATH" "$MOUNT_POINT" || { echo "❌ Mount fallito"; exit 1; }

# 3. PREPARAZIONE STORAGE PROXMOX
echo ">>> [3/6] Preparazione Storage..."
# Estrarre subito storage.cfg per permettere il restore delle VM
if [ -f "$MOUNT_POINT/$BACKUP_MASTER" ]; then
    tar -xzf "$MOUNT_POINT/$BACKUP_MASTER" -C /tmp/ ./etc/storage.cfg
    cp /tmp/etc/storage.cfg /etc/pve/storage.cfg
    # Ricarica pvestatd per fargli vedere lo storage
    systemctl restart pvestatd
    echo "✅ Storage Configuration applicata."
else
    echo "❌ Backup Master non trovato! Impossibile configurare storage."
    exit 1
fi

# 4. RIPRISTINO VM CRITICHE (IPFire e Pi-hole)
RESTORE_VM() {
    ID=$1
    TYPE=$2 # qemu o lxc
    ORDER=$3
    echo "--- Ripristino ID $ID (Priorità: $ORDER) ---"
    
    # Cerca il file più recente
    if [ "$TYPE" == "qemu" ]; then
        FILE=$(ls -t "$MOUNT_POINT/dump"/vzdump-qemu-$ID-*.vma* 2>/dev/null | head -n1)
        CMD="qmrestore"
        CONF_CMD="qm set"
    else
        FILE=$(ls -t "$MOUNT_POINT/dump"/vzdump-lxc-$ID-*.tar* 2>/dev/null | head -n1)
        CMD="pct restore"
        CONF_CMD="pct set"
    fi

    if [ -n "$FILE" ]; then
        echo "File: $(basename "$FILE")"
        $CMD "$FILE" $ID --force --storage local-zfs
        $CONF_CMD $ID --onboot 1
        # Imposta ordine di avvio solo per QEMU o LXC (sintassi simile)
        if [ "$TYPE" == "qemu" ]; then
            qm set $ID --boot order=$ORDER
        else
            pct set $ID --startup order=$ORDER
        fi
        echo "✅ ID $ID ripristinato."
    else
        echo "⚠️ Backup per ID $ID non trovato!"
    fi
}

echo ">>> [4/6] Ripristino INFRASTRUTTURA DI RETE..."
# Priorità 1: IPFire
RESTORE_VM $VM_IPFIRE_ID "qemu" 1
# Priorità 2: Pi-hole
RESTORE_VM $CT_PIHOLE_ID "lxc" 2

# 5. RIPRISTINO ALTRE VM
echo ">>> [5/6] Ripristino ALTRE VM e CONTAINER..."
# Scansiona la cartella dump
for backup in "$MOUNT_POINT/dump"/*; do
    # Estrai ID dal nome file (es. vzdump-qemu-103-...)
    filename=$(basename "$backup")
    
    # Salta se non è un backup valido
    [[ ! "$filename" =~ vzdump-(qemu|lxc)-([0-9]+)- ]] && continue
    
    type=${BASH_REMATCH[1]}
    id=${BASH_REMATCH[2]}

    # Salta IPFire e Pi-hole (già fatti)
    if [ "$id" == "$VM_IPFIRE_ID" ] || [ "$id" == "$CT_PIHOLE_ID" ]; then
        continue
    fi

    # Ripristina con priorità bassa (3)
    RESTORE_VM $id "$type" 3
done

# 6. RIPRISTINO CERVELLO (Configurazioni Finali)
echo ">>> [6/6] Applicazione Configurazione Sistema (Brain)..."
TEMP_RESTORE="/tmp/restore_data"
rm -rf "$TEMP_RESTORE"
mkdir -p "$TEMP_RESTORE"
tar -xzvf "$MOUNT_POINT/$BACKUP_MASTER" -C "$TEMP_RESTORE"

# Script Root e Bin
cp -r "$TEMP_RESTORE/root/." /root/
chmod +x /root/*.sh
if [ -d "$TEMP_RESTORE/usr_local_bin/mqtt_scripts" ]; then
    mkdir -p /usr/local/bin/mqtt_scripts
    cp -r "$TEMP_RESTORE/usr_local_bin/mqtt_scripts/." /usr/local/bin/mqtt_scripts/
fi
cp "$TEMP_RESTORE/usr_local_bin/"*.sh /usr/local/bin/ 2>/dev/null || true
chmod +x /usr/local/bin/mqtt_scripts/*.py 2>/dev/null
chmod +x /usr/local/bin/*.sh 2>/dev/null

# Servizi e Mail
if [ -f "$TEMP_RESTORE/root_crontab" ]; then crontab "$TEMP_RESTORE/root_crontab"; fi
if [ -f "$TEMP_RESTORE/systemd/iniziomieiscript.service" ]; then
    cp "$TEMP_RESTORE/systemd/iniziomieiscript.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable iniziomieiscript.service
fi
cp -r "$TEMP_RESTORE/etc/postfix/." /etc/postfix/
cp "$TEMP_RESTORE/etc/aliases" /etc/aliases 2>/dev/null
newaliases
[ -f /etc/postfix/sasl_passwd ] && postmap /etc/postfix/sasl_passwd

# RETE (L'ultimo passo prima del buio)
cp "$TEMP_RESTORE/etc/interfaces" /etc/network/interfaces
cp "$TEMP_RESTORE/etc/hosts" /etc/hosts
cp "$TEMP_RESTORE/etc/resolv.conf" /etc/resolv.conf

# Pulizia
umount "$MOUNT_POINT"
rm -rf "$TEMP_RESTORE"

echo "======================================================"
echo "✅ MISSIONE COMPIUTA!"
echo "------------------------------------------------------"
echo "Al riavvio succederà questo:"
echo "1. Proxmox configurerà i Bridge."
echo "2. Avvierà IPFire (VM $VM_IPFIRE_ID)."
echo "3. Avvierà Pi-hole (CT $CT_PIHOLE_ID) per i DNS."
echo "4. Avvierà tutte le altre VM."
echo "------------------------------------------------------"
echo "Riavvia ora con: reboot"
echo "======================================================"
EOF
