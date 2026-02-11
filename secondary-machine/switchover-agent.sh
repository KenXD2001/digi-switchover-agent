#!/bin/bash

BROKER="192.168.1.201"
PORT="1883"
TOPIC="$1"

STATE_DIR="/var/lib/switchover-agent"
STATE_FILE="$STATE_DIR/floating-state"

LOG_DIR="/var/log/custom-logs"
LOG_FILE="$LOG_DIR/switchover-agent-logs"

INTERFACE=$(ip -o link show | awk -F': ' '/^[0-9]+: (en|eth|eno|ens)/ {print $2}' | head -n 1)

mkdir -p "$STATE_DIR"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

save_state() {
    local ip=$1
    local action=$2
    echo "floating_ip=$ip" > "$STATE_FILE.tmp"
    echo "action=$action" >> "$STATE_FILE.tmp"
    echo "last_updated=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

load_state() {
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
    else
        floating_ip=""
        action="false"
    fi
}

add_ip() {
    local ip=$1
    if ip addr show "$INTERFACE" | grep -qw "$ip"; then
        log "Floating IP $ip already exists"
    else
        ip addr add "$ip/24" dev "$INTERFACE"
        if [ $? -eq 0 ]; then
            log "Added floating IP $ip to $INTERFACE"
        else
            log "ERROR adding floating IP $ip"
        fi
    fi
}

remove_ip() {
    local ip=$1
    if ip addr show "$INTERFACE" | grep -qw "$ip"; then
        ip addr del "$ip/24" dev "$INTERFACE"
        if [ $? -eq 0 ]; then
            log "Removed floating IP $ip from $INTERFACE"
        else
            log "ERROR removing floating IP $ip"
        fi
    else
        log "Floating IP $ip not present"
    fi
}

reconcile() {
    load_state
    if [ -n "$floating_ip" ]; then
        if [ "$action" = "true" ]; then
            add_ip "$floating_ip"
        else
            remove_ip "$floating_ip"
        fi
    fi
}

mqtt_listener() {
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
            log "Invalid message received"
        fi
    done
}

reconcile_loop() {
    while true
    do
        sleep 10
        reconcile
    done
}

log "--------------------------------------------------"
log "Starting switchover-agent"
log "Topic: $TOPIC"
log "Interface: $INTERFACE"

reconcile
mqtt_listener &
reconcile_loop &
wait
