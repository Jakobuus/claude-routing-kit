#!/bin/bash
. "$(dirname "$0")/lib.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PLUGIN_ROOT="$REPO_ROOT/plugins/routing-kit"
QUOTA="$PLUGIN_ROOT/bin/kit-quota"
STATUSLINE="$PLUGIN_ROOT/bin/kit-statusline"

mkprofile() {
  # mkprofile FILE codex jules kimi glm
  printf '{"version":1,"claude_plan":"pro","codex":"%s","jules":%s,"kimi":%s,"glm":%s,"paseo":false}\n' \
    "$2" "$3" "$4" "$5" > "$1"
}

# ---- kit-quota: Claude, fresh sample --------------------------------
d=$(mktmp)
mkprofile "$d/profile.json" none false false false
now=$(date +%s)
reset5=$((now + 7200))     # resets in 2h
resetwk=$((now + 500000))
printf '{"five_hour":{"used_percentage":35,"resets_at":%s},"seven_day":{"used_percentage":10,"resets_at":%s},"sampled":%s}\n' \
  "$reset5" "$resetwk" "$now" > "$d/claude-limits.json"
out=$(env ROUTING_KIT_HOME="$d" CODEX_HOME="$d/no-codex" "$QUOTA")
code=$?
assert_eq 0 "$code" "kit-quota exits 0 on a fresh, valid claude-limits.json"
assert_contains "$out" "Claude 5h 35%" "kit-quota shows the five-hour percent"

# A missing first window must leave the weekly values in their own slot.
dm=$(mktmp); mkprofile "$dm/profile.json" none false false false
printf '{"seven_day":{"used_percentage":41,"resets_at":%s},"sampled":%s}\n' "$resetwk" "$now" > "$dm/claude-limits.json"
json=$(ROUTING_KIT_HOME="$dm" "$QUOTA" --json)
assert_eq null "$(printf '%s' "$json" | /usr/bin/jq -r '.claude.five_hour.percent')" "missing 5h stays unknown"
assert_eq 41 "$(printf '%s' "$json" | /usr/bin/jq -r '.claude.week.percent')" "weekly value stays weekly"

# ---- kit-quota: same file, sampled 7h ago -> marked stale/old --------
d2=$(mktmp)
mkprofile "$d2/profile.json" none false false false
old_sampled=$((now - 25200))  # 7h ago
printf '{"five_hour":{"used_percentage":35,"resets_at":%s},"seven_day":{"used_percentage":10,"resets_at":%s},"sampled":%s}\n' \
  "$reset5" "$resetwk" "$old_sampled" > "$d2/claude-limits.json"
out=$(env ROUTING_KIT_HOME="$d2" CODEX_HOME="$d2/no-codex" "$QUOTA")
assert_contains "$out" "(7 h old)" "kit-quota marks a 7h-old sample as stale"

# ---- kit-quota: malformed claude-limits.json -> "-", exit 0 ---------
d3=$(mktmp)
mkprofile "$d3/profile.json" none false false false
echo '{not json' > "$d3/claude-limits.json"
out=$(env ROUTING_KIT_HOME="$d3" CODEX_HOME="$d3/no-codex" "$QUOTA")
code=$?
assert_eq 0 "$code" "kit-quota exits 0 on a malformed claude-limits.json"
assert_contains "$out" "–" "kit-quota falls back to the em-dash for unreadable Claude data"

# ---- kit-quota: Codex fixture session with primary/secondary windows -
d4=$(mktmp)
mkprofile "$d4/profile.json" plus false false false
sessdir="$d4/codex-home/sessions/2026/09/29"
mkdir -p "$sessdir"
c5reset=$((now + 3600))
cwkreset=$((now + 400000))
cat > "$sessdir/rollout-test.jsonl" <<EOF
{"type":"other"}
{"type":"turn","rate_limits":{"primary":{"used_percent":20,"resets_at":$c5reset,"window_minutes":300},"secondary":{"used_percent":54,"resets_at":$cwkreset,"window_minutes":10080}}}
EOF
out=$(env ROUTING_KIT_HOME="$d4" CODEX_HOME="$d4/codex-home" "$QUOTA")
assert_contains "$out" "Codex 5h 20%" "kit-quota shows Codex 5h percent from the newest session line"
assert_contains "$out" "wk 54%" "kit-quota shows Codex weekly percent from the newest session line"

