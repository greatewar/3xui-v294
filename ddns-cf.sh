#!/bin/bash
# ddns-cf.sh - Cloudflare DDNS updater (standalone, on-demand)
# Usage:
#   ddns-cf.sh install     interactive setup: token/domain/subdomain + cron
#   ddns-cf.sh             run once, silent (for cron); no-op if IP unchanged
#   ddns-cf.sh force       force update even if IP unchanged (for testing)
#   ddns-cf.sh uninstall   remove cron job, config and script

set -u

CONF_DIR=/etc/ddns-cf
CONF=$CONF_DIR/config
STATE=$CONF_DIR/last_ip
LOG=/var/log/ddns-cf.log
SCRIPT_PATH=/usr/local/bin/ddns-cf.sh
CRON_LINE="* * * * * $SCRIPT_PATH >> $LOG 2>&1"

log() { echo "[$(date '+%F %T')] $*"; }

get_public_ip() {
    local ip url
    for url in https://api.ipify.org https://4.ident.me https://ipv4.icanhazip.com; do
        ip=$(curl -4 -s --max-time 8 "$url" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
        [ -n "$ip" ] && { echo "$ip"; return 0; }
    done
    return 1
}

cf_api() { # $1=method $2=path [$3=json]
    if [ $# -ge 3 ]; then
        curl -s --max-time 15 -X "$1" "https://api.cloudflare.com/client/v4$2" \
            -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" -d "$3"
    else
        curl -s --max-time 15 -X "$1" "https://api.cloudflare.com/client/v4$2" \
            -H "Authorization: Bearer $CF_TOKEN"
    fi
}

check_token() { cf_api GET /user/tokens/verify | grep -q '"success":true'; }

get_record_id() {
    cf_api GET "/zones/$ZONE_ID/dns_records?type=A&name=$CF_RECORD" | python3 -c "import sys,json;d=json.load(sys.stdin);r=d.get('result') or [];print(r[0]['id'] if r else '')" 2>/dev/null
}

update_record() { # $1=new ip
    local ip=$1 rid data
    data="{\"type\":\"A\",\"name\":\"$CF_RECORD\",\"content\":\"$ip\",\"ttl\":60,\"proxied\":false}"
    rid=$(get_record_id)
    if [ -n "$rid" ]; then
        cf_api PUT "/zones/$ZONE_ID/dns_records/$rid" "$data" | grep -q '"success":true'
    else
        cf_api POST "/zones/$ZONE_ID/dns_records" "$data" | grep -q '"success":true'
    fi
}

run_once() { # $1=optional "force"
    [ -f "$CONF" ] || { log "no config found, run: $0 install"; exit 1; }
    . "$CONF"
    local ip
    ip=$(get_public_ip) || { log "FAIL: cannot detect public IP"; exit 1; }
    if [ "${1:-}" != "force" ] && [ -f "$STATE" ] && [ "$(cat "$STATE" 2>/dev/null)" = "$ip" ]; then
        exit 0
    fi
    if update_record "$ip"; then
        echo "$ip" > "$STATE"
        log "OK: $CF_RECORD -> $ip"
    else
        log "FAIL: cloudflare api error (ip=$ip), cache not written, retry next round"
        exit 1
    fi
}

install_() {
    [ "$(id -u)" -eq 0 ] || { echo "please run as root"; exit 1; }
    mkdir -p "$CONF_DIR" && chmod 700 "$CONF_DIR"
    echo "== Cloudflare DDNS setup =="
    read -rp "Paste Cloudflare API Token (Zone:DNS:Edit): " CF_TOKEN
    read -rp "Full record name (e.g. hy.example.com): " CF_RECORD
    echo "-- verifying token ..."
    check_token || { echo "invalid token, abort."; exit 1; }
    echo "-- resolving zone for $CF_RECORD ..."
    ZONE_INFO=$(cf_api GET "/zones?per_page=50" | python3 -c "
import sys, json
name = '$CF_RECORD'.strip('.').lower()
try:
    d = json.load(sys.stdin)
except Exception:
    exit(1)
best = ''
zmap = {}
for z in (d.get('result') or []):
    zn = z['name'].strip('.').lower()
    zmap[zn] = z['id']
    if (name == zn or name.endswith('.' + zn)) and len(zn) > len(best):
        best = zn
if best:
    print(best, zmap[best])
" 2>/dev/null)
    [ -n "$ZONE_INFO" ] || { echo "no matching zone for $CF_RECORD (check token zone scope), abort."; exit 1; }
    CF_DOMAIN=${ZONE_INFO%% *}
    ZONE_ID=${ZONE_INFO##* }
    echo "-- matched zone: $CF_DOMAIN"
    printf "CF_TOKEN='%s'\nCF_DOMAIN='%s'\nCF_RECORD='%s'\nZONE_ID='%s'\n" \
        "$CF_TOKEN" "$CF_DOMAIN" "$CF_RECORD" "$ZONE_ID" > "$CONF"
    chmod 600 "$CONF"
    cp -f "$0" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
    (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH"; echo "$CRON_LINE") | crontab -
    echo "-- cron installed: $CRON_LINE"
    echo "-- running first update ..."
    "$SCRIPT_PATH" force
    echo "== done. test record: $CF_RECORD =="
}

uninstall_() {
    (crontab -l 2>/dev/null | grep -vF "$SCRIPT_PATH") | crontab - 2>/dev/null
    rm -rf "$CONF_DIR" "$SCRIPT_PATH"
    echo "removed (log kept at $LOG)"
}

case "${1:-}" in
    install)   install_ ;;
    uninstall) uninstall_ ;;
    force)     run_once force ;;
    run)       run_once ;;
    "")
        if [ -t 0 ]; then
            echo "== Cloudflare DDNS =="
            echo " 1) install          (default, press Enter)"
            echo " 2) uninstall"
            echo " 3) force update now"
            read -rp "Choose [1]: " menu_choice
            case "${menu_choice:-1}" in
                1) install_ ;;
                2) uninstall_ ;;
                3) run_once force ;;
                *) echo "invalid choice: $menu_choice"; exit 1 ;;
            esac
        else
            run_once
        fi
        ;;
    *) echo "usage: $0 [install|uninstall|force|run]"; exit 1 ;;
esac
