#!/bin/sh

SCRIPT_NAME=server-init-harden
SCRIPT_VERSION=3.1
TIMESTAMP=$(date '+%Y-%m-%d-%H-%M-%S')
LOG_FILE_NAME="/var/log/${SCRIPT_NAME}_${TIMESTAMP}.log"

USERNAME=""
RESET_ROOT=false

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
Shell script to harden a new Linux/FreeBSD server's security configurations

SYNOPSIS
    $0 [OPTIONS]

DESCRIPTION
    Following security hardening operations are performed:
        - Reset root password (optional)
        - SSH Hardening (disables root login & password auth)
        - New user with privileged access (optional)
        - Generate OpenSSH keys for the new user
        - Sets up Firewalld/pf firewall rules
        - Configures Fail2ban for intrusion prevention

    Require root/sudo privileges
    Creates backups of each modified configuration files
    If some operation fails, configurations are reverted

    All operations are logged to: /var/log/{SCRIPT_NAME}_TIMESTAMP.log

OPTIONS
    -u USERNAME Create new user with privileged (sudo) access
    -r          Reset root password to a secure random value
    -h          Display this help message

EXAMPLES
    # Harden server (SSH, Fail2ban, Firewalld/pf)
    $0

    # Create new privileged (sudo) user & harden server
    $0 -u jay

    # Create new privileged user, reset root password & harden server
    $0 -r -u jay

REPORTING BUG
    https://github.com/pratiktri/server-init-harden/issues/new
EOF
    exit 1
}

parse_and_validate_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
        -u | --username)
            # Check if username already exists
            if id -u "$2" >/dev/null 2>&1; then
                console_log "ERROR" "User $2 already exists"
                exit 1
            fi

            # Validate username format
            if [ -n "$2" ] && echo "$2" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$'; then
                USERNAME="$2"
                shift 2
            else
                console_log "ERROR" "Invalid username"
                file_log "ERROR" "Invalid username. Must start with a letter and contain alphanumeric characters, hyphens, underscores."
                exit 1
            fi
            ;;
        -r | --reset-root)
            RESET_ROOT=true
            shift
            ;;
        -h | --help)
            usage
            ;;
        *)
            console_log "ERROR" "Unknown option: $1"
            file_log "ERROR" "Unknown option: $1"
            exit 1
            ;;
        esac
    done
}

###########################################################################################
###################################### HELPER FUNCTIONS ###################################

create_log_file() {
    if [ ! -d "/var/log" ]; then
        mkdir -p "/var/log"
    fi

    touch "/var/log/$LOG_FILE_NAME"
}

file_log() {
    # $1: Log level
    # $2: Log message

    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "[%s] %s: %s\n" "$timestamp" "$1" "$2" >>"$LOG_FILE_NAME"
}

console_log() {
    # $1: Log level
    # $2: Log message

    case "$1" in
    Success | SUCCESS) printf "[\033[0;32m  DONE  \033[0m] %s\n" "$2" ;;
    Error | ERROR) printf "[\033[0;31m  FAIL  \033[0m] %s\n" "$2" ;;
    Warning | WARNING) printf "[\033[0;33m  WARN  \033[0m] %s\n" "$2" ;;
    Info | INFO) printf "[\033[0;34m  INFO  \033[0m] %s\n" "$2" ;;
    CREDENTIALS) printf "[\033[0;30m  CREDS \033[0m] %s\n" "$2" ;;
    *) printf "[     ] %s\n" "$2" ;;
    esac
}

log_credentials() {
    message="$1"
    console_log "CREDENTIALS" "$message"
}

print_operation_details() {
    echo "Following system hardening operations will be performed:"

    if [ "$RESET_ROOT" = true ]; then
        echo "    [-r]: root password will be reset"
    fi

    if [ -n "$USERNAME" ]; then
        echo "    [-u $USERNAME]: New user $USERNAME will be created"
        echo "    [-u $USERNAME]: New SSH key will be generated for $USERNAME"
    else
        echo "    New SSH key will be generated for $(whoami)"
    fi

    echo "    SSH: login to root account will be disabled"
    echo "    SSH: can only login using generated SSH keys"
    echo "    Software repository will be updated & required software will be installed"
    echo "    Firewalld/pf: Firewall will be configured to only allow SSH, HTTP, HTTPS traffic into the server"
    echo "    Fail2ban: Configured to automatically block repeat offender IPs"
}

print_log_file_details() {
    echo
    echo "See following log file for detailed output of each operation."
    echo "Location: $LOG_FILE_NAME"
    echo "  tail -f $LOG_FILE_NAME    # Follow log in real-time"
    echo
    echo "WARNING: Credentials WILL be displayed on this screen"
    echo "WARNING: Save the credentials. CREDENTIALS WILL NOT BE SHOWN AGAIN."
}

formatted_execution_duration() {
    end_time=$(date +%s)
    duration=$((end_time - START_TIME))
    days=$((duration / 86400))
    hours=$(((duration % 86400) / 3600))
    minutes=$(((duration % 3600) / 60))
    seconds=$((duration % 60))

    if [ $days -gt 0 ]; then
        echo "${days}d ${hours}h ${minutes}m ${seconds}s"
    elif [ $hours -gt 0 ]; then
        echo "${hours}h ${minutes}m ${seconds}s"
    elif [ $minutes -gt 0 ]; then
        echo "${minutes}m ${seconds}s"
    else
        echo "${seconds}s"
    fi
}