# ---- kit-quota: Codex off in the profile -> absent from text and JSON
d5=$(mktmp)
mkprofile "$d5/profile.json" none false false false
out=$(env ROUTING_KIT_HOME="$d5" CODEX_HOME="$d4/codex-home" "$QUOTA")
case "$out" in
  *Codex*) fail "kit-quota text mentions Codex even though the profile has it off" ;;
  *) pass ;;
esac
json=$(env ROUTING_KIT_HOME="$d5" CODEX_HOME="$d4/codex-home" "$QUOTA" --json)
got=$(echo "$json" | /usr/bin/jq -r '.codex')
assert_eq "null" "$got" "kit-quota --json reports codex:null when the lane is off"

# ---- kit-quota: Kimi ledger sums two lines ---------------------------
d6=$(mktmp)
mkprofile "$d6/profile.json" none false true false
month=$(date +%Y-%m-01)
printf 'date\tlane\tmodel\tname\tin\tout\texit\n' > "$d6/ledger.tsv"
printf '%s\tlocked-build\tkimi-k2.7-code\trun-a\t100\t200\t0\n' "$month" >> "$d6/ledger.tsv"
printf '%s\tlocked-build\tkimi-k2.7-code\trun-b\t50\t25\t0\n' "$month" >> "$d6/ledger.tsv"
out=$(env ROUTING_KIT_HOME="$d6" CODEX_HOME="$d6/no-codex" "$QUOTA")
assert_contains "$out" 'Kimi $– this month (375 tok)' "old ledger lines have unknown spend and known tokens"
json=$(env ROUTING_KIT_HOME="$d6" CODEX_HOME="$d6/no-codex" "$QUOTA" --json)
got=$(echo "$json" | /usr/bin/jq -r '.kimi.tokens')
assert_eq "375" "$got" "kit-quota --json reports the same Kimi sum"
assert_eq null "$(echo "$json" | /usr/bin/jq -r '.kimi.spend_usd')" "old ledger cost is unknown"

# New rows attribute by provider even when the model name has no prefix.
dc=$(mktmp); mkprofile "$dc/profile.json" none false true true
printf 'date\tlane\tmodel\tname\tin\tout\texit\tprovider\tcost_usd\n' > "$dc/ledger.tsv"
printf '%s\tlocked-build\tcustom\ta\t1000000\t200000\t0\tkimi\t0.42\n' "$month" >> "$dc/ledger.tsv"
printf '%s\tlocked-build\tcustom\tb\t-\t50\t0\tglm\t\n' "$month" >> "$dc/ledger.tsv"
json=$(ROUTING_KIT_HOME="$dc" "$QUOTA" --json)
assert_eq 0.42 "$(echo "$json" | /usr/bin/jq -r '.kimi.spend_usd')" "provider column attributes Kimi cost"
assert_eq 1200000 "$(echo "$json" | /usr/bin/jq -r '.kimi.tokens')" "new row has input and output token total"
assert_eq null "$(echo "$json" | /usr/bin/jq -r '.glm.tokens')" "missing token count stays unknown"
assert_eq null "$(echo "$json" | /usr/bin/jq -r '.glm.spend_usd')" "missing cost stays unknown"
out=$(ROUTING_KIT_HOME="$dc" "$QUOTA")
assert_contains "$out" 'Kimi $0.42 this month (1.2M tok)' "formatted spend and million tokens"
assert_contains "$out" 'GLM $– this month (– tok)' "unknown counts and spend show dashes"

