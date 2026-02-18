#!/bin/bash

# ---------------------------
# Configuration
# ---------------------------

# PXE broker IP
BROKER="192.168.1.201"
PORT="1883"

# Topic must be passed as first argument (primary-switchover / secondary-switchover)
TOPIC="$1"
if [ -z "$TOPIC" ]; then
    echo "Usage: $0 <topic>"
    exit 1
fi

STATE_DIR="/var/lib/switchover-agent"
STATE_FILE="$STATE_DIR/floating-state.json"

LOG_DIR="/var/log/custom-logs"
LOG_FILE="$LOG_DIR/switchover-agent-logs"

# ---------------------------
# Detect first ethernet interface
# ---------------------------
INTERFACE=$(ip -o link show | awk -F': ' '/^[0-9]+: (en|eth|eno|ens)/ {print $2}' | head -n 1)
if [ -z "$INTERFACE" ]; then
    echo "No network interface found!"
    exit 1
fi

# ---------------------------
# Ensure directories exist
# ---------------------------
mkdir -p "$STATE_DIR"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

# Initialize empty JSON state file if it does not exist
if [ ! -f "$STATE_FILE" ]; then
    echo '{"floating_ip": "", "action": false, "last_updated": ""}' > "$STATE_FILE"
fi

# ---------------------------
# Logging function
# ---------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# ---------------------------
# State management
# ---------------------------
save_state() {
    local ip=$1
    local action=$2
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    cat > "$STATE_FILE.tmp" <<EOF
{
  "floating_ip": "$ip",
  "action": $action,
  "last_updated": "$ts"
}
EOF
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        FLOATING_IP=$(jq -r '.floating_ip' "$STATE_FILE")
        ACTION=$(jq -r '.action' "$STATE_FILE")
    else
        FLOATING_IP=""
        ACTION="false"
    fi
}

# ---------------------------
# Floating IP management
# ---------------------------
add_ip() {
    local ip=$1
    if ip addr show "$INTERFACE" | grep -qw "$ip"; then
        log "Floating IP $ip already exists on $INTERFACE"
    else
        ip addr add "$ip/32" dev "$INTERFACE" 2>/dev/null
        if [ $? -eq 0 ]; then
            log "Added floating IP $ip to $INTERFACE"
        else
            log "ERROR: Failed to add floating IP $ip"
        fi
    fi
}

remove_ip() {
    local ip=$1
    if ip addr show "$INTERFACE" | grep -qw "$ip"; then
        ip addr del "$ip/32" dev "$INTERFACE" 2>/dev/null
        if [ $? -eq 0 ]; then
            log "Removed floating IP $ip from $INTERFACE"
        else
            log "ERROR: Failed to remove floating IP $ip"
        fi
    else
        log "Floating IP $ip not present on $INTERFACE"
    fi
}

# ---------------------------
# Reconciliation loop
# ---------------------------
reconcile() {
    load_state
    if [ -n "$FLOATING_IP" ]; then
        if [ "$ACTION" = "true" ]; then
            add_ip "$FLOATING_IP"
        else
            remove_ip "$FLOATING_IP"
        fi
    fi
}

reconcile_loop() {
    while true; do
        sleep 10
        reconcile
    done
}

# ---------------------------
# MQTT listener with auto-reconnect
# ---------------------------
mqtt_listener() {
    while true; do
        # Wait until broker is reachable
        until ping -c 1 -W 1 "$BROKER" &>/dev/null; do
            log "MQTT broker $BROKER not reachable, retrying in 5s..."
            sleep 5
        done

        log "MQTT broker $BROKER is reachable, starting subscription on topic $TOPIC"

        # Start subscription
        mosquitto_sub -h "$BROKER" -p "$PORT" -t "$TOPIC" | while read -r message
        do
            log "Received message: $message"

            FLOATING_IP=$(echo "$message" | jq -r '.floating_ip')
            ACTION=$(echo "$message" | jq -r '.action')

            if [ -n "$FLOATING_IP" ]; then
                save_state "$FLOATING_IP" "$ACTION"

                if [ "$ACTION" = "true" ]; then
                    add_ip "$FLOATING_IP"
                else
                    remove_ip "$FLOATING_IP"
                fi
            else
                log "Invalid message received: $message"
            fi
        done

        log "MQTT subscription ended unexpectedly, restarting in 5s..."
        sleep 5
    done
}

# ---------------------------
# Main
# ---------------------------
log "--------------------------------------------------"
log "Starting switchover-agent"
log "Topic: $TOPIC"
log "Interface: $INTERFACE"

# Initial reconciliation at startup
reconcile

# Start MQTT listener in background
mqtt_listener &

# Start reconciliation loop in background
reconcile_loop &

# Keep script alive
wait
