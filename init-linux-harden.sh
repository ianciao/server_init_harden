#!/bin/sh

SCRIPT_NAME=server-init-harden
SCRIPT_VERSION=2.0
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
LOGFILE_NAME="${SCRIPT_NAME}_${TIMESTAMP}.log"
START_TIME=$(date +%s)

SHOW_CREDENTIALS=false
USERNAME=""
RESET_ROOT=false

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
A script to harden Linux server security configurations

USAGE:
    $0 [OPTIONS]

DESCRIPTION:
    This script performs several security hardening operations on a Linux server:
    - Hardens SSH configuration (disables root login, password auth)
    - Creates new user with sudo access (optional)
    - Generates secure SSH keys
    - Resets root password (optional)
    - Configures Fail2ban for intrusion prevention
    - Sets up UFW firewall rules

OPTIONS:
    -u USERNAME Create a new sudo user with the specified username
    -r          Reset root password to a secure random value
    -s          Show sensitive information (passwords, keys) in console output
    -h          Display this help message

EXAMPLES:
    # Basic hardening (SSH, Fail2ban, UFW)
    $0

    # Create new sudo user during hardening
    $0 -u jay

    # Create new user and reset root password
    $0 -u jay -r

    # Show all credentials in console output (less secure)
    $0 -u jay -s

LOGGING:
    All operations are logged to: ./${SCRIPT_NAME}_TIMESTAMP.log
    Sensitive information (passwords, keys) are only logged to file by default
    Use -s flag to also show sensitive information in console output

NOTES:
    - Requires root/sudo privileges
    - Creates backups of modified configuration files
    - If some operation fails, configurations will be reverted

For bug reports and contributions:
    https://github.com/pratiktri/server-init-harden
EOF
    exit 1
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
        -u | --username)
            # Validate username format
            if [ -n "$2" ] && echo "$2" | grep -qE '^[a-zA-Z][a-zA-Z0-9_-]*$'; then
                USERNAME="$2"
                shift 2
            else
                console_log "ERROR" "Invalid username format. Must start with a letter and contain only alphanumeric characters, hyphens, or underscores."
                file_log "ERROR" "Invalid username format. Must start with a letter and contain only alphanumeric characters, hyphens, or underscores."
                exit 1
            fi
            ;;
        -r | --reset-root)
            RESET_ROOT=true
            shift
            ;;
        -s)
            SHOW_CREDENTIALS=true
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

create_logfile() {
    touch "$LOGFILE_NAME"
}

file_log() {
    # $1: Log level
    # $2: Log message

    # Write to logfile with timestamps and log level
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    printf "[%s] %s: %s\n" "$timestamp" "$1" "$2" >>"$LOGFILE_NAME"
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
    file_log "CREDENTIALS" "$message"
    if [ "$SHOW_CREDENTIALS" = true ]; then
        console_log "CREDENTIALS" "$message"
    fi
}

# TODO: Print the options chosen by user
print_logfile_details() {
    printf "\nLog file location: %s\n" "$LOGFILE_NAME"
    printf "  cat %s        # View log file\n" "$LOGFILE_NAME"
    printf "  tail -f %s    # Follow log in real-time\n\n" "$LOGFILE_NAME"
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
    file_log "INFO" "Attempting to reset root password"
    ROOT_PASSWORD=$(head -c 12 /dev/urandom | base64 | tr -dc "[:alnum:]" | head -c 15)

    # Change root password
    output=$(printf "%s\n%s\n" "${ROOT_PASSWORD}" "${ROOT_PASSWORD}" | passwd root 2>&1)

    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        console_log "ERROR" "Failed to reset root password"
        file_log "ERROR" "Failed to reset root password"
        if [ -n "$output" ]; then
            file_log "ERROR" "passwd command output: $output"
        fi
        return 1
    fi

    if [ -n "$output" ]; then
        file_log "INFO" "passwd command output: $output"
    fi

    log_credentials "New root password: $ROOT_PASSWORD"

    return 0
}

