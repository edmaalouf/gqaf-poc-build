# PAIR — local prototype

PAIR is a **local development prototype**, not a production dating service. It
has a Flutter Android/iOS client, a one-page website that hands off to the
native app, a Flask API, a SQLite database and a separate matching worker.
The mobile app and backend are prototypes, not store-ready products. Do not
deploy them publicly or enter real or sensitive personal information.

## Technologies

- Flutter/Dart, Material UI, platform secure storage and the native image
  picker for Android and iOS.
- Python, Flask and SQLite for the current API and persistent data; Pillow
  re-encodes photos. A separate Python worker generates matching cycles.
- Flutter's test runner and Python unittest/coverage for tests.

A production replacement still needs a multi-user database such as PostgreSQL,
reliable queue/worker operations, managed storage and
backups, TLS, monitoring, abuse controls, and independent security and privacy
review. These are recommendations, not components already provided here.
See [PRODUCTION-HANDOVER.md](PRODUCTION-HANDOVER.md) for the release work,
verification gates and operational handover.

## Run locally (Windows)

Requires Python 3.10 or later (3.12 recommended). From the repository root in
PowerShell:

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
.\.venv\Scripts\python -m flask --app pair.app run --host 127.0.0.1 --port 5000
```

In a second PowerShell window, from the same directory:

```powershell
$env:PAIR_TIMEZONE = 'UTC' # IANA timezone, e.g. America/New_York
.\.venv\Scripts\python -m pair.worker
```

Open `http://127.0.0.1:5000` for the mobile-app handoff page. The API and worker
default to `instance\pair.sqlite3`; set `PAIR_DB` to the same path in both
terminals to change it. The API uses a random session secret on each restart unless
`PAIR_SECRET` is set in its environment; restarting invalidates sessions when
the secret is not set. Never put a real secret into this repository.

Authentication sessions are stored as hashes in the database, expire after
seven days, and are revoked when a user signs out, is suspended, or is deleted.
Startup adds the required session, activity and privacy fields without deleting
existing data. Restart the API and worker together after an update. For an HTTPS
test environment, set `PAIR_SECURE_COOKIES=1` and provide an explicit,
cryptographically random `PAIR_SECRET` of at least 32 bytes. Keep the same
secret across API processes, outside the repository. Secure cookies alone do
not make this prototype safe to expose publicly.

Authentication has a local, database-backed sliding-window limit per client
IP and endpoint: five registration or verification-code requests and ten
login, activation, verification or account-deletion attempts per 15 minutes. All attempts,
including invalid requests, count. Limited requests return HTTP 429 with a
`Retry-After` header. The database stores keyed hashes rather than raw IP
addresses and removes expired attempts on subsequent authentication requests.
Processes share limits only when they use the same database and `PAIR_SECRET`;
the default random secret resets limits on restart. The server ignores
forwarded IP headers: behind a proxy, users may share a single limit. Do not
trust forwarded headers without a securely configured trusted proxy. This
per-IP prototype limit does not stop distributed attacks or replace production
abuse protection, monitoring and rate limiting.

Registration requires an authenticated SMTP service using implicit TLS. Set
`PAIR_SMTP_HOST`, `PAIR_SMTP_USERNAME`, `PAIR_SMTP_PASSWORD`, and
`PAIR_SMTP_FROM` in the API process environment; `PAIR_SMTP_PORT` defaults to
465. Store credentials outside the repository. Without valid configuration or
if delivery fails, registration returns an error and does not log the code.
Use only a test mailbox with this prototype.

Registration returns the same response for new and existing accounts. A new
address receives a code valid for 30 minutes. Enter it in the app, choose your
password and confirm you are an adult. An unexpired request cannot be replaced;
after it expires, request a new code. Previously issued console registration
codes no longer activate accounts. On first startup after this update, existing
accounts are marked unverified because console codes did not prove mailbox
ownership. They can sign in and request a new emailed code under Settings before
re-entering matching. Their profile data and conversations are retained.
Create a profile and submit a JPEG or PNG. In a third terminal, review submitted photos using the local-only
moderation commands:

