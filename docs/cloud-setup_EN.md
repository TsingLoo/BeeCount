# ☁️ Cloud Sync Configuration Guide

> 🌐 [中文](cloud-setup.md)

BeeCount supports 5 cloud sync options. Choose based on your scenario.

## Comparison

| Option | Best For | Highlights |
|---|---|---|
| **BeeCount Cloud** | Real-time multi-device + self-hosted | One-click Docker, sub-second sync, built-in Web, multi-user |
| **iCloud** | iOS-only users | Zero config, native integration, Apple ecosystem |
| **Supabase** | Cross-platform without NAS | Generous free tier, easy setup, hosted |
| **WebDAV** | NAS users | Local data, Synology/Nextcloud/etc. |
| **S3 protocol** | Flexible cloud storage | Cloudflare R2/AWS S3/MinIO, large free tier |

---

## 🆕 BeeCount Cloud (Self-hosted Sync + Web)

> **Sub-second multi-device sync + Web admin + multi-user isolation.** Recommended for users with NAS / VPS / Docker.

### One-click Deploy

```yaml
# docker-compose.yml
services:
  beecount-cloud:
    image: sunxiao0721/beecount-cloud:latest
    restart: unless-stopped
    ports:
      - "8869:8080"
    volumes:
      - ./data:/data
```

```bash
docker compose up -d
docker compose logs beecount-cloud | grep -A 10 "first launch"
```

Output similar to:

```
 BeeCount Cloud — first launch, admin account auto-created:

   Email:    owner@example.com
   Password: FIDodUnwprkw1zUi
```

With this account:

- Open `http://<server-ip>:8869` in browser → **Web admin console**
- In the App, choose "BeeCount Cloud", enter server URL + credentials

### Add Family / Teammates

Web console → "Users" → "Add User" with their email and password → tell them to log in. Each user's data is isolated.

### Advanced Configuration

```yaml
services:
  beecount-cloud:
    image: sunxiao0721/beecount-cloud:latest
    restart: unless-stopped
    ports:
      - "8869:8080"
    environment:
      # Override default random admin:
      BOOTSTRAP_ADMIN_EMAIL: me@example.com
      BOOTSTRAP_ADMIN_PASSWORD: <strong password>
      # Override JWT secret (default: auto-generated to /data/.jwt_secret):
      # JWT_SECRET: <32+ byte random string>
    volumes:
      - ./data:/data
```

### Tips

- **PWA support**: Web admin is a PWA — install icon appears in the address bar to install as a desktop app
- **Data location**: SQLite + attachments + JWT secret all live in `./data/`. Migrate / back up the whole directory.
- **Public deployment**: Front with nginx / caddy for HTTPS + domain.