# A known spend under a cent must read "<$0.01", not scientific notation;
# an exact zero must read "$0.00", not "<$0.01" or blank.
dt=$(mktmp); mkprofile "$dt/profile.json" none false true true
printf 'date\tlane\tmodel\tname\tin\tout\texit\tprovider\tcost_usd\n' > "$dt/ledger.tsv"
printf '%s\tlocked-build\tcustom\ta\t20\t13\t0\tkimi\t0.000098\n' "$month" >> "$dt/ledger.tsv"
printf '%s\tlocked-build\tcustom\tb\t5\t5\t0\tglm\t0\n' "$month" >> "$dt/ledger.tsv"
out=$(ROUTING_KIT_HOME="$dt" "$QUOTA")
assert_contains "$out" 'Kimi <$0.01 this month (33 tok)' "a known spend under a cent reads <\$0.01, not scientific notation"
assert_contains "$out" 'GLM $0.00 this month (10 tok)' "an exact zero spend reads \$0.00"
json=$(ROUTING_KIT_HOME="$dt" "$QUOTA" --json)
assert_eq 0.000098 "$(echo "$json" | /usr/bin/jq -r '.kimi.spend_usd')" "the JSON keeps the exact small spend, unrounded"
assert_eq 0.0 "$(echo "$json" | /usr/bin/jq -r '.glm.spend_usd')" "the JSON keeps the exact zero spend"

# ---- kit-quota: works under env -i PATH=/usr/bin:/bin ----------------
d7=$(mktmp)
mkprofile "$d7/profile.json" none false false false
printf '{"five_hour":{"used_percentage":5,"resets_at":%s},"seven_day":{"used_percentage":1,"resets_at":%s},"sampled":%s}\n' \
  "$reset5" "$resetwk" "$now" > "$d7/claude-limits.json"
out=$(env -i PATH=/usr/bin:/bin HOME="$d7" ROUTING_KIT_HOME="$d7" CODEX_HOME="$d7/no-codex" "$QUOTA")
code=$?
assert_eq 0 "$code" "kit-quota exits 0 under a bare PATH"
assert_contains "$out" "Claude 5h 5%" "kit-quota still reads claude-limits.json under a bare PATH"

# ---- kit-statusline: no rate_limits -> old file left untouched -------
d8=$(mktmp)
mkprofile "$d8/profile.json" none false false false
printf '{"five_hour":{"used_percentage":42,"resets_at":%s},"seven_day":{"used_percentage":9,"resets_at":%s},"sampled":%s}\n' \
  "$reset5" "$resetwk" "$now" > "$d8/claude-limits.json"
before=$(cat "$d8/claude-limits.json")
echo '{"model":{"display_name":"Opus"}}' | env ROUTING_KIT_HOME="$d8" "$STATUSLINE" >/dev/null
after=$(cat "$d8/claude-limits.json")
assert_eq "$before" "$after" "kit-statusline leaves claude-limits.json untouched when rate_limits is absent"

# ---- kit-statusline: writes claude-limits.json when rate_limits present
d9=$(mktmp)
mkprofile "$d9/profile.json" none false false false
printf '{"rate_limits":{"five_hour":{"used_percentage":61,"resets_at":%s},"seven_day":{"used_percentage":12,"resets_at":%s}}}\n' \
  "$reset5" "$resetwk" \
  | env ROUTING_KIT_HOME="$d9" "$STATUSLINE" >/dev/null
got=$(/usr/bin/jq -r '.five_hour.used_percentage' "$d9/claude-limits.json")
assert_eq "61" "$got" "kit-statusline writes the five_hour percent from rate_limits"
got_sampled=$(/usr/bin/jq -r '.sampled' "$d9/claude-limits.json")
[[ $got_sampled =~ ^[0-9]+$ ]] && pass || fail "kit-statusline writes a numeric sampled epoch"

# ---- kit-statusline: chains to the friend's previous statusline ------
d10=$(mktmp)
mkdir -p "$d10"
mkprofile "$d10/profile.json" none false false false
printf '{"previous_statusline":"echo hi"}\n' > "$d10/statusline-previous.json"
out=$(echo '{"model":{"display_name":"Opus"}}' | env ROUTING_KIT_HOME="$d10" "$STATUSLINE")
assert_eq "hi" "$out" "kit-statusline prints the previous statusline command's own output"

# ---- kit-statusline: no previous_statusline -> short default line ----
d11=$(mktmp)
mkprofile "$d11/profile.json" none false false false
out=$(echo '{"model":{"display_name":"Opus"}}' | env ROUTING_KIT_HOME="$d11" "$STATUSLINE")
[ -n "$out" ] && pass || fail "kit-statusline prints a default line when there is no previous statusline"

