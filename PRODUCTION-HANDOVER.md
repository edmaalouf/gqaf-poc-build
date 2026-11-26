# PAIR production handover

## Status and release decision

**Not production-ready. Do not deploy publicly or use real personal data.**
PAIR is a Flutter Android/iOS prototype backed by Flask, SQLite and a polling
worker. The setup in [README.md](README.md) is for development. This handover
is a work plan and acceptance checklist, not evidence that the controls below
exist or that security, legal compliance or store approval is guaranteed.

The current Android build is debug-only, has a placeholder application ID and
has not been verified on a physical device. iOS build, signing and device
testing have not been verified. SMTP delivery has been tested with a mock, not
against a real mail service. Assign accountable owners, environments, dates
and evidence to every gate before any launch.

## Recommended target architecture

- Flutter Android and iOS clients communicate only with a managed HTTPS API
  using a trusted certificate. Terminate TLS at a hardened ingress and restrict
  internal service traffic; do not expose Flask's development server.
- Use a supported production application server, a managed relational
  database such as PostgreSQL, encrypted managed object storage for photos,
  a supervised durable job scheduler/worker and a transactional email service.
  These components are **not implemented** by the current SQLite prototype.
- Keep credentials, signing keys and encryption keys in a managed secrets/key
  system. Use separate development, staging and production environments,
  least-privilege service identities, restricted administrative access and
  audited infrastructure changes.
- Add centralized privacy-conscious monitoring, alerting and incident
  response. Do not log email codes, credentials, message contents, exact
  locations, questionnaire answers or other sensitive profile data.

## Work required before launch

### Identity and account protection

- Configure and verify real authenticated TLS email delivery, domain
  authentication and deliverability. Exercise mailbox verification, expiry,
  retries, outages and abuse controls end to end using test accounts.
- Existing prototype accounts created with console codes are marked unverified
  on migration and must request an emailed verification code in Settings.
  Preserve data during migration, validate the migration against a copy, and
  confirm unverified accounts cannot enter matching or messaging.
- Implement secure password recovery and account recovery, credential-stuffing
  defenses, distributed and account-aware rate limits, session lifecycle and
  revocation across instances, and monitoring of abusive authentication.
  Review enumeration and timing side channels. Plan secure credential rotation.
- Birth date and adult confirmation are self-attested, not identity or age
  verification. Obtain legal and safety guidance on appropriate age assurance.

### Privacy, safety and moderation

- Document data inventory, purposes, consent, retention, access, deletion,
  jurisdictional obligations and processor agreements with qualified counsel.
  Determine how reports, backups and legal holds interact with deletion; report
  free text can still identify a deleted account.
- Encrypt sensitive data and backups at rest with managed keys, enforce
  least-privilege database and object access, and regularly test restore,
  deletion and key rotation. Do not retain debug databases or logs containing
  personal data.
- Review location privacy against motivated adversaries and fake accounts.
  The current conservative grid reduces precision leakage but does not
  guarantee anonymity, and may exclude genuinely nearby users. Radii below
  approximately 11.1 km produce no matches. Validate the product trade-off,
  add abuse controls and commission an independent privacy review.
- Provide staffed photo and report moderation, escalation and appeals,
  suspension and reinstatement controls, audit trails, abuse detection and
  documented response times. Current CLI moderation is not an admin dashboard.
- Review consent and safety guidance, harassment and impersonation handling,
  block/report propagation, unauthorized messaging, data export and deletion,
  and storage access with an independent security assessment and penetration
  test. Remediate and retest findings before release.

### Matching, data and operations

- Migrate SQLite data to a supported multi-user datastore through a tested,
  reversible migration. Establish backups, retention, disaster recovery and
  documented recovery-time and recovery-point objectives. Current worker
  holds a SQLite write transaction and is not suitable for multi-host scale.
- Replace or harden the scheduler with durable jobs, unique cycle keys,
  concurrency control, retries, health checks and alerts. Verify Monday 09:00
  in the configured IANA timezone, daylight-saving changes, UTC persistence,
  downtime, duplicate invocations and recovery. No midweek backfill is allowed.
- Load-test pairwise scoring and capacity against expected user volumes. Verify
  mutual preferences, dealbreakers, activity, moderation and blocking on
  generation and access; test race conditions. Preserve independent top-three
  ranking, fixed weekly results and mutual-interest-only conversations.
- Version questionnaire content and answers so editing a question never
  reinterprets old responses. Deliver a controlled admin workflow if required.
  Current questions are source-controlled; there is no question editor.
- Define deployment rollback, database migration rollback, incident on-call,
  metrics, alert thresholds, service-level objectives and access reviews.
  Do not replace credentials with insecure hardcoded or shared values.

### Mobile release and accessibility

- Replace Android and iOS placeholder identifiers and launcher assets. Set up
  Android release signing with a protected keystore and Apple signing,
  provisioning and entitlements. Secure keys, verify release artifacts and
  document loss and rotation procedures.
- On current supported Android devices and macOS/Xcode/iOS devices, test clean
  installs, upgrades, interrupted onboarding, secure session storage, network
  failures, photo permission denial, deletion, blocking, messaging,
  accessibility, localization, screen sizes and offline/error states.
- Perform accessibility testing with TalkBack, VoiceOver, dynamic text,
  contrast and keyboard/focus behavior. Complete store privacy disclosures,
  content policies, age ratings, support links and internal testing.
- Validate the final HTTPS API origin, certificate chain and Secure cookie on
  real release builds. The client refuses cleartext release URLs and redirects.

## Required verification evidence

Keep reproducible results for each release candidate, including:

1. Automated backend, browser and Flutter tests, plus measured coverage and
   explicit scenario coverage for success, failure and edge cases. A percentage
   of code coverage does not prove 90% of all scenarios are covered.
2. End-to-end tests for real test-mailbox verification and delivery failure;
   migrations including existing accounts; authorization, account deletion,
   report/block propagation and unauthorized messaging.
3. Matching tests for exactly 64 questions, category weighting, mutual
   preferences, incomplete or inactive users, ties, fewer than three
   candidates, retries, concurrent schedulers, stable results, privacy and
   no backfill.
4. Independent security and privacy assessment, vulnerability remediation,
   dependency and infrastructure scanning, load tests, disaster-recovery
   exercise and rollback rehearsal. Preserve reports without exposing
   credentials or personal data.
5. Signed Android and iOS release artifacts tested on real devices, store
   review evidence and an explicit release approval from accountable owners.

## Release runbook outline

After all gates above are met, provision isolated staging and production
environments, deploy the managed datastore and backend, apply reviewed
migrations, configure HTTPS, secrets, email and worker scheduling, and verify
monitoring and backup restoration. Run smoke tests with approved test accounts
before enabling any real users. Build signed mobile artifacts using the verified
HTTPS API origin, complete internal store testing, and roll out progressively
with a documented rollback and incident contact. The current repository does
not yet provide a production deployment manifest or infrastructure automation.

See [README.md](README.md) for the commands that are currently supported for
local development and debug-device testing.
