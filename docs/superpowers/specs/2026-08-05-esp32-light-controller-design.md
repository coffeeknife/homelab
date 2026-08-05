# ESP32 Dual-Channel Light Controller — Design

**Date:** 2026-08-05
**Status:** Design approved, blocked on one hardware measurement (see Open Questions)
**Scope:** One ESPHome node driving two dimmable low-voltage lights — an IKEA
USB adhesive LED strip and an IKEA UPPLYST LED wall lamp — both co-located,
exposed to Home Assistant as independent `light` entities.

## Problem

Home Assistant currently controls six lights, all of them off-the-shelf Zigbee
(TRÅDFRI bulbs, a TRETAKT plug, a SONOFF ZBMicro). Two dumb IKEA fixtures sit
alongside them with no automation path:

- an **adhesive LED strip**, USB-powered, single-colour white
- an **UPPLYST LED wall lamp** (flower, lilac — art. 004.407.87), 1.6 W /
  110 lm, integrated-but-replaceable LED on a 6'7" low-voltage cord

Neither has a bulb socket, so the usual fix — drop in a TRÅDFRI bulb — does not
apply. Both are low-voltage DC loads, which makes them straightforward PWM
targets for an ESP32.

Secondary motivation: **Adaptive Lighting is attached to only 2 of the 6
existing lights** (`light.bedroom_light`, `light.elfa_light`). Both new channels
will be genuinely dimmable and are good candidates to widen that.

## Constraints

- **Apartment, rented.** No mains work, no fixed wiring. Everything here is
  low-voltage DC on the load side of existing wall adapters.
- **Both fixtures are the owner's**, and cords may be cut. An earlier
  non-destructive barrel-pigtail variant of this design was dropped as
  unnecessary.
- **Co-located.** An earlier two-node variant (one ESP32 each) was dropped once
  placement was settled; a single board is cheaper and removes a part.

## Hardware

### Verified

| Item | Spec | Source |
|---|---|---|
| UPPLYST wall lamp | 1.6 W, 110 lm, 6'7" cord, "low voltage", integrated replaceable LED | ikea.com product page, 2026-08-05 |
| LED strip | USB-powered, single-colour white | Owner |
| ESP32-C3 SuperMini | 4 MB flash, 160 MHz, WiFi + BLE 5.0, USB-C | ACEIRMC 5-pack, ~$3.80/ea |
| MOSFET module | AOD4184 "Dual High-Power MOSFET Trigger Switch", DC 5–36 V, 0–20 kHz PWM | 6-pack, $5.49 |

### Bill of materials

| Part | Qty | Note |
|---|---|---|
| ESP32-C3 SuperMini | 1 | From the 5-pack; 4 spare for future nodes |
| AOD4184 MOSFET module | 2 | From the 6-pack; 4 spare |
| Jumper wire | — | |
| USB breakout / pigtail | 0–2 | Only for the reversible variant; see Power |

Total marginal cost ≈ **$6**.

### Purchasing caveats

1. **Verify the MOSFET module chip marking on arrival.** A visually similar
   blue module is built around an **IRF520**, which is *not* logic-level and
   will not switch cleanly from a 3.3 V GPIO. `D4184` is correct.
2. **The ESP32 listing's metadata contradicts its title** — the title says
   ESP32-C3 while the Model Name field says ESP32-S3. Photos and pin count
   indicate C3. If S3 boards arrive, change `board:` to `esp32-s3-devkitc-1`.
3. **The C3 SuperMini has a known weak-antenna design.** Do not enclose the
   node in metal or mount it behind foil-backed insulation. If WiFi is
   marginal, this is the cause.
4. Headers ship unsoldered.

### Rejected: discrete MOSFET assortment kit

