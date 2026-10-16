# Docker helper commands
# Show running containers in a table
alias dps="docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"

# Show all containers
alias dpsa="docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"

# Show all images
alias dim="docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}'"

# Run an image interactively and remove the container on exit
alias drun="docker run -it --rm"

# Stop a container by name
alias dstop="docker stop"

# Remove a container by name
alias drm="docker rm"

# Remove an image by name or ID
alias drmi="docker rmi"

# Follow container logs
alias dlog="docker logs -f"

# Remove all stopped containers
alias drmc="docker ps -a -q -f status=exited | xargs -r docker rm"

# Remove all dangling images
alias drmid="docker images -f dangling=true -q | xargs -r docker rmi"

check_temps() {
    if [ ! -d /sys/class/thermal ]; then
        echo "Error: /sys/class/thermal is not mounted or unavailable."
        return 1
    fi

    echo "==== Thermal zones ===="
    for zone in /sys/class/thermal/thermal_zone*; do
        # Get the thermal zone type
        type_file="$zone/type"
        if [ -f "$type_file" ]; then
            type=$(cat "$type_file")
        else
            type="unknown"
        fi

        # Read millidegrees Celsius and convert to degrees Celsius
        temp_file="$zone/temp"
        if [ -f "$temp_file" ]; then
            temp=$(cat "$temp_file")
            temp_c=$((temp / 1000))
            temp_milli=$((temp % 1000))
            printf "%-20s : %3d.%03d°C\n" "$type" "$temp_c" "$temp_milli"
        fi
    done
    echo "================================="
}

check_temp_rt() {
    # Make sure the check_temps function has been loaded
    if ! declare -f check_temps > /dev/null; then
        echo "Error: check_temps function not found!"
        return 1
    fi

    echo "Press Ctrl+C to stop real-time temperature monitoring."
    while true; do
        clear                # clear the previous output
        check_temps          # redisplay the temperatures
        sleep 1              # wait 1 second
    done
}

# Transfer files or directories over SSH
# Usage: transfer /local/file-or-directory user@IP /remote/save/path
transfer() {
    if [ $# -ne 3 ]; then
        echo "Usage: transfer /local/file-or-directory user@IP /remote/save/path"
        return 1
    fi

    local SRC="$1"
    local DEST="$2"
    local REMOTE_PATH="$3"

    # Check whether the source file or directory exists
    if [ ! -e "$SRC" ]; then
        echo "Error: source path '$SRC' does not exist!"
        return 1
    fi

    # Transfer recursively, handling both files and directories
    scp -r "$SRC" "$DEST":"$REMOTE_PATH"
    if [ $? -eq 0 ]; then
        echo "Transfer complete: $SRC -> $DEST:$REMOTE_PATH"
    else
        echo "Transfer failed!"
    fi
}
