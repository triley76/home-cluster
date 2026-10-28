# Runbook: encrypted recovery material (Stage 2)

**Status:** executed from 2026-10-16 to 2026-10-19 UTC. The K3s server token, the Grafana admin credential and the filled recovery-material inventory were each encrypted, uploaded, downloaded by exact version and verified, and the inventory was copied to Recovery A and Recovery B. The results, and a cluster incident that interrupted the run, are recorded in the [encrypted recovery material validation](../validation/encrypted-recovery-material.md). Later runs, after any item changes, follow the same procedure and are recorded the same way.

This runbook implements Stage 2 of the [backup and disaster recovery design](../design/backup-disaster-recovery.md), following its [recovery material and client-side encryption](../design/backup-disaster-recovery.md#recovery-material-and-client-side-encryption) rules.

A verified recovery copy shows that the ciphertext decrypts to the current value. It does not show that a restore using it works; only a restore rehearsal does.

## What is protected

| Item | Plaintext exists only | Host that encrypts and verifies | Object key |
| --- | --- | --- | --- |
| `k3s-server-token` | `/var/lib/rancher/k3s/server/token` | `k3s01` | `recovery/k3s-server-token/<YYYY-MM-DD>.age` |
| `grafana-admin` | The protected out-of-band Grafana credential file, recorded in the [observability validation](../validation/observability.md) as `/home/ansible/.config/home-cluster/grafana-admin`; reconfirmed in preflight | `k3s01` | `recovery/grafana-admin/<YYYY-MM-DD>.age` |
| `recovery-inventory` | A private, memory-backed tmpfs on the workstation while it is prepared ([Inventory](#the-filled-inventory)), and, only if an offline plaintext copy is required, the BitLocker recovery media | The administrative workstation (WSL) | `recovery/recovery-inventory/<YYYY-MM-DD>.age` |
| `encryption-config` | `/var/lib/rancher/k3s/server/cred/encryption-config.json`, the K3s secrets-encryption configuration that holds the secretbox key (Stage 3). The helper accepts this exact path only. The file must be a nonempty regular file owned by `root:root` with no group or other permissions, in a `root:root` directory that group and others cannot write to | `k3s01` | `recovery/encryption-config/<YYYY-MM-DD>.age` |

The `encryption-config` item has its own timing and procedure: see [The K3s secrets-encryption configuration](#the-k3s-secrets-encryption-configuration-stage-3). The Velero repository password (Stage 5) is added by its own stage.

## The age identity

These facts were supplied by the repository owner.

- One X25519 identity. It was generated directly onto BitLocker-protected removable media, and it is held offline when the media is disconnected.
- **Recovery A**: a BitLocker AES-256 USB copy, kept locally.
- **Recovery B**: a second BitLocker AES-256 USB copy, kept off-site. Its location and holder are not recorded in Git.
- Auto-unlock is disabled on both. Each was unlocked and decrypted a non-secret test ciphertext.
- **Online copy**: a passphrase-encrypted identity archive, synchronized to OneDrive, together with the public recipient and non-secret instructions. It does not replace either offline copy. Before synchronization, it was decrypted and compared byte-for-byte with the identity. The synchronized archive has the same ciphertext SHA-256:

  `202E17734BB08E56BE97A4EE30049F0F17875FF688714CFB6CED2840080A602E`

  This hash identifies the passphrase-encrypted private identity archive. It reveals nothing about the identity, because `age` output is randomized.
- No plaintext identity exists in OneDrive or in this repository.

**Source-host verification temporarily makes the passphrase-encrypted identity archive available to the source host.**
- `verify` copies the archive into its private root-owned tmpfs, and `age` reads it from there. The private identity then exists only in `age` process memory.
- **The tmpfs copy is removed automatically when `verify` exits**, together with the tmpfs itself.
- **A transported copy of the archive (on `k3s01`, under `~/hc-recovery/out/`) is not touched by `verify`.** It remains until the explicit [per-host cleanup](#per-host-cleanup), which runs as soon as that host is finished, not at the end of the whole session.
- The passphrase is entered only at `age`'s own `/dev/tty` prompt. It is never passed through command arguments, environment variables, files, stdin pipelines or logs.

## The public recipient

The public recipient is committed at [`recovery/home-cluster-recovery-recipient.txt`](../../recovery/home-cluster-recovery-recipient.txt): one line, LF-terminated. It is a public key, so committing it exposes nothing, but reviews in this repository do not print it.

- Check it, printing only `PASS` or `FAIL`:

  ```bash
  python3 scripts/validate-recovery-material.py --check-recipient recovery/home-cluster-recovery-recipient.txt
  ```

- To review staged changes without printing it:

  ```bash
  git diff --cached -- . ':(exclude)recovery/home-cluster-recovery-recipient.txt'
  git diff --cached --stat
  git show :recovery/home-cluster-recovery-recipient.txt | python3 scripts/validate-recovery-material.py --check-recipient -
  ```

- **Before the first live encryption**, prove that the committed recipient matches the identity, without exposing either. Encrypt a fixed, non-secret test string with the committed file (`age -R recovery/home-cluster-recovery-recipient.txt`), then decrypt it with Recovery A, and separately with the online archive. Record only each outcome.

To replace the recipient, copy the new file without displaying it, normalize it to one LF-terminated line, check it as above, and compare it with its source by exit status only.

## Roles and hosts

| Host | Runs | Holds |
| --- | --- | --- |
| Source host (`k3s01`) | `scripts/recovery-material.sh`, as root through `sudo` | The plaintext sources. Briefly: ciphertext, and a transported copy of the identity archive until per-host cleanup |
| Administrative workstation (WSL) | `scripts/recovery-material-s3.sh`, with the `home-cluster-backup-operator` profile; `recovery-material.sh`, through `sudo`, for the inventory | Ciphertext; the filled inventory, only inside its private tmpfs |

All Stage 2 AWS operations use the routine `HomeClusterBackupOperator` role. `AdministratorAccess` is for provisioning and break-glass only. Here, that means only the rollback in [Rollback](#rollback).

## Prerequisites and live-pass gates

Each live run needs every prerequisite below, and each needs its own explicit approval. For the 2026-10-16 to 2026-10-19 run, the [validation record](../validation/encrypted-recovery-material.md#prerequisites) shows:
- items 1, 2 and 3 were met;
- the helpers came from a reviewed commit (item 7);
- the AWS steps used the routine role through the CLI wrapper described under item 5.

It does not record how the bucket name was configured (item 6), or whether the separate item 4 rehearsal was performed. Every `verify` with the real identity archive reported `MATCH`.

1. **A fresh on-demand local etcd snapshot** as the recovery point (design: Stages 2–5 each start with one). It is a cluster action.
2. **`age` v1.3.2 on every host that runs `encrypt` or `verify`:**
   - **`k3s01`**: installed by the homelab-k3s `recovery-tools` role, using `configure-recovery-tools.yml --limit k3s01`. It was installed and validated for the Stage 2 run.
   - **The WSL workstation**: a separately approved installation from the pinned Linux amd64 release archive, checksum-verified. It was installed and validated for the Stage 2 run. The Windows `age.exe` cannot be used by the Linux helper.

   The helpers never install or download software, and they fail closed when `age` is missing or is any other version.
3. **Swap disabled on every host that runs `verify` or holds the filled inventory**, so that `swapon --show` prints nothing:
   - `k3s01`: confirmed in preflight;
   - WSL: `swap=0` in `.wslconfig`, then a WSL restart.

   `verify` refuses to run while swap is active.

   **Changing swap state on a K3s server is a live node change.** Do it only as a separately approved step, with a fresh snapshot in place. During the Stage 2 run, the first server's local Kubernetes API became unavailable after a temporary swap-state change on that node. The cause was not determined; see the [validation record](../validation/encrypted-recovery-material.md#cluster-incident-and-recovery). If swap is active on a source host, stop and decide separately how to proceed.
4. **`/dev/tty` passphrase gate.** On each host that will run `verify`, run it once with a throwaway identity archive that you create interactively with `age -p`. This confirms that `age` v1.3.2 prompts on `/dev/tty`, with stdin from `/dev/null` and under `sudo`, and that `MATCH` is reported. The repository tests cannot exercise this, because they would need a terminal and a passphrase.
5. **The AWS CLI v2 on the workstation**, signed in with `aws sso login --profile home-cluster-backup-operator`. In the Stage 2 run, the CLI used from WSL was a private wrapper around the authenticated Windows AWS CLI. It normalized carriage returns and converted WSL paths for the Windows CLI's file operations. The repository's tests do not cover that wrapper.
6. **The bucket name** in `HOME_CLUSTER_BACKUP_BUCKET`, or in a mode `600` file at `~/.config/home-cluster/backup-bucket`. It is never committed or printed.
7. **The helpers and the recipient on the source host**, copied from a reviewed commit with the repository layout kept:

   ```bash
   git archive --format=tar <reviewed-commit> scripts/recovery-material.sh recovery/ \
     | ssh k3s01 'install -d -m 0700 ~/hc-recovery ~/hc-recovery/out && tar -x -C ~/hc-recovery'
   ```

## Session hygiene

Start each shell used in this runbook, on every host, with:

```bash
set +o history
unset HISTFILE
set +x
umask 077
export AWS_PAGER=""
```

Never do any of the following:
- use the AWS CLI's debug option, shell tracing, `script`, terminal logging or screen recording;
- `cat`, `echo`, `less`, hash or copy a source file;
- open the filled inventory in a Windows editor, VS Code, or any editor that keeps swap, backup or undo files on disk.

The helpers refuse to run with tracing enabled, or with any `AGE_*` or `*PASSPHRASE*` variable set.

## Preflight (metadata only)

On the source host, without reading either file:

```bash
sudo stat -c '%a %U:%G %F' /var/lib/rancher/k3s/server/token
sudo stat -c '%a %U:%G %F' /home/ansible/.config/home-cluster/grafana-admin
swapon --show
age --version
findmnt -t tmpfs -S recovery-material
stat -c '%a %U' ~/hc-recovery/out
bash ~/hc-recovery/scripts/recovery-material.sh check-recipient
```

Pass conditions:
- both sources are regular files with no group or other permissions;
- `swapon --show` and `findmnt` print nothing;
- `age` prints `v1.3.2`;
- `~/hc-recovery/out` is `700` and owned by you;
- the recipient check prints `PASS`.

On the workstation:

```bash
swapon --show
age --version
bash scripts/recovery-material-s3.sh check-role
```

`swapon --show` must print nothing and `age` must print `v1.3.2`. `check-role` must print `PASS`, meaning the session is the `HomeClusterBackupOperator` role; it never prints the ARN or the account ID.

## Procedure for the token and the Grafana credential

Repeat for `k3s-server-token`, then `grafana-admin`. Use one date, `<YYYY-MM-DD>`, for the whole run.

**Before step 1**, create and verify the inventory tmpfs on the workstation and copy the template into it ([The filled inventory](#the-filled-inventory), steps 1 and 2). Identifiers from this procedure are typed straight into it and are written nowhere else.

1. **Encrypt on the source host.** `age` reads the source itself. The output is created exclusively, as you, never overwriting an existing path.

   ```bash
   sudo bash ~/hc-recovery/scripts/recovery-material.sh encrypt --item k3s-server-token \
     --source /var/lib/rancher/k3s/server/token --out ~/hc-recovery/out/k3s-server-token.age
   ```

   Record the printed ciphertext SHA-256.
2. **Copy the ciphertext to the workstation** (ciphertext only):

   ```bash
   install -d -m 0700 ~/hc-recovery
   scp k3s01:hc-recovery/out/k3s-server-token.age ~/hc-recovery/k3s-server-token.age
   ```

3. **Upload with the routine role:**

   ```bash
   bash scripts/recovery-material-s3.sh upload --item k3s-server-token --date <YYYY-MM-DD> \
     --file ~/hc-recovery/k3s-server-token.age
   ```

   S3 checks the SHA-256 checksum on receipt. Record the version ID for the private inventory only, never in Git.
4. **Download that exact version and compare the ciphertexts:**

   ```bash
   bash scripts/recovery-material-s3.sh download --item k3s-server-token --date <YYYY-MM-DD> \
     --version-id <version-id> --out ~/hc-recovery/k3s-server-token.downloaded.age \
     --compare-with ~/hc-recovery/k3s-server-token.age
   ```

   It must print `result: MATCH`.
5. **Copy the downloaded ciphertext to the source host.** The first time only, also copy the identity archive from its OneDrive location:

   ```bash
   scp ~/hc-recovery/k3s-server-token.downloaded.age k3s01:hc-recovery/out/
   scp <identity-archive> k3s01:hc-recovery/out/identity-archive.age   # first item only
   ```

   On `k3s01`, check that the archive's SHA-256 matches the value recorded above before using it.
6. **Verify on the source host**, in an interactive session (`ssh -t k3s01`), so that `age` can prompt on `/dev/tty`:

   ```bash
   sudo bash ~/hc-recovery/scripts/recovery-material.sh verify --item k3s-server-token \
     --ciphertext ~/hc-recovery/out/k3s-server-token.downloaded.age \
     --source /var/lib/rancher/k3s/server/token \
     --identity-archive ~/hc-recovery/out/identity-archive.age
   ```

   The helper:
   - mounts a private, root-owned 0700 tmpfs and verifies it;
   - copies the archive into the tmpfs;
   - lets `age` prompt for the passphrase;
   - decrypts into the tmpfs and compares with `cmp -s`;
   - removes its tmpfs files and unmounts the tmpfs on exit.

   It must print `result: MATCH`. The transported `identity-archive.age` is still on `k3s01` afterwards.
7. **Record** the object key, version ID, ciphertext SHA-256 and verification result directly in the filled inventory, inside its tmpfs. Never write them anywhere else, and never into Git.

### Per-host cleanup

**Run this on `k3s01` as soon as both items are verified there**, before moving on to the inventory, not at the end of the whole session:

```bash
rm -f -- ~/hc-recovery/out/identity-archive.age ~/hc-recovery/out/*.age
test ! -e ~/hc-recovery/out/identity-archive.age && echo "identity archive: absent"
find ~/hc-recovery/out -maxdepth 1 -type f -name '*.age' | wc -l      # must print 0
findmnt -t tmpfs -S recovery-material                                 # must print nothing
```

These checks use file names and mount tables only; they never read file contents. Then remove the helper copy (`rm -rf -- ~/hc-recovery`) and confirm with `test ! -e ~/hc-recovery && echo "helper copy: absent"`.

## The K3s secrets-encryption configuration (Stage 3)

**Status:** implemented and tested with synthetic data only. It has not been run against the live cluster; no real configuration has been read, encrypted, uploaded or verified.

The homelab-k3s Stage 3 procedure enables K3s secretbox encryption at rest and rotates its key once. The key exists only in `/var/lib/rancher/k3s/server/cred/encryption-config.json`, identical on every server after the second restart round, and in K3s bootstrap data in etcd, encrypted with the server token. Restoring a post-activation snapshot onto servers that have lost that file, from the snapshot and the token alone, is untested. This recovery copy is therefore required: without the key, every Secret encrypted under it is lost, whatever snapshots survive. The Stage 3 side of this dependency is described in homelab-k3s `docs/secrets-encryption.md`, section "Key material and the off-node recovery copy".

### Timing

- **Make the copy only after all of these, in order:**
  1. the second (post-rotation) restart round has completed on all three servers;
  2. the enforced-enabled validation has passed;
  3. the p2 snapshot has been taken and recorded.

  Never earlier. Before the rotation, the file holds the key that coexisted with plaintext data, and that key is retired by the rotation.
- **The Stage 3 rollout is not complete until all four checks pass**, for the same object version:
  1. the upload succeeds;
  2. the exact-version download succeeds;
  3. the downloaded ciphertext is byte-identical to the uploaded one (`recovery-material-s3.sh download`: `result: MATCH`);
  4. the controlled decryption comparison reports `result: MATCH` (`recovery-material.sh verify`).

  Until then, the rollout must not be declared complete.
- **Any later approved key rotation requires a new verified recovery copy**, made by this same procedure after that rotation's own restart round, validation and snapshot. The earlier copy is marked superseded in the inventory; it is never deleted by the routine role.
- **No post-activation snapshot may be moved off the node** (p2 or any later snapshot, including the Stage 4 uploads) until the encryption-configuration recovery copy that matches its key state has passed all four checks.

### What is never done

The plaintext configuration, any key, any key name, the plaintext's hash or size, and decrypted output are never printed, logged, displayed, parsed, copied to the controller or workstation, or stored in an Ansible fact or any other variable. Specifically:
- `age` reads the protected source directly, on `k3s01`. No `cat`, `jq`, `cp`, `sha256sum` or `stat -c %s` is run on it, and no Ansible task reads it.
- Only ciphertext leaves `k3s01`.
- Decrypted output exists only inside `verify`'s private tmpfs and is compared there with `cmp -s`.

**The source path is bound.** In production, `recovery-material.sh` accepts `--source` for this item only as exactly `/var/lib/rancher/k3s/server/cred/encryption-config.json`. It refuses, using metadata only:
- any other path, including another root-owned file;
- a relative path or an alias, such as `./`, `//`, `..` or a trailing `/`;
- a symbolic link as the file or as any directory above it;
- a path whose canonical form (`realpath -e`) is not that exact path;
- a credential directory (`/var/lib/rancher/k3s/server/cred`) that is missing, is not a directory, is not owned by `root:root`, or is writable by group or others.

The tests stand in for that path with `RECOVERY_MATERIAL_TEST_EXPECTED_SOURCE`, and for the required owners with `RECOVERY_MATERIAL_TEST_SOURCE_OWNER` and `RECOVERY_MATERIAL_TEST_PARENT_OWNER`.
- They take effect only with `RECOVERY_MATERIAL_TEST=1`, which is refused for root.
- Outside test mode, the helper refuses to run at all while any of them is set, even empty, so none of them can redirect or relax a production run.

The helpers print metadata only:
- the item name;
- the source check: regular file, nonempty, mode, no group or other access, owner `root:root`, expected path, and the credential directory's ownership and writability;
- the ciphertext path, size and SHA-256;
- the object key;
- the path of the private version receipt;
- `MATCH`, `DIFFER` or `ERROR`;
- the cleanup result.

**The version ID of this item is never printed.**
- `upload` requires `--receipt`, and writes the object key and version ID to a new mode `600` file in the inventory tmpfs.
  - The content is first written to a fresh private file from `mktemp`, which is then hard-linked to the receipt name.
  - A hard link fails if the name already exists in any form, and never follows or opens it. This includes a receipt, FIFO or symbolic link planted after the helper's preliminary check.
  - The temporary name is always removed.
- `download` requires the same receipt, and refuses a receipt for any other object key.
- The bucket name is never printed, as for every item.

### Procedure

The prerequisites, session hygiene and per-host cleanup are those of the token and Grafana procedure above. Create and verify the inventory tmpfs first ([The filled inventory](#the-filled-inventory), step 1); `$inv` below is that tmpfs.

1. **Preflight on `k3s01`**, metadata only:

   ```bash
   sudo stat -c '%a %U:%G %F' /var/lib/rancher/k3s/server/cred/encryption-config.json
   ```

   ```bash
   sudo stat -c '%a %U:%G %F' /var/lib/rancher/k3s/server/cred
   ```

   - The first command must print a mode with no group or other permissions, `root:root`, and `regular file`.
   - The second must print a mode without group or other write permission, `root:root`, and `directory`.

   The helper repeats these checks. It also refuses an empty file, any other file type, any other path, and a symbolic link anywhere in the path.
2. **Encrypt on `k3s01`:**

   ```bash
   sudo bash ~/hc-recovery/scripts/recovery-material.sh encrypt --item encryption-config \
     --source /var/lib/rancher/k3s/server/cred/encryption-config.json \
     --out ~/hc-recovery/out/encryption-config.age
   ```

   It prints the source check, ciphertext path, size and SHA-256. Record the size and SHA-256 in the inventory.
3. **Copy the ciphertext to the workstation**, ciphertext only:

   ```bash
   scp k3s01:hc-recovery/out/encryption-config.age ~/hc-recovery/encryption-config.age
   ```

   Check that its SHA-256 equals the value printed in step 2.
4. **Upload, writing a private receipt:**

   ```bash
   bash scripts/recovery-material-s3.sh upload --item encryption-config --date <YYYY-MM-DD> \
     --file ~/hc-recovery/encryption-config.age --receipt "$inv/encryption-config.receipt"
   ```

   It prints the object key, the receipt path, and the ciphertext size and SHA-256. It refuses to run without `--receipt`, or if the receipt exists, is a link, or sits in a directory with group or other access.
5. **Download that exact version and compare the ciphertexts:**

   ```bash
   bash scripts/recovery-material-s3.sh download --item encryption-config --date <YYYY-MM-DD> \
     --receipt "$inv/encryption-config.receipt" --out ~/hc-recovery/encryption-config.downloaded.age \
     --compare-with ~/hc-recovery/encryption-config.age
   ```

   It must print `result: MATCH`. S3 must return the exact version in the receipt, or the download is refused and nothing is written to `--out`.
6. **Controlled decryption comparison on `k3s01`.**
   - Copy the downloaded ciphertext, and the identity archive if it is not already there, as in step 5 of the token procedure.
   - Then run, in an interactive session (`ssh -t k3s01`):

   ```bash
   sudo bash ~/hc-recovery/scripts/recovery-material.sh verify --item encryption-config \
     --ciphertext ~/hc-recovery/out/encryption-config.downloaded.age \
     --source /var/lib/rancher/k3s/server/cred/encryption-config.json \
     --identity-archive ~/hc-recovery/out/identity-archive.age
   ```

   `verify` behaves as for the token:
   - it refuses to run while swap is active;
   - it decrypts only inside its own root-owned 0700 tmpfs;
   - it compares with `cmp -s`, and prints `MATCH`, `DIFFER` or `ERROR` with the `cmp` exit status (a failed decryption is `ERROR`);
   - it removes its files and unmounts the tmpfs on success, failure, `INT`, `TERM` or `HUP`, and turns any cleanup failure into a non-zero exit.

   It must print `result: MATCH`. Afterwards, `findmnt -t tmpfs -S recovery-material` must print nothing.
7. **Record** these in the filled inventory, inside its tmpfs:
   - the object key, and the version ID, read from the receipt in the editor (for example with `:r`), never displayed in a terminal;
   - the ciphertext SHA-256 and size;
   - the source check;
   - both comparison results;
   - the cleanup result;
   - the rotation and p2 snapshot it follows;
   - `Recovery-copy status: verified`.
8. **Run the [per-host cleanup](#per-host-cleanup) on `k3s01`**, then re-encrypt, upload and verify the changed inventory ([The filled inventory](#the-filled-inventory), steps 3 to 5). Its cleanup removes the receipt with the tmpfs.

### Stop conditions for this item

These are in addition to the general [stop conditions](#stop-conditions):
- the source check fails;
- any comparison reports `DIFFER` or `ERROR`;
- the receipt cannot be written after an upload. Treat that version as unverified, and upload again with `--new-version` and a new receipt;
- the copy was attempted before the second restart round, the enforced-enabled validation and p2.

On any of these, Stage 3 stays incomplete. The cluster keeps running encrypted, with the key on all three servers and in etcd. Do not upload any snapshot off the node, and do not rotate again. Fix the cause and repeat the procedure.

### Required cross-repository follow-up (homelab-k3s)

homelab-k3s `docs/secrets-encryption.md`, section "Key material and the off-node recovery copy", must be aligned with this helper before the Stage 3 live run. Open as of this change:
- **Remove the source file's size from the metadata it says may be recorded.** This helper never records the plaintext or source size, only its mode, ownership and path checks, and the ciphertext's size and SHA-256.
- **Replace `MATCH`/`MISMATCH` with `MATCH`, `DIFFER` or `ERROR`**, the results the helper reports.

## The filled inventory

The filled inventory holds backup identifiers and version IDs, but no secret values. Its plaintext exists only in two places:
- **a private tmpfs on the workstation**, with swap disabled, while it is prepared and verified;
- **the BitLocker recovery media**, and only if an offline plaintext copy is required.

**It is never created on the WSL virtual disk, the Windows system disk, OneDrive or in the repository.**

1. **Create and verify the private tmpfs** (in WSL), before the token and Grafana procedure starts:

   ```bash
   inv=/run/hc-inventory
   swapon --show                                   # must print nothing
   sudo install -d -m 0700 -o root -g root "$inv"
   sudo mount -t tmpfs -o size=4m,mode=0700,uid="$(id -u)",gid="$(id -g)",noexec,nosuid,nodev hc-inventory "$inv"
   findmnt -no FSTYPE --mountpoint "$inv"          # must print: tmpfs
   stat -c '%a %U' "$inv"                          # must print: 700 <your user>
   ```

   Stop if any check differs.
2. **Fill it in only inside the tmpfs**, during and after the token and Grafana procedure, with an editor that writes no swap, backup, undo or history files:

   ```bash
   install -m 0600 docs/runbooks/recovery-material-inventory-template.md "$inv/recovery-material-inventory.md"
   vim -n -i NONE -c 'set nobackup nowritebackup noundofile' "$inv/recovery-material-inventory.md"
   python3 scripts/validate-recovery-material.py --scan "$inv/recovery-material-inventory.md"
   ```

   The scan must report no findings. It prints only path, line number and rule name.
3. **Encrypt, upload, download and verify** on the workstation, as in steps 1, 3, 4 and 6 above, with `--item recovery-inventory`:

   ```bash
   sudo bash scripts/recovery-material.sh encrypt --item recovery-inventory \
     --source "$inv/recovery-material-inventory.md" --out ~/hc-recovery/recovery-inventory.age
   bash scripts/recovery-material-s3.sh upload --item recovery-inventory --date <YYYY-MM-DD> \
     --file ~/hc-recovery/recovery-inventory.age
   bash scripts/recovery-material-s3.sh download --item recovery-inventory --date <YYYY-MM-DD> \
     --version-id <version-id> --out ~/hc-recovery/recovery-inventory.downloaded.age \
     --compare-with ~/hc-recovery/recovery-inventory.age
   sudo bash scripts/recovery-material.sh verify --item recovery-inventory \
     --ciphertext ~/hc-recovery/recovery-inventory.downloaded.age \
     --source "$inv/recovery-material-inventory.md" --identity-archive <identity-archive>
   ```

   On the workstation, `--identity-archive` points at the archive in its OneDrive location. `verify` copies it into its own tmpfs, removes that copy on exit, and does not create a transported copy on the WSL disk.
4. **Copy the verified ciphertext to Recovery A, then to Recovery B**, as in [Offline copies](#offline-copies-on-recovery-a-and-b). If an offline plaintext copy is also required, copy `recovery-material-inventory.md` from the tmpfs straight to the recovery media in the same way. Never stage it through any other location.
5. **Clean up and check:**

   ```bash
   rm -f -- "$inv/recovery-material-inventory.md"
   sudo umount "$inv" && sudo rmdir "$inv"
   findmnt --mountpoint "$inv"                     # must print nothing
   test ! -e "$inv" && echo "inventory tmpfs: removed"
   rm -f -- ~/hc-recovery/*.age
   find ~/hc-recovery -maxdepth 1 -type f -name '*.age' | wc -l    # must print 0
   ```

## Offline copies on Recovery A and B

Only one recovery device is connected at a time. Copy and check sequentially, from Windows PowerShell. Use `\\wsl.localhost\Ubuntu\...` for the WSL source path, and never mount the recovery media inside WSL.

For each device in turn (Recovery A first; Recovery B when it is next available):

1. Connect only that device and unlock it at the BitLocker prompt. Note its drive letter for this session only; never record it.
2. Copy the verified ciphertext and check it against the SHA-256 recorded by `encrypt`:

   ```powershell
   $src = '\\wsl.localhost\Ubuntu\home\<user>\hc-recovery\recovery-inventory.age'
   $dst = '<drive>:\home-cluster\recovery-inventory-<YYYY-MM-DD>.age'
   Copy-Item -LiteralPath $src -Destination $dst
   (Get-FileHash -Algorithm SHA256 -LiteralPath $dst).Hash -eq '<recorded ciphertext sha256>'   # must print True
   ```

3. Lock the device (`manage-bde -lock <drive>:`), eject it, and disconnect it before connecting the other.

If Recovery B is not available during the run, its copy stays pending. Record only "Recovery B: pending" or "Recovery B: verified", with the date, in the evidence. Never record a drive letter, physical location, device serial or holder.

## Stop conditions

Stop the run, record the outcome only, and do not improvise if:

- any helper guard fails: the wrong or missing `age`, tracing on, active swap, a tmpfs that can't be mounted or verified, a missing terminal, a source with group or other permissions, or an output directory that is shared or is a link;
- `cmp -s` reports `DIFFER` or `ERROR`, or a ciphertext SHA-256 changes in transit or on recovery media;
- `check-role` prints `FAIL`;
- `AccessDenied` on a designed action. Do not widen permissions, and do not switch to `AdministratorAccess`;
- the inventory tmpfs checks differ from their expected output;
- any secret-shaped value appears in a terminal, log, evidence file or Git. Treat it as compromised and follow [SECURITY.md](../../SECURITY.md): rotate the token or password, then re-encrypt.

## Partial failure

- **Upload succeeded, verification failed:** the object stays as an unverified version. Mark it unverified in the inventory, fix the cause, and re-run with `upload --new-version`. The routine role cannot delete objects.
- **Download or comparison failed:** a failed or rejected download leaves nothing at `--out`. Re-run step 4 from the same version ID. If it still fails, treat the uploaded version as unverified.
- **Verification interrupted:** `verify` removes its tmpfs files and unmounts its tmpfs, keeps the original failure status, and reports any cleanup failure. Confirm that `findmnt -t tmpfs -S recovery-material` prints nothing before retrying.
- **Stopped part-way through:** run the per-host cleanup on every host already used, and the inventory cleanup if its tmpfs exists, before anything else.

## Rollback

The design's Stage 2 rollback: delete the uploaded ciphertext versions, as an administrator. That is a break-glass `AdministratorAccess` action, recorded with timestamps. Nothing changes on the cluster.

## Evidence

May be recorded:
- object keys;
- ciphertext SHA-256 values;
- `cmp -s` exit statuses and `MATCH`/`DIFFER` results;
- `age` and AWS CLI versions;
- the `check-role` result;
- the role name `HomeClusterBackupOperator`;
- the cleanup check results;
- Recovery A/B copy status;
- timestamps.

Never recorded:
- plaintext, or any plaintext hash, size or prefix;
- the private identity, the passphrase or a passphrase hint;
- version IDs, which belong in the private inventory, and version receipts;
- any part of the K3s secrets-encryption configuration, including key names;
- the bucket name;
- the account ID, ARNs, IAM Identity Center identifiers or the portal URL;
- the off-site location or holder, drive letters or device serials.

Scan each evidence file before archiving it: `python3 scripts/validate-recovery-material.py --scan <evidence file>`.
- `--scan` applies the content rules only and needs no repository files.
- It prints only path, line number and rule name.
- A finding blocks archiving and triggers the leaked-secret procedure.

## Residual risks

- **Hypervisor paging.** Disabling swap inside a VM does not stop the host from paging the VM's memory:
  - Windows can page the WSL2 VM's memory to `pagefile.sys`;
  - VMware can swap a guest such as `k3s01` to its `.vswp` file.

  "Memory-backed" here means protected from the guest's own swap only. Whether the host page file and the VM swap files sit on encrypted storage is not established by this runbook.
- **The operator has `sudo`.** The helpers protect against mistakes and leaks, not against the operator.

## What the repository tests do and do not cover

| Coverage | Where | What |
| --- | --- | --- |
| Complete helper tests under Linux, with real `age` v1.3.2 | CI only (`scripts/test-recovery-material.sh`, group B is mandatory there) | Encrypt and verify round trips with a throwaway identity; `MATCH` and `DIFFER`; failed decryption; two-recipient refusal; no plaintext in any output; cleanup of the test directory |
| Refusal paths and the S3 helper | CI and any Linux host with bash (groups A and C) | Guards, header checks, a TERM trap test, and the S3 helper against a stub `aws` command, including a zero-byte checksum case |
| The `encryption-config` item | CI and any Linux host with bash (group D); its round trips need real `age` v1.3.2, which CI requires | A synthetic configuration with a random key. Covered: source checks (missing, symbolic link, directory, FIFO, device, empty, ownership simulated by a test-mode owner override, every group or other mode bit); path binding through the test-only expected-source override (the exact path accepted; an alternate file, relative and normalized aliases, a final-component or ancestor symbolic link, a differing canonical path by stub, a missing or non-directory credential directory, wrong directory ownership and a group- or other-writable directory refused); refusal of every test-only variable outside test mode and of test mode as root; the committed production path; `age` version refusals; invalid headers; `MATCH`, `DIFFER` and `ERROR`; cleanup after success, command failure, comparison failure and `TERM`, `HUP` and `INT`; receipt-based upload and exact-version download, including mismatched versions and receipts, and receipts, FIFOs and links planted during an upload; and that no key, key name, plaintext hash, bucket name or receipt-held version ID is printed |
| Limited Windows probes | Run once by hand with `age.exe` v1.3.2 and a throwaway key | That real v1.3.2 X25519 ciphertext has exactly one stanza and passes the header check, and one encrypt/decrypt round trip. They do not run the Linux helpers |

**Untested by any of them:**
- a real `root:root` source and credential directory, and the production path itself: test mode cannot run as root, so ownership is checked against overrides, and the path through the test-only expected-source override. The tests never access `/var/lib/rancher/k3s/server/cred`;
- production `sudo` and `runuser`;
- the tmpfs mount;
- the swap check;
- the `/dev/tty` passphrase prompt with a real passphrase-encrypted archive;
- SSH, AWS and S3.

These are covered only by the live-pass gates above and by the live run.
