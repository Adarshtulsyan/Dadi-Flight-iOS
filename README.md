# Dadi Flight App (iOS)

A high-fidelity iOS application built with SwiftUI, designed for synchronized spiritual audio experiences in multi-user environments.

## Overview
The Dadi Flight App provides a seamless, synchronized audio journey. It maintains parity with the Android version of the system to ensure that all participants—regardless of their device—hear the same audio at the exact same moment.

## Key Features
- **SwiftUI + Combine**: Modern reactive architecture for a smooth, responsive UI.
- **Server-Side Clock Sync**: Resolves iOS device clock drift by calculating an offset from server-provided HTTP Date headers.
- **Dynamic Scheduling**: Automatically calculates playback start points and handles late-joining scenarios with sub-second precision.
- **Parity with Android**: Uses the same logic and configuration source (`raw.githubusercontent.com`) as the Android client for a unified experience.
- **Live Status Monitoring**: Real-time network health tracking using `NWPathMonitor`.

## Tech Stack
- **Framework**: SwiftUI
- **Asynchronous Logic**: Combine
- **Audio Engine**: AVFoundation (AVPlayer)
- **Network**: URLSession with custom header parsing

## Setup
1. Open `Dadi Flight App.xcodeproj` in Xcode.
2. Ensure you have an audio file named `audio.mp3` added to the project bundle.
3. Ensure you have an image asset named `dadi` for the UI.
4. Build and run on an iPhone (iOS 15.0+).

## Implementation Details
The app polls the central `config.json` every 15 seconds. It uses the `Date` header from the response to calculate `serverClockOffset`, which is then used to adjust the system's `Date()` for all playback and countdown logic.
