#!/usr/bin/env bash

# Default mode
MODE=""

# Counters for summary
CONTAINERS_PROCESSED=0
CONTAINERS_FAILED=0
CONTAINERS_SKIPPED=0

# Parse arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --auto) MODE="auto"; shift ;;
        --manual) MODE="manual"; shift ;;
        *) echo "Unknown parameter: $1"; echo "Usage: $0 [--auto | --manual]"; exit 1 ;;
    esac
done

# If no argument is passed, force selection
if [ -z "$MODE" ]; then
    echo "=================================================="
    echo " Select Script Operation Mode"
    echo "=================================================="
    echo " 1) Manual Mode (Prompt before installing changes)"
    echo " 2) Automatic Mode (Apply all updates immediately)"
    echo "--------------------------------------------------"
    read -p "Enter choice [1-2]: " choice
    case $choice in
        1) MODE="manual" ;;
        2) MODE="auto" ;;
        *) echo "Invalid choice. Exiting."; exit 1 ;;
    esac
fi

# Fetch all currently running LXC container IDs
RUNNING_CT=$(pct list | tail -n +2 | awk '$2=="running" {print $1}')

echo "=================================================="
echo " Starting Proxmox LXC Updates in [$MODE] Mode"
echo "=================================================="

# Helper function for manual confirmations
confirm_action() {
    local prompt_msg="$1"
    if [ "$MODE" = "auto" ]; then
        return 0
    fi
    read -p "   --> $prompt_msg [y/N]: " resp
    if [[ "$resp" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

for CTID in $RUNNING_CT; do
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
            echo "--------------------------------------------------"
            echo "[OS Status] THE FOLLOWING PACKAGES WILL BE UPDATED:"
            echo "--------------------------------------------------"
            echo "$UPGRADE_LIST"
            echo "--------------------------------------------------"
            
            if confirm_action "Install these OS package updates on $CT_NAME?"; then
                echo "[OS Action] Processing installation. Output stream active:"
                pct exec $CTID -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get dist-upgrade -y && apt-get autoremove -y"
            else
                echo "[OS Action] Skipped. No packages were altered."
            fi
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
            echo "--------------------------------------------------"
            echo "[OS Status] THE FOLLOWING PACKAGES WILL BE UPDATED:"
            echo "--------------------------------------------------"
            echo "$UPGRADE_LIST"
            echo "--------------------------------------------------"
            
            if confirm_action "Install these Alpine updates on $CT_NAME?"; then
                echo "[OS Action] Processing installation. Output stream active:"
                pct exec $CTID -- apk upgrade
            else
                echo "[OS Action] Skipped. No packages were altered."
            fi
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

                        echo "--------------------------------------------------"
                        echo "[Docker Stack] Found Project File: $COMPOSE_PATH"
                        echo "--------------------------------------------------"
                        
                        if [ "$MODE" = "manual" ]; then
                            echo "[Docker Stack] Fetching remote manifest data to check for image updates..."
                            
                            # Run pull and capture raw data to show the user exactly what changed
                            if PULL_LOG=$(pct exec $CTID -- bash -c "$COMPOSE_CMD -f $COMPOSE_PATH pull" 2>&1); then
                                # Filter pull stream to show exactly which container tags fetched new layers
                                CHANGED_IMAGES=$(echo "$PULL_LOG" | grep -E "Pulling|pulling|Downloaded newer image" | sed 's/^/     /')
                                
                                if echo "$PULL_LOG" | grep -qE "Downloaded newer image|Downloaded|pulling|Pulling"; then
                                    echo "[Docker Status] IMAGE LAYER REVISIONS DETECTED:"
                                    echo "$CHANGED_IMAGES"
                                    echo "--------------------------------------------------"
                                    
                                    if confirm_action "Deploy new images and recreate the stack containers?"; then
                                        echo "[Docker Action] Rebuilding applications with new layers..."
                                        pct exec $CTID -- bash -c "$COMPOSE_CMD -f $COMPOSE_PATH up -d && docker image prune -a -f --filter 'until=24h'"
                                    else
                                        echo "[Docker Action] Aborted. Active applications left running on existing layers."
                                    fi
                                else
                                    echo "[Docker Status] Clean: Local container image layers already match remote repository tags."
                                fi
                            else
                                echo "[Docker Error] Failed to pull images from $COMPOSE_PATH"
                            fi
                        else
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
echo "=========================================================================="
echo " >>> ALL SELECTED TASKS COMPLETED <<<"
echo "=========================================================================="
