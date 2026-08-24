#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

threshold="$ROOT/bin/omarchy-battery-threshold"
init="$ROOT/bin/omarchy-battery-threshold-init"
sudoers_file="$ROOT/etc/sudoers.d/omarchy-battery-threshold"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# Builds a power-supply tree. `start` and `end` can be "-" to leave that file out
# entirely. The end-only drivers (asus_wmi, lg_laptop, toshiba_acpi) look this way.
make_battery() {
  local dir="$1" start="$2" end="$3"

  mkdir -p "$dir/BAT0"
  printf 'Battery\n' >"$dir/BAT0/type"
  printf '1\n' >"$dir/BAT0/present"
  [[ $start == "-" ]] || printf '%s\n' "$start" >"$dir/BAT0/charge_control_start_threshold"
  [[ $end == "-" ]] || printf '%s\n' "$end" >"$dir/BAT0/charge_control_end_threshold"
}

# The privileged half. This runs it directly, so it needs no elevation.
apply() {
  local dir="$1"
  shift
  OMARCHY_POWER_SUPPLY_PATH="$dir" "$threshold" --apply "$@"
}

report() {
  OMARCHY_POWER_SUPPLY_PATH="$1" "$threshold"
}

# ---------------------------------------------------------------- reading ----

thinkpad="$tmp_dir/thinkpad"
make_battery "$thinkpad" 0 100

# USB-C sources enumerate alongside the battery, and nothing must write to them.
mkdir -p "$thinkpad/AC" "$thinkpad/ucsi-source-psy-USBC000:001"
printf 'Mains\n' >"$thinkpad/AC/type"
printf '1\n' >"$thinkpad/AC/online"
printf 'Battery\n' >"$thinkpad/ucsi-source-psy-USBC000:001/type"
printf '0\n' >"$thinkpad/ucsi-source-psy-USBC000:001/present"
printf '50\n' >"$thinkpad/ucsi-source-psy-USBC000:001/charge_control_end_threshold"

output=$(report "$thinkpad")
[[ $output == $'end\t100\nstart\t0' ]] ||
  fail "battery threshold reports both thresholds where the driver exposes them" "got: $output"

pass "battery threshold reports both thresholds"

end_only="$tmp_dir/asus"
make_battery "$end_only" - 100
output=$(report "$end_only")
[[ $output == $'end\t100' ]] ||
  fail "battery threshold omits the start line where the driver exposes no start file" "got: $output"

pass "battery threshold reports an end-only driver without inventing a start"

desktop="$tmp_dir/desktop"
mkdir -p "$desktop/AC"
printf 'Mains\n' >"$desktop/AC/type"
report "$desktop" >/dev/null && fail "battery threshold exits non-zero where no battery has a limit"

pass "battery threshold exits non-zero on hardware with no charge limit"

# The existence of the file is what proves support. asus_wmi returns -ENODATA for
# the value until something writes to it. Code that treats this as "unsupported"
# hides the control on the hardware that needs it most.
unreadable="$tmp_dir/enodata"
make_battery "$unreadable" - -
: >"$unreadable/BAT0/charge_control_end_threshold"
output=$(report "$unreadable") ||
  fail "battery threshold treats an unreadable value as supported"
[[ -z $output ]] ||
  fail "battery threshold reports no value where the driver has none to give" "got: $output"

pass "battery threshold counts an unreadable end threshold as supported"

# ---------------------------------------------------------------- writing ----

apply "$thinkpad" 80 >/dev/null
[[ $(<"$thinkpad/BAT0/charge_control_end_threshold") == "80" ]] ||
  fail "battery threshold writes the end threshold"
[[ $(<"$thinkpad/BAT0/charge_control_start_threshold") == "0" ]] ||
  fail "battery threshold leaves a start threshold already below the new end alone"
[[ $(<"$thinkpad/ucsi-source-psy-USBC000:001/charge_control_end_threshold") == "50" ]] ||
  fail "battery threshold does not write to a USB-C power source"

pass "battery threshold writes the end threshold and leaves a lower start alone"

