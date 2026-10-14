# Stage 1: AWS backup foundation

These CloudFormation templates implement only the AWS foundation described in
`docs/design/backup-disaster-recovery.md`. They do not create access keys,
upload data, or change the cluster.

## Deployment order

1. Choose a globally unique bucket name of the form
   `home-cluster-backup-<random-suffix>`. Do not include an AWS account ID.
2. From the member-account administrator SSO profile, validate and deploy
   `member-account.yaml` in `us-east-1` with `CAPABILITY_NAMED_IAM`.
3. Wait at least 15 minutes after versioning is first enabled before the first
   object upload, as recommended by AWS.
4. From the management-account administrator SSO profile, obtain the IAM
   Identity Center instance ARN and the user or group principal ID, then deploy
   `management-account.yaml` in the IAM Identity Center home region.
5. Verify the bucket controls, lifecycle, policy, IAM users, permission-set
   assignment, and the absence of access keys before proceeding.

Use parameters or protected local environment variables for account-specific
values. Never place account IDs, Identity Center identifiers, personal email
addresses, access keys, or generated parameter files in Git.

The routine permission set deliberately cannot alter bucket policy, encryption,
versioning, lifecycle, public-access protections, or delete the bucket. Any
rehearsal-only identity remains an administrator-created, time-bounded manual
action and is not managed by this stack.

Stack deletion is intentionally non-routine. The bucket and bucket policy are
retained, and the policy denies bucket deletion. Teardown requires a separately
reviewed destructive procedure that first preserves or deliberately removes all
object versions and then changes the deny policy.
