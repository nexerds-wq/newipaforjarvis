# Jarvis Glasses V3 — Better + Changeable Wake Word

V3 keeps the working M02S Bluetooth wake command and upgrades the phone-side wake-word detector.

## Main upgrades

- Wake phrase is editable in the app. Default: **Hey Jarvis**.
- Four sensitivity levels: **Strict / Balanced / High / Max**.
- Default is **High**.
- Recognition aliases are editable. Add phrases iOS mishears, such as `Hey Jervis`.
- No longer requires an exact `hey jarvis` transcript.
- Fuzzy matching handles small speech-recognition mistakes.
- Uses Apple's contextual phrase biasing to push recognition toward your selected phrase and aliases.
- Uses live partial speech results for faster activation.
- Smaller 512-frame microphone buffers for lower detection latency.
- Automatically rotates the Apple Speech session every ~48 seconds so long-running listening is less likely to go stale.
- Restarts after audio-route changes, interruptions, and media-service resets.
- Keeps Bluetooth HFP mic preference for the glasses when iOS exposes it.
- Background audio + BLE modes remain enabled.

## Recommended settings

Start with:

- Wake phrase: `Hey Jarvis`
- Sensitivity: `High`
- Aliases: `Hey Jervis, Hey Jarvus, A Jarvis`
- On-device only: OFF

If it misses you, switch to **Max**. If it false-triggers, use **Balanced**.

Watch the **Live speech** field. If iOS repeatedly hears something different, add that exact wording to Recognition aliases.

## Build

1. Upload this entire folder to a GitHub repository.
2. Open **Actions**.
3. Run **Build Jarvis Glasses V3 IPA**.
4. Download `JarvisGlasses-V3-unsigned-ipa`.
5. Extract `JarvisGlasses-V3-unsigned.ipa`.
6. Install it with Sideloadly.

## Background / lock screen

Turn Wake-word listening on while the app is open first. Leave the app normally and lock the phone. Do not swipe-force-close Jarvis Glasses. iOS still controls third-party background process lifetime, so locked-screen listening cannot be made as privileged as Siri, but V3 aggressively restarts the audio/speech pipeline when iOS allows it.

## SDK note

The HeyCyan/QCSDK framework exposes controls for the glasses' onboard voice-wakeup feature, but it does not expose a documented API for replacing the onboard wake model with arbitrary text such as “Hey Jarvis.” V3 therefore keeps the reliable M02S BLE control path and performs the custom/changeable phrase detection on the iPhone.