# ---- Jules: a normal session list is counted -------------------------
dj=$(mktmp)
jbin=$(mktmp)
mkprofile "$dj/profile.json" none true false false
cat > "$jbin/jules" <<'EOF'
#!/bin/bash
printf 'ID          Description    Repo       Last active    Status\n'
printf '111         fix a          me/r       2h10m ago      Completed\n'
printf '222         fix b          me/r       5m ago         In Progress\n'
EOF
chmod +x "$jbin/jules"
out=$(env PATH="$jbin:/usr/bin:/bin" ROUTING_KIT_HOME="$dj" CODEX_HOME="$dj/no-codex" "$QUOTA")
assert_contains "$out" "Jules 24h 13% (2/15, 1 running)" "kit-quota counts Jules sessions from the last 24 h"

# ---- Jules: profile's jules_daily_limit changes the denominator -------
dj2=$(mktmp)
printf '{"version":1,"claude_plan":"pro","codex":"none","jules":true,"kimi":false,"glm":false,"paseo":false,"jules_daily_limit":5}\n' \
  > "$dj2/profile.json"
out=$(env PATH="$jbin:/usr/bin:/bin" ROUTING_KIT_HOME="$dj2" CODEX_HOME="$dj2/no-codex" "$QUOTA")
assert_contains "$out" "Jules 24h 40% (2/5, 1 running)" "kit-quota uses the profile's jules_daily_limit (2/5=40%)"

# ---- Jules: KIT_JULES_DAILY_LIMIT still wins over the profile's value --
out=$(env PATH="$jbin:/usr/bin:/bin" KIT_JULES_DAILY_LIMIT=10 ROUTING_KIT_HOME="$dj2" CODEX_HOME="$dj2/no-codex" "$QUOTA")
assert_contains "$out" "Jules 24h 20% (2/10, 1 running)" "KIT_JULES_DAILY_LIMIT overrides the profile's jules_daily_limit"

# ---- Jules: a hung CLI is killed, the line still prints ----------------
dh=$(mktmp)
hbin=$(mktmp)
mkprofile "$dh/profile.json" none true false false
printf '#!/bin/bash\nexec /bin/sleep 30\n' > "$hbin/jules"
chmod +x "$hbin/jules"
start=$(date +%s)
out=$(env PATH="$hbin:/usr/bin:/bin" KIT_JULES_TIMEOUT=2 ROUTING_KIT_HOME="$dh" CODEX_HOME="$dh/no-codex" "$QUOTA")
took=$(( $(date +%s) - start ))
assert_contains "$out" "Jules 24h –" "a hung jules shows as unknown"
(( took < 10 )) && pass || fail "a hung jules is killed within the timeout (took ${took}s)"

# ---- Linux (and WSL2, which reports uname as Linux) is supported: kit-quota
# must run normally, not refuse the way it used to when the kit was
# macOS-only. -------------------------------------------------------------
d12=$(mktmp)
fakebin=$(mktmp)
cat > "$fakebin/uname" <<'EOF'
#!/bin/bash
echo "Linux"
EOF
chmod +x "$fakebin/uname"
mkprofile "$d12/profile.json" none false false false
assert_exit 0 "kit-quota runs on a faked Linux uname" -- env PATH="$fakebin:$PATH" ROUTING_KIT_HOME="$d12" "$QUOTA"

# ---- native Windows (no WSL, faked via a MINGW64_NT-shaped uname): still
# not a supported system, so kit-quota refuses with the supported-systems
# message. ------------------------------------------------------------------
d13=$(mktmp)
winbin=$(mktmp)
cat > "$winbin/uname" <<'EOF'
#!/bin/bash
echo "MINGW64_NT-10.0"
EOF
chmod +x "$winbin/uname"
mkprofile "$d13/profile.json" none false false false
out=$(env PATH="$winbin:$PATH" ROUTING_KIT_HOME="$d13" "$QUOTA" 2>&1)
code=$?
assert_eq 2 "$code" "kit-quota refuses on a faked native-Windows uname"
assert_contains "$out" "routing-kit needs macOS, Linux, or WSL2 on Windows" "kit-quota prints the supported-systems message"

