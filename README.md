# Linux Server Hardener

POSIX-compliant shell script that automates server security hardening on a new Linux/FreeBSD server.
It is intended to be executed **interactively** as `root`.

## Usage

- WARNING: Make sure you:
    - Have root access to the server
    - Have 2 ssh sessions active to the server:
        - 1st: for running the script
        - 2nd: for viewing script's logs and to recover from it's failure
    - SAVE ALL CREDENTIALS SHOWN POST EXECUTION: THEY AREN'T SAVED ANYWHERE AND WON'T BE DISPLAYED AGAIN.

- Options:
    - `-r`: Reset root password
    - `-u USERNAME`: Create a new user with sudo privileges
    - `-h`: Display help message

```sh
curl -L -o harden.sh https://sot.li/hardensh
cat harden.sh          # review content
chmod +x harden.sh

# Harden server: SSH hardening, Fail2ban, Firewalld/pf
./harden.sh

# Create new privileged (sudo) user & harden server
./harden.sh -u jay

# Create new privileged user, reset root password & harden server
./harden.sh -r -u jay
```

- Quick & Dirty:

    ```sh
    curl -sL https://sot.li/hardensh | sh -s -- -r -u jay
    ```

    > There are security risks involved with running scripts directly from web, as done above. Everyone does it; but, you have been warned.

## Post Installation

- Linux:

    ```sh
    # Check firewall status
    sudo firewall-cmd --state && sudo firewall-cmd --list-services

    # Allow a port/service (e.g., dhcp)
    sudo firewall-cmd --permanent --add-service=dhcp

    # Block a port/service (e.g., http)
    sudo firewall-cmd --permanent --remove-service=http

    # List all active jails
    sudo fail2ban-client status

    # List all IPs banned by a jail (e.g., sshd)
    sudo fail2ban-client status sshd

    # Manually ban an IP
    sudo fail2ban-client set sshd banip 192.0.2.1

    # Manually un-ban an IP
    sudo fail2ban-client set sshd unbanip 192.0.2.1
    ```

- FreeBSD:

    ```sh
    # Show active firewall rules
    sudo pfctl -s rules

    # Allow or block port/service
    # Edit /etc/pf.conf & add/remove the port/service to the comma separated list in { }
    #
    # OR use the following command (e.g., allow dhcp)
    sed -i.bak 's/[[:space:]]}/, dhcp }/' /etc/pf.conf && pfctl -nf /etc/pf.conf && pfctl -vvf /etc/pf.conf

    # List all active Fail2ban jails
    sudo fail2ban-client status

    # List all IPs banned by a Fail2ban jail (e.g., sshd)
    sudo fail2ban-client status sshd

    # Manually ban an IP
    sudo fail2ban-client set sshd banip 192.0.2.1

    # Manually un-ban an IP
    sudo fail2ban-client set sshd unbanip 192.0.2.1
    ```

## Status

Tested and working on:

- Linux:
    - Debian 13
    - Ubuntu 22.04, 24.04
    - Fedora 42
    - Rocky Linux
    - Alma Linux
    - CentOS Stream 10
    - openSUSE
- FreeBSD:
    - FreeBSD 14.3

> Tested with each OS's official qcow2 file through KVM virtualisation.

## What does it do exactly?

Depending on options chosen & OS (Linux vs FreeBSD), it does the following:

1. (Optional) Resets `root` users password
2. Creates new user & give it `sudo` privileges
3. Generates OpenSSH (ed25519) keys (public & private) for the user with a passphrase
4. Updates SSH configuration to:
    - Disable `root` login
    - Disable password login
    - Enable sshkey-only login
5. Installs applications:
    - Linux: curl, sudo, firewalld, fail2ban
    - FreeBSD: curl, sudo, fail2ban
6. Configures firewall which allows incoming sshd, http, https traffic & blocks everything else:
    - Linux: `firewalld` is used as firewall
    - FreeBSD: `pf` is used as firewall
7. Linux: Configures `fail2ban` to with following jails (FreeBSD: `pf` table is used to block IPs):
    - sshd
    - nginx-botsearch
    - nginx-http-auth
    - nginx-limit-req
    - haproxy-http-auth
    - recidive
8. Displays following on console:
    - New root password
    - New user name & password
    - SSH Private & Public keys
    - SSH Passphrase
9. Deletes SSH Private Key from server

> Handling Operation Failure
>
> - The script creates back up of each file it changes, in the same location as the original file. Backup file name: [original-name].bak.[timestamp]
> - On failure of an operation that depends on a configuration file, the script restores the original file and restarts the relevant service.
> - Reason for failures can be found in the log file.

### Why `firewalld` and not `ufw`?

- `firewalld` is default firewall on Rocky Linux, SUSE, Fedora, RHEL
- Commands for basic administration are similar to that of `ufw`
- Comes with a lot more power when needed

## To-do

- [ ] LUKS encryption
- [ ] Unattended-updates if distro supports it (do it during installations)
- [ ] Layer 2 security: Midtier: OSSEC
- [ ] Audit: Lynis
- [ ] Monitoring + Alerts: Goaccess???
- [ ] Backups: ???

## Retrospect: Why a script?

You CAN do everything this script does with Ansible. That is, if you know how it works (not trivial) and have it's *control node* installed on your local machine. I don't.

Personally, writing the script has given me deeper understanding of cloud security and about the similarities (and differences) between Unix-like operating systems.

That said, the quirks of shell scripting is tiring to keep up with. Also, most VPS providers support cloud-init. Cloud-init can't do everything the script does; but it's *trivial* to accomplish 80% of it using cloud-init. That makes it worthwhile to learn and use.
