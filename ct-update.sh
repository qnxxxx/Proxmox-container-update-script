#!/usr/bin/env bash

# Default mode
MODE=""
SELECTED_CT=""

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
ALL_RUNNING_CT=$(pct list | tail -n +2 | awk '$2=="running" {print $1}')

# Display available containers
echo ""
echo "=================================================="
echo " Available Running Containers"
echo "=================================================="
for CTID in $ALL_RUNNING_CT; do
    CT_NAME=$(pct config $CTID | grep "hostname:" | awk '{print $2}')
    echo "   ID: $CTID  Name: $CT_NAME"
done
echo "--------------------------------------------------"
echo " Select containers to update:"
echo " - Press ENTER for all containers"
echo " - Enter comma-separated IDs (e.g., 100,102,105)"
echo "--------------------------------------------------"
read -p "Enter container IDs or leave blank for all: " container_input

# Process container selection
if [ -z "$container_input" ]; then
    SELECTED_CT=$ALL_RUNNING_CT
    echo "[Info] Selected: ALL running containers"
else
    SELECTED_CT=""
    IFS=',' read -ra ID_ARRAY <<< "$container_input"
    for id in "${ID_ARRAY[@]}"; do
        id=$(echo $id | xargs)
        if echo "$ALL_RUNNING_CT" | grep -q "^$id$"; then
            SELECTED_CT="$SELECTED_CT $id"
        else
            echo "[Warning] Container ID $id not found or not running. Skipping..."
        fi
    done
    if [ -z "$SELECTED_CT" ]; then
        echo "[Error] No valid containers selected. Exiting."
        exit 1
    fi
    echo "[Info] Selected: $SELECTED_CT"
fi

echo ""
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

# Refresh APT indexes, falling back only when an Ubuntu archive source is present.
# The source edit is persistent, so later apt commands use the working mirror.
apt_update_with_mirror_fallback() {
    local ctid="$1"
    pct exec "$ctid" -- bash -c '
        if apt-get update; then
            exit 0
        fi

        sources=(/etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources)
        has_archive=false
        for source in "${sources[@]}"; do
            [[ -f "$source" ]] || continue
            if grep -Fq "archive.ubuntu.com/ubuntu" "$source"; then
                has_archive=true
                break
            fi
        done

        if [[ "$has_archive" != true ]]; then
            echo "[APT Error] Update failed and no archive.ubuntu.com Ubuntu source was found to switch."
            exit 1
        fi

        echo "[APT Warning] archive.ubuntu.com failed; switching Ubuntu sources to mirror.math.princeton.edu/pub/ubuntu and retrying."
        for source in "${sources[@]}"; do
            [[ -f "$source" ]] || continue
            sed -i "s|archive\\.ubuntu\\.com/ubuntu|mirror.math.princeton.edu/pub/ubuntu|g" "$source"
        done

        if apt-get update; then
            echo "[APT Info] Fallback mirror update succeeded; the source change has been saved."
            exit 0
        fi

        echo "[APT Error] Update failed with the fallback mirror as well."
        exit 1
    '
}

# Helper function to check if compose file has services using build
has_build_services() {
    local compose_path="$1"
    local ctid="$2"
    pct exec "$ctid" -- bash -c "grep -q 'build:' '$compose_path'" &>/dev/null
    return $?
}

# Counters for summary
CONTAINERS_PROCESSED=0
CONTAINERS_FAILED=0