manage_service() {
    service_name="$1"
    action="$2" # start, stop, restart, enable

    command_status=0
    # Try service command
    if command -v service >/dev/null 2>&1; then
        file_log "INFO" "Using service command for $service_name $action"
        case "$action" in
        enable)
            # Service command doesn't support enable
            # We will do nothing here, and let the systemctl handle this
            ;;
        *)
            output=$(service "$service_name" "$action" 2>&1)
            command_status=$?
            if [ -n "$output" ]; then
                file_log "INFO" "service $action output: $output"
            fi
            return $command_status
            ;;
        esac
    fi

    # Try systemctl first (systemd)
    if command -v systemctl >/dev/null 2>&1; then
        file_log "INFO" "Using systemctl for $service_name $action"
        output=$(systemctl "$action" "$service_name" 2>&1)
        command_status=$?
        if [ -n "$output" ]; then
            file_log "INFO" "systemctl $action output: $output"
        fi
        return $command_status
    fi

    # Try init.d script
    if [ -x "/etc/init.d/$service_name" ]; then
        file_log "INFO" "Using init.d script for $service_name $action"
        case "$action" in
        enable)
            # Try to enable using chkconfig if available
            if command -v chkconfig >/dev/null 2>&1; then
                output=$(chkconfig "$service_name" on 2>&1)
                command_status=$?
                if [ -n "$output" ]; then
                    file_log "INFO" "chkconfig output: $output"
                fi
                return $command_status
            elif command -v update-rc.d >/dev/null 2>&1; then
                output=$(update-rc.d "$service_name" defaults 2>&1)
                command_status=$?
                if [ -n "$output" ]; then
                    file_log "INFO" "update-rc.d output: $output"
                fi
                return $command_status
            fi
            ;;
        *)
            output=$("/etc/init.d/$service_name" "$action" 2>&1)
            command_status=$?
            if [ -n "$output" ]; then
                file_log "INFO" "init.d $action output: $output"
            fi
            return $command_status
            ;;
        esac
    fi

    file_log "ERROR" "No suitable service manager found for $service_name"
    return 1
}

###########################################################################################
###################################### OPERATIONS #########################################

reset_root_password() {
    console_log "INFO" "Resetting root password..."
    file_log "INFO" "Attempting to reset root password"

    ROOT_PASSWORD=$(head -c 12 /dev/urandom | base64 | tr -dc "[:alnum:]" | head -c 15)

    if command -v pw >/dev/null 2>&1; then # FreeBSD
        output=$(printf '%s\n' "$ROOT_PASSWORD" | pw usermod root -h 0 2>&1)
        command_status=$?
    else # Linux
        output=$(printf "%s\n%s\n" "${ROOT_PASSWORD}" "${ROOT_PASSWORD}" | passwd root 2>&1)
        command_status=$?
    fi

    file_log "INFO" "$output"

    # shellcheck disable=SC2181
    if [ $command_status -ne 0 ]; then
        console_log "ERROR" "Failed to reset root password"
        file_log "ERROR" "Failed to reset root password"
        return 1
    else
        console_log "SUCCESS" "Root password reset"
        file_log "SUCCESS" "Root password reset"
        log_credentials "New root password: [ $ROOT_PASSWORD ]"
    fi
}

revert_create_user() {
    console_log "INFO" "Attempting to remove user [ $USERNAME ]"
    file_log "INFO" "Attempting to remove user [ $USERNAME ]"

    # Check if the user exists before attempting to remove
    if id "$USERNAME" >/dev/null 2>&1; then
        # Remove user and its home directory
        output=$(userdel -r "$USERNAME" 2>&1)
        command_status=$?
        file_log "INFO" "$output"

        if [ $command_status -eq 0 ]; then
            console_log "INFO" "User [ $USERNAME ] and home directory removed"
            file_log "INFO" "User [ $USERNAME ] and home directory removed"
        else
            console_log "ERROR" "Failed to remove user [ $USERNAME ]"
            file_log "ERROR" "Failed to remove user [ $USERNAME ]"
        fi
    else
        console_log "WARNING" "No user [ $USERNAME ] found to remove"
        file_log "WARNING" "No user $USERNAME found to remove"
    fi
}

create_user() {
    console_log "INFO" "Creating user [ $USERNAME ]..."
    file_log "INFO" "Creating user [ $USERNAME ]"

    # Generate a 15-character random password
    USER_PASSWORD=$(head -c 12 /dev/urandom | base64 | tr -dc "[:alnum:]" | head -c 15)

    if command -v pw >/dev/null 2>&1; then
        # FreeBSD
        output=$(pw useradd "$USERNAME" -m -w yes && printf '%s\n' "$USER_PASSWORD" | pw usermod "$USERNAME" -h 0 2>&1)
        command_status=$?
    else
        # Linux
        output=$(useradd -m "$USERNAME" 2>&1 && printf '%s\n%s\n' "$USER_PASSWORD" "$USER_PASSWORD" | passwd "$USERNAME" 2>&1)
        command_status=$?
    fi

    file_log "INFO" "$output"

    if [ $command_status -eq 0 ]; then
        file_log "SUCCESS" "Created user [ $USERNAME ]"
        console_log "SUCCESS" "Created user [ $USERNAME ]"
        log_credentials "$USERNAME's password [ $USER_PASSWORD ]"
    else
        console_log "ERROR" "Failed to create user [ $USERNAME ]"
        file_log "ERROR" "Failed to create user [ $USERNAME ]"
        revert_create_user
        return 1
    fi
}