revert_create_user() {
    file_log "INFO" "Attempting to remove user $USERNAME"

    # Check if the user exists before attempting to remove
    if id "$USERNAME" >/dev/null 2>&1; then
        # Remove user and its home directory
        output=$(userdel -r "$USERNAME" 2>&1)
        if [ -n "$output" ]; then
            file_log "INFO" "userdel command output: $output"
        fi

        # shellcheck disable=SC2181
        if [ $? -eq 0 ]; then
            file_log "SUCCESS" "User $USERNAME and home directory removed successfully"
            return 0
        else
            file_log "ERROR" "Failed to remove user $USERNAME"
            return 1
        fi
    else
        file_log "WARNING" "No user $USERNAME found to remove"
        return 0
    fi
}

create_user() {
    # Check if username already exists
    if id "$USERNAME" >/dev/null 2>&1; then
        file_log "WARNING" "User $USERNAME already exists"
        return 1
    fi

    # Generate a 15-character random password
    USER_PASSWORD=$(head -c 12 /dev/urandom | base64 | tr -dc "[:alnum:]" | head -c 15)

    file_log "INFO" "Creating user $USERNAME"
    output=$(printf '%s\n%s\n' "${USER_PASSWORD}" "${USER_PASSWORD}" | adduser "$USERNAME" -q --gecos "First Last,RoomNumber,WorkPhone,HomePhone" 2>&1)

    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        file_log "ERROR" "Failed to create user $USERNAME"
        return 1
    fi
    if [ -n "$output" ]; then
        file_log "INFO" "adduser command output: $output"
    fi

    output=$(usermod -aG sudo "$USERNAME" 2>&1)

    # shellcheck disable=SC2181
    if [ $? -ne 0 ]; then
        console_log "WARNING" "Failed to add user $USERNAME to sudo group"
        file_log "WARNING" "Failed to add user $USERNAME to sudo group"
    fi

    if [ -n "$output" ]; then
        file_log "INFO" "usermod command output: $output"
    fi

    # Log user creation details
    file_log "SUCCESS" "User created: $USERNAME"
    console_log "SUCCESS" "User created: $USERNAME"
    log_credentials "$USERNAME's - Password: $USER_PASSWORD"

    return 0
}

generate_ssh_key() {
    target_user="$1"

    console_log "INFO" "Generating SSH key for user: $target_user..."
    file_log "INFO" "Generating SSH key for user: $target_user"

    home_dir=$(eval echo "~$target_user")
    if [ ! -d "$home_dir" ]; then
        console_log "ERROR" "Home directory not found for user: $target_user"
        file_log "ERROR" "Home directory not found for user: $target_user"
        return 1
    fi

    # Create .ssh directory & set proper permissions
    ssh_dir="$home_dir/.ssh"
    if [ ! -d "$ssh_dir" ]; then
        mkdir -p "$ssh_dir"
        chown "$target_user:$target_user" "$ssh_dir"
        chmod 700 "$ssh_dir"
        file_log "INFO" "Created .ssh directory: $ssh_dir"
    fi

    # Generate a strong passphrase
    key_passphrase=$(head -c 12 /dev/urandom | base64 | tr -dc "[:alnum:]" | head -c 15)

    key_name="id_${target_user}_ed25519"
    key_path="$ssh_dir/$key_name"

    # Generate the SSH key
    file_log "INFO" "Generating SSH key for $target_user"
    if ! output=$(su -c "ssh-keygen -o -a 1000 -t ed25519 -f '$key_path' -N '$key_passphrase'" - "$target_user" 2>&1); then
        console_log "ERROR" "Failed to generate SSH key for user: $target_user"
        file_log "ERROR" "Failed to generate SSH key for user: $target_user"
        file_log "ERROR" "ssh-keygen output: $output"
        return 1
    fi
    file_log "INFO" "SSH key generated successfully for user: $target_user"

    # Set proper permissions for the key
    chmod 600 "$key_path"
    chmod 644 "$key_path.pub"

    # Append public key to authorized_keys
    authorized_keys="$ssh_dir/authorized_keys"
    if ! cat "$key_path.pub" >>"$authorized_keys"; then
        console_log "ERROR" "Failed to append public key to authorized_keys"
        file_log "ERROR" "Failed to append public key to authorized_keys"
        return 1
    fi

    # Set proper permissions on authorized_keys
    chmod 400 "$authorized_keys"
    chown "$target_user:$target_user" "$authorized_keys"
    file_log "INFO" "Added public key to: $authorized_keys"

    # Log the key details
    file_log "INFO" "SSH key generated successfully for user: $target_user"
    console_log "SUCCESS" "SSH key generated successfully for user: $target_user"
    file_log "SUCCESS" "Key path: $key_path"

    console_log "INFO" "Key path: $key_path"
    console_log "INFO" "Authorized keys path: $authorized_keys"

    log_credentials "SSH key details for $target_user:"
    log_credentials "SSH Key passphrase: $key_passphrase"
    log_credentials "Private key content:"
    log_credentials "$(cat "$key_path")"
    log_credentials "Public key content:"
    log_credentials "$(cat "$key_path.pub")"

    return 0
}

