# Bitwarden CLI Power Tools

A suite of Bash utilities designed to extend the Bitwarden CLI (`bw`). While these scripts provide general-purpose functions for searching items, retrieving fields, and managing sessions, they are specifically optimized for a secure, automated SSH workflow.

## Features

* **Secure Session Management:** Handles `bw unlock` and stores session keys in a `tmpfs` RAM-disk (`/run/user/`). Includes a background auto-lock timer that wipes keys after 15 minutes of inactivity.
* **Deep Item Integration:** Scripts to quickly grab passwords, custom fields, and attachment IDs without writing complex `jq` filters manually.
* **"Just-in-Time" SSH Keys:** Fetches private keys from Bitwarden attachments and injects them into `ssh-agent` with a 15-second TTL—no keys are ever stored on the local disk.
* **Automated Server Provisioning:** `bw.keysetup` automates server hardening, creates "jumper" users, and handles Yescrypt password hashing.
* **Secure Password Piping:** Uses Unix FIFOs to pipe secrets to `SSH_ASKPASS`, ensuring passwords never appear in process lists or shell history.

## Prerequisites

1.  **Bitwarden CLI:** Installed on your local machine.
2.  **Binary Alias:** These scripts expect the Bitwarden CLI binary to be available as `bw.bin`.
    * *Setup:* `sudo ln -s $(which bw) /usr/local/bin/bw.bin`
3.  **`jq`:** Required for JSON processing.
4.  **`perl`:** Used for Yescrypt password hashing in `bw.keysetup`.

## Installation

1.  Clone the repository:
    ```bash
    git clone [https://github.com/yourusername/bw-tools.git](https://github.com/yourusername/bw-tools.git)
    cd bw-tools
    ```
2.  Add the directory to your `$PATH` or move the scripts to `/usr/local/bin`.
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



1.  **Volatile Session Storage:** Session keys reside in `/run/user/$(id -u)/`, a memory-backed filesystem. They are never written to the HDD/SSD.
2.  **Auto-Lock Background Loop:** When a session is created, a background process monitors the session file's timestamp. If 15 minutes pass without activity, the script executes `bw lock` and cleans up the RAM directory.
3.  **Encrypted Transport:** Private keys are piped directly from `bw.bin` to `ssh-add`. By using a 15-second TTL (`-t 15`), the key is automatically purged from your SSH agent shortly after the connection is established.

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
bw.ssh root@production-server.com
```

### Provisioning a New Server

```bash
# Hardens root, creates a jumper user, and saves everything to Bitwarden
bw.keysetup root@192.168.1.50
```