user_privileged_access() {
    file_log "INFO" "Granting privileged access (sudo) to [ $USERNAME ]"
    console_log "INFO" "Granting privileged access (sudo) to [ $USERNAME ]"

    if getent group wheel >/dev/null 2>&1; then
        if command -v pw >/dev/null 2>&1; then # FreeBSD
            SUDOERS_DIR="/usr/local/etc/sudoers.d"
            output=$(pw groupmod wheel -m "$USERNAME" 2>&1)
            command_status=$?
        else # Fedora, RHEL, SUSE, Arch
            SUDOERS_DIR="/etc/sudoers.d/"
            output=$(usermod -aG wheel "$USERNAME" 2>&1)
            command_status=$?
        fi

        echo "%wheel ALL=(ALL) ALL" >"$SUDOERS_DIR"/wheel
    elif getent group sudo >/dev/null 2>&1; then # Debian, Ubuntu
        output=$(usermod -aG sudo "$USERNAME" 2>&1)
        command_status=$?
    fi

    file_log "INFO" "$output"

    if [ "$command_status" -eq 0 ]; then
        file_log "SUCCESS" "[ $USERNAME ] granted privileged access"
        console_log "SUCCESS" "[ $USERNAME ] granted privileged access"
    else
        console_log "ERROR" "Failed to grant privileged access to [ $USERNAME ]"
        file_log "ERROR" "Failed to grant privileged access to [ $USERNAME ]"
        console_log "WARNING" "From [ $USERNAME ], use [su -] to login to root & perform special operations"
        file_log "WARNING" "From [ $USERNAME ], use [su -] to login to root & perform special operations"
    fi
}

generate_ssh_key() {
    console_log "INFO" "Generating SSH key for [ $SSH_KEY_USER ]..."
    file_log "INFO" "Generating SSH key for [ $SSH_KEY_USER ]"

    # Create .ssh directory & set proper permissions
    home_dir=$(eval echo "~$USERNAME")
    ssh_dir="$home_dir/.ssh"
    if [ ! -d "$home_dir" ]; then
        console_log "ERROR" "Home directory not found for [ $SSH_KEY_USER ]"
        file_log "ERROR" "Home directory not found for [ $SSH_KEY_USER ]"
        return 1
    else
        mkdir -p "$ssh_dir" && chown "$SSH_KEY_USER:$SSH_KEY_USER" "$ssh_dir" && chmod 700 "$ssh_dir" || return 1
        file_log "INFO" "Created .ssh directory: $ssh_dir"
    fi

    # Generate passphrase
    SSH_KEY_PASSPHRASE=$(head -c 12 /dev/urandom | base64 | tr -dc "[:alnum:]" | head -c 15)

    key_name="id_${SSH_KEY_USER}_ed25519"
    SSH_KEY_FILE="$ssh_dir/$key_name"

    # Generate the SSH key
    file_log "INFO" "Generating SSH key for $SSH_KEY_USER"
    if ! output=$(ssh-keygen -o -a 1000 -t ed25519 -f "$SSH_KEY_FILE" -N "$SSH_KEY_PASSPHRASE" -C "$SSH_KEY_USER" -q 2>&1); then
        console_log "ERROR" "Failed to generate SSH key for user [ $SSH_KEY_USER ]"
        file_log "ERROR" "Failed to generate SSH key for user [ $SSH_KEY_USER ]"
        file_log "ERROR" "$output"
        return 1
    fi
    file_log "INFO" "SSH key generated for $SSH_KEY_USER"
    file_log "INFO" "To change passphrase: ssh-keygen -p -f $SSH_KEY_FILE -P"

    # Set proper permissions for the key
    chmod 600 "$SSH_KEY_FILE"
    chmod 644 "$SSH_KEY_FILE.pub"

    # Append public key to authorized_keys
    authorized_keys="$ssh_dir/authorized_keys"
    if ! cat "$SSH_KEY_FILE.pub" >>"$authorized_keys"; then
        console_log "ERROR" "Failed to append public key to authorized_keys"
        file_log "ERROR" "Failed to append public key to authorized_keys"
        return 1
    fi

    # Set proper permissions on authorized_keys
    chmod 400 "$authorized_keys"
    chown "$SSH_KEY_USER:$SSH_KEY_USER" "$authorized_keys"
    file_log "INFO" "Added public key to: $authorized_keys"

    # Log the key details
    file_log "INFO" "SSH key generated for [ $SSH_KEY_USER ]"
    console_log "SUCCESS" "SSH key generated for [ $SSH_KEY_USER ]"
    file_log "SUCCESS" "Key path: [ $SSH_KEY_FILE ]"

    console_log "INFO" "Key path: [ $SSH_KEY_FILE ]"
    console_log "INFO" "Authorized keys path: [ $authorized_keys ]"

    log_credentials "SSH Key passphrase: [ $SSH_KEY_PASSPHRASE ]"
    log_credentials "Private key content:"
    log_credentials "[$(cat "$SSH_KEY_FILE")]"
    log_credentials "Public key content:"
    log_credentials "[$(cat "$SSH_KEY_FILE.pub")]"
}