# ---- a missing jq exits 3 with an install hint, not a silent all-"–"
# dashboard. KIT_TEST_NO_JQ forces "not found" the way a genuinely jq-less
# host would resolve, since this dev Mac always has /usr/bin/jq for real. --
d14=$(mktmp)
mkprofile "$d14/profile.json" none false false false
out=$(env KIT_TEST_NO_JQ=1 ROUTING_KIT_HOME="$d14" "$QUOTA" 2>&1)
code=$?
assert_eq 3 "$code" "kit-quota exits 3 when jq is missing"
assert_contains "$out" "install jq" "kit-quota gives the install-jq hint, not a blank dashboard"


# ---- kit-statusline install/uninstall: fake HOME only, never the real
# ~/.claude/settings.json -------------------------------------------------

# --- install with no prior statusLine: settings gets the shim, no
# previous_statusline is recorded, uninstall removes statusLine entirely --
fh1=$(mktmp)
mkdir -p "$fh1/.claude"
printf '{"otherKey":"keepme"}\n' > "$fh1/.claude/settings.json"
env HOME="$fh1" "$STATUSLINE" install
shim="$fh1/.config/routing-kit/bin/statusline"
[ -x "$shim" ] && pass || fail "install writes an executable shim"
got_cmd=$(/usr/bin/jq -r '.statusLine.command' "$fh1/.claude/settings.json")
assert_eq "$shim" "$got_cmd" "install points statusLine.command at the shim"
got_other=$(/usr/bin/jq -r '.otherKey' "$fh1/.claude/settings.json")
assert_eq "keepme" "$got_other" "install keeps other settings.json keys"
prof_prev=$(/usr/bin/jq -r '.previous_statusline // empty' "$fh1/.config/routing-kit/profile.json" 2>/dev/null)
assert_eq "" "$prof_prev" "install with no prior statusLine records no previous_statusline"

env HOME="$fh1" "$STATUSLINE" uninstall
has_statusline=$(/usr/bin/jq 'has("statusLine")' "$fh1/.claude/settings.json")
assert_eq "false" "$has_statusline" "uninstall removes statusLine when there was none before"
[ -e "$shim" ] && fail "uninstall did not remove the shim" || pass
got_other2=$(/usr/bin/jq -r '.otherKey' "$fh1/.claude/settings.json")
assert_eq "keepme" "$got_other2" "uninstall keeps other settings.json keys"

# --- install with an existing statusLine command: it's saved as
# previous_statusline and restored on uninstall ----------------------------
fh2=$(mktmp)
mkdir -p "$fh2/.claude"
printf '{"statusLine":{"type":"command","command":"echo old"}}\n' > "$fh2/.claude/settings.json"
env HOME="$fh2" "$STATUSLINE" install
prof_prev2=$(/usr/bin/jq -r '.previous_statusline_json.command' "$fh2/.config/routing-kit/statusline-previous.json")
assert_eq "echo old" "$prof_prev2" "install saves the existing statusLine command as previous_statusline"
got_cmd2=$(/usr/bin/jq -r '.statusLine.command' "$fh2/.claude/settings.json")
assert_eq "$fh2/.config/routing-kit/bin/statusline" "$got_cmd2" "install still points statusLine at the shim"

env HOME="$fh2" "$STATUSLINE" uninstall
got_cmd2b=$(/usr/bin/jq -r '.statusLine.command' "$fh2/.claude/settings.json")
assert_eq "echo old" "$got_cmd2b" "uninstall restores the previous statusLine command"
prof_prev2b=$(/usr/bin/jq -r '.previous_statusline // empty' "$fh2/.config/routing-kit/profile.json" 2>/dev/null)
assert_eq "" "$prof_prev2b" "uninstall drops previous_statusline from the profile"

# --- install is idempotent: a second install must not clobber the saved
# previous_statusline with the shim's own path ------------------------------
fh3=$(mktmp)
mkdir -p "$fh3/.claude"
printf '{"statusLine":{"type":"command","command":"echo original"}}\n' > "$fh3/.claude/settings.json"
env HOME="$fh3" "$STATUSLINE" install
env HOME="$fh3" "$STATUSLINE" install
prof_prev3=$(/usr/bin/jq -r '.previous_statusline_json.command' "$fh3/.config/routing-kit/statusline-previous.json")
assert_eq "echo original" "$prof_prev3" "a second install does not overwrite previous_statusline with the shim's own path"