```powershell
.\.venv\Scripts\python -m flask --app pair.app moderate photos
.\.venv\Scripts\python -m flask --app pair.app export-photo 1 .\review-photo.jpg
# Inspect the exported image, then delete the exported copy.
.\.venv\Scripts\python -m flask --app pair.app moderate approve-photo 1
# Alternatively: moderate reject-photo 1
.\.venv\Scripts\python -m flask --app pair.app moderate reports
# After review: moderate suspend 1, or moderate resolve-report 1
```

The numeric argument for `resolve-report` is the **report ID**; other actions
use a user ID. Commands require direct access to the local database and are
not a multi-user admin interface. The temporary exported image is not deleted
automatically. User-entered coordinates can be approximate city coordinates;
they are used to calculate mutual distance, and are not returned in match
cards. Card distance is estimated from coordinates rounded to a 0.25-degree
grid, then rounded to 25 km; it can differ from the distance used to match.
Eligibility uses a 0.05-degree grid plus a conservative approximately 11.1 km
margin, so repeated eligibility checks cannot reveal coordinates within a
grid cell. The margin prevents matches outside the requested radius due to
rounding but can exclude nearby eligible people; radii below the margin yield
no matches. Location updates and account creation still need production abuse
controls, and a grid does not provide complete location privacy.
Free-text bios and interests are public to introductions, so users must avoid
entering addresses or other sensitive information there.

## Flutter mobile app

The native Flutter client is in `mobile`. Install Flutter 3.50.1, then install
Android Studio, the Android SDK, an emulator or USB-connected device, and a
supported JDK (21 recommended), and
accept the SDK licenses using `flutter doctor --android-licenses`. Run
`flutter doctor` and address its Android toolchain errors. From PowerShell,
start the API above on `127.0.0.1:5000`, start an Android emulator, then:

```powershell
cd mobile
flutter pub get
flutter run -d android --dart-define=PAIR_API_URL=http://10.0.2.2:5000
```

On Windows, if the Flutter package cache and the project are on different
drive letters, Kotlin incremental compilation can fail with “different
roots”. In the `mobile` directory, set
`$env:PUB_CACHE = Join-Path (Get-Location) '.pub-cache'`, run `flutter pub get`
again, and retry the build. If the error persists, remove the failed plugin's
generated `mobile\build\<plugin>\kotlin\compileDebugKotlin` cache and retry;
an earlier cache or Gradle daemon can still contain the old drive's paths.
For a retry in the current PowerShell session, use
`$env:GRADLE_OPTS = '-Dorg.gradle.daemon=false -Dorg.gradle.configuration-cache=false'`
to start a fresh Gradle process. The local package cache is ignored by Git.

`10.0.2.2` is the Android emulator's route to the host's loopback interface;
it is not the address of a physical phone. Debug HTTP is deliberately
restricted to loopback/emulator hosts and Android debug builds. For an iOS
simulator or a physical device, use a reachable HTTPS API with a certificate
trusted by the device; iOS transport security remains enabled even in debug.
Do not expose the prototype API to an untrusted network to test it.

For a physical Android device connected by USB, a local **debug-only** option
avoids exposing the server on the network. Enable USB debugging, authorize
the computer on the device, keep the API running on the host's loopback
address, and run:

```powershell
adb devices
adb reverse tcp:5000 tcp:5000
cd mobile
flutter run -d <device-id> --dart-define=PAIR_API_URL=http://127.0.0.1:5000
```

`adb reverse` forwards the device's loopback port to the development computer;
reconnect and run it again if the USB connection is interrupted. This does not
apply to release builds, which require HTTPS and a trusted certificate. A
remote backend would need its own reachable, properly configured HTTPS
endpoint and production infrastructure; the existing Flask/SQLite service
must not be deployed publicly in its current form.

An APK can also be built and installed from `mobile` after setting up
`adb reverse`:

```powershell
flutter build apk --debug --dart-define=PAIR_API_URL=http://127.0.0.1:5000
adb install -r build\app\outputs\flutter-apk\app-debug.apk
```

It is debug-signed, uses a placeholder application ID, and is not suitable for
distribution.

iOS development requires macOS, Xcode, CocoaPods and an Apple development
team. On a Mac, install the dependencies, open `ios/Runner.xcworkspace` in
Xcode, configure signing, and run `flutter run -d ios` with an HTTPS
`PAIR_API_URL`. Flutter displays UTC server timestamps in the device's local
timezone. Mobile sessions are stored in platform secure storage, separately per
API origin; photos are loaded through authenticated requests.

