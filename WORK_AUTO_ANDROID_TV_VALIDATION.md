# work-auto Android TV validation

Target host: `192.168.1.14`

APK:

```text
D:\WXData\xwechat_files\mars0221_2bfb\msg\file\2026-06\影视仓_5.0.44.1-通用版.apk
```

Config URLs:

```text
https://cdn.jsdelivr.net/gh/MarsAres0221/tvbox-config@master/DC.json
https://cdn.jsdelivr.net/gh/MarsAres0221/tvbox-config@master/singles.json
```

## Goal

Run a weekly Android-side smoke test for the TVBox / 影视仓 configuration. The PC scripts only prove that JSON and spider URLs are reachable. This validation should prove that the Android app can load the config and that at least one source can search, open details, and reach a playable item.

## Scope

Allowed:

- Install and run 影视仓 in an Android TV emulator or compatible Android runtime.
- Load the two jsDelivr config URLs.
- Search public catalog metadata using normal app UI behavior.
- Capture screenshots and logs for pass/fail evidence.

Not allowed:

- Crawl video content or playback URLs at scale.
- Bypass source anti-scraping, login, paywall, region, or copyright controls.
- Automatically replace `DC.json` or `singles.json` without human confirmation.

## Preferred Environment

Use Android Studio Emulator with an Android TV image if available.

Suggested device:

- Android TV 11 or newer
- x86_64 image
- Network enabled
- Screen resolution close to TV layout, for example 1280x720 or 1920x1080

If Android Studio is not installed, install it manually or report the missing dependency. Do not spend the weekly task inventing a custom Android runtime.

## Manual Setup Checklist

1. Confirm the APK exists on work-auto. If not, copy it from the current machine or ask for the file.
2. Create or start an Android TV emulator.
3. Install the APK:

```powershell
adb install -r "D:\WXData\xwechat_files\mars0221_2bfb\msg\file\2026-06\影视仓_5.0.44.1-通用版.apk"
```

4. Launch 影视仓.
5. Configure the app with `DC.json`, then repeat with `singles.json`.

## Weekly Validation Flow

Run the repository-side checks first:

```powershell
cd D:\projects\tvbox-config
powershell -ExecutionPolicy Bypass -File .\weekly-update.ps1
powershell -ExecutionPolicy Bypass -File .\publish.ps1
```

Then run Android app smoke tests:

1. Open 影视仓.
2. Load the current config URL.
3. For each healthy source from `discovered-sources.json`, test at least one stable keyword:

```text
庆余年
凡人修仙传
甄嬛传
```

4. Pass criteria for a source:
   - App accepts the config.
   - Search returns at least one result.
   - A result opens a detail page.
   - At least one episode/play item is visible.
   - Optional: playback starts or the player opens without immediate source error.

5. Fail criteria:
   - Config fails to load.
   - Source list is empty.
   - Search has no results for all test keywords.
   - Detail page cannot open.
   - No play items are visible.
   - App crashes or hangs.

## Evidence To Report

For each weekly run, report:

- Date/time and machine name.
- Emulator/runtime used.
- APK version.
- Config URL tested.
- Healthy source count from `weekly-update.ps1`.
- Android-side pass/fail table:
  - source name
  - keyword
  - search result present
  - detail page present
  - play item present
  - playback/player result if checked
- Screenshot paths.
- Any source that should be removed from `DC.json` / `singles.json`, but do not remove it automatically.

## Notes

The Tanix W2 real device remains the final authority. Emulator validation is an intermediate gate that is stronger than HTTP checks but weaker than real-box testing.