A 6-value / 50-piece kit (IRFZ44N, IRF530N, IRF540N, RFP30N06LE, 2N7000,
IRF9540) was evaluated and rejected. Despite "Logic Level" in the listing title,
only **RFP30N06LE** is logic-level; 2N7000 is capped at 200 mA (below the
strip's likely draw); IRFZ44N / IRF530N / IRF540N need ~10 V of gate drive; and
IRF9540 is P-channel. Four of six cannot be driven from a 3.3 V GPIO at all.

> **Rule of thumb:** the letter `L` denotes logic-level. `IRF540N` ✗ vs
> `IRL540N` ✓; `IRFZ44N` ✗ vs `IRLZ44N` ✓. If a datasheet quotes `R_DS(on)` at
> `V_GS = 10 V`, the part is unsuitable for direct MCU drive.

## Design

Single ESP32-C3 driving two independent low-side switched channels. The MOSFET
modules perform low-side switching internally, so no conductor-level splicing is
needed — supply enters `IN`, load leaves `OUT`.

```
USB 5V ────► M1 IN+ │ M1 OUT+ ────► strip V+
USB GND ───► M1 IN− │ M1 OUT− ────► strip V−

lamp adapter + ──► M2 IN+ │ M2 OUT+ ──► lamp +
lamp adapter − ──► M2 IN− │ M2 OUT− ──► lamp −

ESP32 GPIO4 ──────► M1 SIG
ESP32 GPIO5 ──────► M2 SIG
ESP32 GND ────┬───► M1 GND
              └───► M2 GND
```

### Grounding

Each module's signal ground is internally common with its `IN−`, so bonding both
module grounds to the ESP32 also bonds the two wall adapters' negatives. This is
required — the gates need a shared reference — and is safe: both supplies are
isolated switching adapters. **This holds only while both outputs are DC.**

### GPIO selection

`GPIO4` and `GPIO5`. Avoid `GPIO2`, `GPIO8`, `GPIO9` on the ESP32-C3 — they are
strapping pins, and holding one at boot prevents the board starting.

### PWM frequency

**10 kHz.** Above audible range and above camera-flicker range, with margin
below the modules' 20 kHz ceiling. The modules have no gate driver, so switching
edges soften near the top of their range; there is no benefit to running at the
limit for loads this small.

### Gate resistors

These modules normally integrate the gate series resistor and a ~10 kΩ pulldown.
**Measure gate-to-source before adding external parts** — if it reads ~10 kΩ,
omit the discrete 100 Ω and 10 kΩ. Without a pulldown from somewhere, the gate
floats during ESP32 boot and the load glows or flickers at every power-up.

## Power

Two acceptable topologies; pick on the strip's measured current.

**Option A — no extra parts (strip ≤ 500 mA).** The SuperMini's `5V` pin is USB
VBUS. Power the board through its own USB-C port and take 5 V back off the
header to `M1 IN`. Strip current then flows through the board's connector and
5 V trace, which is acceptable at ≤ 500 mA.

**Option B — one cut, no extra parts (any current).** Cut the strip's USB cable
mid-run. The charger-side half becomes the 5 V/GND source; the strip-side half
becomes the load. Feed both the ESP32 `5V` pin and `M1 IN+` from the charger
side, so load current never crosses the ESP32 board.

**Reversible variant.** A USB-A female breakout with screw terminals (strip
plugs in, fed from `M1 OUT`) plus a USB-A male pigtail for input. ≈ $3.50.

Verify USB polarity with a meter rather than trusting wire colour — VBUS and GND
are the two outer contacts (pins 1 and 4). If the cable carries four conductors,
the D+/D− pair is unused; trim and insulate.

## Firmware

```yaml
esphome:
  name: corner-lights
  friendly_name: Corner Lights

esp32:
  board: esp32-c3-devkitm-1
  framework:
    type: esp-idf

logger:
  hardware_uart: USB_SERIAL_JTAG

api:
  encryption:
    key: !secret api_encryption_key
ota:
  - platform: esphome
    password: !secret ota_password

wifi:
  ssid: !secret wifi_ssid
  password: !secret wifi_password
  ap:
    ssid: "Corner Lights Fallback"

captive_portal:

output:
  - platform: ledc
    pin: GPIO4
    id: out_strip
    frequency: 10000Hz
  - platform: ledc
    pin: GPIO5
    id: out_lamp
    frequency: 10000Hz

light:
  - platform: monochromatic
    name: "Strip"
    output: out_strip
    default_transition_length: 500ms
    restore_mode: RESTORE_DEFAULT_OFF
  - platform: monochromatic
    name: "Flower Lamp"
    output: out_lamp
    default_transition_length: 500ms
    restore_mode: RESTORE_DEFAULT_OFF
```

`logger.hardware_uart: USB_SERIAL_JTAG` is required on the C3 — it uses native
USB rather than a separate UART bridge, and without this line the USB-C port
produces no serial output, which reads as a dead board.

## Home Assistant integration

Both channels arrive over the **ESPHome native API** (encrypted, no MQTT) as
`light.strip` and `light.flower_lamp`. Assign both to their area and add the
repo's standard labels if any manifests are later added.

Once stable, consider adding both to the Adaptive Lighting `Main` switch, which
currently manages only `light.bedroom_light` and `light.elfa_light`.

## Open questions

1. **Is the UPPLYST adapter DC or AC?** IKEA publishes only "low voltage". Read
   the brick: `⎓` (or `DC`) versus `~`.
   - **DC (expected):** design is final as written. Voltage is irrelevant to
     part selection — the AOD4184 is rated to 40 V, and the ESP32 is powered
     from the strip's USB 5 V, so no buck converter is needed.
   - **AC:** PWM dimming is impossible. Channel 2 degrades to relay on/off, or
     the adapter is replaced with a DC equivalent. Ground bonding above would
     also need re-examining.
2. **Strip current draw** — decides Option A versus Option B. Read the wattage
   off the packaging and divide by 5, or measure with an inline USB power meter.
3. **Does the lamp contain its own constant-current driver?** If so it may
   respond poorly to chopped DC — stepping, buzzing, or cutting out below some
   floor. If observed, fall back to on/off for that channel. Testing reveals
   this within a minute.

## Verification

1. Flash and confirm the node appears in ESPHome and HA.
2. Bench-test each channel on the strip before wiring the lamp.
3. Sweep each channel 1 → 100 % and check for flicker, buzz, and a usable low
   end.
4. Power-cycle the node and confirm neither load glows during boot (gate
   pulldown present and working).
5. Leave running 24 h; confirm no WiFi dropouts (antenna caveat above).

## Related future work

This is the first of several ESP32 nodes scoped for this apartment. The others,
in rough payoff order:

1. **Midea AC controller** — an SLWF-01pro dongle in the AC's WiFi bay running
   ESPHome's native `midea` platform. Highest payoff of the set: it bypasses
   Matter node 15 and the gallifrey Matter server entirely, and retires both the
   Versatile Thermostat and the duplicate `generic_thermostat` that currently
   fight over one temperature sensor.
2. **Per-room environment nodes** — SHT4x + BH1750 + LD2410C mmWave. The
   apartment has only two real environmental sensors today.
3. **Bathroom humidity / fan controller** — fan driven by humidity rise-rate
   rather than a timer.
4. **Water leak probes** — one mains-powered node with wired probes to the
   kitchen sink, bathroom sink, and toilet.