# --- the shim: no plugin install and no kit-statusline on PATH -> prints a
# short line and exits 0, never fails the friend's whole statusline --------
fh4=$(mktmp)
mkdir -p "$fh4/.claude"
printf '{}\n' > "$fh4/.claude/settings.json"
env HOME="$fh4" "$STATUSLINE" install >/dev/null
shim4="$fh4/.config/routing-kit/bin/statusline"
out=$(echo '{}' | env HOME="$fh4" PATH=/usr/bin:/bin "$shim4")
code=$?
assert_eq 0 "$code" "the shim exits 0 even with nothing to chain to"
assert_contains "$out" "kit-statusline not found" "the shim explains it found nothing to run"

# --- the shim resolves the newest of several matching installs under
# ~/.claude/plugins (mtime, not path sort order) ----------------------------
fh5=$(mktmp)
mkdir -p "$fh5/.claude"
printf '{}\n' > "$fh5/.claude/settings.json"
env HOME="$fh5" "$STATUSLINE" install >/dev/null
shim5="$fh5/.config/routing-kit/bin/statusline"

old_install_dir="$fh5/.claude/plugins/zzz-newer-by-name-only/routing-kit/bin"
new_install_dir="$fh5/.claude/plugins/aaa-older-by-name-only/routing-kit/bin"
mkdir -p "$old_install_dir" "$new_install_dir"
printf '#!/bin/bash\necho from-old\n' > "$old_install_dir/kit-statusline"
printf '#!/bin/bash\necho from-new\n' > "$new_install_dir/kit-statusline"
chmod +x "$old_install_dir/kit-statusline" "$new_install_dir/kit-statusline"
touch -t 202501010000 "$old_install_dir/kit-statusline"
touch -t 202502020000 "$new_install_dir/kit-statusline"
out=$(echo '{}' | env HOME="$fh5" PATH=/usr/bin:/bin "$shim5")
assert_eq "from-new" "$out" "the shim runs the newest install by mtime, not alphabetical path order"

# --- a separate Claude config dir is the only settings/plugin tree touched --
fh6=$(mktmp)
mkdir -p "$fh6/.claude" "$fh6/other/plugins/cache/routing-kit/bin"
printf '{"real":"unchanged"}\n' > "$fh6/.claude/settings.json"
printf '{"other":true,"statusLine":{"type":"command","command":"echo prior","refreshInterval":30,"padding":2}}\n' > "$fh6/other/settings.json"
home_before=$(shasum "$fh6/.claude/settings.json")
status_before=$(/usr/bin/jq -c '.statusLine' "$fh6/other/settings.json")
env HOME="$fh6" CLAUDE_CONFIG_DIR="$fh6/other" "$STATUSLINE" install
assert_eq "$home_before" "$(shasum "$fh6/.claude/settings.json")" "install leaves default Claude settings byte-identical"
assert_eq 30 "$(/usr/bin/jq -r '.statusLine.refreshInterval' "$fh6/other/settings.json")" "install preserves refreshInterval"
assert_eq "$status_before" "$(/usr/bin/jq -c '.previous_statusline_json' "$fh6/.config/routing-kit/statusline-previous.json")" "install saves the full statusLine object"
out=$(printf '{}\n' | env HOME="$fh6" ROUTING_KIT_HOME="$fh6/.config/routing-kit" "$STATUSLINE")
assert_eq "prior" "$out" "statusline runtime chains to the command in the saved object"
printf '#!/bin/bash\necho from-config-dir\n' > "$fh6/other/plugins/cache/routing-kit/bin/kit-statusline"
chmod +x "$fh6/other/plugins/cache/routing-kit/bin/kit-statusline"
shim6="$fh6/.config/routing-kit/bin/statusline"
out=$(printf '{"rate_limits":{"five_hour":{"used_percentage":7}}}\n' | env HOME="$fh6" PATH=/usr/bin:/bin "$shim6")
assert_eq "from-config-dir" "$out" "shim resolves plugins under install-time CLAUDE_CONFIG_DIR"
# The real install layout has a version folder: cache/<marketplace>/routing-kit/<version>/bin.
mkdir -p "$fh6/other/plugins/cache/some-market/routing-kit/0.1.1/bin"
printf '#!/bin/bash\necho from-versioned\n' > "$fh6/other/plugins/cache/some-market/routing-kit/0.1.1/bin/kit-statusline"
chmod +x "$fh6/other/plugins/cache/some-market/routing-kit/0.1.1/bin/kit-statusline"
touch -t 203001010000 "$fh6/other/plugins/cache/some-market/routing-kit/0.1.1/bin/kit-statusline"
out=$(printf '{}\n' | env HOME="$fh6" PATH=/usr/bin:/bin "$shim6")
assert_eq "from-versioned" "$out" "shim finds kit-statusline under a versioned plugin cache folder"
env HOME="$fh6" CLAUDE_CONFIG_DIR="$fh6/other" "$STATUSLINE" uninstall
assert_eq "$home_before" "$(shasum "$fh6/.claude/settings.json")" "uninstall leaves default Claude settings byte-identical"
assert_eq "$status_before" "$(/usr/bin/jq -c '.statusLine' "$fh6/other/settings.json")" "uninstall restores all statusLine keys"