update_ssh_setting() {
    setting="$1"
    value="$2"

    # Comment out existing setting if found
    output=$(sed -i "s/^${setting}/#${setting}/" "$SSHD_CONFIG" 2>&1)
    if [ -n "$output" ]; then
        file_log "INFO" "sed command output: $output"
    fi

    # Add new setting at the end of file
    echo "${setting} ${value}" >>"$SSHD_CONFIG"
    file_log "INFO" "Updated SSH setting: ${setting} ${value}"
}

harden_ssh_config() {
    console_log "INFO" "Configuring SSH hardening settings..."
    file_log "INFO" "Starting SSH configuration hardening..."

    SSHD_CONFIG="/etc/ssh/sshd_config"

    if [ ! -f "$SSHD_CONFIG" ]; then
        console_log "ERROR" "SSH config file not found at $SSHD_CONFIG"
        file_log "ERROR" "SSH config file not found at $SSHD_CONFIG"
        return 1
    fi

    # Create backup with timestamps
    BACKUP_FILE="${SSHD_CONFIG}.bak.${TIMESTAMP}"
    output=$(cp "$SSHD_CONFIG" "$BACKUP_FILE" 2>&1)
    if [ -n "$output" ]; then
        file_log "INFO" "cp command output: $output"
    fi
    file_log "INFO" "Created backup of sshd_config at: $BACKUP_FILE"

    # Update SSH settings
    update_ssh_setting "PermitRootLogin" "no"
    update_ssh_setting "PasswordAuthentication" "no"
    update_ssh_setting "PubkeyAuthentication" "yes"
    update_ssh_setting "AuthorizedKeysFile" ".ssh/authorized_keys"

    console_log "SUCCESS" "SSH configuration hardening completed"
    file_log "SUCCESS" "SSH configuration hardening completed"

    # Restart SSH service
    if manage_service sshd restart || manage_service ssh restart; then
        console_log "SUCCESS" "SSH service restarted successfully"
        file_log "SUCCESS" "SSH service restarted successfully"
        return 0
    fi

    console_log "ERROR" "Failed to restart SSH service"
    file_log "ERROR" "Failed to restart SSH service"

    # Revert to backup and try restarting again
    console_log "INFO" "Reverting to backup configuration..."
    file_log "INFO" "Reverting to backup configuration from: $BACKUP_FILE"

    if ! cp "$BACKUP_FILE" "$SSHD_CONFIG"; then
        console_log "ERROR" "Failed to restore SSH config backup"
        file_log "ERROR" "Failed to restore SSH config backup"
        exit 1
    fi

    # Try restarting SSH with original config
    if manage_service sshd restart || manage_service ssh restart; then
        console_log "SUCCESS" "SSH service restarted successfully with original configuration"
        file_log "SUCCESS" "SSH service restarted successfully with original configuration"
        exit 1
    fi

    console_log "ERROR" "Failed to restart SSH service even with original configuration"
    file_log "ERROR" "Failed to restart SSH service even with original configuration"
    exit 1
}

