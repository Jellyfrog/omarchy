#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const power = requireFromRoot('shell/plugins/panels/power/Model.js')
const panelSource = fs.readFileSync(root + '/shell/plugins/panels/power/Panel.qml', 'utf8')
const states = { Charging: 1, Discharging: 2, FullyCharged: 3, PendingCharge: 4 }

assertEqual(power.selectProfileIndex(0, 1, ['balanced', 'performance']), 1, 'power advances profile selection')
assertEqual(power.selectProfileIndex(1, 1, ['balanced', 'performance']), 1, 'power clamps profile selection')

assertDeepEqual(power.parseKeyValue('time\t2:00\nenergy\t42\n'), { time: '2:00', energy: '42' }, 'power parses key-value output')
assertDeepEqual(
  power.parseProfiles('power-saver\t0\nbalanced\t1\nperformance\t0\n', 5),
  { profiles: ['power-saver', 'balanced', 'performance'], activeProfile: 'balanced', profileIndex: 2 },
  'power parses profile output and clamps selection'
)

assert(power.profileIcon('performance').length > 0, 'power maps profile icons')
assertEqual(power.batteryFraction({ isPresent: true, percentage: 1.5 }), 1, 'power clamps battery fraction')

assert(power.chargeThresholdActive({ isPresent: true, percentage: 0.8, state: states.PendingCharge }, false, states), 'power detects threshold by pending charge state')
assert(power.chargeThresholdActive({ isPresent: true, percentage: 0.8, state: states.Charging, changeRate: 0.1, timeToFull: 120 }, false, states), 'power detects threshold by stalled charging')
assert(!power.chargeThresholdActive({ isPresent: true, percentage: 0.8, state: states.Charging, changeRate: 1.0, timeToFull: 120 }, false, states), 'power does not flag active charging as threshold')
assert(!power.chargeThresholdActive({ isPresent: true, percentage: 0.5, state: states.Discharging }, false, states), 'power does not flag discharging as threshold')
assertEqual(power.modeLabel({ isPresent: true, percentage: 1, state: states.FullyCharged }, false, states), 'Fully charged', 'power labels full battery')
assertEqual(power.modeLabel({ isPresent: true, percentage: 0.5, state: states.Discharging }, true, states), 'On battery', 'power labels battery mode')
assertEqual(power.modeLabel({ isPresent: true, percentage: 0.5, state: states.Discharging }, false, states), 'Charging', 'power treats external power as newer than stale discharging state')
assert(power.batteryIcon({ isPresent: true, percentage: 0.4, state: states.Charging }, false, states).length > 0, 'power maps battery icons')
assertEqual(
  power.batteryIcon({ isPresent: true, percentage: 0.4, state: states.Discharging }, false, states),
  power.batteryIcon({ isPresent: true, percentage: 0.4, state: states.Charging, changeRate: 1.0, timeToFull: 120 }, false, states),
  'power shows charging icon when external power is present before battery state refreshes'
)
assertEqual(
  power.batteryIcon({ isPresent: true, percentage: 0.4, state: states.Charging }, true, states),
  power.batteryIcon({ isPresent: true, percentage: 0.4, state: states.Discharging }, true, states),
  'power shows battery icon when unplugged before battery state refreshes'
)

assert(/if \(b === Qt\.RightButton\) root\.togglePercentage\(\)/.test(panelSource), 'power right click toggles the bar percentage')
assert(/Object\.assign\([^\n]+showPercentage: !root\.showPercentage[^\n]+\)[\s\S]*updateEntryInline/.test(panelSource), 'power persists the bar percentage setting')
assert(/Math\.round\(root\.batteryFraction \* 100\) \+ "% " \+ root\.batteryIcon\(\)/.test(panelSource), 'power places the percentage before the battery icon')
assert(/openPanelIndicatorWidth:.*showPercentage.*button\.glyphPaintedWidth : 0/.test(panelSource), 'power spans the open-panel mark across the painted percentage block')
assert(/IpcHandler[\s\S]*?function togglePercentage\(\) \{ root\.togglePercentage\(\) \}/.test(panelSource), 'power exposes togglePercentage over IPC')
assert(/manageIpc: false/.test(panelSource), 'power owns its IPC handler so it can extend the target methods')

const stops = [40, 50, 60, 70, 80, 90, 100]
assertEqual(power.nearestThresholdStop(stops, 80), 4, 'power maps a charge limit onto its notch')
// The CLI takes any integer, and the driver can round again. Thus the slider must
// show an off-notch value, and it must not move the hardware to a notch.
assertEqual(power.nearestThresholdStop(stops, 86), 5, 'power rounds an off-notch charge limit to the nearest notch')
// A value exactly between two notches takes the lower one. A tie thus goes to the
// gentler limit, and the battery does not charge further than the user asked.
assertEqual(power.nearestThresholdStop(stops, 85), 4, 'power breaks a notch tie toward the lower limit')
assertEqual(power.nearestThresholdStop(stops, 5), 0, 'power clamps a charge limit below the lowest notch')
assertEqual(power.nearestThresholdStop([], 80), 0, 'power survives an empty notch list')

assertEqual(power.chargeLimitLabel(100), 'Off', 'power calls a 100% limit off, since that is what the drivers mean by it')
assertEqual(power.chargeLimitLabel(80), '80%', 'power labels a real charge limit')
assertEqual(power.chargeLimitLabel(-1), '\u2014', 'power shows a placeholder where supported hardware has reported no limit yet')

assert(/command: \["omarchy-battery-threshold"\]/.test(panelSource), 'power reads the charge limit from the CLI')
// A non-zero exit is the capability probe. asus_wmi reports the interface as
// present but unreadable until the first write, so the output alone cannot decide.
assert(/onExited: function\(exitCode\)[\s\S]*?updateChargeLimit\(thresholdProc\.stdout\.text, exitCode === 0\)/.test(panelSource), 'power takes charge limit support from the reader exit code')
assert(/visible: root\.chargeLimitSupported/.test(panelSource), 'power hides the charge limit section on hardware without one')
assert(/actionProc\.command = \["omarchy-battery-threshold", String\(thresholdStops\[index\]\)\]/.test(panelSource), 'power sets the charge limit through the CLI')
assert(/function setChargeLimit\(index\) \{[\s\S]*?chargeLimitPreview = index/.test(panelSource), 'power holds the chosen notch while the change is in flight')
assert(/focusSection === "profile" \? "limit" : "profile"/.test(panelSource), 'power moves the keyboard between the profile row and the charge limit')
JS
