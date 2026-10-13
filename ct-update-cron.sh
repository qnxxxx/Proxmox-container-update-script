#!/usr/bin/env bash

# ============================================================================
# CRON-FRIENDLY VERSION - NO PROMPTS, FULLY AUTOMATIC
# Updates all running containers without any user interaction
# Suitable for scheduled cron jobs
# ============================================================================

# Cron has a minimal PATH. Proxmox installs pct in /usr/sbin.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

MODE="auto"
LOG_FILE="/var/log/ct-update-cron.log"

# Redirect output before running any Proxmox commands so startup errors are logged.
exec >"$LOG_FILE" 2>&1

PCT="$(command -v pct 2>/dev/null || true)"
if [[ -z "$PCT" || ! -x "$PCT" ]]; then
    echo "[Fatal] pct command not found. PATH=$PATH"
    echo "[Fatal] This script must run on a Proxmox host."
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "[Fatal] This script must run as root."
    exit 1
fi

echo ""
echo "=========================================================================="
echo " Proxmox LXC Container Update - Cron Job"
echo " Executed: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================================================="

mapfile -t SELECTED_CT < <(
    "$PCT" list | awk 'NR > 1 && $2 == "running" { print $1 }'
)
echo "[Info] Running containers found: ${#SELECTED_CT[@]}"

has_build_services() {
    local compose_path="$1"
    local ctid="$2"
    "$PCT" exec "$ctid" -- bash -c "grep -q 'build:' '$compose_path'" &>/dev/null
}

CONTAINERS_PROCESSED=0
CONTAINERS_FAILED=0
CONTAINERS_SKIPPED=0