# thinkpad_acpi, dell_laptop and the TUXEDO driver test start < end after each
# write, not across the pair. Thus an end at or below the current start needs room
# first.
printf '90\n' >"$thinkpad/BAT0/charge_control_start_threshold"
apply "$thinkpad" 80 >/dev/null
[[ $(<"$thinkpad/BAT0/charge_control_start_threshold") == "75" ]] ||
  fail "battery threshold lowers a start threshold that blocks the new end" \
    "got: $(<"$thinkpad/BAT0/charge_control_start_threshold")"

printf '90\n' >"$thinkpad/BAT0/charge_control_start_threshold"
apply "$thinkpad" 3 >/dev/null
[[ $(<"$thinkpad/BAT0/charge_control_start_threshold") == "0" ]] ||
  fail "battery threshold floors the lowered start at zero"

pass "battery threshold orders the pair so start stays below end"

apply "$end_only" 60 >/dev/null
[[ $(<"$end_only/BAT0/charge_control_end_threshold") == "60" ]] ||
  fail "battery threshold writes an end-only driver"
[[ ! -e $end_only/BAT0/charge_control_start_threshold ]] ||
  fail "battery threshold does not create a start file the driver never exposed"

pass "battery threshold writes an end-only driver without creating a start file"

output=$(apply "$thinkpad" off)
[[ $output == "100" ]] || fail "battery threshold maps off to 100" "got: $output"
[[ $(<"$thinkpad/BAT0/charge_control_end_threshold") == "100" ]] ||
  fail "battery threshold clears the limit for off"

pass "battery threshold maps off to no limit"

for bad in 101 -1 banana "" "80 90"; do
  apply "$thinkpad" $bad >/dev/null 2>&1 &&
    fail "battery threshold rejects out-of-range or non-numeric input: '$bad'"
done

apply "$desktop" 80 >/dev/null 2>&1 &&
  fail "battery threshold refuses to set a limit on hardware that has none"

pass "battery threshold rejects bad input and unsupported hardware"

# ------------------------------------------------------------------ state ----

state_dir="$tmp_dir/state"
stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"

# Stands in for the elevation at the end of run_privileged, so a test can run the
# unprivileged half of the setter without sudo or polkit. It fails on request, to
# prove that the code does not record a rejected value.
cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
if [[ $1 == -n && $2 == -l ]]; then
  echo "    Options: !authenticate"
  exit 0
fi
[[ -n ${STUB_APPLY_FAILS:-} ]] && exit 1
exit 0
STUB
# pkexec is never reached while the sudo stub grants; a stub only keeps a real
# pkexec from being found.
cat >"$stub_bin/pkexec" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$stub_bin/sudo" "$stub_bin/pkexec"

set_limit() {
  OMARCHY_POWER_SUPPLY_PATH="$thinkpad" \
  OMARCHY_BATTERY_STATE_DIR="$state_dir" \
  PATH="$stub_bin:$PATH" \
    "$threshold" "$@" </dev/null
}

set_limit 80 >/dev/null
[[ $(<"$state_dir/threshold") == "80" ]] ||
  fail "battery threshold records the value it set" "got: $(<"$state_dir/threshold")"

# A login must not replay a value that the hardware refused.
STUB_APPLY_FAILS=1 set_limit 60 >/dev/null 2>&1 &&
  fail "battery threshold fails when the privileged half does"
[[ $(<"$state_dir/threshold") == "80" ]] ||
  fail "battery threshold does not record a value the hardware refused" \
    "got: $(<"$state_dir/threshold")"

pass "battery threshold records only what the hardware took"

# The grant is what makes sudo passwordless. Without the grant, the code must route
# to polkit. An install still on an older omarchy-settings does this, and so does a
# user outside %wheel. A bet on sudo here makes the slider in the panel exec into a
# password prompt that it has no terminal to show.
cat >"$stub_bin/sudo" <<'STUB'
#!/bin/bash
if [[ $1 == -n && $2 == -l ]]; then
  echo "    Matched: ${!#}"
  exit 0
fi
printf 'sudo %s\n' "$*" >"$ELEVATION_LOG"
STUB
cat >"$stub_bin/pkexec" <<'STUB'
#!/bin/bash
printf 'pkexec %s\n' "$*" >"$ELEVATION_LOG"
STUB
chmod +x "$stub_bin/sudo" "$stub_bin/pkexec"