### Preparing another device or development computer

The supported clients are Android and iOS, not arbitrary desktop devices.
Clone the repository onto the development computer. Install Python and the
backend dependencies as above, and install Flutter plus the relevant platform
tools. Run `flutter doctor` and `flutter devices` to confirm the toolchain and
target device. In `mobile`, run `flutter pub get`.

On the computer hosting the backend:

1. Configure the `PAIR_SMTP_*` variables described above in the API terminal;
   SMTP must use implicit TLS and authenticated delivery to a test mailbox.
   Without SMTP, registration fails rather than displaying a code locally.
2. Start the API and worker in separate terminals with the same `PAIR_DB`.
   Set `PAIR_TIMEZONE` on the worker. Use an isolated test database and do not
   use real personal data. Changing computers does not copy an existing SQLite
   database or accounts; provision a new test database or transfer one only
   through an approved secure process.
3. Register with a test mailbox, enter the emailed code, complete onboarding,
   and have an operator approve the photo with the commands above. Populate
   additional mutually eligible test accounts before the first matching cycle.
   Once a cycle exists, new accounts wait until the next cycle.
4. On an Android emulator, use the `10.0.2.2` command above. On a USB Android
   phone, authorize USB debugging and use `adb reverse` and the loopback
   command above. Both the API and worker must remain running.
5. For an iOS simulator or phone, use a Mac with Xcode, CocoaPods and a
   configured development team. Supply a reachable HTTPS API origin whose
   certificate the device trusts, and run from `mobile`:

   ```text
   flutter run -d <device-id> --dart-define=PAIR_API_URL=https://your-test-api-origin
   ```

   The current backend does not provide an HTTPS deployment or hardened
   hosting. An appropriately secured, isolated test environment must be set
   up independently; never expose the development Flask server to the public
   internet. The iOS build and device workflow have not been verified here.

If a device cannot connect, check the selected device with `flutter devices`,
the API and worker processes, the API origin, certificate trust, SMTP delivery,
and, for USB Android, `adb devices` and `adb reverse --list`. A registration
code is delivered to the configured mailbox; it is never printed by the app.

### Deployment and distribution

**Do not deploy the current backend publicly or distribute the app to real
users.** Follow the production handover first. After its security, hosting,
privacy and operational gates are satisfied:

1. Provision and verify a separately managed HTTPS backend and worker, durable
   database and storage, SMTP, secrets, backups, monitoring and moderation.
   Set an explicit stable `PAIR_SECRET` and `PAIR_SECURE_COOKIES=1` if retaining
   this API; ensure the production architecture addresses the limitations in
   the handover. Never expose Flask's development server.
2. Set the Flutter `PAIR_API_URL` to the verified HTTPS origin. Give Android
   and iOS their own permanent identifiers, release signing and store
   configuration. Keep signing keys and credentials outside the repository.
3. Only after configuring Android release signing, build from `mobile` with
   `flutter build appbundle --release --dart-define=PAIR_API_URL=https://your-api-origin`
   and follow Google Play's internal testing and publishing process.
4. On macOS, configure Apple signing and provisioning in Xcode. After a
   successful device and archive validation, build with
   `flutter build ipa --release --dart-define=PAIR_API_URL=https://your-api-origin`
   and follow TestFlight and App Store Connect procedures. These release
   commands are unverified and require the missing release configuration.

Before any Android or iOS release, replace the `com.example` application and
bundle identifiers, provide real app icons, configure Android release signing
with a private keystore kept outside version control, and configure Apple
signing, entitlements and provisioning in Xcode. Use HTTPS
`--dart-define=PAIR_API_URL=https://your-api-origin` for profile/release builds.
The client rejects non-HTTPS production origins, redirects, and production
session cookies without the Secure flag. The backend requires explicit
`PAIR_SECURE_COOKIES=1` and has no production HTTPS configuration:
hardening the backend and all items below is required before release. Validate
platform builds, permissions, accessibility, privacy disclosures, signing and
store policies on actual devices and current platform toolchains.

## Matching and safety behavior

