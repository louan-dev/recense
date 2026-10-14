# Multi-Platform Sync Matrix & Fact-Checked Architecture

**Status:** Verified 2026-10-08. Companion architecture document for cross-platform synchronization across Apple Photos, Notability, Obsidian, DEVONthink, and Apple Calendar.

---

## 1. Executive Sync Matrix Across Ecosystems

| Service | Primary Ecosystem | Cross-Platform / Non-Apple Options | Limitations & Constraints |
|---|---|---|---|
| **Apple Photos & Videos** | iCloud Photos (bi-directional sync, Optimize Storage)[cite: 1] | Web browser access (`icloud.com`) | No native Windows or Android client apps; relies entirely on Apple ecosystem or web wrappers. |
| **Notability** | Notability Cloud / iCloud | iOS, iPadOS, macOS, Android, and Web | Older legacy accounts require migration to Notability Cloud for cross-platform Android/Web access. |
| **Obsidian** | Obsidian Sync (first-party)[cite: 2] | iCloud, OneDrive, Google Drive, Syncthing[cite: 2], Git/Working Copy[cite: 2] | Full cross-platform support across macOS, Windows, Linux, iOS, and Android via local file structures. |
| **DEVONthink** | CloudKit, Bonjour, Dropbox, WebDAV, Local Sync Store | Web interface via DEVONthink Server (accessible on Windows/Linux) | Native desktop client is macOS-only; cross-platform access requires DEVONthink Server or WebDAV/Nextcloud. |
| **Apple Calendar** | iCloud CalDAV | Standard CalDAV / CardDAV (DAVx5 on Android, Thunderbird on Windows/Linux, Web clients)[cite: 2] | Native Apple features (like advanced invitation UI) require CalDAV server compliance (RFC 4791 / RFC 6638)[cite: 2]. |

---

## 2. Platform-by-Platform Analysis & Fact-Checking

### Apple Photos & Videos
* **iCloud Photos:** Provides native bi-directional synchronization across macOS, iOS, and iPadOS with "Download Originals" or "Optimize Storage" options[cite: 1]. 
* **Fact-Check / Limitation:** Non-Apple platforms (Windows, Android, Linux) are restricted to accessing media solely through the web interface (`icloud.com`), lacking background sync daemons or native folder integration.
* **Collaboration:** iCloud Shared Photo Library allows multi-user editing, while Shared Albums bypass personal storage quotas by downscaling images to 2048px on the long edge[cite: 1].

### Notability
* **Notability Cloud:** Fact-checked current architecture replaces legacy iCloud-only sync with Notability Cloud, enabling full bi-directional synchronization across iOS, iPadOS, macOS, Android, and Web clients.
* **Fact-Check:** Audio recordings made on one device successfully sync and play back across all supported platforms. Requires active internet connection and identical account credentials across devices.

### Obsidian
* **Local-First Architecture:** Operates directly on plain Markdown files, making it the most flexible cross-platform note-taking tool.
* **Sync Methods:** 
  - *First-Party:* Obsidian Sync provides end-to-end encrypted synchronization across all desktop and mobile platforms[cite: 2].
  - *Third-Party & Local:* Syncthing provides direct peer-to-peer local syncing[cite: 2], Git/Working Copy handles version control[cite: 2], and standard cloud drives (iCloud, OneDrive, Google Drive) manage file-level transport[cite: 2].

### DEVONthink
* **Ecosystem Scope:** Native client software is strictly macOS and iOS (DEVONthink To Go). 
* **Sync Channels:** Supports Bonjour (local Wi-Fi), CloudKit / iCloud, Local Sync Store (NAS/SMB network shares), standard WebDAV servers (Nextcloud, Synology), and Dropbox.
* **Fact-Check / Cross-Platform Solution:** To allow Windows or Linux clients to access databases, deployment of **DEVONthink Server** on a primary Mac provides an integrated browser-based web interface.

### Apple Calendar
* **Standards-Based Sync:** Relies natively on CalDAV and iCalendar protocols.
* **Cross-Platform Interoperability:** By deploying a standards-compliant CalDAV server (such as a Cloudflare Worker backed by R2 and D1, or a self-hosted instance), Apple devices sync natively via iOS/macOS Account settings, while Android devices connect seamlessly using **DAVx5**, and Windows/Linux clients connect via **Thunderbird** or web interfaces[cite: 2].

---

## 3. Concrete Actionable Next Steps

1. **Deploy Standards-Compliant CalDAV Server:** Stand up the Cloudflare Worker (`dav` module) backed by R2 object storage and D1 indexing to handle cross-platform calendar synchronization without iCloud dependencies[cite: 2].
2. **Configure Client Accounts:** Add the CalDAV account natively to macOS and iOS Internet Accounts (`syncAccountName` / `syncCalendarTitle`), and configure DAVx5 on mobile endpoints[cite: 2].
3. **Migrate Notes & Files:** Transition Notability accounts to Notability Cloud for cross-platform access, and establish local Syncthing or WebDAV endpoints for Obsidian and document vaults[cite: 2].