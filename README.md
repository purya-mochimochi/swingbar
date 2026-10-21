# swingbar

A lightweight, standalone auto-attack swing interval HUD for **Ashita v4** (Final Fantasy XI).  
Features a clean, Scoreboard-inspired dark plate interface rendered using Ashita's native ImGui.

---

## Features
- **Visual Attack Interval:** Displays smooth progress bars for both melee auto-attack and ranged attack timing.
- **Dynamic Interval Estimation:** Automatically tracks elapsed time between local attack packets (`0x028`) using an exponential moving average. No complex stat/delay math required.
- **CC & Debuff Handling:**
  - **Paralysis:** Instantly resets the bar when a paralysis interruption (`0x029`) occurs and alerts via an amber color.
  - **Sleep / Incapacitation:** Pauses the swing timer during disabling crowd control effects (Sleep, Terror, Petrification, etc.) and resumes accurately upon recovery.
  - **Spell & WS Guard:** Temporarily ignores delay estimation spikes caused by weapon skills or spellcasting delays.
- **Lightweight & Asset-Free:** Pure ImGui rendering with zero external PNG or image dependencies.

---

## Installation
1. Download or clone this repository.
2. Place the `swingbar` folder into your Ashita addons directory:
   ```text
   Ashita/
   └── addons/
       └── swingbar/
           └── swingbar.lua

   In-game, load the addon via the chat console:
   /addon load swingbar

## References & Credits
- **Original Source / Algorithm:**  
  - [XivUI by maybeLynd](https://github.com/maybeLynd/XivUI)  
  - The interval estimation logic is adapted from XivUI's `castbar.lua` component.
- **Port & Redesign:**  
  - Re-implemented and redesigned for Ashita v4 using native ImGui.
