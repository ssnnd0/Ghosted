# Dolphin Runtime Checklist

## Before launch

- Confirm iOS 17.4+
- Enable Developer Mode
- Generate a fresh pairing file
- Import the pairing file into the app
- Keep the loopback VPN active
- Connect the device to Wi‑Fi
- Mount the correct DDI
- Verify the location channel is open
- Verify the heartbeat remains active

## During route playback

- Confirm the simulated route advances without stalls
- Confirm the app remains alive while the screen is locked
- Confirm the fake GPS is visible to the rest of the system
- Confirm route exposure and camera alerts still fire correctly

## If anything fails

- Re-check pairing freshness
- Re-check loopback VPN reachability
- Re-check DDI compatibility
- Re-check Developer Mode state
- Re-check background-mode entitlement setup

## Exit criteria

The live runtime is considered valid only after the device-side contract is fully satisfied in a real iPhone environment.
