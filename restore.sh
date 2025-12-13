#!/bin/bash
# ==========================================
# PROXMOX DISASTER RECOVERY (Sonar Mode)
# ==========================================

# --- CONFIGURAZIONE ---
NAS_IP="192.168.2.105"
NAS_PATH="/export/proxmox_bk"
MOUNT_POINT="/mnt/restore_temp"
BACKUP_FILE="proxmox_config_master.tar.gz"
VM_IPFIRE_ID="105"
TEMP_IP="192.168.2.222"
# ----------------------

echo "!!! DISASTER RECOVERY MODE !!!"
echo "Questo script cerca automaticamente dove è collegato il NAS."
read -p "Premi INVIO per procedere..."

echo ">>> 1. Installazione tool (Uso Internet dal FritzBox)..."
# Qui usiamo la connessione predefinita (Fritzbox) per scaricare
apt update && apt install -y nfs-common python3-paho-mqtt unzip curl iputils-ping

echo ">>> 2. RICERCA DEL NAS (Modalità Sonar)..."
# Cerchiamo su quale scheda fisica è attaccato il NAS
FOUND_INTERFACE=""
INTERFACES=$(ls /sys/class/net | grep -E 'en|eth') # Elenca solo schede fisiche

for IFACE in $INTERFACES; do
    echo "Testing interfaccia: $IFACE..."
    # Assegno IP temporaneo su questa scheda
    ip addr add $TEMP_IP/24 dev $IFACE 2>/dev/null
    ip link set $IFACE up
    
    # Provo a pingare il NAS
    if ping -c 1 -W 1 $NAS_IP >/dev/null 2>&1; then
        echo "✅ TROVATO! Il NAS è collegato a $IFACE"
        FOUND_INTERFACE="$IFACE"
        break
    else
EOFo "======================================================"v/nulld/system/ntab"; fil | head -n1)
root@pve:~# cat /root/DA_CARICARE_SU_GITHUB.sh
#!/bin/bash
# ==========================================
# PROXMOX DISASTER RECOVERY (Sonar Mode)
# ==========================================

# --- CONFIGURAZIONE ---
NAS_IP="192.168.2.105"
NAS_PATH="/export/proxmox_bk"
MOUNT_POINT="/mnt/restore_temp"
BACKUP_FILE="proxmox_config_master.tar.gz"
VM_IPFIRE_ID="105"
TEMP_IP="192.168.2.222"
# ----------------------

echo "!!! DISASTER RECOVERY MODE !!!"
echo "Questo script cerca automaticamente dove è collegato il NAS."
read -p "Premi INVIO per procedere..."

echo ">>> 1. Installazione tool (Uso Internet dal FritzBox)..."
# Qui usiamo la connessione predefinita (Fritzbox) per scaricare
apt update && apt install -y nfs-common python3-paho-mqtt unzip curl iputils-ping

echo ">>> 2. RICERCA DEL NAS (Modalità Sonar)..."
# Cerchiamo su quale scheda fisica è attaccato il NAS
FOUND_INTERFACE=""
INTERFACES=$(ls /sys/class/net | grep -E 'en|eth') # Elenca solo schede fisiche

for IFACE in $INTERFACES; do
    echo "Testing interfaccia: $IFACE..."
    # Assegno IP temporaneo su questa scheda
    ip addr add $TEMP_IP/24 dev $IFACE 2>/dev/null
    ip link set $IFACE up
    
    # Provo a pingare il NAS
    if ping -c 1 -W 1 $NAS_IP >/dev/null 2>&1; then
        echo "✅ TROVATO! Il NAS è collegato a $IFACE"
        FOUND_INTERFACE="$IFACE"
        break
    else
        # Se non risponde, tolgo l'IP e provo la prossima
        ip addr del $TEMP_IP/24 dev $IFACE 2>/dev/null
    fi
done

if [ -z "$FOUND_INTERFACE" ]; then
    echo "❌ ERRORE: Non riesco a trovare il NAS su nessuna porta!"
    echo "Verifica che il NAS sia acceso e collegato."
    echo "Tentativo di risveglio (Wake up)..."
    # Provo a svegliarlo sparando su tutte le porte (disperato)
    for IFACE in $INTERFACES; do
        ip addr add $TEMP_IP/24 dev $IFACE 2>/dev/null
        ping -c 3 $NAS_IP >/dev/null 2>&1 &
    done
    sleep 15
    exit 1
fi

