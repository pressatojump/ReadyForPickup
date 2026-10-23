# ReadyForPickup for iOS

A native iPhone and iPad companion to the macOS Apple Store pickup-availability watcher in this repository.

## Open the app

Open `ReadyForPickup.xcodeproj`, select the **ReadyForPickup** scheme, and run on an iPhone or iPad simulator. The app supports **iOS 17 or newer** and uses only Apple frameworks. Xcode 16 or newer is required for its synchronized project groups. Builds have been tested with Xcode 27; older Xcode versions have not been verified.

For a physical device, select your own development team in Xcode. No signing identity, provisioning profile, or release credential is included. Store submission and distribution are not configured.

## What it does

- Save multiple watches for an iPhone or Mac, a country, an Apple Store, and up to 20 exact configurations.
- Search bundled stores and configurations, include nearby stores, and optionally enter a custom part number.
- Query Apple’s pickup endpoint with country-specific part numbers; manually refresh or check automatically while the app is open.
- Keep watches, successful results, and availability activity on the device across launches.
- Request local-notification permission only when needed and alert when newly available configurations appear.
- Pause, edit, and delete watches. Failed checks retain earlier results instead of claiming that stock is unavailable.
- Respect Apple’s rate limiting with a shared 30-minute cooldown, including across app restarts.

## Important iOS limitations

An iOS app cannot continuously poll Apple while suspended. This app requests occasional Background App Refresh, but **iOS controls the schedule and may not run it**. Foreground refresh defaults to every five minutes. Force-quitting, disabled Background App Refresh, and system power policies can prevent background checks.

There is **no server-side watcher, APNs service, or guarantee of immediate background alerts**. For dependable monitoring while the phone app is closed, keep the upstream macOS watcher running with its existing Pushover integration, or add a separately operated monitoring service. Pushover setup and Sparkle’s macOS updater are not part of this iOS port.

Inventory is informational: the app does not reserve products, place orders, or guarantee that stock remains available. Complete any purchase with Apple.

## Build

Run from the repository root:

```sh
xcodebuild -project ios/ReadyForPickup.xcodeproj \
  -scheme ReadyForPickup -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/readyforpickup-ios-build CODE_SIGNING_ALLOWED=NO build
```

## UI verification

Use a booted, dedicated simulator. From the repository root, install the unsigned Simulator build:

```sh
xcrun simctl install <SIMULATOR_UDID> \
  /tmp/readyforpickup-ios-build/Build/Products/Debug-iphonesimulator/ReadyForPickup.app
```

Install [Maestro](https://maestro.mobile.dev), then run from the repository root:

```sh
maestro test --udid <SIMULATOR_UDID> ios/.maestro/demo.yaml \
  --test-output-dir /tmp/readyforpickup-ios-proof/maestro-demo
maestro test --udid <SIMULATOR_UDID> ios/.maestro/watch-lifecycle.yaml \
  --test-output-dir /tmp/readyforpickup-ios-proof/maestro-lifecycle
```

The flows retain screenshots and recordings. **Use a dedicated simulator: these flows reset the app’s simulator data.** `--demo` explicitly shows labeled sample availability without making network requests or saving demo state. `--ui-testing` uses separate persistence and defaults automatic refresh off, so lifecycle checks do not require Apple’s live service. These modes are not evidence of live inventory availability.

For an optional real network check, run `ios/.maestro/live-check.yaml` the same way. It makes one live Apple inventory request, can fail when Apple is unavailable or rate-limiting, and never substitutes fixture data.

## Data and attribution

The app bundles the macOS app's product catalog and store list straight from `../ReadyForPickup/` (`ProductCatalog.json` and `Stores_LocalBootstrap.json`), so refreshing them with the scripts in the [root README](../README.md#store-list-and-product-catalog) updates both apps. Product and store data are a snapshot, not live stock; part numbers may become obsolete. The app icon is drawn by `Scripts/make-app-icon.swift` along with the Mac icon, as an opaque square that iOS rounds itself. Unknown product-family identifiers remain selectable with their identifier as the display label.

Licensed under [GPL-3.0](../LICENSE.md). Independent of and not endorsed by Apple.
