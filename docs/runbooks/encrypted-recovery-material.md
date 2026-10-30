# Runbook: encrypted recovery material (Stage 2)

**Status:** executed from 2026-10-16 to 2026-10-19 UTC. The K3s server token, the Grafana admin credential and the filled recovery-material inventory were each encrypted, uploaded, downloaded by exact version and verified, and the inventory was copied to Recovery A and Recovery B. The results, and a cluster incident that interrupted the run, are recorded in the [encrypted recovery material validation](../validation/encrypted-recovery-material.md). The Stage 3 `encryption-config` item was run on 2026-10-29 UTC, with an updated inventory copied to both recovery devices; see the [Stage 3 section of the validation record](../validation/encrypted-recovery-material.md#stage-3-the-k3s-secrets-encryption-configuration-2026-10-29). Later runs, after any item changes, follow the same procedure and are recorded the same way.

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

   **Keep WSL running while the inventory tmpfs exists.** WSL shuts its virtual machine down shortly after the last WSL process exits. That unmounts every tmpfs, including the inventory tmpfs and any upload receipt in it. *Observed 2026-10-29:* between two steps, with no WSL process left running, the VM shut down and was started again by the next command. The `encryption-config` receipt was lost (see [Partial failure](#partial-failure)). Before creating the inventory tmpfs, start a keep-alive in its own Windows terminal:

   ```powershell
   wsl.exe -e sleep 14400
   ```

   Keep it running until the [inventory cleanup](#the-filled-inventory) has completed, then stop it. Commands run one at a time through `wsl.exe` do not keep the VM alive between them.

   **Changing swap state on a K3s server is a live node change.** Do it only as a separately approved step, with a fresh snapshot in place. During the Stage 2 run, the first server's local Kubernetes API became unavailable after a temporary swap-state change on that node. The cause was not determined; see the [validation record](../validation/encrypted-recovery-material.md#cluster-incident-and-recovery). If swap is active on a source host, stop and decide separately how to proceed.
4. **`/dev/tty` passphrase gate.** On each host that will run `verify`, run it once with a throwaway identity archive that you create interactively with `age -p`. This confirms that `age` v1.3.2 prompts on `/dev/tty`, with stdin from `/dev/null` and under `sudo`, and that `MATCH` is reported. The repository tests cannot exercise this, because they would need a terminal and a passphrase.
5. **The AWS CLI v2 on the workstation**, signed in with `aws sso login --profile home-cluster-backup-operator`. In the Stage 2 run, the CLI used from WSL was a private wrapper around the authenticated Windows AWS CLI. It normalized carriage returns and converted WSL paths for the Windows CLI's file operations. The repository's tests do not cover that wrapper.
6. **The bucket name** in `HOME_CLUSTER_BACKUP_BUCKET`, or in a mode `600` file at `~/.config/home-cluster/backup-bucket`. It is never committed or printed.
7. **The helpers and the recipient on the source host**, copied from a reviewed commit with the repository layout kept:

   ```bash
   git archive --format=tar <reviewed-commit> scripts/recovery-material.sh recovery/ \
     | ssh k3s01 'test ! -e ~/hc-recovery && install -d -m 0700 ~/hc-recovery && tar -x -C ~/hc-recovery \
         && bash ~/hc-recovery/scripts/recovery-material.sh start-run --dir ~/hc-recovery/out'
   ```

   `~/hc-recovery` must not exist on `k3s01` beforehand: a copy left by an earlier run stops this step. `start-run` creates `out` as this run's directory ([Run directories](#run-directories-and-scoped-cleanup)) and must print `result: PASS`.

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

## Run directories and scoped cleanup

Every file that a run creates or transports goes into a run directory made for that run by `start-run`, and only `cleanup` removes it. Never remove these files with a wildcard or a recursive delete. Ciphertexts kept from earlier runs, such as the Stage 2 copies directly under `~/hc-recovery` on the workstation, have the same names as the files a new run creates.

- **On `k3s01`**: `~/hc-recovery/out`, created by prerequisite 7.
- **On the workstation**: a new directory for each run, created before the first copy, in the shell that holds `$inv`:

  ```bash
  install -d -m 0700 ~/hc-recovery
  run=~/hc-recovery/run-<YYYY-MM-DD>
  bash scripts/recovery-material.sh start-run --dir "$run"
  ```

  It must print `result: PASS`. It refuses a directory that already exists, so a second run on the same day needs a new name, such as `run-<YYYY-MM-DD>-2`. In a new shell, set `run` again; do not run `start-run` again.

`start-run` creates the directory with mode `700` and an empty run marker. `cleanup` takes the files to remove by name (`--remove`), and every ciphertext kept from an earlier run by absolute path (`--keep`). Before it removes anything, it refuses, and then removes nothing, if it finds:
- a directory without the run marker, or one that is a symbolic link, lies under a symbolic-link path, is not mode `700` or is not yours;
- a name other than `<item>.age`, `<item>.downloaded.age` or `identity-archive.age`, including any wildcard or path;
- a named file that is missing, is not a regular file, is a symbolic link, has another hard link, is not yours, or is older than the run marker, so that this run did not create it;
- any entry in the directory that is not named, including a retained ciphertext copied into it;
- a kept file that is missing, is a symbolic link or lies inside the run directory.

It then removes the named files, the marker and the directory. It confirms that the directory is absent and that each kept file still has the same inode, link count, size, modification time and SHA-256. It prints each removed and retained path, then `result: PASS`; otherwise `result: ERROR`, with a non-zero exit. It refuses to run as root, and it never prints a hash.

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

**Before step 1**, create and verify the inventory tmpfs on the workstation and copy the template into it ([The filled inventory](#the-filled-inventory), steps 1 and 2). Then create the workstation run directory, `$run` ([Run directories](#run-directories-and-scoped-cleanup)). Identifiers from this procedure are typed straight into the inventory and are written nowhere else.

1. **Encrypt on the source host.** `age` reads the source itself. The output is created exclusively, as you, never overwriting an existing path.

   ```bash
   sudo bash ~/hc-recovery/scripts/recovery-material.sh encrypt --item k3s-server-token \
     --source /var/lib/rancher/k3s/server/token --out ~/hc-recovery/out/k3s-server-token.age
   ```

   Record the printed ciphertext SHA-256.
2. **Copy the ciphertext to the workstation** (ciphertext only):

   ```bash
   scp k3s01:hc-recovery/out/k3s-server-token.age "$run/k3s-server-token.age"
   ```

3. **Upload with the routine role:**

   ```bash
   bash scripts/recovery-material-s3.sh upload --item k3s-server-token --date <YYYY-MM-DD> \
     --file "$run/k3s-server-token.age"
   ```

   S3 checks the SHA-256 checksum on receipt. Record the version ID for the private inventory only, never in Git.
4. **Download that exact version and compare the ciphertexts:**

   ```bash
   bash scripts/recovery-material-s3.sh download --item k3s-server-token --date <YYYY-MM-DD> \
     --version-id <version-id> --out "$run/k3s-server-token.downloaded.age" \
     --compare-with "$run/k3s-server-token.age"
   ```

   It must print `result: MATCH`.
5. **Copy the downloaded ciphertext to the source host.** The first time only, also copy the identity archive from its OneDrive location:

   ```bash
   scp "$run/k3s-server-token.downloaded.age" k3s01:hc-recovery/out/
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
bash ~/hc-recovery/scripts/recovery-material.sh cleanup --dir ~/hc-recovery/out \
  --remove k3s-server-token.age --remove k3s-server-token.downloaded.age \
  --remove grafana-admin.age --remove grafana-admin.downloaded.age \
  --remove identity-archive.age
findmnt -t tmpfs -S recovery-material                                 # must print nothing
```

Name exactly the files this run put in `out`. For the `encryption-config` item, they are `encryption-config.age`, `encryption-config.downloaded.age` and `identity-archive.age`. After a stop part-way through, name only those that exist. `cleanup` must print `removed:` for each of them, `run directory: absent` and `result: PASS` ([Run directories](#run-directories-and-scoped-cleanup)). Nothing on `k3s01` is kept, so no `--keep` is given. These checks use metadata and mount tables only; they never read file contents.

Then remove the helper copy, by name, and confirm that nothing else was in it:

```bash
rm -f -- ~/hc-recovery/scripts/recovery-material.sh ~/hc-recovery/recovery/home-cluster-recovery-recipient.txt
rmdir -- ~/hc-recovery/scripts ~/hc-recovery/recovery ~/hc-recovery
test ! -e ~/hc-recovery && echo "helper copy: absent"
```

`rmdir` fails on a directory that still holds anything. If it does, stop and find out why, rather than removing the rest.

## The K3s secrets-encryption configuration (Stage 3)

**Status:** run against the live cluster on 2026-10-29 UTC, after homelab-k3s's second restart round, enforced-enabled validation and p2. All four completion checks passed for the same object version; see the [validation record](../validation/encrypted-recovery-material.md#stage-3-the-k3s-secrets-encryption-configuration-2026-10-29). Before that it was tested with synthetic data only.

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

The prerequisites, session hygiene and per-host cleanup are those of the token and Grafana procedure above. Create and verify the inventory tmpfs first ([The filled inventory](#the-filled-inventory), step 1), then the workstation run directory ([Run directories](#run-directories-and-scoped-cleanup)). `$inv` below is that tmpfs, and `$run` is the run directory.

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
   scp k3s01:hc-recovery/out/encryption-config.age "$run/encryption-config.age"
   ```

   Check that its SHA-256 equals the value printed in step 2.
4. **Upload, writing a private receipt:**

   ```bash
   bash scripts/recovery-material-s3.sh upload --item encryption-config --date <YYYY-MM-DD> \
     --file "$run/encryption-config.age" --receipt "$inv/encryption-config.receipt"
   ```

   It prints the object key, the receipt path, and the ciphertext size and SHA-256. It refuses to run without `--receipt`, or if the receipt exists, is a link, or sits in a directory with group or other access.
5. **Download that exact version and compare the ciphertexts:**

   ```bash
   bash scripts/recovery-material-s3.sh download --item encryption-config --date <YYYY-MM-DD> \
     --receipt "$inv/encryption-config.receipt" --out "$run/encryption-config.downloaded.age" \
     --compare-with "$run/encryption-config.age"
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
8. **Run the [per-host cleanup](#per-host-cleanup) on `k3s01`**, then re-encrypt, upload and verify the changed inventory ([The filled inventory](#the-filled-inventory), steps 3 to 5). Its cleanup removes the receipt with the tmpfs. Then make the [offline copies](#offline-copies-on-recovery-a-and-b), and only after both are verified, the workstation run cleanup.

### Stop conditions for this item

These are in addition to the general [stop conditions](#stop-conditions):
- the source check fails;
- any comparison reports `DIFFER` or `ERROR`;
- the receipt cannot be written after an upload. Treat that version as unverified, and upload again with `--new-version` and a new receipt;
- the copy was attempted before the second restart round, the enforced-enabled validation and p2.

On any of these, Stage 3 stays incomplete. The cluster keeps running encrypted, with the key on all three servers and in etcd. Do not upload any snapshot off the node, and do not rotate again. Fix the cause and repeat the procedure.

### Required cross-repository follow-up (homelab-k3s)

**Resolved before the live run:** homelab-k3s `docs/secrets-encryption.md`, section "Key material and the off-node recovery copy", was aligned with this helper in homelab-k3s commit `a5991e5` (pull request #6, merged in `09ce4af`):
- the source file's size was removed from the metadata it says may be recorded. This helper never records the plaintext or source size, only its mode, ownership and path checks, and the ciphertext's size and SHA-256;
- `MATCH`/`MISMATCH` was replaced with `MATCH`, `DIFFER` or `ERROR`, the results the helper reports.

## The interim manual p2 snapshot copy (stage3-p2-snapshot)

**What it is.** A one-time, manually preserved, `age`-encrypted copy of the Stage 3 p2 (post-encryption) etcd snapshot. It is stored as `recovery/stage3-p2-snapshot/<YYYY-MM-DD>.age` with the routine role, so that a post-activation snapshot exists off the node before Stage 4.

**It is not a Stage 4 upload.** Stage 4 is K3s's built-in, scheduled upload of etcd snapshots under `etcd/`, with the etcd machine identity ([design](../design/backup-disaster-recovery.md#etcd-and-k3s-server-token-backup)). This copy does not configure, test or replace that, and making it does not complete Stage 4. It is recorded in the inventory's **Interim manual p2 snapshot copy** rows, never as a Stage 4 restore point. When a Stage 4 upload of a later snapshot is verified, mark this copy superseded.

**What a restore would need.** This ciphertext and the age identity; the K3s server token recovery copy, because the snapshot's bootstrap data is encrypted with the token; and the encryption-configuration recovery copy, because the snapshot's Secrets are encrypted with its key. No restore from this copy has been rehearsed.

**Approvals.** Each live step needs its own approval: the encryption on `k3s01`; the upload; the decryption comparison; the inventory update; and each offline copy.

### What is never done

- The plaintext snapshot never leaves `k3s01`, and is never copied, moved, renamed or deleted there.
- The snapshot's own size and SHA-256 are never printed or recorded. The helper compares the SHA-256 only with the value already in the Stage 3 checkpoints file.
- This procedure does not copy the snapshot ciphertext to Recovery A, Recovery B or OneDrive. Only the updated inventory goes to the recovery media.
- No K3s `etcd-s3` setting is added, and nothing is written under `etcd/`.

### What the helper enforces

`encrypt` and `verify` refuse the source unless all of the following hold, checking metadata first:
- it is an absolute, normalized path directly in `/var/lib/rancher/k3s/server/db/snapshots`. That directory must be `root:root` and not writable by group or others, with no symbolic link anywhere in its path;
- its name has the p2 form, `stage3-p2-post-encryption-<YYYYMMDD>t<HHMMSS>z-k3s01-<epoch>`;
- it is a regular, nonempty, singly linked `root:root` file, mode `600`, at most 64 MiB, whose canonical path is itself;
- it is the only `p2-post-encryption` record in `/var/lib/homelab-secrets-encryption/checkpoints`, which must be a singly linked `root:root` file with no group or other access, in a `root:root` directory. The record's name, size, modification time and SHA-256 must match the file.

`encrypt` also enforces:
- **Ownership.** It must run through `sudo` from your own account, never as root directly. It writes the ciphertext as you, through `runuser`, and then requires a regular, singly linked, mode `600` file owned by you. Otherwise it removes the file. So `scp` and the scoped `cleanup`, which both run as you, can read and remove it.
- **No substitution.** After encrypting, it checks the source again (device, inode, link count, size and times, and the SHA-256 against the record), and removes the ciphertext if anything changed.

`verify` also enforces:
- `--ciphertext-sha256`: the ciphertext must have the SHA-256 that `encrypt` printed, so an incomplete or wrong transfer is refused before anything is decrypted;
- memory: it uses an 80 MiB private tmpfs, and refuses to mount it unless `MemAvailable` is at least twice that.

The S3 helper requires a private receipt for both upload and download. On upload it also requires `--ciphertext-sha256`, and a ciphertext of at most 65 MiB.

### Procedure

The prerequisites, session hygiene and per-host cleanup are those of the token and Grafana procedure. First:
- start the keep-alive;
- create and verify the inventory tmpfs ([The filled inventory](#the-filled-inventory), step 1);
- create the workstation run directory, `$run` ([Run directories](#run-directories-and-scoped-cleanup));
- set up the helper copy on `k3s01`, with `~/hc-recovery/out` (prerequisite 7).

`<snapshot date>` below is the UTC date in the snapshot's name, for example `2026-10-29` for the 2026-10-29 p2.

1. **Preflight on `k3s01`**, metadata only:

   ```bash
   p2=/var/lib/rancher/k3s/server/db/snapshots/<p2 snapshot file name>
   sudo stat -c '%a %U:%G %h %F' "$p2"                                 # must print: 600 root:root 1 regular file
   sudo stat -c '%a %U:%G %F' /var/lib/rancher/k3s/server/db/snapshots  # root:root directory, no group or other write
   swapon --show                                                       # must print nothing
   awk '$1 == "MemAvailable:" { print $2 }' /proc/meminfo              # must be at least 163840 (kB)
   ```

   Swap on `k3s01` is off only until its next reboot. If it is on, stop.
2. **Encrypt on `k3s01`**, in an interactive session (`ssh -t k3s01`):

   ```bash
   sudo bash ~/hc-recovery/scripts/recovery-material.sh encrypt --item stage3-p2-snapshot \
     --source "$p2" --out ~/hc-recovery/out/stage3-p2-snapshot.age
   stat -c '%a %U %h' ~/hc-recovery/out/stage3-p2-snapshot.age          # must print: 600 <your user> 1
   ```

   It prints the source check, the ciphertext path, size and SHA-256. Record the size and SHA-256 in the inventory. On the workstation, set `p2sha=<ciphertext SHA-256 printed by encrypt>`.
3. **Copy the ciphertext to the workstation**, ciphertext only:

   ```bash
   scp k3s01:hc-recovery/out/stage3-p2-snapshot.age "$run/stage3-p2-snapshot.age"
   sha256sum "$run/stage3-p2-snapshot.age"                             # must equal $p2sha
   ```

   If the copy is interrupted or the SHA-256 differs, do not upload. Repeat the `scp` into the same run file; `upload` refuses any file whose SHA-256 differs from `$p2sha`.
4. **Upload, writing a private receipt:**

   ```bash
   bash scripts/recovery-material-s3.sh upload --item stage3-p2-snapshot --date <snapshot date> \
     --file "$run/stage3-p2-snapshot.age" --ciphertext-sha256 "$p2sha" \
     --receipt "$inv/stage3-p2-snapshot.receipt"
   ```

   It refuses an existing key, a missing or existing receipt, and a file that differs from `$p2sha`.
5. **Download that exact version and compare the ciphertexts:**

   ```bash
   bash scripts/recovery-material-s3.sh download --item stage3-p2-snapshot --date <snapshot date> \
     --receipt "$inv/stage3-p2-snapshot.receipt" --out "$run/stage3-p2-snapshot.downloaded.age" \
     --compare-with "$run/stage3-p2-snapshot.age"
   ```

   It must print `result: MATCH`.
6. **Controlled decryption comparison on `k3s01`.** Copy the downloaded ciphertext into the run directory there, and the identity archive as in step 5 of the token procedure:

   ```bash
   scp "$run/stage3-p2-snapshot.downloaded.age" k3s01:hc-recovery/out/stage3-p2-snapshot.downloaded.age
   ```

   Then, in an interactive session (`ssh -t k3s01`):

   ```bash
   sudo bash ~/hc-recovery/scripts/recovery-material.sh verify --item stage3-p2-snapshot \
     --ciphertext ~/hc-recovery/out/stage3-p2-snapshot.downloaded.age \
     --ciphertext-sha256 <ciphertext SHA-256 printed by encrypt> \
     --source "$p2" --identity-archive ~/hc-recovery/out/identity-archive.age
   findmnt -t tmpfs -S recovery-material                               # must print nothing
   ```

   It must print `private tmpfs: 80 MiB` and `result: MATCH`.
7. **Record** in the filled inventory, inside its tmpfs, the **Interim manual p2 snapshot copy** rows: the object key; the version ID, read from the receipt in the editor; the ciphertext SHA-256 and size; the snapshot name; the source check; both comparisons; the cleanup result; the restore dependencies; the scope; and `Recovery-copy status: verified`.
8. **Run the per-host cleanup on `k3s01`**, naming exactly this run's files:

   ```bash
   bash ~/hc-recovery/scripts/recovery-material.sh cleanup --dir ~/hc-recovery/out \
     --remove stage3-p2-snapshot.age --remove stage3-p2-snapshot.downloaded.age \
     --remove identity-archive.age
   ```

   Then remove the helper copy as in [Per-host cleanup](#per-host-cleanup).
9. **Update the inventory** ([Updating an existing inventory](#updating-an-existing-inventory)). If the new inventory has the same date as the previous one, upload it as an explicit new version ([The filled inventory](#the-filled-inventory), step 3, same-date update). Then make the [offline copies](#offline-copies-on-recovery-a-and-b) of the new inventory under their timestamped names. Run the workstation run cleanup only after both are verified, naming this run's four files and passing `--keep "$prior"`.

### Interruption and recovery

- **`encrypt` fails or stops.** A failed encryption removes its partial output. If a file remains in `~/hc-recovery/out`, name it in the per-host cleanup; never remove it by hand.
- **The ownership or substitution check fails.** The ciphertext is removed. Stop and find out why; do not retry until the cause is known.
- **A transfer is interrupted** (in either direction). The SHA-256 differs, and `upload` or `verify` refuses the file before using it. Repeat the copy.
- **The upload succeeds but the receipt is lost**, for example because WSL shut down. Follow [Partial failure](#partial-failure). To add the version again, pass `--new-version --replaces-sha256 "$p2sha"`, because the current version is this ciphertext, with a new receipt.
- **The download fails.** Nothing is written to `--out`; run it again with the same receipt.
- **`verify` is interrupted.** It removes its tmpfs files and unmounts the tmpfs. Confirm that `findmnt -t tmpfs -S recovery-material` prints nothing before retrying.
- **`k3s01` reboots.** Its swap returns, so `verify` refuses. Stop.

### Stop conditions for this item

Stop, and do not improvise, if:
- any source, checkpoint, ownership, substitution, memory or transfer check refuses;
- either comparison is not `MATCH`;
- the key already exists;
- a receipt exists before the upload;
- swap is active on `k3s01`.

## The filled inventory

The filled inventory holds backup identifiers and version IDs, but no secret values. Its plaintext exists only in two places:
- **a private tmpfs on the workstation**, with swap disabled, while it is prepared and verified;
- **the BitLocker recovery media**, and only if an offline plaintext copy is required.

**It is never created on the WSL virtual disk, the Windows system disk, OneDrive or in the repository.**

1. **Create and verify the private tmpfs** (in WSL), before the token and Grafana procedure starts:

   ```bash
   inv=/run/hc-inventory
   pgrep -fx 'sleep 14400'                         # the WSL keep-alive (prerequisite 3) must be running
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

   **To update an existing inventory**, do not copy the template. Follow [Updating an existing inventory](#updating-an-existing-inventory) in place of this step; it ends by returning to step 3.
3. **Encrypt, upload, download and verify** on the workstation, as in steps 1, 3, 4 and 6 above, with `--item recovery-inventory`:

   ```bash
   sudo bash scripts/recovery-material.sh encrypt --item recovery-inventory \
     --source "$inv/recovery-material-inventory.md" --out "$run/recovery-inventory.age"
   bash scripts/recovery-material-s3.sh upload --item recovery-inventory --date <YYYY-MM-DD> \
     --file "$run/recovery-inventory.age"
   bash scripts/recovery-material-s3.sh download --item recovery-inventory --date <YYYY-MM-DD> \
     --version-id <version-id> --out "$run/recovery-inventory.downloaded.age" \
     --compare-with "$run/recovery-inventory.age"
   sudo bash scripts/recovery-material.sh verify --item recovery-inventory \
     --ciphertext "$run/recovery-inventory.downloaded.age" \
     --source "$inv/recovery-material-inventory.md" --identity-archive <identity-archive>
   ```

   On the workstation, `--identity-archive` points at the archive in its OneDrive location. `verify` copies it into its own tmpfs, removes that copy on exit, and does not create a transported copy on the WSL disk.

   **Same-date update.** If this inventory has the same date as the one it replaces (for example a second inventory on 2026-10-29), its key already exists, and `upload` refuses it. Add the new version explicitly instead, and pin it with a receipt:

   ```bash
   bash scripts/recovery-material-s3.sh upload --item recovery-inventory --date <YYYY-MM-DD> \
     --file "$run/recovery-inventory.age" --receipt "$inv/recovery-inventory.receipt" \
     --new-version --replaces-sha256 <recorded previous inventory ciphertext SHA-256>
   bash scripts/recovery-material-s3.sh download --item recovery-inventory --date <YYYY-MM-DD> \
     --receipt "$inv/recovery-inventory.receipt" --out "$run/recovery-inventory.downloaded.age" \
     --compare-with "$run/recovery-inventory.age"
   ```

   `--new-version` is refused unless the key exists, S3's stored SHA-256 checksum of its current version equals `--replaces-sha256`, and a new receipt is given. So it can only add a version on top of the exact inventory being replaced. The earlier version stays in S3 as a noncurrent version under the `recovery/` lifecycle; the inventory records it as **Previous inventory object** and **Previous inventory ciphertext SHA-256**.
4. **Copy the exact-version downloaded ciphertext (`recovery-inventory.downloaded.age`, verified in step 3) to Recovery A, then to Recovery B**, as in [Offline copies](#offline-copies-on-recovery-a-and-b). If an offline plaintext copy is also required, copy `recovery-material-inventory.md` from the tmpfs straight to the recovery media in the same way. Never stage it through any other location.
5. **Clean up the inventory tmpfs and check:**

   ```bash
   rm -f -- "$inv/recovery-material-inventory.md"
   sudo umount "$inv" && sudo rmdir "$inv"
   findmnt --mountpoint "$inv"                     # must print nothing
   test ! -e "$inv" && echo "inventory tmpfs: removed"
   ```

   Then stop the WSL keep-alive. **Leave `$run` as it is.** Its cleanup waits until both offline copies are verified; see [Workstation run cleanup](#workstation-run-cleanup-after-both-offline-copies).

### Updating an existing inventory

Use this in place of step 2 when a run changes items that the previous inventory already records. The new inventory starts from the previous one. **It decrypts the previous inventory on the workstation, which needs its own explicit approval.** The plaintext exists only inside the inventory tmpfs from step 1, and `age` reads the passphrase only at its own `/dev/tty` prompt.

Two values must be explicitly approved for the run before it starts. They are written nowhere else:
- **the identity-archive path**: one fixed path to the passphrase-encrypted identity archive. Its expected SHA-256 is the archive value in [The age identity](#the-age-identity);
- **the previous inventory ciphertext**: the exact-version downloaded ciphertext of the inventory being replaced, kept from its run or copied from its verified offline copy. Its expected SHA-256 is the inventory ciphertext SHA-256 recorded for that run in the [validation record](../validation/encrypted-recovery-material.md). It must not be inside `$inv` or `$run`.

1. **Gates.** Run these in the same WSL shell as step 1, in an interactive terminal:

   ```bash
   pgrep -fx 'sleep 14400'                         # the keep-alive (prerequisite 3) must still be running
   swapon --show                                   # must print nothing
   findmnt -no FSTYPE --mountpoint "$inv"          # must print: tmpfs
   stat -c '%a %U' "$inv"                          # must print: 700 <your user>
   umask 077
   archive=<approved identity-archive path>
   prior=<approved path of the previous inventory ciphertext>
   ```

   Stop if any check differs. Without the keep-alive, WSL can shut down and lose the tmpfs mid-update.
2. **Decrypt the previous inventory into the tmpfs:**

   ```bash
   bash scripts/recovery-material.sh decrypt-inventory --inventory-dir "$inv" \
     --ciphertext "$prior" --ciphertext-sha256 <recorded previous inventory ciphertext SHA-256> \
     --identity-archive "$archive" --archive-sha256 <identity-archive SHA-256 from The age identity>
   ```

   It runs as you, not through `sudo`. Before decrypting, it refuses:
   - an inventory directory that is not a mode `700` tmpfs mount point owned by you;
   - active swap, or no terminal for the passphrase prompt;
   - an existing `previous-inventory.md` or `recovery-material-inventory.md`;
   - an input that is not a regular file, is or lies under a symbolic link, is inside the tmpfs, or differs from its expected SHA-256 and header (one X25519 stanza for the ciphertext, one scrypt stanza for the archive).

   The checks apply to private copies in the tmpfs, which are what `age` reads; the originals are only read. Then `age` prompts for the passphrase and writes `$inv/previous-inventory.md`. The helper requires a nonempty, singly linked, mode `600` regular file that passes the inventory check, and otherwise removes it. It removes its copies on exit, including after `INT`, `TERM` or `HUP`. It prints only check results, the output path and `result: PASS`. It prints nothing from the plaintext and no version ID.
3. **Build the replacement inside the tmpfs**, with the same editor settings as step 2:

   ```bash
   install -m 0600 -- "$inv/previous-inventory.md" "$inv/recovery-material-inventory.md"
   vim -n -i NONE -c 'set nobackup nowritebackup noundofile' "$inv/recovery-material-inventory.md"
   ```

   In the editor:
   - set **Inventory date** to this run's date;
   - set **Previous inventory object** to the exact object key of the inventory being replaced, `recovery/recovery-inventory/<previous YYYY-MM-DD>.age`. It may equal this run's key for a same-date update;
   - set **Previous inventory ciphertext SHA-256** to the recorded previous inventory ciphertext SHA-256, the value given to `decrypt-inventory`;
   - add any row the template has and the previous inventory lacks, such as the **Interim manual p2 snapshot copy** rows (`not made` where nothing was made);
   - update the rows of the items this run changed, reading any version ID from its receipt inside the editor (for example with `:r`);
   - mark a replaced item's earlier entry as superseded rather than deleting it.

   Never display, search, page or copy either plaintext file, and never open it in any other editor or in Windows. Version IDs stay inside the editor and the tmpfs.
4. **Validate the replacement:**

   ```bash
   python3 scripts/validate-recovery-material.py --check-inventory "$inv/recovery-material-inventory.md" \
     --previous-key recovery/recovery-inventory/<previous YYYY-MM-DD>.age \
     --previous-sha256 <recorded previous inventory ciphertext SHA-256>
   python3 scripts/validate-recovery-material.py --scan "$inv/recovery-material-inventory.md"
   ```

   `--check-inventory` must print `PASS`. It requires:
   - a regular file;
   - no secret-shaped content;
   - every required inventory row and every replacement row, with no template placeholder left;
   - **Previous inventory object** equal to the given key;
   - **Previous inventory ciphertext SHA-256** equal to the given SHA-256.

   Like `--scan`, it prints only path, line number and rule name, never a value.
5. **Remove the previous plaintext before encrypting:**

   ```bash
   rm -f -- "$inv/previous-inventory.md"
   test ! -e "$inv/previous-inventory.md" && echo "previous plaintext: removed"
   ```

   `encrypt` refuses the inventory while `previous-inventory.md`, or a decryption copy, is still beside it.
6. **Only then continue with step 3**, passing `--identity-archive "$archive"` to `verify`, then steps 4 and 5.

The previous inventory ciphertext is never overwritten, moved or deleted. `decrypt-inventory` only reads it, and `encrypt` writes only a new file in `$run`, never over an existing path. The [workstation run cleanup](#workstation-run-cleanup-after-both-offline-copies) names it with `--keep` to confirm that it is unchanged, and only after both recovery devices have verified the exact-version downloaded replacement.

## Offline copies on Recovery A and B

Only one recovery device is connected at a time. Copy and check sequentially, from Windows PowerShell. Use `\\wsl.localhost\Ubuntu\...` for the WSL source path, and never mount the recovery media inside WSL.

For each device in turn (Recovery A first; Recovery B when it is next available):

1. Connect only that device and unlock it at the BitLocker prompt. Note its drive letter for this session only; never record it.
2. Copy the exact-version downloaded ciphertext to a **new, timestamped name**, and check it against the SHA-256 recorded by `encrypt`. The download comparison reported `MATCH`, so the two are byte-identical.
   - The name is `recovery-inventory-<YYYY-MM-DD>-<YYYYMMDDTHHMMSSZ>.age`: the inventory date, then the UTC time at which this inventory version was encrypted, as recorded in the evidence. Recovery A and Recovery B therefore hold the same name for the same version, and two inventories with the same date never share a name.
   - The copy is opened with `CreateNew`, which fails if the name exists in any form. An earlier copy on the device, such as `recovery-inventory-2026-10-29.age`, is never replaced, renamed, moved or removed.

   ```powershell
   $src = '\\wsl.localhost\Ubuntu\home\<user>\hc-recovery\run-<YYYY-MM-DD>\recovery-inventory.downloaded.age'
   $dst = '<drive>:\home-cluster\recovery-inventory-<YYYY-MM-DD>-<YYYYMMDDTHHMMSSZ>.age'
   $in = [IO.File]::OpenRead($src)
   try {
     $out = [IO.File]::Open($dst, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
     try { $in.CopyTo($out) } finally { $out.Dispose() }
   } finally { $in.Dispose() }
   (Get-FileHash -Algorithm SHA256 -LiteralPath $dst).Hash -eq '<recorded ciphertext sha256>'   # must print True
   ```

   If `CreateNew` fails because the name exists, stop: change nothing on the device. If the copy is interrupted or the check prints `False`, the device stays pending. Removing the incomplete file, by its exact name only, needs separate approval, and the copy is then repeated under the same name.

3. Lock the device (`manage-bde -lock <drive>:`), eject it, and disconnect it before connecting the other.

If a device is not available during the run, usually Recovery B, its copy stays pending. Record only "Recovery A: pending" or "Recovery A: verified", and likewise for Recovery B, with the date, in the evidence. Never record a drive letter, physical location, device serial or holder.

### Workstation run cleanup (after both offline copies)

**Do not run the workstation run cleanup until Recovery A and Recovery B have both verified the exact-version downloaded inventory ciphertext.** For each device, step 2 must have printed `True` for its copy of `recovery-inventory.downloaded.age`, and the device must then have been locked and ejected.

**If either device is pending or unavailable, keep the entire run directory**, with both inventory ciphertexts, exactly as it is:
- do not run `cleanup` on it, and do not remove any file from it, even one unrelated to the pending copy;
- do not move or copy its inventory ciphertext into `~/hc-recovery`, beside the retained Stage 2 ciphertexts, or anywhere else on the workstation;
- record the device as pending. When it is next available, set `run` to the same directory in a new shell, without running `start-run`. Copy and check as in steps 1 to 3 above, and only then run this cleanup. The inventory tmpfs and the keep-alive are not needed for this.

Once both devices are verified:

```bash
bash scripts/recovery-material.sh cleanup --dir "$run" \
  --remove k3s-server-token.age --remove k3s-server-token.downloaded.age \
  --remove grafana-admin.age --remove grafana-admin.downloaded.age \
  --remove recovery-inventory.age --remove recovery-inventory.downloaded.age \
  --keep ~/hc-recovery/<retained ciphertext>
```

Name with `--remove` exactly the files this run put in `$run`. For the `encryption-config` run, they are `encryption-config.age`, `encryption-config.downloaded.age`, `recovery-inventory.age` and `recovery-inventory.downloaded.age`. For the [interim manual p2 snapshot copy](#the-interim-manual-p2-snapshot-copy-stage3-p2-snapshot), they are `stage3-p2-snapshot.age`, `stage3-p2-snapshot.downloaded.age`, `recovery-inventory.age` and `recovery-inventory.downloaded.age`. Name with `--keep`, one per option, every ciphertext kept from an earlier run, such as each Stage 2 copy directly under `~/hc-recovery`. After an [inventory update](#updating-an-existing-inventory), also pass `--keep "$prior"`, so that `cleanup` confirms the previous inventory ciphertext is unchanged. `cleanup` must print `run directory: absent`, `retained unchanged:` for each kept file, and `result: PASS` ([Run directories](#run-directories-and-scoped-cleanup)).

## Stop conditions

Stop the run, record the outcome only, and do not improvise if:

- any helper guard fails: the wrong or missing `age`, tracing on, active swap, a tmpfs that can't be mounted or verified, a missing terminal, a source with group or other permissions, or an output directory that is shared or is a link;
- `cmp -s` reports `DIFFER` or `ERROR`, or a ciphertext SHA-256 changes in transit or on recovery media;
- `check-role` prints `FAIL`;
- `AccessDenied` on a designed action. Do not widen permissions, and do not switch to `AdministratorAccess`;
- the inventory tmpfs checks differ from their expected output;
- `start-run` or `cleanup` refuses, or `cleanup` prints `result: ERROR`. Remove nothing by hand, and never fall back to a wildcard or a recursive delete;
- an offline copy is pending or unverified when the workstation run cleanup is due. This stop is mandatory: do not run the cleanup, and keep the entire run directory until Recovery A and Recovery B have both verified the exact-version downloaded inventory ciphertext ([Workstation run cleanup](#workstation-run-cleanup-after-both-offline-copies));
- any secret-shaped value appears in a terminal, log, evidence file or Git. Treat it as compromised and follow [SECURITY.md](../../SECURITY.md): rotate the token or password, then re-encrypt.

## Partial failure

- **Upload succeeded, verification failed:** the object stays as an unverified version. Mark it unverified in the inventory, fix the cause, and re-run with `upload --new-version --replaces-sha256 <ciphertext SHA-256 of the current version> --receipt <new receipt>`. The routine role cannot delete objects.
- **Download or comparison failed:** a failed or rejected download leaves nothing at `--out`. Re-run step 4 from the same version ID. If it still fails, treat the uploaded version as unverified.
- **Inventory tmpfs lost after an upload** (for example, WSL shut down): the uploaded version is intact, but its receipt is gone. Stop, start the keep-alive, and recreate the tmpfs. Then either:
  - upload again with `--new-version`, `--replaces-sha256` set to the recorded ciphertext SHA-256 of the version already uploaded, and a new receipt, and repeat the comparisons; or
  - with separate approval, rebuild the receipt from read-only S3 metadata, as on 2026-10-29. The listing must hold exactly one version and no delete marker for the exact key, the latest version, the recorded ciphertext size, and a `ChecksumSHA256` equal to the recorded ciphertext SHA-256. Write the receipt in the helper's two-line format, exclusively, mode 600, without printing the version ID. Prove it with `download --receipt … --compare-with` against the original ciphertext, which must report `result: MATCH`, and record the reconstruction as a deviation.
- **Verification interrupted:** `verify` removes its tmpfs files and unmounts its tmpfs, keeps the original failure status, and reports any cleanup failure. Confirm that `findmnt -t tmpfs -S recovery-material` prints nothing before retrying.
- **Stopped part-way through:** run the per-host cleanup on every host already used, and the inventory cleanup if its tmpfs exists, before anything else. Name with `--remove` only the run files that exist. The workstation run cleanup still waits until both offline copies are verified.

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
| Run directories and scoped cleanup | CI and any Linux host with bash (group E), as in production, with no test mode | `start-run` (mode `700` and marker; an existing directory, a relative path and a symbolic-link parent refused); `cleanup` removing only the named run files and the directory while each retained ciphertext beside it stays byte-identical; refusal, with nothing removed, of a retained ciphertext copied into the run directory (named or not), a `..` name, a wildcard or unrelated name, the retained directory itself, a duplicate or missing name, symbolic and hard links to a retained ciphertext, a symbolic-link directory, path, marker or kept file, a kept file inside the run directory, an unexpected subdirectory and a directory that is not mode `700`; and mutants with the timestamp, exact-contents, name or marker guard disabled, each caught |
| Inventory update (`decrypt-inventory`) | CI and any Linux host with bash (group F); decryption cases need real `age` v1.3.2, which CI requires. The scanner's mutation tests cover the runbook procedure | A synthetic previous inventory with a throwaway identity: decryption only to `previous-inventory.md`, mode `600` and byte-identical, with the private copies removed; refusal, with nothing left behind, of a wrong or malformed SHA-256, an archive without one scrypt stanza, a ciphertext with two stanzas, symbolic links and symbolic-link paths, a relative path, a missing file, an input inside the tmpfs, a directory that is not mode `700` or is a link, an existing previous plaintext or replacement, and, outside test mode, a directory that is not a tmpfs; removal of the plaintext after a wrong identity, a failed inventory check, an empty result and `TERM`; `encrypt` refusing the inventory beside a leftover previous plaintext or copy, and never overwriting the previous ciphertext; mutants with the SHA-256, plaintext-removal, tmpfs or encrypt guard disabled, each caught. The runbook checks reject a decryption outside the helper or the tmpfs, missing keep-alive, swap or tmpfs gates, plaintext output or an unsafe editor, a missing validation or plaintext removal before encryption, a write to or removal of the previous ciphertext, and a run cleanup before both offline copies |
| Limited Windows probes | Run once by hand with `age.exe` v1.3.2 and a throwaway key | That real v1.3.2 X25519 ciphertext has exactly one stanza and passes the header check, and one encrypt/decrypt round trip. They do not run the Linux helpers |

**Untested by any of them:**
- a real `root:root` source and credential directory, and the production path itself: test mode cannot run as root, so ownership is checked against overrides, and the path through the test-only expected-source override. The tests never access `/var/lib/rancher/k3s/server/cred`;
- production `sudo` and `runuser`;
- the tmpfs mount;
- the swap check;
- the `/dev/tty` passphrase prompt with a real passphrase-encrypted archive;
- SSH, AWS and S3.

These are covered only by the live-pass gates above and by the live run.