revert_ssh_config_changes() {
    # Revert backup and try restarting again
    console_log "INFO" "Reverting to backup configuration..."
    file_log "INFO" "Reverting to backup configuration from: $SSH_CONFIG_BACKUP_FILE"

    if ! cp "$SSH_CONFIG_BACKUP_FILE" "$SSHD_CONFIG_FILE" >/dev/null 2>&1; then
        console_log "ERROR" "Failed to restore SSH config backup"
        file_log "ERROR" "Failed to restore SSH config backup"
    fi

    # Try restarting SSH with original config
    if manage_service sshd restart >/dev/null 2>&1 || manage_service ssh restart >/dev/null 2>&1; then
        console_log "INFO" "SSH service restarted with original configuration"
        file_log "INFO" "SSH service restarted with original configuration"
    else
        console_log "ERROR" "Failed to restart SSH service even with original configuration"
        file_log "ERROR" "Failed to restart SSH service even with original configuration"
        return 1
    fi
}

update_ssh_setting() {
    setting="$1"
    value="$2"

    file_log "INFO" "Updating $SSHD_CONFIG_FILE [ $setting $value ]"

    # Comment out existing setting if enabled
    # New settings are always appended to the end of file
    output=$(sed -i.tmp "s/^${setting}/#${setting}/" "$SSHD_CONFIG_FILE" 2>&1)
    command_status=$?
    rm -f "$SSHD_CONFIG_FILE.tmp" >/dev/null 2>&1

    file_log "INFO" "$output"

    if [ $command_status -eq 0 ]; then
        # Add new setting at the end of file
        echo "${setting} ${value}" >>"$SSHD_CONFIG_FILE"
        file_log "INFO" "Updated SSH setting: ${setting} ${value}"
    else
        console_log "ERROR" "Updating SSH configuration [ $setting $value ] failed"
        file_log "ERROR" "Updating SSH configuration [ $setting $value ] failed: $output"
        revert_ssh_config_changes
        return 1
    fi
}

harden_ssh_config() {
    console_log "INFO" "Configuring SSH hardening settings..."
    file_log "INFO" "Starting SSH configuration hardening..."

    SSHD_CONFIG_FILE="/etc/ssh/sshd_config"

    if [ ! -f "$SSHD_CONFIG_FILE" ]; then
        console_log "ERROR" "SSH config file not found at $SSHD_CONFIG_FILE"
        file_log "ERROR" "SSH config file not found at $SSHD_CONFIG_FILE"
        return 1
    fi

    # Create backup with timestamps
    SSH_CONFIG_BACKUP_FILE="${SSHD_CONFIG_FILE}.bak.${TIMESTAMP}"
    output=$(cp "$SSHD_CONFIG_FILE" "$SSH_CONFIG_BACKUP_FILE" 2>&1)
    if [ -n "$output" ]; then
        file_log "INFO" "cp command output: $output"
    fi
    file_log "INFO" "Created backup of sshd_config at: $SSH_CONFIG_BACKUP_FILE"

    # Update SSH settings
    update_ssh_setting "PermitRootLogin" "no"
    update_ssh_setting "PasswordAuthentication" "no"
    update_ssh_setting "PubkeyAuthentication" "yes"
    update_ssh_setting "AuthorizedKeysFile" ".ssh/authorized_keys"

    console_log "SUCCESS" "SSH configuration hardening completed"
    file_log "SUCCESS" "SSH configuration hardening completed"

    # Test configuration syntax
    output=$(sshd -T 2>&1)
    command_status=$?
    file_log "INFO" "$output"

    # Restart SSH service
    if [ $command_status -eq 0 ] && { manage_service sshd restart || manage_service ssh restart; }; then
        console_log "SUCCESS" "SSH service restarted"
        file_log "SUCCESS" "SSH service restarted"
    else
        console_log "ERROR" "Failed to restart SSH service"
        file_log "ERROR" "Failed to restart SSH service"
        revert_ssh_config_changes
        return 1
    fi
}

