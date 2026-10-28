# Security Policy

## Supported state

This repository is an evolving lab and portfolio project. It is not presented as a production support offering.

## Secret-handling requirements

Do not commit:

- Passwords, API tokens, or cloud access keys
- Private keys or certificates containing private material
- Kubeconfig files or service-account tokens
- Plaintext Kubernetes Secret values
- Terraform state or unreviewed variable files
- Credentials embedded in URLs, manifests, scripts, or documentation
- `age` private identities, identity-archive passphrases, or passphrase hints
- The K3s server token, or any hash or fingerprint of it
- The K3s secrets-encryption configuration (`encryption-config.json`), any key or key name from it, or any hash or size of it
- `age` ciphertext of recovery material, or a filled recovery-material inventory

Before committing, inspect staged content:

```bash
git diff --cached
```

The public `age` recipient in `recovery/` is not a secret, but reviews in this repository do not print it. Exclude it from the diff and check it by format instead:

```bash
git diff --cached -- . ':(exclude)recovery/home-cluster-recovery-recipient.txt'
git show :recovery/home-cluster-recovery-recipient.txt | python3 scripts/validate-recovery-material.py --check-recipient -
python3 scripts/validate-recovery-material.py
```

The repository scan reports findings by path, line number and rule name only, never the matched text.

Repository history and current tracked content should be scanned before changing repository visibility.

## Reporting a vulnerability

Use GitHub's private vulnerability-reporting or security-advisory capability when it is available for this repository. Do not open a public issue containing credentials or exploitable details.

If a secret is committed:

1. Treat it as compromised.
2. Revoke or rotate it immediately.
3. Remove it from active configuration.
4. Assess and, when appropriate, rewrite Git history.
5. Validate that dependent systems use the replacement credential.

Removing a secret from the latest commit alone is not sufficient.