- The worker polls every minute and identifies the latest Monday at 09:00 in
  `PAIR_TIMEZONE` (default UTC), including daylight-saving changes. Timestamps
  are stored in UTC and displayed in the device's timezone.
- It takes an atomic SQLite write transaction, checks completion, applies both
  users' preferences and exact lifestyle dealbreakers, scores all eligible
  pairs and independently saves each user's top three. Random tie-breaking is
  fixed in the saved result. A unique cycle ID makes retries idempotent.
- An approved photo, verified account, adult birth date, complete profile and
  preferences, all 64 answers, and activity within the last 90 days are
  required. Authenticated requests and sign-in update activity. Accounts
  without a recorded activity timestamp use their creation time until their
  next sign-in. Matches are rechecked for
  current eligibility and safety before display or messaging; removals do not
  trigger midweek replacements. Passing permanently excludes the pair in this
  prototype. Open reports and blocks immediately hide both sides.
- Both users must like each other before a conversation can be created.
  If someone likes a person who did not receive them in their own top three,
  the recipient can respond to a separate private invitation during that
  cycle. These invitations do not replace or change the top three; they
  disappear at the next cycle, and safety and eligibility checks still apply.
  Likes from older cycles are not reissued as invitations.
  Unmatching deletes the conversation and permanently passes the other user.
  Questionnaire responses are never returned to other users.
- Settings can pause a profile. Pausing hides introductions and prevents
  access to conversations for both people, but preserves existing selections
  and messages. Resuming restores eligible existing conversations; there is
  no midweek backfill for selections missed while paused.
- Reports persist after account deletion with the relevant account ID removed;
  their free text can still contain identifying information. Photos are
  re-encoded to remove image metadata. Data is **not encrypted at rest**.

The worker must be kept running. If started late it generates the current
week's cycle at startup, using data at that time; it does not reconstruct
missed historical cycles. There is no production job supervisor or monitoring.
The first empty cycle is still final for that week. To try matching immediately
with newly created test accounts, start the worker after their onboarding and
photo approval, before any cycle has been generated.

## Important limitations

This prototype intentionally does not claim production security or completeness:

- Email delivery requires an independently configured SMTP service; live
  delivery and operational protections have not been verified. Existing
  console-verified accounts require mailbox re-verification. There is no identity or
  age verification beyond self-attestation and birth date. There is
  no password recovery, distributed session revocation service,
  distributed abuse protection, or hardened production authentication.
- No production HTTPS, encrypted storage, backups, retention policy, verified
  photo moderation service, moderation staffing, automated abuse detection,
  audit-grade administrative controls, or operational incident process.
- No push notifications, real-time messaging, configurable pass expiry,
  granular profile visibility controls, admin dashboard, or question editor.
  Questions are source-controlled with stable IDs; changing question meaning
  requires versioning rather than silently reinterpreting existing answers.
- Free-text lifestyle dealbreakers are exact, case-sensitive matches. The
  four intention choices include “other” but do not collect a custom
  description. Only one photo is supported.
- The scheduler relies on a running single-host process and SQLite, not the
  requested PostgreSQL/Redis/BullMQ architecture. It is not appropriate for
  production or multi-host operation.

## Tests

Install the development dependencies and run the backend suite with branch
coverage. The report enforces a 90% minimum for the Python backend:

```powershell
.\.venv\Scripts\python -m pip install -r requirements-dev.txt
.\.venv\Scripts\python -m coverage run -m unittest discover -s tests -v
.\.venv\Scripts\python -m coverage report
```

The tests cover question counts, scoring, timezone and daylight-saving
boundaries, incomplete accounts, mutual preferences and dealbreakers, empty
and limited results, ties, retry and rollback, blocks, reports, moderation,
mutual interest, authorization, session revocation, input errors and account
deletion.

Run the mobile handoff page test separately:

```powershell
.\.venv\Scripts\python -m unittest discover -s tests-ui -v
```

The website intentionally contains no browser app; the only supported
experience is the native Flutter mobile client.

Run mobile static analysis and Flutter unit/widget tests:

```powershell
cd mobile
flutter analyze
flutter test
```

These tests do not establish 90% mobile scenario coverage, and do not replace
Android/iOS device, accessibility, security, integration or release testing.
