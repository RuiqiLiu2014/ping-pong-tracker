<!--
  README TEMPLATE — fill each bracketed placeholder, then delete these comments.
  Section order is recruiter-first: hook + demo at the very top, build/hardware
  details lower down. Keep the top third skimmable in ~30 seconds.
-->
# Ping Pong Tracker

> An advanced ping pong paddle motion tracker, attached to the base of the handle, that sends 6-axis IMU data to a phone app at 1660 Hz via BLE. The phone app saves and displays the data in a readable format, analyzing hit time, paddle speed, spin ratio, and more for every shot, allowing users to easily analyze their shot quality and find shortcomings in their swings.

---

## Demo

<!-- Lead with an autoplaying GIF (plays inline, no click needed). Keep it 5-10s. -->
![ demo GIF goes here ]( path/to/demo.gif )

**Full demo video:** [ YouTube link goes here ]

---

## Overview

There are sports trackers out there for racket sports, but they tend to be expensive, with ping pong being one of the most expensive as it generally relies on technology embedded within the paddle itself. My goal is to create a budget-friendly alternative that can still accurately track metrics like swing speed, hit timing, and spin. My tracker uses a lightweight 3D printed case, housing a XIAO nRF52840 Sense microcontroller (with onboard 6-axis IMU) soldered to a 100 mAh LiPo battery pack. The whole unit weighs ~7g and is mounted to the base of the handle, and has features as described in the next section.

---

## Features

- Accelerometer and gyroscope streaming at 1660 Hz to accurately capture swing motions
- Automatic hit detection to automatically log data before and after each hit
- Manual logging mode to log practice swings
- Metrics for every log including swing speed, spin ratio, paddle orientation, and hit timing
- Rechargeable battery pack via USB-C port
- Straightforward app interface, color themes, light and dark mode, and very flexible settings options

---

## Screenshots

<!-- 2-4 app screenshots. A table keeps them aligned. -->
| [ caption goes here ] | [ caption goes here ] |
|---|---|
| ![ screenshot goes here ]() | ![ screenshot goes here ]() |

---

## How it works

<!-- Architecture / data-flow diagram (image or ASCII). Shows systems thinking. -->
![ architecture diagram goes here ]()

[ Short explanation of the end-to-end pipeline goes here. ]

---

## Technical highlights

<!-- The hard parts. This is what depth-checking engineers scan for. -->
- The 6-axis IMU streams at its maximum (hardware constrained) frequency of 1.66 kHz via BLE to the phone app, packaged with timestamps. App notifies the user of any dropped data packets.
- Speed is calculated by integrating accelerometer data and combining with gyroscope data. Accelerometer data contains natural drift when integrated, which is fixed by a centered moving average high-pass.
- The app has a calibration feature that is done at the start of each session, which calibrates by measuring gravitational acceleration in two paddle positions and allows for data such as paddle angle.
- The app uses a 2-pole high pass filter to determine when the ball was hit by detecting high-frequency paddle vibrations and records these in each log, enabling the automatic logging feature that records one log per hit. This also enables the ability to analyze swing quality by looking at points of maximum speed and spin generation compared to hit timing.

---

## Hardware

<!-- Photos of the assembled device + mount — physical build is a differentiator. -->
![ hardware photo goes here ]()

**Parts list**

| Part | Notes | Link |
|---|---|---|
| XIAO nRF52840 Sense | microcontroller with 6-axis IMU | https://www.amazon.com/dp/B0DJ6PZGB7 |
| 100 mAh LiPo Battery Pack | rechargeable battery pack to power the microcontroller | https://www.amazon.com/dp/B083NWXLTK |
| 1P2T Mini Slide Switch | switch to turn the unit on and off | https://www.amazon.com/dp/B01N25FBWD |

**3D-printed mount:** [ reference to print files goes here ]

---

## Build & run

Visit the releases page (https://github.com/RuiqiLiu2014/ping-pong-tracker/releases) and download the latest apk (app) and uf2 (firmware) files.
### Install the firmware
1. Plug in the XIAO nRF52840 Sense, and double tap the reset button to enter bootloader mode.
2. Drag the uf2 file into the bootloader.
### Download the app
1. [todo]

---

## Repository structure

- app: contains the flutter app
- calibration_drawings: contains SVG files for calibration wizard images
- firmware: contains firmware deployed to the board for data collection
- stls: contains STL files for 3D printed case

---

## Next Steps

- Implement a TinyML model to classify swings, allowing for grouping logs in the app based on swing type and better analysis among swings. Allows for focused improvement of certain swings.
- Improved metrics and in-app analysis of multiple logs.
- Use dual-endpoint ZUPT and direction-reversal zeroing for more accurate speed integration.
- Add a phone camera with YOLO to track the paddle frame by frame, allowing for more accurate metrics and live swing analysis.
- Add a live AI coach feature to the app.

---

## License

[ license statement goes here ]