install_packages() {
    console_log "INFO" "Installing required applications..."
    file_log "INFO" "Installing required applications..."

    LINUX_ONLY_PACKAGES="firewalld fail2ban"
    FREEBSD_ONLY_PACKAGES="py311-fail2ban"
    COMMON_PACKAGES="curl sudo"

    # Detect the package manager and OS
    if [ -f /etc/debian_version ] || [ -f /etc/ubuntu_version ]; then # Debian/Ubuntu
        # Don't let timezone setting stop installation: make UTC server's timezone
        ln -fs /usr/share/zoneinfo/UTC /etc/localtime >/dev/null 2>&1
        console_log "WARNING" "Timezone set to UTC to avoid installation interruption"
        file_log "WARNING" "Timezone set to UTC to avoid installation interruption. Change this after the script completes."
        file_log "INFO" "Installing $COMMON_PACKAGES $LINUX_ONLY_PACKAGES using apt..."
        # shellcheck disable=SC2086
        output=$(DEBIAN_FRONTEND=noninteractive apt-get update -y && apt-get install -y --no-install-recommends $COMMON_PACKAGES $LINUX_ONLY_PACKAGES 2>&1)
        command_status=$?
    elif [ -f /etc/fedora-release ]; then # Fedora
        file_log "INFO" "Installing $COMMON_PACKAGES $LINUX_ONLY_PACKAGES using dnf..."
        # shellcheck disable=SC2086
        output=$(dnf makecache >/dev/null 2>&1 && dnf install -y $COMMON_PACKAGES $LINUX_ONLY_PACKAGES 2>&1)
        command_status=$?
    elif [ -f /etc/SuSE-release ] || [ -f /etc/SUSE-brand ] || command -v zypper >/dev/null 2>&1; then # SUSE
        file_log "INFO" "Installing $COMMON_PACKAGES $LINUX_ONLY_PACKAGES using zypper..."
        # shellcheck disable=SC2086
        output=$(zypper refresh >/dev/null 2>&1 && zypper install -y $COMMON_PACKAGES $LINUX_ONLY_PACKAGES 2>&1)
        command_status=$?
    elif [ -f /etc/arch-release ] || command -v pacman >/dev/null 2>&1; then # Arch Linux
        file_log "INFO" "Installing $COMMON_PACKAGES $LINUX_ONLY_PACKAGES using pacman..."
        # shellcheck disable=SC2086
        output=$(pacman -Sy >/dev/null 2>&1 && pacman -S --noconfirm $COMMON_PACKAGES $LINUX_ONLY_PACKAGES 2>&1)
        command_status=$?
    elif [ -f /etc/freebsd-update.conf ]; then # FreeBSD
        file_log "INFO" "Installing $COMMON_PACKAGES using pkg..."
        # shellcheck disable=SC2086
        output=$(pkg update 2>&1 && pkg install -y $COMMON_PACKAGES $FREEBSD_ONLY_PACKAGES 2>&1)
        command_status=$?
    else
        file_log "ERROR" "Unsupported operating system"
        return 1
    fi

    file_log "INFO" "Applications installation output: $output"

    if [ $command_status -eq 0 ]; then
        file_log "SUCCESS" "Installed required applications"
        console_log "SUCCESS" "Installed required applications"
    else
        console_log "ERROR" "Failed to install applications"
        file_log "ERROR" "Failed to install applications"
        return 1
    fi
}

configure_firewall_linux() {
    # Debian/Ubuntu -> Disable ufw if active
    if command -v ufw >/dev/null 2>&1 && ufw status 2>&1 | grep -q "Status: active"; then
        file_log "INFO" "ufw installed & active. Disabling it..."
        output=$(ufw disable 2>&1)
        console_log "WARNING" "Pre-installed firewall application ufw disabled"
        file_log "WARNING" "Pre-installed firewall application ufw disabled: $output"
        output=$(systemctl disable --now ufw 2>&1)
        file_log "INFO" "$output"
    fi

    # Enable Firewalld
    output=$(systemctl enable firewalld 2>&1 && systemctl start --now firewalld)
    file_log "INFO" "Enable firewalld: $output"

    output=$(firewall-cmd --permanent --add-service=ssh 2>&1)
    file_log "INFO" "Allow SSH: $output"

    output=$(firewall-cmd --permanent --add-service=http 2>&1)
    file_log "INFO" "Allow HTTP: $output"

    output=$(firewall-cmd --permanent --add-service=https 2>&1)
    file_log "INFO" "Allow HTTPS: $output"

    # Enable Firewall
    output=$(firewall-cmd --reload 2>&1)
    file_log "INFO" "Reload firewalld service: $output"

    # Verify Firewall is active
    output=$(firewall-cmd --list-services 2>&1)
    file_log "INFO" "Active firewalls: $output"

    if echo "$output" | grep -q '\bssh\b' &&
        echo "$output" | grep -q '\bhttp\b' &&
        echo "$output" | grep -q '\bhttps\b'; then
        return 0
    else
        return 1
    fi
}