# --- old profiles with only the string field still restore their command --
fh7=$(mktmp)
mkdir -p "$fh7/other" "$fh7/.config/routing-kit"
printf '{"statusLine":{"type":"command","command":"%s"}}\n' "$fh7/.config/routing-kit/bin/statusline" > "$fh7/other/settings.json"
printf '{"previous_statusline":"echo legacy"}\n' > "$fh7/.config/routing-kit/profile.json"
env HOME="$fh7" CLAUDE_CONFIG_DIR="$fh7/other" "$STATUSLINE" uninstall
assert_eq "echo legacy" "$(/usr/bin/jq -r '.statusLine.command' "$fh7/other/settings.json")" "old string profile restores its statusLine command"

fm=$(mktmp); mkdir -p "$fm/.claude" "$fm/.config/routing-kit"
printf '{"version":1,"claude_plan":"pro","codex":"none","jules":false,"kimi":false,"glm":false,"paseo":false,"previous_statusline":"","previous_statusline_json":null}\n' > "$fm/.config/routing-kit/profile.json"
printf '{}\n' > "$fm/.claude/settings.json"
env HOME="$fm" "$STATUSLINE" install
assert_eq false "$(/usr/bin/jq -r 'has("previous_statusline") or has("previous_statusline_json")' "$fm/.config/routing-kit/profile.json")" "install removes empty legacy fields"

# Uninstall without an active shim must not rewrite settings, even once.
fu=$(mktmp); mkdir -p "$fu/.claude"
printf '{ "statusLine": { "command": "echo mine" }, "other": 1 }\n' > "$fu/.claude/settings.json"
before=$(shasum "$fu/.claude/settings.json")
env HOME="$fu" "$STATUSLINE" uninstall
assert_eq "$before" "$(shasum "$fu/.claude/settings.json")" "never-installed uninstall leaves settings bytes alone"
env HOME="$fu" "$STATUSLINE" uninstall
assert_eq "$before" "$(shasum "$fu/.claude/settings.json")" "repeated uninstall leaves settings bytes alone"
fr=$(mktmp); mkdir -p "$fr/.claude"
printf '{"statusLine":{"type":"command","command":"echo old"}}\n' > "$fr/.claude/settings.json"
env HOME="$fr" "$STATUSLINE" install
printf '{ "statusLine": { "type": "command", "command": "echo replacement" } }\n' > "$fr/.claude/settings.json"
before=$(shasum "$fr/.claude/settings.json")
env HOME="$fr" "$STATUSLINE" uninstall
assert_eq "$before" "$(shasum "$fr/.claude/settings.json")" "user replacement survives uninstall byte-identically"
if [ -f "$fr/.config/routing-kit/profile.json" ]; then
  assert_eq false "$(/usr/bin/jq -r 'has("previous_statusline_json")' "$fr/.config/routing-kit/profile.json")" "profile holds no previous statusline"
else pass; fi

echo "PASS $PASS_COUNT / FAIL $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
