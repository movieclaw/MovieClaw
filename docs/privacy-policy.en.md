# MovieClaw Privacy Policy

Last updated: October 10, 2026

MovieClaw is a source-available, self-hosted media server and its clients (the iOS app, web app, Mac transcoder and command line tools). This policy explains how MovieClaw clients handle your information.

## We do not collect your data

- The MovieClaw app communicates only with a MovieClaw server that you host or have been invited to use. Your account, media library, watch history, subscriptions and settings are stored on that server and managed by its administrator.
- The app does not send data to the developer. It contains no analytics, advertising, crash reporting or third-party tracking SDKs, and does not track you across apps. There are two optional connections to services operated by the developer: when an administrator enables official push notifications, your server forwards encrypted notifications through the developer's push relay (see Push notifications); when an administrator connects a server to a MovieClaw account, they register an account on the website (see MovieClaw accounts).
- To help your server administrator diagnose playback problems, the app sends playback quality records to your own server. These include startup time, seeking, buffering and playback failure reasons, with recent player logs attached on failure. They are not sent to the developer or any third party.
- Sign-in credentials are stored only in your device's Keychain and are used to access your server.

## Push notifications

Push notifications are optional. They are sent only after you allow notifications and your server administrator enables push:

- The app gives your server this device's Apple-assigned push token and a decryption key. The app generates the key randomly on your device, with a separate key for each server and account. It exists only in your device's Keychain and on your server.
- Your server encrypts notification content, such as a library arrival, using this key before sending it through a push relay to the Apple Push Notification service (APNs). The app decrypts and displays it on your device. The relay and Apple see only ciphertext, not the notification content.
- The relay may be the official relay operated by the MovieClaw developer, used after an administrator connects the server to a MovieClaw account, or a relay hosted by the administrator. The official relay forwards ciphertext without storing push tokens or notification content. It records only daily notification counts per server for quota enforcement; logs contain only a short prefix of a push token hash.
- When a server connects to a MovieClaw account, the developer's cloud service receives the server's name, software version, operating system and architecture. It also receives device counts aggregated by platform and app version, which the administrator can disable. It does not know your household members, which phone received which notification, or what you watch or download.
- When you sign out, the app deletes the corresponding decryption key from your device and the server removes that device's push registration.

## Device permissions

| Permission | Purpose | When requested |
|---|---|---|
| Local Network | Discover and connect to your MovieClaw server on the local network | When first searching for a server |
| Photos | Choose an avatar, library cover or image attachment for an AI conversation. Images are uploaded to your server. For AI attachments, the server forwards them to the administrator's AI provider, as described below. | When you choose an image |
| Camera | Scan a sign-in QR code or take a photo for an AI conversation, handled as described above | When you scan a code or take a photo |
| Notifications | Display notifications from your server, such as library arrivals and new device sign-ins | After signing in to a server |

You can revoke these permissions at any time in system Settings.

## AI assistant

The AI assistant is optional. It works only after your server administrator connects an AI model provider, such as Moonshot Kimi, OpenAI or Alibaba Cloud Model Studio:

- Your server sends your messages and images, together with library information the assistant retrieves to answer you, such as titles, file information and watch history, to the provider configured by the administrator. The app does not communicate directly with AI providers, and the developer does not receive this content.
- Before you first use the assistant on a device, the app explains where this information goes and names the current provider. It sends content only after you agree.
- The provider's privacy policy governs its handling of this information. Your administrator can change or remove the provider at any time. Conversation history is stored on your server and can be deleted in the app.

## MovieClaw accounts

Connecting MovieClaw Cloud for official push notifications is optional. A server administrator signs in on the website with Apple, Google or email, creating a MovieClaw account. The website's privacy policy explains how that account's information is handled: https://movieclaw.io/en/privacy . You can delete the account at any time from the website's Account page. The app provides a direct link under Server settings > MovieClaw Cloud.

Your account on a MovieClaw server is created and deleted by its administrator, without going through the developer. Contact the administrator if you want it deleted.

## Third-party services

Your server retrieves media information and images from public sources such as TMDB and Douban. The app reads this information through your server and does not send your personal information directly to those services. The administrator's configuration determines how your server interacts with third parties.

Notifications are delivered through APNs. Apple handles push tokens under its privacy policy; notification content is encrypted before it reaches Apple.

## Children

The app does not collect information targeted at any particular age group. Server administrators can configure content rating restrictions for family member accounts.

## Contact

For questions about this policy, open an issue in the project repository: https://github.com/movieclaw/movieclaw/issues