configure_firewall_freebsd() {
    PF_CONF_FILE="/etc/pf.conf"

    # Create backup with timestamps
    if [ -f "$PF_CONF_FILE" ]; then
        PF_CONF_BACKUP_FILE="${PF_CONF_FILE}.bak.${TIMESTAMP}"
        output=$(mv "$PF_CONF_FILE" "$PF_CONF_BACKUP_FILE" 2>&1)
        file_log "INFO" "Backed up existing configuration to $PF_CONF_BACKUP_FILE"
        file_log "INFO" "$output"
    fi

    touch $PF_CONF_FILE
    cat >>$PF_CONF_FILE <<EOF
# Network Hygiene: Normalize network packets
scrub in all

# Do not filter on the loopback interface for performance
set skip on lo0

# Block all incoming and outgoing traffic by default
# Only those that are allowed subsequently will happen
block all

# Allow all outgoing traffic and track connections
pass out all keep state

# Allow incoming ssh, http, https traffic
pass in proto tcp from any to any port { ssh, http, https } keep state
EOF

    output=$(service pf start 2>&1)
    file_log "INFO" "$output"

    # Verify rules and load configuration
    output=$(pfctl -nf $PF_CONF_FILE 2>&1 && pfctl -vvf $PF_CONF_FILE 2>&1)
    command_status=$?
    file_log "INFO" "$output"

    # On config success, enable PF & pflog on boot
    if [ $command_status -eq 0 ]; then
        output=$(pfctl -e 2>/dev/null || true)
        file_log "INFO" "PF Enabled: $output"

        # Enable the PF firewall service on boot
        output=$(sysrc pf_enable="YES" 2>&1)
        file_log "INFO" "$output"

        output=$(sysrc pf_rules="$PF_CONF_FILE" 2>&1)
        file_log "INFO" "$output"

        # Enable logging for the firewall
        output=$(sysrc pflog_enable="YES" 2>&1)
        file_log "INFO" "$output"

        # Set pf logfile to /var/log/pflog
        output=$(sysrc pflog_logfile="/var/log/pflog" 2>&1)
        file_log "INFO" "$output"

        # Start pflog service
        output=$(service pflog start 2>&1)
        file_log "INFO" "$output"

        file_log "SUCCESS" "PF firewall configured"

        return $command_status
    else # Error in PF configuration
        console_log "ERROR" "PF firewall configuration failed"
        file_log "ERROR" "PF firewall configuration failed"

        console_log "INFO" "Reverting PF configuration..."
        file_log "INFO" "Reverting PF configuration..."

        if cp "$PF_CONF_BACKUP_FILE" "$PF_CONF_FILE" >/dev/null 2>&1; then
            console_log "INFO" "Restored [ $PF_CONF_FILE ]"
            file_log "INFO" "Restored [ $PF_CONF_FILE ]"
        else
            console_log "ERROR" "Failed to restore $PF_CONF_FILE"
            file_log "ERROR" "Failed to restore $PF_CONF_FILE"
        fi

        # Load original PF config
        if pfctl -vvnf $PF_CONF_FILE >/dev/null 2>&1 && pfctl -f $PF_CONF_FILE >/dev/null 2>&1; then
            console_log "INFO" "Restarted PF with original configuration"
            file_log "INFO" "Restarted PF with original configuration"
        else
            console_log "ERROR" "Failed to restart PF even with original configuration"
            file_log "ERROR" "Failed to restart PF even with original configuration"
        fi

        return $command_status
    fi

    # TIP: Troubleshoot:
    # List defined "rules": pfctl -s rules
    # Debug rules:          pfctl -vvsr
    # Reset PF:             pfctl -F all
}

configure_firewall() {
    console_log "INFO" "Configuring firewall..."
    file_log "INFO" "Configuring firewall..."

    if command -v firewall-cmd >/dev/null 2>&1; then # Linux
        configure_firewall_linux
        command_status=$?
    elif [ -f /etc/freebsd-update.conf ]; then # FreeBSD
        configure_firewall_freebsd
        command_status=$?
    else
        console_log "ERROR" "Could not find required application for firewall configuration"
        file_log "ERROR" "Could not find required application for firewall configuration"
        return 1
    fi

    if [ $command_status -eq 0 ]; then
        console_log "SUCCESS" "Firewall configured"
        file_log "SUCCESS" "Firewall configured"
    else
        console_log "ERROR" "Failed to configure firewall"
        file_log "ERROR" "Failed to configure firewall"
        return 1
    fi
}

