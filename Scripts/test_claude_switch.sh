#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'if [ -n "${TEST_SLEEP_PID:-}" ]; then kill "$TEST_SLEEP_PID" 2>/dev/null || true; wait "$TEST_SLEEP_PID" 2>/dev/null || true; fi; rm -rf "$TEMP_ROOT"' EXIT
mkdir -p "$TEMP_ROOT/bin"
cat > "$TEMP_ROOT/bin/pgrep" <<'STUB'
#!/bin/sh
if [ -n "${FAKE_RUNNING_PID:-}" ]; then printf '%s\n' "$FAKE_RUNNING_PID"; exit 0; fi
exit 1
STUB
chmod +x "$TEMP_ROOT/bin/pgrep"
# The upstream test uses a fake Keychain and an isolated HOME. Suppress real
# machine process discovery so the user's running sessions cannot affect it.
env -u CCSWITCH_TEST_CLAUDE PATH="$TEMP_ROOT/bin:$PATH" bash "$ROOT/Vendor/ccswitch/test/keychain.sh"
# Guard must run before even creating or changing the shared MCP credential pool.
mkdir -p "$TEMP_ROOT/home" "$TEMP_ROOT/vault"
sleep 60 & TEST_SLEEP_PID=$!
if env HOME="$TEMP_ROOT/home" CCSWITCH_HOME="$TEMP_ROOT/vault" CCSWITCH_BACKEND=file \
  FAKE_RUNNING_PID="$TEST_SLEEP_PID" PATH="$TEMP_ROOT/bin:$PATH" \
  bash "$ROOT/Vendor/ccswitch/bin/ccswitch" use test > "$TEMP_ROOT/out" 2>&1; then
    echo 'FAIL: switching was allowed while Claude was running' >&2; exit 1
fi
if ! grep -q 'Claude Code is running' "$TEMP_ROOT/out" || [ -e "$TEMP_ROOT/vault/mcp-oauth.json" ]; then
    echo 'FAIL: running-session guard was late or missing' >&2; exit 1
fi
printf 'PASS: running-session guard prevents credential writes\n'
# Reproduce the migration from an older isolated profile with fake Keychain items.
mkdir -p "$TEMP_ROOT/migration-home/.claude" "$TEMP_ROOT/migration-home/old-profile" "$TEMP_ROOT/fake-keychain"
cat > "$TEMP_ROOT/bin/uname" <<'STUB'
#!/bin/sh
[ "${1:-}" = -n ] && { printf 'test-host\n'; exit 0; }
printf 'Darwin\n'
STUB
chmod +x "$TEMP_ROOT/bin/uname"
export HOME="$TEMP_ROOT/migration-home" USER=testuser FAKE_KEYCHAIN="$TEMP_ROOT/fake-keychain"
export PATH="$TEMP_ROOT/bin:$ROOT/Vendor/ccswitch/test/fixtures:$PATH" CCSWITCH_HOME="$TEMP_ROOT/shared-vault"
unset FAKE_RUNNING_PID CLAUDE_CONFIG_DIR CCSWITCH_BACKEND XDG_CONFIG_HOME
cat > "$HOME/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"first@example.test"},"userID":"first","mcpServers":{"shared":{"command":"fake"}}}
JSON
cat > "$HOME/old-profile/.claude.json" <<'JSON'
{"oauthAccount":{"emailAddress":"second@example.test"},"userID":"second"}
JSON
python3 - <<'PY'
import hashlib, json, os, subprocess, time
home=os.environ['HOME']; user=os.environ['USER']; now=int(time.time()*1000)
for folder, token, suffix, expiry in [(None,'first','',now+2400000000),(home+'/old-profile','second',None,now+2500000000)]:
 if suffix is None: suffix='-'+hashlib.sha256(folder.encode()).hexdigest()[:8]
 cred={'claudeAiOauth':{'accessToken':token,'refreshToken':'refresh-'+token,'expiresAt':now+3600000,'refreshTokenExpiresAt':expiry},'mcpOAuth':{'server':{'accessToken':'shared-mcp'}}}
 subprocess.run(['security','add-generic-password','-U','-a',user,'-s','Claude Code-credentials'+suffix,'-X',json.dumps(cred,separators=(',',':')).encode().hex()],check=True)
