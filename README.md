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
    # Firewalld: Check firewall status
    sudo firewall-cmd --status && sudo firewall-cmd --list-services

    # Firewalld: Allow a port/service (e.g., dhcp)
    sudo firewall-cmd --permanent --add-service=dhcp

    # Firewalld: Block a port/service (e.g., http)
    sudo firewall-cmd --permanent --remove-service=http

    # Fail2ban: List all active jails
    sudo fail2ban-client status

    # Fail2ban: List all IP banned by a jail (e.g., sshd)
    sudo fail2ban-client status sshd

    # Fail2ban: Manually ban an IP
    sudo fail2ban-client set sshd banip 192.0.2.1

    # Fail2ban: Manually un-ban an IP
    sudo fail2ban-client set sshd unbanip 192.0.2.1
    ```

- FreeBSD:

    ```sh
    # pf: Show active rules
    sudo pfctl -s rules

    # pf: Allow or block services
    # Edit /etc/pf.conf & add/remove the port/service to the comma separated list in { }
    #
    # OR use the following command (e.g., allow dhcp)
    sed -i.bak 's/[[:space:]]}/, dhcp }/' /etc/pf.conf && pfctl -nf /etc/pf.conf && pfctl -vvf /etc/pf.conf

    # Fail2ban: List all active jails
    sudo fail2ban-client status

    # Fail2ban: List all IP banned by a jail (e.g., sshd)
    sudo fail2ban-client status sshd

    # Fail2ban: Manually ban an IP
    sudo fail2ban-client set sshd banip 192.0.2.1

    # Fail2ban: Manually un-ban an IP
    sudo fail2ban-client set sshd unbanip 192.0.2.1
    ```

## Status

Tested and working on:

- Linux:
    - Debian 12, 13
    - Fedora 42
    - Ubuntu 22.04, 24.04, 24.10
- FreeBSD:
    - FreeBSD 14.3

> Tested with each OS's official qcow2 file through KVM virtualisation.

## What does it do exactly?

Depending on options chosen & OS (Linux vs FreeBSD), it does the following:

1. (Optional) Resets `root` users password
2. (Optional) Creates new user & give it `sudo` privileges
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

> [!NOTE] Handling Operation Failure
>
> - The script creates back up of each file it changes, in the same location as the original file. Backup file name: [original-name].bak.[timestamp]
> - On failure of an operation that depends on a configuration file, the script restores the original file and restarts the relevant service.
> - Reason for failures can be found in the log file.

### Why `firewalld` and not `ufw`?

- `firewalld` is default firewall on Rocky Linux, SUSE, Fedora, RHEL
- Can use similar commands like `ufw`, for basic administration
- Comes with a lot more power when needed

## To-do

- [ ] LUKS encryption
- [ ] Unattended-updates if distro supports it (do it during installations)
- [ ] Layer 2 security: Midtier: OSSEC
- [ ] Audit: Lynis
- [ ] Monitoring + Alerts: Goaccess???
- [ ] Backups: ???

## License

Copyright © 2025, Pratik Kumar Tripathy. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