for CTID in $SELECTED_CT; do
    # Check if container is reachable
    if ! pct exec "$CTID" -- true &>/dev/null; then
        echo ""
        echo "=========================================================================="
        echo " >>> CONTAINER ID $CTID - UNREACHABLE <<<"
        echo "=========================================================================="
        echo "[Error] Container $CTID is not responding. Skipping..."
        CONTAINERS_FAILED=$((CONTAINERS_FAILED + 1))
        continue
    fi

    CT_NAME=$(pct config "$CTID" | grep "hostname:" | awk '{print $2}')
    echo ""
    echo "=========================================================================="
    echo " >>> ACTIVE TARGET: ID $CTID ($CT_NAME) <<<"
    echo "=========================================================================="

    # 0. LOCALE CONFIGURATION
    echo "[Locale Info] Check: Detecting locale configuration..."
    if pct exec "$CTID" -- which apt-get &>/dev/null; then
        echo "[Locale Info] Environment: Debian/Ubuntu base detected."
        if ! pct exec "$CTID" -- dpkg -l | grep -q "^ii.*locales"; then
            echo "[Locale Action] Installing locale support..."
            if apt_update_with_mirror_fallback "$CTID"; then
                pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y locales" &>/dev/null
            else
                echo "[Locale Warning] Skipping locale installation because APT indexes could not be refreshed."
            fi
        fi
        if ! pct exec "$CTID" -- locale -a 2>/dev/null | grep -q "en_US.utf8"; then
            echo "[Locale Action] Generating en_US.UTF-8 locale..."
            pct exec "$CTID" -- bash -c "sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen" &>/dev/null
        fi
        if pct exec "$CTID" -- locale -a 2>/dev/null | grep -q "en_US.utf8"; then
            echo "[Locale Status] Locale configuration: OK (en_US.UTF-8 available)"
        else
            echo "[Locale Warning] Locale setup attempted but may not be fully available"
        fi
    elif pct exec "$CTID" -- which apk &>/dev/null; then
        echo "[Locale Info] Environment: Alpine Linux base detected."
        if ! pct exec "$CTID" -- apk info 2>/dev/null | grep -q "musl-locales"; then
            echo "[Locale Action] Installing locale support for Alpine..."
            pct exec "$CTID" -- apk add musl-locales &>/dev/null
        fi
        if pct exec "$CTID" -- apk info 2>/dev/null | grep -q "musl-locales"; then
            echo "[Locale Status] Locale configuration: OK (musl-locales installed)"
        fi
    else
        echo "[Locale Warning] Unsupported: Unknown package manager. Skipping locale segment."
    fi

    # 1. CONTAINER OS UPDATE
    echo "[OS Info] Check: Detecting package manager..."
    if pct exec "$CTID" -- which apt-get &>/dev/null; then
        echo "[OS Info] Environment: Debian/Ubuntu base detected."
        echo "[OS Info] Action: Refreshing remote package indexes..."
        if apt_update_with_mirror_fallback "$CTID"; then
            UPGRADE_LIST=$(pct exec "$CTID" -- bash -c "apt-get --simulate upgrade | grep -E '^Inst '" | awk '{print "     - " $2 " (" $3 " -> " $4 ")"}')
            if [ -n "$UPGRADE_LIST" ]; then
                echo "--------------------------------------------------"
                echo "[OS Status] THE FOLLOWING PACKAGES WILL BE UPDATED:"
                echo "--------------------------------------------------"
                echo "$UPGRADE_LIST"
                echo "--------------------------------------------------"
                if confirm_action "Install these OS package updates on $CT_NAME?"; then
                    echo "[OS Action] Processing installation. Output stream active:"
                    pct exec "$CTID" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get dist-upgrade -y && apt-get autoremove -y"
                else
                    echo "[OS Action] Skipped. No packages were altered."
                fi
            else
                echo "[OS Status] Clean: All OS system packages are fully up-to-date."
            fi
        else
            echo "[OS Error] Skipping package upgrades because APT indexes could not be refreshed."
        fi
    elif pct exec "$CTID" -- which apk &>/dev/null; then
        echo "[OS Info] Environment: Alpine Linux base detected."
        echo "[OS Info] Action: Refreshing remote repository indexes..."
        pct exec "$CTID" -- apk update &>/dev/null
        UPGRADE_LIST=$(pct exec "$CTID" -- sh -c "apk version -l '<' | tail -n +2" | awk '{print "     - " $1}')
        if [ -n "$UPGRADE_LIST" ]; then
            echo "--------------------------------------------------"
            echo "[OS Status] THE FOLLOWING PACKAGES WILL BE UPDATED:"
            echo "--------------------------------------------------"
            echo "$UPGRADE_LIST"
            echo "--------------------------------------------------"
            if confirm_action "Install these Alpine updates on $CT_NAME?"; then
                echo "[OS Action] Processing installation. Output stream active:"
                pct exec "$CTID" -- apk upgrade
            else
                echo "[OS Action] Skipped. No packages were altered."
            fi
        else
            echo "[OS Status] Clean: All OS system packages are fully up-to-date."
        fi
    else
        echo "[OS Warning] Unsupported: Unknown package manager. Skipping OS segment."
    fi

    # 2. DOCKER / DOCKER COMPOSE
    echo "[Docker Info] Check: Looking for active container management runtimes..."
    if pct exec "$CTID" -- systemctl is-active docker &>/dev/null || pct exec "$CTID" -- rc-service docker status &>/dev/null; then
        echo "[Docker Info] Environment: Active Docker Engine discovery successful."
        if pct exec "$CTID" -- docker compose version &>/dev/null; then
            COMPOSE_CMD="docker compose"
        elif pct exec "$CTID" -- docker-compose version &>/dev/null; then
            COMPOSE_CMD="docker-compose"
        else
            COMPOSE_CMD=""
        fi

        if [ -n "$COMPOSE_CMD" ]; then
            echo "[Docker Info] Tooling: Using deployment layout '$COMPOSE_CMD'."
            COMPOSE_FILES=$(pct exec "$CTID" -- $COMPOSE_CMD ls --format json 2>/dev/null | grep -o '"ConfigFiles":"[^"]*"' | cut -d'"' -f4)
            if [ -z "$COMPOSE_FILES" ]; then
                COMPOSE_FILES=$(pct exec "$CTID" -- find /opt /home /root -maxdepth 4 \( -name "docker-compose.yml" -o -name "compose.yml" \) 2>/dev/null)
            fi

            if [ -n "$COMPOSE_FILES" ]; then
                while IFS= read -r COMPOSE_PATH; do
                    [ -z "$COMPOSE_PATH" ] && continue
                    if ! pct exec "$CTID" -- test -f "$COMPOSE_PATH" &>/dev/null; then
                        echo "[Docker Warning] Compose file not found: $COMPOSE_PATH. Skipping..."
                        continue
                    fi
                    echo "--------------------------------------------------"
                    echo "[Docker Stack] Found Project File: $COMPOSE_PATH"
                    echo "--------------------------------------------------"
                    if has_build_services "$COMPOSE_PATH" "$CTID"; then
                        echo "[Docker Stack] Detected services using Dockerfile (build:). Processing locally-built images..."
                        if [ "$MODE" = "manual" ]; then
                            echo "[Docker Stack] Checking for Dockerfile changes and rebuild requirements..."
                            if confirm_action "Rebuild Dockerfile-based images and redeploy the stack?"; then
                                echo "[Docker Action] Building and deploying locally-built images..."
                                if pct exec "$CTID" -- bash -c "$COMPOSE_CMD -f '$COMPOSE_PATH' build --no-cache && $COMPOSE_CMD -f '$COMPOSE_PATH' up -d && docker image prune -a -f --filter 'until=24h'"; then
                                    echo "[Docker Action] Successfully rebuilt and deployed stack."
                                else
                                    echo "[Docker Error] Failed to rebuild and deploy stack at $COMPOSE_PATH"
                                fi
                            else
                                echo "[Docker Action] Skipped. No changes made to locally-built images."
                            fi
                        else
                            echo "[Docker Action] Auto-Mode: Rebuilding and deploying stack immediately..."
                            if pct exec "$CTID" -- bash -c "$COMPOSE_CMD -f '$COMPOSE_PATH' build --no-cache && $COMPOSE_CMD -f '$COMPOSE_PATH' up -d && docker image prune -a -f --filter 'until=24h'"; then
                                echo "[Docker Action] Successfully rebuilt and deployed stack."
                            else
                                echo "[Docker Error] Failed to rebuild and deploy stack at $COMPOSE_PATH"
                            fi
                        fi
                    else
                        echo "[Docker Stack] No Dockerfile services detected. Checking for remote image updates..."
                        if [ "$MODE" = "manual" ]; then
                            echo "[Docker Stack] Fetching remote manifest data to check for image updates..."
                            if PULL_LOG=$(pct exec "$CTID" -- bash -c "$COMPOSE_CMD -f '$COMPOSE_PATH' pull" 2>&1); then
                                CHANGED_IMAGES=$(echo "$PULL_LOG" | grep -E "Pulling|pulling|Downloaded newer image" | sed 's/^/     /')
                                if echo "$PULL_LOG" | grep -qE "Downloaded newer image|Downloaded|pulling|Pulling"; then
                                    echo "[Docker Status] IMAGE LAYER REVISIONS DETECTED:"
                                    echo "$CHANGED_IMAGES"
                                    echo "--------------------------------------------------"
                                    if confirm_action "Deploy new images and recreate the stack containers?"; then
                                        echo "[Docker Action] Rebuilding applications with new layers..."
                                        pct exec "$CTID" -- bash -c "$COMPOSE_CMD -f '$COMPOSE_PATH' up -d && docker image prune -a -f --filter 'until=24h'"
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
                            if pct exec "$CTID" -- bash -c "$COMPOSE_CMD -f '$COMPOSE_PATH' pull && $COMPOSE_CMD -f '$COMPOSE_PATH' up -d && docker image prune -a -f --filter 'until=24h'"; then
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