PY
HELPER="$ROOT/Vendor/ccswitch/bin/ccswitch"
bash "$HELPER" add first >/dev/null
CLAUDE_CONFIG_DIR="$HOME/old-profile" CCSWITCH_HOME="$TEMP_ROOT/migration-vault" bash "$HELPER" add second >/dev/null
mv "$TEMP_ROOT/migration-vault/accounts/second" "$CCSWITCH_HOME/accounts/second"
bash "$HELPER" use second >/dev/null
python3 - <<'PY'
import json, os, subprocess
home=os.environ['HOME']; vault=os.environ['CCSWITCH_HOME']; user=os.environ['USER']
identity=json.load(open(home+'/.claude.json'))
cred=json.loads(subprocess.check_output(['security','find-generic-password','-a',user,'-s','Claude Code-credentials','-w']))
assert identity['oauthAccount']['emailAddress']=='second@example.test'
assert identity['mcpServers']['shared']['command']=='fake'
assert cred['claudeAiOauth']['accessToken']=='second'
assert cred['mcpOAuth']['server']['accessToken']=='shared-mcp'
assert json.load(open(vault+'/accounts/first/credentials.json'))['claudeAiOauth']['accessToken']=='first'
assert os.stat(vault+'/accounts/second/credentials.json').st_mode & 0o077 == 0
PY
printf 'PASS: earlier account migrates while current account and MCP sign-in are preserved\n'
if FAKE_DENY_DELETE=1 bash "$HELPER" logout-local > "$TEMP_ROOT/denied" 2>&1; then
    echo 'FAIL: local sign-out succeeded despite denied Keychain deletion' >&2; exit 1
fi
python3 - <<'PYDENIED'
import json,os,subprocess
home=os.environ['HOME']; user=os.environ['USER']
assert json.load(open(home+'/.claude.json'))['oauthAccount']['emailAddress']=='second@example.test'
cred=json.loads(subprocess.check_output(['security','find-generic-password','-a',user,'-s','Claude Code-credentials','-w']))
assert cred['claudeAiOauth']['accessToken']=='second'
PYDENIED
printf 'PASS: denied Keychain deletion rolls identity back\n'
bash "$HELPER" logout-local >/dev/null
if security find-generic-password -a "$USER" -s Claude\ Code-credentials >/dev/null 2>&1; then
    echo 'FAIL: local logout left live Claude credential present' >&2; exit 1
fi
if [ ! -s "$CCSWITCH_HOME/accounts/second/credentials.json" ] || [ ! -s "$CCSWITCH_HOME/mcp-oauth.json" ]; then
    echo 'FAIL: local logout removed saved login or MCP pool' >&2; exit 1
fi
bash "$HELPER" use second >/dev/null
python3 - <<'PY'
import json,os,subprocess
cred=json.loads(subprocess.check_output(['security','find-generic-password','-a',os.environ['USER'],'-s','Claude Code-credentials','-w']))
assert cred['claudeAiOauth']['accessToken']=='second' and cred['mcpOAuth']['server']['accessToken']=='shared-mcp'
PY
printf 'PASS: local sign-out preserves the saved login and MCP sign-in\n'

# Atomic identity updates must preserve a user's symlink to their config.
mv "$HOME/.claude.json" "$HOME/claude-config.json"
ln -s "$HOME/claude-config.json" "$HOME/.claude.json"
bash "$HELPER" use first >/dev/null
[ -L "$HOME/.claude.json" ] || { echo 'FAIL: identity update replaced a config symlink' >&2; exit 1; }
python3 - <<'PYSYMLINK'
import json,os
assert json.load(open(os.environ['HOME']+'/claude-config.json'))['oauthAccount']['emailAddress']=='first@example.test'
PYSYMLINK
mkdir "$CCSWITCH_HOME/.profile-switch-lock"
printf '%s\n' "$$" > "$CCSWITCH_HOME/.profile-switch-lock/pid"
if bash "$HELPER" use second > "$TEMP_ROOT/locked" 2>&1; then
    echo 'FAIL: concurrent profile operation was allowed' >&2; exit 1
fi
grep -q 'operation is in progress' "$TEMP_ROOT/locked"
rm "$CCSWITCH_HOME/.profile-switch-lock/pid"
rmdir "$CCSWITCH_HOME/.profile-switch-lock"
printf 'PASS: config symlinks and concurrent operation lock\n'
# A failed identity write must roll back the new Keychain credential.
chmod 500 "$HOME"
if bash "$HELPER" use second > "$TEMP_ROOT/write-failed" 2>&1; then
    chmod 700 "$HOME"; echo 'FAIL: switching succeeded despite an unwritable config directory' >&2; exit 1
fi
chmod 700 "$HOME"
python3 - <<'PYROLLBACK'
import json,os,subprocess
home=os.environ['HOME']; user=os.environ['USER']
assert json.load(open(home+'/.claude.json'))['oauthAccount']['emailAddress']=='first@example.test'
cred=json.loads(subprocess.check_output(['security','find-generic-password','-a',user,'-s','Claude Code-credentials','-w']))
assert cred['claudeAiOauth']['accessToken']=='first'
assert open(os.environ['CCSWITCH_HOME']+'/active').read().strip()=='first'
PYROLLBACK
printf 'PASS: failed identity update rolls back credential and active account\n'
