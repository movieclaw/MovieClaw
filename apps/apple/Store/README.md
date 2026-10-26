# App Store localization

`en-US.json` is the English product-page copy for the shared iPhone/iPad, Mac and Apple TV App Store record. Keep feature claims aligned with the release being submitted. This file is reviewable source material; editing it does not upload metadata or submit a release.

The app requires a server and provides no media content. The description states these requirements. Review accounts and private review credentials remain outside this file; use the release process in `docs/design/ios-release.md`.

Validate name/subtitle (30 characters), promotional text (170), keywords (100 ASCII characters here) and description (4,000) before upload. Limits: [App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information), [platform version information](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information), [product page](https://developer.apple.com/app-store/product-page/).

English screenshots must come from the English UI test plan on each target device, using the same fixture as the Chinese comparison. Capture home, detail, playback, sign-in and settings, and check clipping and text expansion. Do not use a Chinese screenshot to advertise an English interface. The i18n verification results are recorded in `docs/design/i18n.md`.
