# Remi for iPhone

Experimental native SwiftUI client for Remi, iOS 17+. This repository contains
only the iPhone application, synthetic tests and a macOS build workflow. It
connects to an existing Remi HTTPS backend; it does not contain backend code,
production credentials, account tokens or personal data.

## Build from Windows

Pushes to `main` affecting `ios/` trigger **iPhone native experiment** on a
GitHub-hosted macOS runner. It runs XCTest on an installed iPhone Simulator,
then builds a device IPA only if the tests pass. You can also use Actions →
iPhone native experiment → Run workflow.

- `iphone-simulator-test-results`: Xcode test evidence (`.xcresult`).
- `remi-iphone-unsigned`: `Remi-unsigned.ipa` and SHA-256 checksum.

An unsigned IPA must be personally signed before installation. A failed workflow
or simulator report is not a usable phone build. Actual build status belongs to
[GitHub Actions](https://github.com/ElysiaTheElysier/ios_remi/actions).

Verified build on 2026-10-04: [run 37189052422](https://github.com/ElysiaTheElysier/ios_remi/actions/runs/37189052422)
passed all 11 XCTest cases (zero failures) with Xcode 16.4 and successfully built
the unsigned iPhone IPA from commit `a277bfb65e097660ad287108a0b1bc38f7a9e6a2`.
The [IPA artifact](https://github.com/ElysiaTheElysier/ios_remi/actions/runs/37189052422/artifacts/11298413386)
expires on 2026-10-11. Physical installation, backend integration and locked-screen
wake detection have not yet been verified on a real iPhone.

## Install on your iPhone from Windows

1. Download/extract the successful `remi-iphone-unsigned` artifact.
2. Install [Sideloadly from its official site](https://sideloadly.io/) and follow
   its Windows prerequisites. Connect your iPhone by USB and trust the computer.
3. Select `Remi-unsigned.ipa`, your iPhone and your own Apple Account in that tool
   to sign and install. Never send Apple credentials to this repository/chat.
4. Follow iPhone prompts to trust the developer profile. If required enable
   [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
   under Privacy & Security, restart and confirm.
5. Open Remi and enter your matching HTTPS API endpoint (`…/api/v1`), Supabase
   project URL and public publishable/anon key. Sign in with your Remi account.
   Never use a service-role key. Verify text chat and explicit proposal confirmation.

[Sideloadly documents](https://sideloadly.io/faq) 7-day validity for free-account
signing and refresh requirements. Installation depends on your iOS/account/tool
versions and remains unverified until tested on your physical phone.

## Enable Hey Remi, including screen lock/background

1. In [Picovoice Console](https://console.picovoice.ai/), obtain an AccessKey and
   generate/export a **Hey Remi** `.ppn` keyword model for **iOS, SDK v4**.
   Provider account/licensing conditions apply; no model or subscription has
   been created by this repository.
2. Put the model in Files on your iPhone. In Remi → Settings → Hey Remi, import
   it and enter the AccessKey on the phone. The key is stored in device-only
   Keychain, never embedded in the public source or IPA.
3. Enable listening and accept the continuous microphone explanation. Say
   “Hey Remi”, pause briefly, then speak your Vietnamese command and stop.
   About 1.5 seconds of quiet submits; the command limit is 30 seconds. A silent
   activation cancels after 8 seconds without an upload.
4. Unlock to review/edit/confirm proposals. Wake detection never confirms a
   task/event/note/expense/debt/reminder write. Stop listening in Settings.

Wake processing is local. Only the subsequent command goes to backend STT/chat.
Background/locked-screen listening needs an actively enabled audio session;
force quit, system termination and audio interruptions can stop it. Open Remi
and explicitly enable again after interruption/relaunch. Silence metering is
approximate; device testing must establish accuracy, false activations, noise
tolerance and battery cost. This is not a guaranteed system-wide Siri replacement.

## Local Mac build and verification

Install Xcode and XcodeGen (`brew install xcodegen`), then:

```sh
cd ios
bash scripts/check.sh
# After tests pass, build unsigned device package:
bash scripts/package-device.sh
```

The test script automatically selects an available iOS 17+ iPhone Simulator;
`DESTINATION` can override selection. Native screens include Auth, chat/voice,
history, proposals, Today/calendar, five record domains, source/query references,
server inbox/reminder controls and data export/deletion.

The experiment does not claim parity with all 28 Remi MVP stories. Domain edits
currently use a visible JSON editor; onboarding/timezone settings, advanced code
block rendering, APNs, OAuth/deep-link Auth and offline cache remain incomplete.
No confirmations are queued offline. Device-only tokens are accessible after
first unlock to support explicitly enabled background commands. Temporary audio
is removed on completion/cancellation; continuous keyword audio is not persisted.

Upstream experiment: `AI20K-Build-Phase-Cohort-4/P-020`, branch
`duonglh/native-ios-experiment`. This personal repository has its own Git history
and build workflow; it does not merge or deploy the upstream PWA.