echo ">>> 3. Connessione al NAS..."
mkdir -p "$MOUNT_POINT"
# A questo punto l'IP temporaneo è sulla scheda giusta, quindi montiamo
if mount -t nfs "$NAS_IP:$NAS_PATH" "$MOUNT_POINT"; then
    echo "✅ NAS connesso e montato."
else
    echo "⚠️ Primo mount fallito (spin-up dischi?). Riprovo tra 10s..."
    sleep 10
    mount -t nfs "$NAS_IP:$NAS_PATH" "$MOUNT_POINT" || exit 1
fi

# --- FASE A: RIPRISTINO IPFIRE ---
echo ">>> 4. Ripristino VM IPFire ($VM_IPFIRE_ID)..."
LATEST_BACKUP=$(ls -t "$MOUNT_POINT/dump"/vzdump-qemu-$VM_IPFIRE_ID-*.vma* 2>/dev/null | head -n1)

if [ -n "$LATEST_BACKUP" ]; then
    echo "Backup trovato: $(basename "$LATEST_BACKUP")"
    qmrestore "$LATEST_BACKUP" $VM_IPFIRE_ID --force
    qm set $VM_IPFIRE_ID --onboot 1
    echo "✅ IPFire ripristinato."
else
    echo "⚠️ NESSUN BACKUP IPFIRE TROVATO!"
    read -p "Premi INVIO per continuare comunque..."
fi

# --- FASE B: RIPRISTINO SISTEMA ---
echo ">>> 5. Ripristino Configurazioni Proxmox..."
if [ ! -f "$MOUNT_POINT/$BACKUP_FILE" ]; then
    echo "❌ File $BACKUP_FILE non trovato!"
    exit 1
fi

TEMP_RESTORE="/tmp/restore_data"
rm -rf "$TEMP_RESTORE"
mkdir -p "$TEMP_RESTORE"
tar -xzvf "$MOUNT_POINT/$BACKUP_FILE" -C "$TEMP_RESTORE"

# Ripristino Script Root
cp -r "$TEMP_RESTORE/root/." /root/
chmod +x /root/*.sh

# Ripristino MQTT
mkdir -p /usr/local/bin/mqtt_scripts
if [ -d "$TEMP_RESTORE/usr_local_bin/mqtt_scripts" ]; then
    cp -r "$TEMP_RESTORE/usr_local_bin/mqtt_scripts/." /usr/local/bin/mqtt_scripts/
fi
cp "$TEMP_RESTORE/usr_local_bin/"*.sh /usr/local/bin/ 2>/dev/null || true
chmod +x /usr/local/bin/mqtt_scripts/*.py 2>/dev/null
chmod +x /usr/local/bin/*.sh 2>/dev/null

# Ripristino Servizi
if [ -f "$TEMP_RESTORE/root_crontab" ]; then crontab "$TEMP_RESTORE/root_crontab"; fi
if [ -f "$TEMP_RESTORE/systemd/iniziomieiscript.service" ]; then
    cp "$TEMP_RESTORE/systemd/iniziomieiscript.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable iniziomieiscript.service
fi

# Ripristino Mail
cp -r "$TEMP_RESTORE/etc/postfix/." /etc/postfix/
cp "$TEMP_RESTORE/etc/aliases" /etc/aliases 2>/dev/null
newaliases
[ -f /etc/postfix/sasl_passwd ] && postmap /etc/postfix/sasl_passwd

echo ">>> 6. Ripristino RETE ORIGINALE..."
# Sovrascriviamo la rete temporanea con quella vera (Bridge, ecc)
cp "$TEMP_RESTORE/etc/interfaces" /etc/network/interfaces
cp "$TEMP_RESTORE/etc/hosts" /etc/hosts
cp "$TEMP_RESTORE/etc/resolv.conf" /etc/resolv.conf
cp "$TEMP_RESTORE/etc/storage.cfg" /etc/pve/storage.cfg 2>/dev/null

echo ">>> 7. Pulizia..."
umount "$MOUNT_POINT"
rm -rf "$TEMP_RESTORE"

echo "======================================================"
echo "✅ OPERAZIONE COMPLETATA CON SUCCESSO!"
echo "Al riavvio:"
echo "1. La scheda Internet (Fritz) tornerà vmbr0."
echo "2. La scheda NAS tornerà vmbr2."
echo "3. IPFire partirà e gestirà il traffico."
echo "CMD: reboot"
echo "======================================================"
