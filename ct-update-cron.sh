#!/usr/bin/env bash

# ============================================================================
# CRON-FRIENDLY VERSION - NO PROMPTS, FULLY AUTOMATIC
# Updates all running containers without any user interaction
# Suitable for scheduled cron jobs
# ============================================================================

# Force automatic mode for all operations
MODE="auto"
ALL_RUNNING_CT=$(pct list | tail -n +2 | awk '$2=="running" {print $1}')
SELECTED_CT=$ALL_RUNNING_CT

# Log file for cron execution
LOG_FILE="/var/log/ct-update-cron.log"

# Redirect output to log file
exec >> "$LOG_FILE" 2>&1

echo ""
echo "=========================================================================="
echo " Proxmox LXC Container Update - Cron Job"
echo " Executed: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================================================="

# Helper function to check if compose file has services using build
has_build_services() {
    local compose_path="$1"
    local ctid="$2"
    pct exec $ctid -- bash -c "grep -q 'build:' '$compose_path'" &>/dev/null
    return $?
}

# Counters for summary
CONTAINERS_PROCESSED=0
CONTAINERS_FAILED=0
CONTAINERS_SKIPPED=0

for CTID in $SELECTED_CT; do
    # Check if container is reachable
    if ! pct exec $CTID -- true &>/dev/null; then
        echo ""
        echo "=========================================================================="
        echo " >>> CONTAINER ID $CTID - UNREACHABLE <<<"
        echo "=========================================================================="
        echo "[Error] Container $CTID is not responding. Skipping..."
        CONTAINERS_FAILED=$((CONTAINERS_FAILED + 1))
        continue
    fi

    CT_NAME=$(pct config $CTID | grep "hostname:" | awk '{print $2}')
    echo ""
    echo "=========================================================================="
    echo " >>> ACTIVE TARGET: ID $CTID ($CT_NAME) <<<"
    echo "=========================================================================="

    # ==========================================
    # 0. LOCALE CONFIGURATION SEGMENT
    # ==========================================
    echo "[Locale Info] Check: Detecting locale configuration..."
    
    # --- DEBIAN / UBUNTU SYSTEM ---
    if pct exec $CTID -- which apt-get &>/dev/null; then
        echo "[Locale Info] Environment: Debian/Ubuntu base detected."
        
        # Check if locales package is installed
        if ! pct exec $CTID -- dpkg -l | grep -q "^ii.*locales"; then
            echo "[Locale Action] Installing locale support..."
            pct exec $CTID -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y locales" &>/dev/null
        fi
        
        # Check if en_US.UTF-8 locale is generated
        if ! pct exec $CTID -- locale -a 2>/dev/null | grep -q "en_US.utf8"; then
            echo "[Locale Action] Generating en_US.UTF-8 locale..."
            # Enable en_US.UTF-8 in locale.gen, then generate it
            pct exec $CTID -- bash -c "sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen" &>/dev/null
        fi
        
        if pct exec $CTID -- locale -a 2>/dev/null | grep -q "en_US.utf8"; then
            echo "[Locale Status] Locale configuration: OK (en_US.UTF-8 available)"
        else
            echo "[Locale Warning] Locale setup attempted but may not be fully available"
        fi
    
    # --- ALPINE LINUX SYSTEM ---
    elif pct exec $CTID -- which apk &>/dev/null; then
        echo "[Locale Info] Environment: Alpine Linux base detected."
        
        # Check if musl-locales is installed
        if ! pct exec $CTID -- apk info 2>/dev/null | grep -q "musl-locales"; then
            echo "[Locale Action] Installing locale support for Alpine..."
            pct exec $CTID -- apk add musl-locales &>/dev/null
        fi
        
        if pct exec $CTID -- apk info 2>/dev/null | grep -q "musl-locales"; then
            echo "[Locale Status] Locale configuration: OK (musl-locales installed)"
        fi
    else
        echo "[Locale Warning] Unsupported: Unknown package manager. Skipping locale segment."
    fi

    # ==========================================
    # 1. CONTAINER OS UPDATE SEGMENT
    # ==========================================
    echo "[OS Info] Check: Detecting package manager..."
    
    # --- DEBIAN / UBUNTU SYSTEM ---
    if pct exec $CTID -- which apt-get &>/dev/null; then
        echo "[OS Info] Environment: Debian/Ubuntu base detected."
        echo "[OS Info] Action: Refreshing remote package indexes..."
        pct exec $CTID -- bash -c "apt-get update" &>/dev/null
        
        # Extract and format the list of pending package upgrades
        UPGRADE_LIST=$(pct exec $CTID -- bash -c "apt-get --simulate upgrade | grep -E '^Inst '" | awk '{print "     - " $2 " (" $3 " -> " $4 ")"}')
        
        if [ -n "$UPGRADE_LIST" ]; then
            echo "[OS Status] THE FOLLOWING PACKAGES WILL BE UPDATED:"
            echo "$UPGRADE_LIST"
            echo "[OS Action] Processing installation..."
            pct exec $CTID -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get dist-upgrade -y && apt-get autoremove -y"
        else
            echo "[OS Status] Clean: All OS system packages are fully up-to-date."
        fi
    
    # --- ALPINE LINUX SYSTEM ---
    elif pct exec $CTID -- which apk &>/dev/null; then
        echo "[OS Info] Environment: Alpine Linux base detected."
        echo "[OS Info] Action: Refreshing remote repository indexes..."
        pct exec $CTID -- apk update &>/dev/null
        
        # Extract and format the list of pending Alpine upgrades
        UPGRADE_LIST=$(pct exec $CTID -- sh -c "apk version -l '<' | tail -n +2" | awk '{print "     - " $1}')
        
        if [ -n "$UPGRADE_LIST" ]; then
            echo "[OS Status] THE FOLLOWING PACKAGES WILL BE UPDATED:"
            echo "$UPGRADE_LIST"
            echo "[OS Action] Processing installation..."
            pct exec $CTID -- apk upgrade
        else
            echo "[OS Status] Clean: All OS system packages are fully up-to-date."
        fi
    else
        echo "[OS Warning] Unsupported: Unknown package manager. Skipping OS segment."
    fi

    # ==========================================
    # 2. DOCKER / DOCKER COMPOSE SEGMENT
    # ==========================================
    echo "[Docker Info] Check: Looking for active container management runtimes..."
    
    if pct exec $CTID -- systemctl is-active docker &>/dev/null || pct exec $CTID -- rc-service docker status &>/dev/null; then
        echo "[Docker Info] Environment: Active Docker Engine discovery successful."
        
        if pct exec $CTID -- docker compose version &>/dev/null; then
            COMPOSE_CMD="docker compose"
        elif pct exec $CTID -- docker-compose version &>/dev/null; then
            COMPOSE_CMD="docker-compose"
        else
            COMPOSE_CMD=""
        fi

        if [ -n "$COMPOSE_CMD" ]; then
            echo "[Docker Info] Tooling: Using deployment layout '$COMPOSE_CMD'."
            
            COMPOSE_FILES=$(pct exec $CTID -- $COMPOSE_CMD ls --format json 2>/dev/null | grep -o '"ConfigFiles":"[^"]*"' | cut -d'"' -f4)
            
            if [ -z "$COMPOSE_FILES" ]; then
                COMPOSE_FILES=$(pct exec $CTID -- find /opt /home /root -maxdepth 4 -name "docker-compose.yml" -o -name "compose.yml" 2>/dev/null)
            fi

            if [ -n "$COMPOSE_FILES" ]; then
                while IFS= read -r COMPOSE_PATH; do
                    if [ -n "$COMPOSE_PATH" ]; then
                        # Validate compose file exists
                        if ! pct exec $CTID -- test -f "$COMPOSE_PATH" &>/dev/null; then
                            echo "[Docker Warning] Compose file not found: $COMPOSE_PATH. Skipping..."
                            continue
                        fi

                        echo "[Docker Stack] Found Project File: $COMPOSE_PATH"
                        
                        # Check if this compose file has services using build (Dockerfile)
                        if has_build_services "$COMPOSE_PATH" "$CTID"; then
                            echo "[Docker Stack] Detected services using Dockerfile (build:). Processing locally-built images..."
                            echo "[Docker Action] Auto-Mode: Rebuilding and deploying stack immediately..."
                            
                            if pct exec $CTID -- bash -c "$COMPOSE_CMD -f $COMPOSE_PATH build --no-cache && $COMPOSE_CMD -f $COMPOSE_PATH up -d && docker image prune -a -f --filter 'until=24h'"; then
                                echo "[Docker Action] Successfully rebuilt and deployed stack."
                            else
                                echo "[Docker Error] Failed to rebuild and deploy stack at $COMPOSE_PATH"
                            fi
                        else
                            # No build services, proceed with pull-based updates
                            echo "[Docker Stack] No Dockerfile services detected. Checking for remote image updates..."
                            echo "[Docker Action] Auto-Mode: Pulling and deploying stack immediately..."
                            
                            if pct exec $CTID -- bash -c "$COMPOSE_CMD -f $COMPOSE_PATH pull && $COMPOSE_CMD -f $COMPOSE_PATH up -d && docker image prune -a -f --filter 'until=24h'"; then
                                echo "[Docker Action] Successfully deployed stack."
                            else
                                echo "[Docker Error] Failed to deploy stack at $COMPOSE_PATH"
                            fi
                        fi
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
