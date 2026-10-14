# AUDIT.md · iCloud containers on this Mac · 2026-10-14T01:12:44.015Z

Read-only scan of `/Users/chauphan/Library/Mobile Documents` by `node ledger.mjs audit`. Denied (never opened): `ZP9ZJ4EF3S~com~gingerlabs~Notability`, `iCloud~com~gingerlabs~Notability`. Full detail: `/Users/chauphan/.ledger/audit/audit-20261014T011244015Z.json`.

- **Quota remaining (`brctl quota`):** 16.4 GB
- **Local containers:** 1814 files, 15.1 GB apparent, 1.8 GB on this disk; 443 dataless placeholders (13.3 GB only in the cloud)
- Not visible here but counted by Apple: Photos, device Backups, Messages, Mail, app data in CloudKit (not in Mobile Documents). The owner's storage breakdown screenshot is the only source for those.

| Container / Drive folder | Files | Apparent | On disk | Dataless | Dev junk |
|---|--:|--:|--:|--:|--:|
| `.Trash` | 687 | 13.0 GB | 282.9 MB | 210 (12.7 GB) | – |
| `iCloud~com~apple~clips` | 49 | 1.3 GB | 1.3 GB | 0 (0 B) | – |
| `57T9237FN3~net~whatsapp~WhatsApp` | 22 | 423.3 MB | 0 B | 22 (423.3 MB) | – |
| `iCloud~md~obsidian` | 243 | 220.4 MB | 73.4 MB | 90 (147.3 MB) | – |
| `iCloud Drive/Downloads` | 47 | 96.8 MB | 17.0 MB | 38 (79.9 MB) | – |
| `iCloud~com~apple~iBooks` | 614 | 73.0 MB | 74.5 MB | 0 (0 B) | – |
| `iCloud Drive/Documents` | 6 | 7.9 MB | 7.9 MB | 0 (0 B) | – |
| `com~apple~QuickTimePlayerX` | 2 | 5.8 MB | 5.8 MB | 0 (0 B) | – |
| `iCloud Drive/Revelato 006` | 13 | 4.3 MB | 4.3 MB | 0 (0 B) | – |
| `iCloud~net~mkswap~Dropshare4` | 83 | 201.7 KB | 0 B | 83 (201.7 KB) | – |
| `com~apple~shoebox` | 11 | 167.3 KB | 192.5 KB | 0 (0 B) | – |
| `3L68KQB4HG~com~readdle~CommonDocuments` | 9 | 37.6 KB | 61.4 KB | 0 (0 B) | – |
| `com~apple~ScriptEditor2` | 2 | 13.0 KB | 20.5 KB | 0 (0 B) | – |
| `com~apple~TextInput` | 10 | 12.0 KB | 49.2 KB | 0 (0 B) | – |
| `iCloud Drive/(root)` | 1 | 10.2 KB | 12.3 KB | 0 (0 B) | – |
| 13 others | 15 | 58.0 KB | 86.0 KB | | |

**Largest files** (top 10 of 50 in the JSON; ☁ = dataless):
- 11.3 GB ☁ `.Trash/20260804 Nicholle - SESSION SUMMARY.wav`
- 304.5 MB ☁ `.Trash/Alison Wood Brooks - Talk - The Science of Conversation and the Art of Being Ourselves.m4b`
- 236.4 MB ☁ `57T9237FN3~net~whatsapp~WhatsApp/Accounts/33648943449/backup/Media.tar`
- 180.7 MB `.Trash/DynamicLakePro.app/Contents/MacOS/DynamicLakePro`
- 155.7 MB ☁ `57T9237FN3~net~whatsapp~WhatsApp/Accounts/33648943449/backup/Document.tar`
- 108.3 MB ☁ `.Trash/Foundation Workbook Guided .pdf`
- 73.0 MB ☁ `iCloud~md~obsidian/Documents/Obsidian/Imported/ScreenRecording_05-02-2026 07-51-41_1.mov`
- 65.3 MB `iCloud~com~apple~clips/Documents/49F07C0A-812E-410D-AAFB-F6344E1DF5E0.clipsproject/Assets/2DFB1375-4785-4AC4-9176-CD4F557BE81B-metadata.mov`
- 61.0 MB ☁ `.Trash/Product Designs/Revelato 001/ScreenRecording_05-02-2026 07-51-41_1.mov`
- 59.9 MB `iCloud~com~apple~clips/Documents/49F07C0A-812E-410D-AAFB-F6344E1DF5E0.clipsproject/Assets/E159F612-A13E-4A96-895A-6B45617EC7FA-metadata.mov`

**Duplicates** (≥1.0 MB, local copies, sha256): 0 sets, 0 B redundant.

**Dev junk inside iCloud** (6 dir names): none