: >"$tmp_dir/elevation"
ELEVATION_LOG="$tmp_dir/elevation" set_limit 80 >/dev/null
elevation=$(<"$tmp_dir/elevation")
[[ $elevation == "pkexec /usr/bin/omarchy-battery-threshold --apply 80" ]] ||
  fail "battery threshold falls back to polkit where the sudoers grant is not installed" \
    "got: $elevation"

pass "battery threshold falls back to polkit wherever the grant does not reach"

# ------------------------------------------------------------------- init ----

init_run() {
  OMARCHY_POWER_SUPPLY_PATH="$1" \
  OMARCHY_BATTERY_STATE_DIR="$2" \
  PATH="$stub_bin:$ROOT/bin:$PATH" \
    "$init" </dev/null
}

init_run "$thinkpad" "$tmp_dir/empty-state" ||
  fail "battery threshold init is a no-op with nothing saved"

init_run "$desktop" "$state_dir" ||
  fail "battery threshold init is a no-op on hardware with no charge limit"

mkdir -p "$tmp_dir/junk-state"
printf 'banana\n' >"$tmp_dir/junk-state/threshold"
init_run "$thinkpad" "$tmp_dir/junk-state" ||
  fail "battery threshold init ignores a state file it cannot parse"

pass "battery threshold init exits quietly where there is nothing to restore"

# The EC kept the limit across the reboot. Restoring elevates nothing, so a login
# on an install without the sudoers grant does not stop at a polkit prompt.
printf '80\n' >"$thinkpad/BAT0/charge_control_end_threshold"
: >"$tmp_dir/elevation"
ELEVATION_LOG="$tmp_dir/elevation" init_run "$thinkpad" "$state_dir"
[[ -z $(<"$tmp_dir/elevation") ]] ||
  fail "battery threshold init does not elevate where the hardware kept the limit" \
    "got: $(<"$tmp_dir/elevation")"

# The EC lost it. The saved value replays through the normal setter path.
printf '100\n' >"$thinkpad/BAT0/charge_control_end_threshold"
: >"$tmp_dir/elevation"
ELEVATION_LOG="$tmp_dir/elevation" init_run "$thinkpad" "$state_dir"
elevation=$(<"$tmp_dir/elevation")
[[ $elevation == "pkexec /usr/bin/omarchy-battery-threshold --apply 80" ]] ||
  fail "battery threshold init replays a limit the hardware lost" "got: $elevation"

pass "battery threshold init replays only a limit the hardware lost"

# ---------------------------------------------------------------- sudoers ----

rule='%wheel ALL=(root) NOPASSWD: /usr/bin/omarchy-battery-threshold --apply [0-9], /usr/bin/omarchy-battery-threshold --apply [0-9][0-9], /usr/bin/omarchy-battery-threshold --apply 100'

rules=$(grep -vE '^[[:space:]]*(#|$)' "$sudoers_file")
[[ $rules == "$rule" ]] ||
  fail "battery threshold sudoers file carries exactly the --apply rule and nothing else" "got: $rules"

# The bare form writes the state file. A grant for it puts that file in the home
# directory of root, at the moment the panel takes the sudo path.
grep -q 'omarchy-battery-threshold [^-]' <<<"$rules" &&
  fail "battery threshold sudoers grants only the --apply form, never the bare setter"

if command -v visudo >/dev/null; then
  visudo -cf "$sudoers_file" >/dev/null || fail "battery threshold sudoers rule parses"
fi

grep -Fx 'PACKAGED_PATH=/usr/bin/omarchy-battery-threshold' "$threshold" >/dev/null ||
  fail "battery threshold elevates the path the sudoers rule names"

grep -E 'sudo -n -l -l' "$threshold" >/dev/null ||
  fail "battery threshold reads the grant from the long sudo listing"

pass "battery threshold sudoers rule is scoped to the privileged half"

grep -Fq 'omarchy-battery-threshold-init' "$ROOT/default/hypr/autostart.lua" ||
  fail "battery threshold is restored from autostart"

pass "battery threshold is restored at session start"