fail2ban_jail_settings() {
    JAIL_LOCAL=$1

    # Backup jail.local if it exists
    if [ -f "$JAIL_LOCAL" ]; then
        JAIL_LOCAL_BACKUP="${JAIL_LOCAL}.bak.${TIMESTAMP}"
        cp "$JAIL_LOCAL" "$JAIL_LOCAL_BACKUP"
        file_log "INFO" "Created backup of existing jail.local at $JAIL_LOCAL_BACKUP"
    fi

    # Get server's public IP
    file_log "Getting server's public IP..."
    PUBLIC_IP=$(curl -s -4 --max-time 10 --fail https://ifconfig.me 2>&1)
    file_log "INFO" "Server public IP: $PUBLIC_IP"

    file_log "INFO" "Adding jails to $JAIL_LOCAL..."

    cat <<EOF >"$JAIL_LOCAL"
[DEFAULT]
backend = auto
banaction = firewallcmd-rich-rules[actiontype=<multiport>]
banaction_allports = firewallcmd-rich-rules[actiontype=<allports>]
ignoreip = 127.0.0.1/8 ::1 $PUBLIC_IP
bantime  = 1h
findtime = 10m
maxretry = 5
# Action: ban only (action_) or ban and email (action_mwl)
action = %(action_)s

#
# SSH Jail
#
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = %(sshd_log)s
           /var/log/auth.log
           /var/log/secure
maxretry = 5
bantime  = 1h
findtime = 10m

#
# Nginx Bot Search - Blocks bots searching for vulnerabilities (404 errors)
#
[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = %(nginx_access_log)s
           /var/log/nginx/access.log
           $(dirname "$JAIL_LOCAL_BACKUP")/emptylog
maxretry = 5
bantime  = 6h
findtime = 10m

#
# Nginx HTTP Authentication
#
[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = %(nginx_error_log)s
           /var/log/nginx/error.log
           $(dirname "$JAIL_LOCAL_BACKUP")/emptylog
maxretry = 3
bantime  = 6h
findtime = 10m

#
# Nginx Limit Request (DDoS protection)
#
[nginx-limit-req]
enabled  = true
port     = http,https
filter   = nginx-limit-req
logpath  = %(nginx_error_log)s
           /var/log/nginx/error.log
           $(dirname "$JAIL_LOCAL_BACKUP")/emptylog
maxretry = 10
bantime  = 6h
findtime = 10m

#
# HAProxy HTTP Authentication Failures
#
[haproxy-http-auth]
enabled  = true
port     = http,https
filter   = haproxy-http-auth
logpath  = /var/log/haproxy.log
           /var/log/haproxy/haproxy.log
           /var/log/haproxy/*.log
           $(dirname "$JAIL_LOCAL_BACKUP")/emptylog
maxretry = 3
bantime  = 6h
findtime = 10m

#
# Recidive Jail - Ban repeat offenders
# This jail monitors fail2ban.log for IPs that have been banned multiple times
#
[recidive]
enabled  = true
filter   = recidive
logpath  = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime  = 1w
findtime = 1d
maxretry = 3
EOF

    # FreeBSD specific ban-actions
    if [ -f /etc/pf.conf ]; then
        sed -i.bak -E 's/(^banaction = )firewallcmd.*/\1pf[actiontype=<allports>]/' "$JAIL_LOCAL"
        sed -i.bak -E 's/(^banaction_allports = )firewallcmd.*/\1pf[actiontype=<allports>]/' "$JAIL_LOCAL"
        rm "$JAIL_LOCAL".bak >/dev/null 2>&1
    fi

    # Dummy logfile so the configuration doesn't fail
    touch "$(dirname "$JAIL_LOCAL")"/emptylog && chmod 644 "$(dirname "$JAIL_LOCAL")"/emptylog

    file_log "INFO" "Jails added to $JAIL_LOCAL"
}

revert_fail2ban_jail_file() {
    if [ -f "$JAIL_LOCAL_BACKUP" ]; then
        console_log "INFO" "Reverting jail.local using [ $JAIL_LOCAL_BACKUP ]..."
        file_log "INFO" "Reverting jail.local using [ $JAIL_LOCAL_BACKUP ]..."

        if cp "$JAIL_LOCAL_BACKUP" "$JAIL_LOCAL" >/dev/null 2>&1; then
            console_log "INFO" "Restored jail.local to original version"
            file_log "INFO" "Restored jail.local to original version"
        else
            console_log "ERROR" "Failed to restore jail.local"
            file_log "INFO" "Failed to restore jail.local"
            return 1
        fi
    else
        # If no backup exists -> we created new jail.local file; delete it
        console_log "INFO" "Removing jail.local..."
        file_log "INFO" "Removing jail.local..."
        rm -f "$JAIL_LOCAL"
        console_log "INFO" "Removed jail.local file"
        file_log "INFO" "Removed jail.local file"
    fi

    # Try restarting fail2ban with original configuration
    if manage_service fail2ban restart; then
        console_log "INFO" "Restarted fail2ban with original configuration"
        file_log "INFO" "Restarted fail2ban with original configuration"
    else
        console_log "ERROR" "Failed to restart fail2ban service even with original configuration"
        file_log "ERROR" "Failed to restart fail2ban service even with original configuration"
        return 1
    fi
}

configure_fail2ban_linux() {
    fail2ban_jail_settings "/etc/fail2ban/jail.local"

    # Restart fail2ban
    if ! manage_service fail2ban restart; then # Error in configuration
        console_log "ERROR" "Failed to restart fail2ban service"
        file_log "ERROR" "Failed to restart fail2ban service"

        revert_fail2ban_jail_file

        return 1
    fi
}

configure_fail2ban_freebsd() {
    RC_CONF_FILE="/etc/rc.conf"
    PF_CONF_FILE="/etc/pf.conf"
    fail2ban_jail_settings "/usr/local/etc/fail2ban/jail.local"

    # Auto start fail2ban on boot and restart with new configuration
    output=$(sysrc fail2ban_enable="YES" 2>&1 && manage_service fail2ban restart 2>&1)
    command_output=$?

    file_log "INFO" "$output"

    # Revert fail2ban & rc.conf changes if fail2ban starting failed
    if [ $command_output -ne 0 ]; then
        file_log "ERROR" "Could not start fail2ban service. Reverting changes..."

        # Don't start fail2ban on boot
        sed -i.bak '/^fail2ban_enable/d' $RC_CONF_FILE
        rm "$RC_CONF_FILE".bak >/dev/null 2>&1

        file_log "INFO" "Reverted $RC_CONF_FILE"

        revert_fail2ban_jail_file

        return 1
    fi

    if [ -f "$PF_CONF_FILE" ]; then
        PF_CONF_BACKUP_FILE="${PF_CONF_FILE}.bak.${TIMESTAMP}"
        output=$(cp "$PF_CONF_FILE" "$PF_CONF_BACKUP_FILE" 2>&1)
        file_log "INFO" "Backed up existing configuration to $PF_CONF_BACKUP_FILE"
        file_log "INFO" "$output"
    fi

    # Add fail2ban table to PF configuration
    if ! grep -q 'table <f2b>' "$PF_CONF_FILE" 2>/dev/null; then
        cat <<EOF >>"$PF_CONF_FILE"

# Fail2ban table and anchor
table <f2b> persist
anchor "f2b/*"
block drop in quick from <f2b> to any
EOF
    fi

    # Verify rules and load configuration
    output=$(pfctl -nf $PF_CONF_FILE 2>&1 && pfctl -vvf $PF_CONF_FILE 2>&1)
    command_status=$?
    file_log "INFO" "$output"

    if [ $command_output -ne 0 ]; then
        console_log "ERROR" "Failed to restart pf post fail2ban. Reverting pf.config..."
        file_log "ERROR" "Failed to restart pf post fail2ban. Reverting pf.config..."

        if cp "$PF_CONF_BACKUP_FILE" "$PF_CONF_FILE" >/dev/null 2>&1; then
            console_log "INFO" "Restored pf.conf to original version"
            file_log "INFO" "Restored pf.conf to original version"
        else
            console_log "ERROR" "Failed to restore pf.conf"
            file_log "INFO" "Failed to restore pf.conf"
            return 1
        fi

        # Try restarting pf with original configuration
        if pfctl -f $PF_CONF_FILE >/dev/null 2>&1; then
            console_log "INFO" "Restarted pf with original configuration"
            file_log "INFO" "Restarted pf with original configuration"
        else
            console_log "ERROR" "Failed to restart pf even with original configuration"
            file_log "ERROR" "Failed to restart pf even with original configuration"
        fi

        return 1
    fi
}

configure_fail2ban() {
    console_log "INFO" "Configuring Fail2ban..."
    file_log "INFO" "Configuring Fail2ban..."

    if command -v firewall-cmd >/dev/null 2>&1; then # Linux
        configure_fail2ban_linux
        command_status=$?
    elif [ -f /etc/pf.conf ]; then # FreeBSD
        configure_fail2ban_freebsd
        command_status=$?
    fi

    if [ "$command_status" -eq 0 ]; then
        console_log "SUCCESS" "Configured Fail2ban"
        file_log "SUCCESS" "Configured Fail2ban"
    else
        console_log "ERROR" "Fail2ban configuration unsuccessful"
        file_log "ERROR" "Fail2ban configuration unsuccessful"
        return 1
    fi
}

print_credentials_and_clean_up() {
    echo
    echo "#########################################################################################"

    if [ "$RESET_ROOT" = "true" ]; then
        echo "New password for root: $ROOT_PASSWORD"
        echo
    fi

    if [ -n "$USERNAME" ]; then
        echo "New user: $USERNAME"
        echo "New user password: $USER_PASSWORD"
        echo
    fi

    echo "SSH private key:"
    cat "$SSH_KEY_FILE" && rm "$SSH_KEY_FILE" >/dev/null 2>&1
    echo

    echo "SSH Key's Passphrase: $SSH_KEY_PASSPHRASE"
    echo

    echo "SSH public key location: $SSH_KEY_FILE.pub:"
    cat "$SSH_KEY_FILE.pub"
    echo "########################################################################################"
}

main() {
    parse_and_validate_args "$@"
    create_log_file
    clear

    print_operation_details
    print_log_file_details

    echo
    echo "Press [Enter] to continue. [Ctrl + c] to cancel..."
    # shellcheck disable=SC2162,SC2034
    read dummy

    # Log script start
    START_TIME=$(date +%s)
    console_log "INFO" "Starting $SCRIPT_NAME v$SCRIPT_VERSION..."
    file_log "INFO" "Starting $SCRIPT_NAME v$SCRIPT_VERSION..."

    # Step 1: Reset root password if requested
    if [ "$RESET_ROOT" = true ]; then
        reset_root_password
        # Continue regardless of error
    fi

    # Step 2: Create new user
    if [ -n "$USERNAME" ]; then
        if ! create_user; then
            print_log_file_details
            return 1 # Abort on error
        fi
        if ! user_privileged_access; then
            print_log_file_details
            return 1 # Abort on error
        fi
    fi

    # Step 3: Generate SSH key for user
    if [ -n "$USERNAME" ]; then
        SSH_KEY_USER="$USERNAME"
    else
        SSH_KEY_USER="$USER"
    fi

    if ! generate_ssh_key "$SSH_KEY_USER"; then
        console_log "ERROR" "Failed to generate SSH key for [ $SSH_KEY_USER ]"
        print_log_file_details
        return 1 # Abort on error
    fi

    # Step 4: Configure SSH
    if ! harden_ssh_config; then
        console_log "ERROR" "Failed to update ssh configuration to harden it"
        print_log_file_details
        return 1 # Abort on error
    fi

    # Step 5: Install required packages
    if ! install_packages; then
        print_log_file_details
        return 1 # Abort on error
    fi

    # Step 6: Configure Firewall
    if ! configure_firewall; then
        print_log_file_details
        return 1 # Abort on error
    fi

    # Step 7: Configure Fail2ban
    if ! configure_fail2ban; then
        print_log_file_details
        return 1 # Abort on error
    fi

    console_log "SUCCESS" "All Done"
    file_log "SUCCESS" "All Done"

    # Calculate and show execution time
    FORMATTED_DURATION=$(formatted_execution_duration)
    console_log "INFO" "Total execution time: [ $FORMATTED_DURATION ]"
    file_log "INFO" "Total execution time: [ $FORMATTED_DURATION ]"

    print_log_file_details
    print_credentials_and_clean_up
    return 0
}

main "$@"