install_package() {
    if [ $# -eq 0 ]; then
        file_log "ERROR" "No package specified for installation"
        return 1
    fi

    PACKAGE_NAME="$1"

    # Detect the package manager and OS
    if [ -f /etc/debian_version ] || [ -f /etc/ubuntu_version ]; then
        # Debian/Ubuntu
        file_log "INFO" "Installing $PACKAGE_NAME using apt..."
        # Don't let timezone setting stop the installation: make UTC the system timezone
        ln -fs /usr/share/zoneinfo/UTC /etc/localtime
        file_log "WARNING" "Set UTC as system timezone. Change this after the script completes."
        # shellcheck disable=SC2086
        output=$(DEBIAN_FRONTEND=noninteractive apt-get update -y && apt-get install -y --no-install-recommends $PACKAGE_NAME 2>&1)
        ret=$?
    elif [ -f /etc/fedora-release ]; then
        # Fedora
        file_log "INFO" "Installing $PACKAGE_NAME using dnf..."
        # shellcheck disable=SC2086
        output=$(dnf makecache && dnf install -y $PACKAGE_NAME 2>&1)
        ret=$?
    elif [ -f /etc/freebsd-update.conf ]; then
        # FreeBSD
        file_log "INFO" "Installing $PACKAGE_NAME using pkg..."
        # shellcheck disable=SC2086
        output=$(pkg update && pkg install -y $PACKAGE_NAME 2>&1)
        ret=$?
    else
        file_log "ERROR" "Unsupported operating system"
        return 1
    fi

    # Log the output if any
    if [ -n "$output" ]; then
        file_log "INFO" "Package installation output: $output"
    fi

    # Handle the return status
    if [ $ret -ne 0 ]; then
        file_log "ERROR" "Failed to install package: $PACKAGE_NAME"
        return 1
    fi

    file_log "SUCCESS" "Successfully installed package: $PACKAGE_NAME"
    return 0
}

configure_ufw() {
    console_log "INFO" "Starting UFW configuration..."
    file_log "INFO" "Starting UFW configuration"

    # Check if UFW is installed
    if ! command -v ufw >/dev/null 2>&1; then
        file_log "ERROR" "UFW is not installed"
        return 1
    fi

    output=$(ufw allow ssh 2>&1)
    if [ -n "$output" ]; then
        file_log "INFO" "ufw allow ssh output: $output"
    fi

    output=$(ufw allow http 2>&1)
    if [ -n "$output" ]; then
        file_log "INFO" "ufw allow http output: $output"
    fi

    output=$(ufw allow https 2>&1)
    if [ -n "$output" ]; then
        file_log "INFO" "ufw allow https output: $output"
    fi

    # Enable UFW
    output=$(echo "y" | ufw enable 2>&1)
    if [ -n "$output" ]; then
        file_log "INFO" "ufw enable output: $output"
    fi

    # Verify UFW is active
    output=$(ufw status 2>&1)
    if [ -n "$output" ]; then
        file_log "INFO" "ufw status output: $output"
    fi

    if ! echo "$output" | grep -q "Status: active"; then
        console_log "ERROR" "UFW is not active after enabling"
        file_log "ERROR" "UFW is not active after enabling"
        return 1
    fi

    console_log "SUCCESS" "UFW configuration completed successfully"
    file_log "SUCCESS" "UFW configuration completed successfully"
    return 0
}

update_fail2ban_jail_local_file() {
    search_term="$1"
    new_value="$2"

    # We want to update the setting in the [DEFAULT] section
    # [DEFAULT] section ends right before "# JAILS"
    range_start="^\[DEFAULT\]$"
    range_end="^# JAILS$"
    file=$JAIL_LOCAL_FILE

    # When the setting exists & it's NOT commented out -> comment it and add the new setting on next line
    if sed -n "/${range_start}/,/${range_end}/p" "$file" | grep -q "^${search_term}[[:blank:]]*="; then
        sed -ri "/${range_start}/,/${range_end}/ s/^(${search_term}[[:blank:]]*=.*)/#\1/" "$file"
        sed -ri "/${range_start}/,/${range_end}/ s/^#${search_term}[[:blank:]]*=.*/&\n${search_term} = ${new_value}/" "$file"
    else # If the setting is commented out or it doesn't exist -> add it after the commented line or at the end of the section
        sed -ri "/${range_start}/,/${range_end}/ s/^#${search_term}[[:blank:]]*=.*/&\n${search_term} = ${new_value}/" "$file"
    fi
}

configure_fail2ban() {
    console_log "INFO" "Starting Fail2ban configuration..."
    file_log "INFO" "Starting Fail2ban configuration"

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        file_log "ERROR" "Fail2ban is not installed"
        return 1
    fi

    JAIL_LOCAL_FILE="/etc/fail2ban/jail.local"
    DEFAULT_JAIL_CONF_FILE="/etc/fail2ban/jail.conf"
    CUSTOM_JAILS_FILE="/etc/fail2ban/jail.d/custom-enabled.conf"

    # Backup jail.local if it exists
    if [ -f "$JAIL_LOCAL_FILE" ]; then
        JAIL_LOCAL_BACKUP_FILE="${JAIL_LOCAL_FILE}.bak.${TIMESTAMP}"
        cp "$JAIL_LOCAL_FILE" "$JAIL_LOCAL_BACKUP_FILE"
        file_log "INFO" "Created backup of existing jail.local at $JAIL_LOCAL_BACKUP_FILE"
    else # Copy jail.conf to jail.local if jail.local doesn't exist
        if [ -f "$DEFAULT_JAIL_CONF_FILE" ]; then
            cp "$DEFAULT_JAIL_CONF_FILE" "$JAIL_LOCAL_FILE"
            file_log "INFO" "Created jail.local from jail.conf"
        else
            console_log "ERROR" "Neither jail.conf nor jail.local exists"
            file_log "ERROR" "Neither jail.conf nor jail.local exists"
            return 1
        fi
    fi

    # Fetch public IP using ipinfo.io/ip
    file_log "INFO" "Attempting to get server's public IP"
    output=$(curl -s -4 ifconfig.me 2>&1 || curl -s -4 icanhazip.com 2>&1 || curl -s -4 ipinfo.io/ip 2>&1)
    if [ -z "$output" ]; then
        console_log "ERROR" "Could not determine server's public IP"
        file_log "ERROR" "Could not determine server's public IP"
        PUBLIC_IP=""
    else
        PUBLIC_IP="$output"
        file_log "INFO" "Server public IP: $PUBLIC_IP"
    fi

    # Update default settings in jail.local
    update_fail2ban_jail_local_file "bantime" "5h"
    update_fail2ban_jail_local_file "backend" "systemd"
    update_fail2ban_jail_local_file "ignoreip" "127.0.0.1\/8 ::1 $PUBLIC_IP"

    # Enable jails and more settings for them in /etc/fail2ban/jail.d/custom-enabled.conf
    file_log "INFO" "Enabling jails in $CUSTOM_JAILS_FILE"
    cat <<FAIL2BAN >$CUSTOM_JAILS_FILE
[sshd]
enabled = true
filter = sshd
bantime = 1d
maxretry = 3

[nginx-http-auth]
enabled = true
logpath = /var/log/nginx/error.log
maxretry = 3

# Repeat offenders across all other jails
[recidive]
enabled = true
filter = recidive
findtime = 1d
bantime  = 30d
maxretry = 50
FAIL2BAN

    if ! manage_service fail2ban restart; then

        console_log "ERROR" "Failed to restart fail2ban service"
        file_log "ERROR" "Failed to restart fail2ban service"

        # Revert jail.local to backup if it exists
        if [ -f "$JAIL_LOCAL_BACKUP_FILE" ]; then
            console_log "INFO" "Reverting jail.local to backup..."
            file_log "INFO" "Reverting jail.local to backup from: $JAIL_LOCAL_BACKUP_FILE"

            if ! cp "$JAIL_LOCAL_BACKUP_FILE" "$JAIL_LOCAL_FILE"; then
                console_log "ERROR" "Failed to restore jail.local backup"
                file_log "ERROR" "Failed to restore jail.local backup"
                exit 1
            fi
        else # If no backup exists (i.e, jail.local was created from jail.conf) -> remove jail.local
            console_log "INFO" "Removing newly created jail.local..."
            file_log "INFO" "Removing newly created jail.local"
            rm -f "$JAIL_LOCAL_FILE"
        fi

        # Remove the custom enabled configuration
        if [ -f "$CUSTOM_JAILS_FILE" ]; then
            console_log "INFO" "Removing custom jail configuration..."
            file_log "INFO" "Removing custom jail configuration: $CUSTOM_JAILS_FILE"
            rm -f "$CUSTOM_JAILS_FILE"
        fi

        # Try restarting fail2ban with original configuration
        if ! manage_service fail2ban restart; then
            console_log "ERROR" "Failed to restart fail2ban service even with original configuration"
            file_log "ERROR" "Failed to restart fail2ban service even with original configuration"
            exit 1
        fi

        console_log "INFO" "Fail2ban restarted with original configuration"
        file_log "INFO" "Fail2ban restarted with original configuration"
        exit 1
    fi

    console_log "SUCCESS" "Fail2ban configuration completed successfully"
    file_log "SUCCESS" "Fail2ban configuration completed successfully"
    return 0
}

main() {
    parse_args "$@"
    create_logfile

    clear
    print_logfile_details
    echo "Press Enter to continue..."
    # shellcheck disable=SC2162,SC2034
    read dummy

    # Log script start
    console_log "INFO" "Starting $SCRIPT_NAME v$SCRIPT_VERSION..."
    file_log "INFO" "Starting $SCRIPT_NAME v$SCRIPT_VERSION..."

    # Step 1: Reset root password if requested
    if [ "$RESET_ROOT" = true ]; then
        console_log "INFO" "Resetting root password..."
        reset_root_password
        # Continue regardless of any errors
    fi

    # Step 2: Create new user
    if [ -n "$USERNAME" ]; then
        console_log "INFO" "Creating user..."
        create_user
        # Continue regardless of any errors
    fi

    # Step 3: Generate SSH key for user
    if [ -n "$USERNAME" ]; then
        if ! generate_ssh_key "$USERNAME"; then
            console_log "ERROR" "Failed to generate SSH key for new user: $USERNAME"
            print_logfile_details
            return 1 # Abort on error
        fi
    else
        CURRENT_USER=$(whoami)
        if ! generate_ssh_key "$CURRENT_USER"; then
            console_log "ERROR" "Failed to generate SSH key for current user: $CURRENT_USER"
            print_logfile_details
            return 1 # Abort on error
        fi
    fi

    # Step 4: Configure SSH
    if ! harden_ssh_config; then
        print_logfile_details
        return 1 # Abort on error
    fi

    # Step 5: Install required packages
    console_log "INFO" "Installing required packages..."
    file_log "INFO" "Installing required packages..."
    if ! install_package "curl ufw fail2ban"; then
        console_log "ERROR" "Failed to install required packages"
        print_logfile_details
        return 1 # Abort on error
    fi
    console_log "SUCCESS" "Successfully installed all required packages"

    # Step 6: Configure UFW
    console_log "INFO" "Configuring UFW..."
    file_log "INFO" "Configuring UFW..."
    if ! configure_ufw; then
        console_log "ERROR" "Failed to configure UFW"
        print_logfile_details
        return 1 # Abort on error
    fi
    console_log "SUCCESS" "Successfully configured UFW"
    file_log "SUCCESS" "Successfully configured UFW"

    # Step 7: Configure Fail2ban
    console_log "INFO" "Configuring Fail2ban..."
    file_log "INFO" "Configuring Fail2ban..."
    if ! configure_fail2ban; then
        console_log "ERROR" "Failed to configure Fail2ban"
        print_logfile_details
        return 1 # Abort on error
    fi
    console_log "SUCCESS" "Successfully configured Fail2ban"
    file_log "SUCCESS" "Successfully configured Fail2ban"

    console_log "SUCCESS" "Script completed successfully"
    file_log "SUCCESS" "Script completed successfully"

    # Calculate and show execution time
    FORMATTED_DURATION=$(formatted_execution_duration)
    console_log "INFO" "Total execution time: $FORMATTED_DURATION"
    file_log "INFO" "Total execution time: $FORMATTED_DURATION"

    print_logfile_details
    return 0
}

main "$@"
