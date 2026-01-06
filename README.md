# Bitwarden CLI Power Tools

A suite of Bash utilities designed to extend the Bitwarden CLI (`bw`). While these scripts provide general-purpose functions for searching items, retrieving fields, and managing sessions, they are specifically optimized for a secure, automated SSH workflow.

## Features

* **Kernel-Level Session Management:** Uses the Linux Kernel Keyring (`keyctl`) to store session keys. This keeps secrets out of the filesystem (even RAM-disks) and protects them within kernel memory.
* **Persistent & Shared Sessions:** Leverages the `@u` (user) keyring to allow a single Bitwarden unlock to persist across multiple terminal windows, tmux panes, and SSH sessions.
* **Sliding Auto-Lock:** Implements a 15-minute "sliding window" timeout. The kernel automatically purges the session key after 15 minutes of inactivity, but every use of the `bw` wrapper resets the timer.
* **"Just-in-Time" SSH Keys:** Fetches private keys from Bitwarden attachments and injects them into `ssh-agent` with a 15-second TTL—no keys are ever stored on the local disk.
* **Automated Server Provisioning:** `bw.keysetup` automates server hardening (PermitRootLogin), creates "jumper" users, and manages per-host SSH keys and password salts.
* **Injection-Safe Remote Execution:** Uses quoted Heredocs for remote SSH commands to prevent shell interpolation and injection attacks.

## Prerequisites

1.  **Bitwarden CLI:** Installed on your local machine.
2.  **Binary Alias:** These scripts expect the Bitwarden CLI binary to be available as `bw.bin`.
    * *Setup:* `cd "$(dirname "$(which bw)")"; mv bw bw.bin`
3.  **`keyutils`:** Provides the `keyctl` command-line tool.
4.  **`jq`:** Required for JSON processing.
5.  **`perl`:** Used for Yescrypt password hashing in `bw.keysetup`.

## Installation

1.  Clone the repository:
    ```bash
    git clone [https://github.com/neoautomata/bw_scripts.git](https://github.com/neoautomata/bw_scripts.git)
    cd bw_scripts
    ```
2.  Add the directory to your `$PATH` or move the scripts to somewhere in your existing path (e.g. `~/bin`).
3.  Ensure all scripts are executable:
    ```bash
    chmod +x bw*
    ```

## Script Reference

### General Utilities
| Script | Description |
| :--- | :--- |
| `bw` | A wrapper that ensures a valid session before executing any standard `bw` command. |
| `bw.sess` | Manages vault locking/unlocking and the background auto-lock timer. |
| `bw.item.get` | Fetches the full JSON object for a specific Item ID. |
| `bw.item.search` | Returns the ID of an item based on a search string (expects exactly 1 match). |
| `bw.item.pass` | Outputs the raw password of an item. |
| `bw.item.field` | Retrieves the value of a specific custom field by name. |

### SSH Focused Utilities
| Script | Description |
| :--- | :--- |
| `bw.ssh` | SSH wrapper. Uses Bitwarden attachments for keys or `SSH_ASKPASS` for passwords. |
| `bw.keysetup` | Automates remote server hardening and Bitwarden item creation. |
| `bw.item.attachmentID` | Finds an attachment ID based on a `jq` query (used for key management). |
| `bw.item.privKeyID` | Helper to find private key attachments. |

## Security Architecture

1.  **Kernel Keyring Storage:** Session keys are stored in the Linux kernel's retention service. They are not visible in the process list (`ps`), shell history, or the filesystem.
2.  **Sliding Timeout:** The kernel-managed timeout is reset to 900 seconds (15 minutes) on every call to `bw`. This ensures the vault stays open while you are working but locks automatically when you walk away.
3.  **Memory-Only SSH Keys:** Private keys are piped from Bitwarden directly into `ssh-add`. By using a 15-second TTL (`-t 15`), the key is automatically purged from your SSH agent memory shortly after connection.
4.  **Secure Piping:** Uses `echo` pipes instead of Bash "here-strings" (`<<<`) to ensure sensitive data is never written to temporary files during redirection.

## Usage Examples

### General CLI Usage
Use the `bw` wrapper to run any command without manually managing `BW_SESSION`:
```bash
bw list items --search "Github"
```

### Fetching a Custom Field

```bash
# Get a custom field named "api_key" from an item named "Cloudflare"
bw.item.field $(bw.item.search "Cloudflare") "api_key"
```

### Connecting to a Server via SSH

```bash
# Automatically pulls the key from Bitwarden
bw.ssh root@production_server
```

### Provisioning a New Server

```bash
# Hardens root, creates a jumper user, and saves everything to Bitwarden
bw.keysetup root@my_host
```