for CTID in "${SELECTED_CT[@]}"; do
    if ! "$PCT" exec "$CTID" -- true &>/dev/null; then
        echo ""
        echo "=========================================================================="
        echo " >>> CONTAINER ID $CTID - UNREACHABLE <<<"
        echo "=========================================================================="
        echo "[Error] Container $CTID is not responding. Skipping..."
        CONTAINERS_FAILED=$((CONTAINERS_FAILED + 1))
        continue
    fi

    CT_NAME=$("$PCT" config "$CTID" | awk '/^hostname:/ {print $2}')
    echo ""
    echo "=========================================================================="
    echo " >>> ACTIVE TARGET: ID $CTID ($CT_NAME) <<<"
    echo "=========================================================================="

    echo "[Locale Info] Check: Detecting locale configuration..."
    if "$PCT" exec "$CTID" -- which apt-get &>/dev/null; then
        echo "[Locale Info] Environment: Debian/Ubuntu base detected."
        if ! "$PCT" exec "$CTID" -- dpkg -l | grep -q '^ii.*locales'; then
            echo "[Locale Action] Installing locale support..."
            "$PCT" exec "$CTID" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y locales' &>/dev/null
        fi
        if ! "$PCT" exec "$CTID" -- locale -a 2>/dev/null | grep -q 'en_US.utf8'; then
            echo "[Locale Action] Generating en_US.UTF-8 locale..."
            "$PCT" exec "$CTID" -- bash -c "sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen" &>/dev/null
        fi
        if "$PCT" exec "$CTID" -- locale -a 2>/dev/null | grep -q 'en_US.utf8'; then
            echo "[Locale Status] Locale configuration: OK (en_US.UTF-8 available)"
        else
            echo "[Locale Warning] Locale setup attempted but may not be fully available"
        fi
    elif "$PCT" exec "$CTID" -- which apk &>/dev/null; then
        echo "[Locale Info] Environment: Alpine Linux base detected."
        if ! "$PCT" exec "$CTID" -- apk info 2>/dev/null | grep -q 'musl-locales'; then
            echo "[Locale Action] Installing locale support for Alpine..."
            "$PCT" exec "$CTID" -- apk add musl-locales &>/dev/null
        fi
        if "$PCT" exec "$CTID" -- apk info 2>/dev/null | grep -q 'musl-locales'; then
            echo "[Locale Status] Locale configuration: OK (musl-locales installed)"
        fi
    else
        echo "[Locale Warning] Unsupported: Unknown package manager. Skipping locale segment."
    fi

    echo "[OS Info] Check: Detecting package manager..."
    if "$PCT" exec "$CTID" -- which apt-get &>/dev/null; then
        echo "[OS Info] Environment: Debian/Ubuntu base detected."
        echo "[OS Info] Action: Refreshing remote package indexes..."
        "$PCT" exec "$CTID" -- apt-get update &>/dev/null
        UPGRADE_LIST=$("$PCT" exec "$CTID" -- bash -c "apt-get --simulate upgrade | grep -E '^Inst '" | awk '{print "     - " $2 " (" $3 " -> " $4 ")"}')
        if [[ -n "$UPGRADE_LIST" ]]; then
            echo "[OS Status] THE FOLLOWING PACKAGES WILL BE UPDATED:"
            echo "$UPGRADE_LIST"
            echo "[OS Action] Processing installation..."
            "$PCT" exec "$CTID" -- bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get dist-upgrade -y && apt-get autoremove -y'
        else
            echo "[OS Status] Clean: All OS system packages are fully up-to-date."
        fi
    elif "$PCT" exec "$CTID" -- which apk &>/dev/null; then
        echo "[OS Info] Environment: Alpine Linux base detected."
        echo "[OS Info] Action: Refreshing remote repository indexes..."
        "$PCT" exec "$CTID" -- apk update &>/dev/null
        UPGRADE_LIST=$("$PCT" exec "$CTID" -- sh -c "apk version -l '<' | tail -n +2" | awk '{print "     - " $1}')
        if [[ -n "$UPGRADE_LIST" ]]; then
            echo "[OS Status] THE FOLLOWING PACKAGES WILL BE UPDATED:"
            echo "$UPGRADE_LIST"
            echo "[OS Action] Processing installation..."
            "$PCT" exec "$CTID" -- apk upgrade
        else
            echo "[OS Status] Clean: All OS system packages are fully up-to-date."
        fi
    else
        echo "[OS Warning] Unsupported: Unknown package manager. Skipping OS segment."
    fi

    echo "[Docker Info] Check: Looking for active container management runtimes..."
    if "$PCT" exec "$CTID" -- systemctl is-active docker &>/dev/null || "$PCT" exec "$CTID" -- rc-service docker status &>/dev/null; then
        echo "[Docker Info] Environment: Active Docker Engine discovery successful."
        if "$PCT" exec "$CTID" -- docker compose version &>/dev/null; then
            COMPOSE_CMD="docker compose"
        elif "$PCT" exec "$CTID" -- docker-compose version &>/dev/null; then
            COMPOSE_CMD="docker-compose"
        else
            COMPOSE_CMD=""
        fi

        if [[ -n "$COMPOSE_CMD" ]]; then
            echo "[Docker Info] Tooling: Using deployment layout '$COMPOSE_CMD'."
            COMPOSE_FILES=$("$PCT" exec "$CTID" -- $COMPOSE_CMD ls --format json 2>/dev/null | grep -o '"ConfigFiles":"[^"]*"' | cut -d'"' -f4)
            if [[ -z "$COMPOSE_FILES" ]]; then
                COMPOSE_FILES=$("$PCT" exec "$CTID" -- find /opt /home /root -maxdepth 4 \( -name docker-compose.yml -o -name compose.yml \) 2>/dev/null)
            fi

            if [[ -n "$COMPOSE_FILES" ]]; then
                while IFS= read -r COMPOSE_PATH; do
                    [[ -z "$COMPOSE_PATH" ]] && continue
                    if ! "$PCT" exec "$CTID" -- test -f "$COMPOSE_PATH" &>/dev/null; then
                        echo "[Docker Warning] Compose file not found: $COMPOSE_PATH. Skipping..."
                        continue
                    fi
                    echo "[Docker Stack] Found Project File: $COMPOSE_PATH"
                    if has_build_services "$COMPOSE_PATH" "$CTID"; then
                        echo "[Docker Stack] Detected services using Dockerfile (build:). Processing locally-built images..."
                        DOCKER_ACTION="$COMPOSE_CMD -f '$COMPOSE_PATH' build --no-cache && $COMPOSE_CMD -f '$COMPOSE_PATH' up -d"
                    else
                        echo "[Docker Stack] No Dockerfile services detected. Checking for remote image updates..."
                        DOCKER_ACTION="$COMPOSE_CMD -f '$COMPOSE_PATH' pull && $COMPOSE_CMD -f '$COMPOSE_PATH' up -d"
                    fi
                    echo "[Docker Action] Auto-Mode: Deploying stack immediately..."
                    if "$PCT" exec "$CTID" -- bash -c "$DOCKER_ACTION && docker image prune -a -f --filter 'until=24h'"; then
                        echo "[Docker Action] Successfully deployed stack."
                    else
                        echo "[Docker Error] Failed to deploy stack at $COMPOSE_PATH"
                    fi
                done <<< "$COMPOSE_FILES"
            else
                echo "[Docker Info] Result: No structured Compose layout configurations tracked inside scan pathways."
            fi
        else
            echo "[Docker Warning] Tooling: Docker engine exists but Compose binaries are missing."
        fi
    else
        echo "[Docker Info] Result: No background container runtimes detected."
    fi

    echo "[Finished] Tasks execution completed for Container ID $CTID."
    CONTAINERS_PROCESSED=$((CONTAINERS_PROCESSED + 1))
done

echo ""
echo "=========================================================================="
echo " >>> EXECUTION SUMMARY <<<"
echo "=========================================================================="
echo "   Containers Processed:  $CONTAINERS_PROCESSED"
echo "   Containers Failed:     $CONTAINERS_FAILED"
echo "   Timestamp:             $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================================================="
echo " >>> ALL TASKS COMPLETED <<<"
echo "=========================================================================="
echo ""
