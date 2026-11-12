#!/bin/bash
# keepalived notify script: posts VRRP state changes to Slack.
# Used from keepalived.conf as: notify "/etc/keepalived/notify.sh <node-name>"
# keepalived appends: <GROUP|INSTANCE> <name> <MASTER|BACKUP|FAULT|STOP|DELETED> <priority>
# The webhook URL is read from the slack_keepalived_webhook Podman secret; the virtual addresses to show come
# from the KEEPALIVED_VIPS environment variable (space separated). Without the secret the script does nothing.

NODE=$1
TYPE=${*: -4:1}
NAME=${*: -3:1}
STATE=${*: -2:1}
PRIORITY=${*: -1:1}

WEBHOOK_FILE=/run/secrets/slack_keepalived_webhook
VIPS=""
for vip in ${KEEPALIVED_VIPS:-}; do VIPS+="\`${vip}\`  "; done

if [ ! -r "$WEBHOOK_FILE" ]; then
  echo "notify.sh: $WEBHOOK_FILE not mounted; skipping Slack" >&2
  exit 0
fi
read -r WEBHOOK_URL < "$WEBHOOK_FILE"

case "$STATE" in
  MASTER)  EMOJI=":large_green_circle:";  COLOR="#2EB67D"; SUMMARY="is now serving the DNS VIPs" ;;
  BACKUP)  EMOJI=":large_yellow_circle:"; COLOR="#ECB22E"; SUMMARY="is standing by" ;;
  FAULT)   EMOJI=":red_circle:";          COLOR="#E01E5A"; SUMMARY="is in FAULT (dnsdist health check or interface down)" ;;
  STOP)    EMOJI=":black_circle:";        COLOR="#616061"; SUMMARY="stopped keepalived" ;;
  *)       EMOJI=":white_circle:";        COLOR="#616061"; SUMMARY="changed state" ;;
esac

TYPE_LABEL=${TYPE,,}
TYPE_LABEL=${TYPE_LABEL^}
NOW=$(date +%s)
FALLBACK="keepalived ${NODE}: ${NAME} -> ${STATE}"

PAYLOAD=$(cat <<PAYLOAD_END
{
  "text": "${FALLBACK}",
  "attachments": [{
    "color": "${COLOR}",
    "blocks": [
      {"type": "section", "text": {"type": "mrkdwn", "text": "${EMOJI} *${NODE}* ${SUMMARY}"}},
      {"type": "section", "fields": [
        {"type": "mrkdwn", "text": "*State*\n${STATE}"},
        {"type": "mrkdwn", "text": "*${TYPE_LABEL}*\n${NAME}"},
        {"type": "mrkdwn", "text": "*Priority*\n${PRIORITY}"},
        {"type": "mrkdwn", "text": "*VIPs*\n${VIPS}"}
      ]},
      {"type": "context", "elements": [
        {"type": "mrkdwn", "text": "keepalived VRRP • <!date^${NOW}^{date_short_pretty} {time_secs}|$(date -u '+%Y-%m-%d %H:%M:%S UTC')>"}
      ]}
    ]
  }]
}
PAYLOAD_END
)

# The image has no curl; BusyBox wget uses Alpine's ssl_client for HTTPS.
wget -q -T 10 -O /dev/null \
  --header 'Content-Type: application/json' \
  --post-data "$PAYLOAD" \
  "$WEBHOOK_URL" || echo "notify.sh: Slack webhook POST failed" >&2
