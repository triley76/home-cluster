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

Before committing, inspect staged content:

```bash
git diff --cached
```

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