[📖 BeeCount-Cloud repo + backup system + audit reports →](https://github.com/TNT-Likely/BeeCount-Cloud)

---

## Option 2: iCloud (Recommended for iOS)

**Best for**: iOS users wanting zero-config, seamless sync.

**Pros**:

- ✅ Zero config: works out of the box
- ✅ Native: auto-sync via Apple ID
- ✅ Privacy: data in your iCloud Drive
- ✅ Multi-device: iPhone + iPad auto-sync

**Setup**:

1. Sign in to iCloud and enable iCloud Drive on the device
2. Open BeeCount → Profile → Cloud Service
3. Choose **iCloud**

> 💡 iCloud only works between iOS devices. For iOS + Android, use Supabase / S3 / BeeCount Cloud.

---

## Option 3: Supabase (Beginner-friendly)

**Best for**: Users without NAS who want quick setup.

**Setup**:

1. **Create Supabase project**
   - Sign up at [supabase.com](https://supabase.com)
   - Create a new project; pick a region
   - Get URL and anon key from project settings

2. **Configure Storage**
   - Create a bucket named `beecount-backups`
   - Set it to Private (don't check Public bucket)
   - **Configure RLS policies**: Create 4 policies so users can only access their own data
     - Go to bucket Policies tab
     - Create the following 4 policies (same configuration each):
       - **SELECT**: read own backup files
       - **INSERT**: create new backups
       - **UPDATE**: update own backups
       - **DELETE**: delete own backups
     - Each policy:
       - **Policy name**: customizable (e.g. `Allow user access to own backups`)
       - **Target roles**: `authenticated`
       - **Policy definition**:

         ```sql
         ((bucket_id = 'beecount-backups'::text) AND ((storage.foldername(name))[1] = 'users'::text) AND ((storage.foldername(name))[2] = (auth.uid())::text))
         ```

       - This ensures users only access `beecount-backups/users/<their-user-id>/`.

3. **Configure in app**
   - Open BeeCount → Profile → Cloud Service
   - Tap "Add custom cloud service"
   - Service type: **Supabase**
   - Enter your URL and anon key
   - Save and enable
   - Tap "Sign in", register or log in to start syncing

---

## Option 4: WebDAV (Recommended for NAS Users)

**Best for**: Users with NAS or private cloud storage.

**Supported services**:

- ✅ UGREEN NAS
- ✅ Synology NAS
- ✅ Nextcloud
- ✅ Jianguoyun WebDAV
- ✅ ownCloud
- ✅ Other WebDAV-compatible servers

**Setup**:

1. **Enable WebDAV**
   - Enable WebDAV on your NAS or cloud platform
   - Note the server URL (e.g. `http://nas.local:5005`)
   - Create or use an existing user account

2. **Prepare directory** (optional)
   - Create `BeeCount` folder under WebDAV root, or use any path

3. **Configure in app**
   - Open BeeCount → Profile → Cloud Service
   - Tap "Add custom cloud service"
   - Service type: **WebDAV**
   - Fill in:
     - **WebDAV server URL**: e.g. `http://nas.local:5005`
     - **Username** / **Password**
     - **Remote path**: e.g. `/home/BeeCount` or `/BeeCount`
   - Tap "Test connection" to verify
   - Save and enable. WebDAV doesn't need login — sync starts after configuration.

**Common WebDAV examples**:

```
UGREEN NAS:
- URL: http://your-nas:5005
- Remote path: /home/BeeCount

Synology NAS:
- URL: http://your-nas:5005 or https://your-domain
- Remote path: /BeeCount

Jianguoyun:
- URL: https://dav.jianguoyun.com/dav/
- Remote path: /BeeCount
```

---

## Option 5: S3 Protocol (Recommended for Flexibility)

**Best for**: Users who want flexible cloud providers or generous free tiers.

**Supported services**:

- ✅ **Cloudflare R2** (recommended, 10GB free)
- ✅ **AWS S3**
- ✅ **MinIO** (self-hosted)
- ✅ **Aliyun OSS** / **Tencent COS** (S3-compatible)
- ✅ Others S3-protocol compatible storages

**Setup (using Cloudflare R2)**:

1. **Create R2 bucket**
   - Log into [Cloudflare Dashboard](https://dash.cloudflare.com/)
   - Open **R2**
   - Create a bucket like `beecount-backups`
   - Note the bucket name

2. **Get API credentials**
   - Click **Manage R2 API Tokens**
   - Create a new API Token
   - Permission: **Object Read & Write**
   - Note:
     - **Access Key ID**
     - **Secret Access Key**
     - **Endpoint** (like `<account-id>.r2.cloudflarestorage.com`)

3. **Configure in app**
   - Open BeeCount → Profile → Cloud Service
   - Tap "Add custom cloud service"
   - Service type: **S3 Protocol** (under "Backup") or **S3 Cloud Collaboration** (under "Collaboration")
   - Fill in:
     - **Endpoint**: R2 endpoint (no `https://`)
     - **Region**: `auto`
     - **Access Key** / **Secret Key**
     - **Bucket name**: e.g. `beecount-backups`
     - **Use HTTPS**: enable (recommended)
     - **Port**: leave blank
   - Tap "Test connection" to verify
   - Save and enable

### Backup vs. Collaboration

**Backup → S3 Protocol** keeps the existing `ledger_*.json` snapshot backup with manual restore. Existing configurations stay where they are and are never silently upgraded to incremental collaboration.

**Collaboration → S3 Cloud Collaboration** uses its own, separate configuration. Enter the same endpoint, bucket, credentials and **sync password** on every device, then turn on "Auto sync ledgers" on the Cloud Sync page.

The sync password is the end-to-end encryption passphrase. It is stored on the device only and never uploaded: collaboration data is encrypted before it leaves the device, so the storage provider only sees object names (ledger id / device id / sequence number) — never amounts, notes or category names.

Encryption uses two layers:

- Ledger data is encrypted with a random 256-bit **data key** (AES-256-GCM, object path as AAD).
- The sync password is stretched with PBKDF2-HMAC-SHA256 (200,000 iterations, random salt) into a **password key** that encrypts the data key only. The result is stored in `beecount-sync/v3/keyparams.json`, which contains no plaintext secret.

That is why changing the sync password only re-wraps the data key — your cloud data is not re-uploaded. You can change it from the S3 Cloud Collaboration dialog; this device must still know the current password (otherwise the data key cannot be unwrapped), and every other device has to switch to the new password before it can sync again. Conversely, losing the password means the data key can never be unwrapped: uploaded data is unrecoverable.

> ⚠️ Changing the password replaces the door to the data key, not the data key itself. If an old password leaked **and** the attacker kept a copy of the `keyparams.json` from that time, they can still decrypt the history encrypted with that data key. To roll the data key itself, delete the cloud collaboration data and enable it again.

Exported configuration files never contain the sync password — after importing on a new device, enter it by hand.

Changes are uploaded right after you record them, and other devices' changes are pulled on launch, on resume, and roughly every 30 seconds while the app is in the foreground. The first run writes discovery snapshots and incremental journals under `beecount-sync/v3/`; legacy `ledger_*.json` backups are never read, rewritten or deleted. Once the device is in the background, the system decides when sync runs again. If the same transaction is edited offline on two devices, the device clock decides which edit wins, so avoid simultaneous edits; image attachments still need a separate backup. Journal objects accumulate as changes pile up.

**Other S3 examples**:

```
Cloudflare R2:
- Endpoint: <account-id>.r2.cloudflarestorage.com
- Region: auto
- Use HTTPS: yes

AWS S3:
- Endpoint: s3.amazonaws.com
- Region: us-east-1 (use your bucket's region)
- Use HTTPS: yes

MinIO (self-hosted):
- Endpoint: minio.example.com
- Region: us-east-1 or auto
- Use HTTPS: based on your config
- Port: 9000 (or your custom)

Aliyun OSS (S3-compatible):
- Endpoint: oss-cn-hangzhou.aliyuncs.com
- Region: oss-cn-hangzhou
- Use HTTPS: yes
```

> 💡 **Tips**:
>
> - **Don't** include `http://` or `https://` in the endpoint
> - Cloudflare R2 free tier: 10GB storage + 10M Class A operations / month

---

## FAQ

**Q: Which option should I pick?**

- iOS single device → **iCloud**
- Multi-device real-time + self-host → **BeeCount Cloud**
- Cross-platform without NAS → **Supabase** or **S3**
- Have a NAS → **WebDAV**

**Q: WebDAV upload failing?**

- Check WebDAV is enabled and port is correct
- Verify username and password
- Some NAS WebDAV needs specific paths (e.g. UGREEN needs `/home/`)
- Tap "Test connection" for detailed errors

**Q: S3 connection failing?**

- Endpoint must **not** include `http://` or `https://`
- Verify Access Key and Secret Key
- Verify bucket name spelling
- Check bucket region matches (AWS S3 needs exact, R2 uses `auto`)

**Q: How to sync between devices?**

- iCloud: log into the same Apple ID
- BeeCount Cloud: same server URL + same account
- Supabase: same URL and anon key, same account
- WebDAV: same server URL and credentials
- S3: same endpoint, Access Key, and bucket

---

## Roadmap

- 📦 Google Drive
- 📦 Dropbox
- 📦 OneDrive

If you want to prioritize a service, please raise an [Issue](https://github.com/TNT-Likely/BeeCount/issues)!
