# Obsidian Sync via Remotely Save and Cloudflare R2 Migration Guide

## 1. Overview & Architectural Constraint
When Obsidian's root folder is saved wihtin an iCloud folder, the apple ecosystem can sync like a dream and also abruptly stop when your iCloud Drive is full. My iCloud storage is full and I am adamant about staying on the free tier. This presents a unique opportunity to reverse engineer the backend to allow syncing work on the 200GB tier iCloud plan. 

A robust solution is to **replace the sync layer** 

## 2. Selected Approach: Remotely Save to Cloudflare R2
The optimal approach utilizes the **Remotely Save** community plugin to connect Obsidian directly to Cloudflare R2 via its S3-compatible API

* **Direct Integration:** Remotely Save talks directly to R2's S3 API, meaning your existing Cloudflare Worker is not involved in the sync traffic
* **Platform Compatibility:** Works seamlessly across desktop and Obsidian mobile

## 3. Configuration Specifications
When configuring Remotely Save for Cloudflare R2, use the following parameters and best practices:

* **Bucket Setup:** Create a dedicated bucket named notes equipped with its own Object Read & Write token 
  * *Avoid* the `share` bucket because it utilizes auto-deleting cleanup
  * *Avoid* `global/lib/files/` because an `rclone` sync of the library would delete any unknown files 
  * *Security benefit:* A per-bucket token ensures that credentials stored on your mobile device cannot reach your wider library
* **Endpoint:** Set the endpoint to "https://7a7972b724b508c99a42844632b8a44c.r2.cloudflarestorage.com" [ or gallery.improvdiplomat.workers.dev/main (?) ] with region set to auto
* **Connectivity Check Note:** Cloudflare rejects `HeadBucket` requests for Object Read & Write keys, which can trip the plugin's initial check
* **CORS Settings:** On current Obsidian versions, you can skip configuring bucket CORS
* **Sync Timing:** Remotely Save cannot sync while Obsidian is running in the background. Expect sync-on-open, interval-based, or on-save syncing rather than iCloud's instant background feel
* **Plugin Settings:** The `.obsidian` configuration folder is not synced by default Leave optional encryption disabled if you prefer readable files stored directly in R2