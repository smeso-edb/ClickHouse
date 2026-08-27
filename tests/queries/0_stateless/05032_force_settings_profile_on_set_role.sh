#!/usr/bin/env bash
# Tags: no-random-settings
# - no-random-settings: the test harness injects randomized settings as URL parameters into
#   every HTTP request made through $CLICKHOUSE_URL. Several scenarios below run queries in
#   sessions with `readonly = 1`, where any injected setting change fails the whole request
#   with READONLY, and others assert exact setting values that an injected override would
#   change (e.g. `max_block_size`).

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Avoid carrying the test harness's log_comment URL parameter into HTTP sessions: after a
# profile sets `readonly=1`, applying that query-level setting would fail before the actual
# query runs, in the same way as the native client's `--send_logs_level`.
export CLICKHOUSE_LOG_COMMENT=
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

# Tests for `force_settings_profile_on_set_role`.
# When the setting is enabled, `SET ROLE` must apply the settings profile of the
# newly activated roles to the session, overwriting explicit session values, resetting
# stale values from previously active roles, replacing (not merging) constraints, and
# failing with READONLY if `readonly` is nonzero. With the setting off, behavior is unchanged.
#
# The session-state scenarios are run over HTTP with a `session_id` so the server-side
# session is the only source of truth. The native `clickhouse-client` keeps its own local
# copy of settings and re-sends explicit `SET` values as query-level settings on every
# subsequent query, which would hide the server-side session overwrite performed by
# `SET ROLE` (and its `--send_logs_level` query setting also makes queries fail after a
# profile sets `readonly=1`).

UNIQUE_NAME="${CLICKHOUSE_TEST_UNIQUE_NAME:-force_settings_profile_on_set_role}"

USER1="${UNIQUE_NAME}_user"
ROLE_A="${UNIQUE_NAME}_role_a"
ROLE_B="${UNIQUE_NAME}_role_b"
ROLE_RO="${UNIQUE_NAME}_role_ro"
ROLE_DEFAULT="${UNIQUE_NAME}_role_default"
ROLE_NOT_GRANTED="${UNIQUE_NAME}_role_not_granted"
PROFILE_A="${UNIQUE_NAME}_profile_a"
PROFILE_B="${UNIQUE_NAME}_profile_b"
PROFILE_RO="${UNIQUE_NAME}_profile_ro"
PROFILE_DEFAULT="${UNIQUE_NAME}_profile_default"

# `custom_` is a registered custom-settings prefix in the test server config.
CUSTOM_SETTING="custom_qux"

$CLICKHOUSE_CLIENT -q "DROP SETTINGS PROFILE IF EXISTS ${PROFILE_A}, ${PROFILE_B}, ${PROFILE_RO}, ${PROFILE_DEFAULT}" 2>/dev/null
$CLICKHOUSE_CLIENT -q "DROP USER IF EXISTS ${USER1}"
$CLICKHOUSE_CLIENT -q "DROP ROLE IF EXISTS ${ROLE_A}, ${ROLE_B}, ${ROLE_RO}, ${ROLE_DEFAULT}, ${ROLE_NOT_GRANTED}"

$CLICKHOUSE_CLIENT -q "
CREATE SETTINGS PROFILE ${PROFILE_A} SETTINGS max_result_rows = 111 MAX 200, max_block_size = 5678;
CREATE SETTINGS PROFILE ${PROFILE_B} SETTINGS max_result_rows = 222;
CREATE SETTINGS PROFILE ${PROFILE_RO} SETTINGS readonly = 1;
CREATE SETTINGS PROFILE ${PROFILE_DEFAULT} SETTINGS max_result_rows = 333;
CREATE ROLE ${ROLE_A} SETTINGS PROFILE ${PROFILE_A};
CREATE ROLE ${ROLE_B} SETTINGS PROFILE ${PROFILE_B};
CREATE ROLE ${ROLE_RO} SETTINGS PROFILE ${PROFILE_RO};
CREATE ROLE ${ROLE_DEFAULT} SETTINGS PROFILE ${PROFILE_DEFAULT};
CREATE ROLE ${ROLE_NOT_GRANTED};
CREATE USER ${USER1} NOT IDENTIFIED;
GRANT ${ROLE_A}, ${ROLE_B}, ${ROLE_RO}, ${ROLE_DEFAULT} TO ${USER1};
SET DEFAULT ROLE ${ROLE_DEFAULT} TO ${USER1};
"

AUTH="${USER1}:"

# Run one query in an HTTP session and print the response body. Each call uses the same
# `session_id`, so all calls share the server-side session state.
function http_session_query()
{
    local session_id="$1"
    local query="$2"
    $CLICKHOUSE_CURL -u "$AUTH" -sS "$CLICKHOUSE_URL&session_id=${session_id}" --data-binary "$query"
}

# Run an HTTP session query and print "Code: N (expected Code: N)", or a fallback marker
# if no error code is present in the response body.
function expect_http_code()
{
    local expected="$1"
    local session_id="$2"
    local query="$3"
    local out
    out=$(http_session_query "$session_id" "$query" | grep -oE "Code: [0-9]+" | head -1)
    if [ -z "$out" ]; then
        echo "no error (expected ${expected})"
    else
        echo "$out (expected ${expected})"
    fi
}

echo "### 1. Overwrite an explicit session SET and apply the new role's profile"
SESSION="${UNIQUE_NAME}_s1"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_session_query "$SESSION" "SET max_result_rows = 999" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('max_result_rows')"
http_session_query "$SESSION" "SET ROLE ${ROLE_A}" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('max_result_rows')"
http_session_query "$SESSION" "SELECT role_name = '${ROLE_A}' OR role_name = '${ROLE_B}' OR role_name = '${ROLE_DEFAULT}' FROM system.current_roles ORDER BY role_name"

echo "### 2. Switch role_a -> role_b applies role_b's profile"
SESSION="${UNIQUE_NAME}_s2"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_A}" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_B}" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('max_result_rows')"
http_session_query "$SESSION" "SELECT role_name = '${ROLE_A}' OR role_name = '${ROLE_B}' OR role_name = '${ROLE_DEFAULT}' FROM system.current_roles ORDER BY role_name"

echo "### 3. SET ROLE NONE resets role-managed settings"
SESSION="${UNIQUE_NAME}_s3"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_A}" >/dev/null
http_session_query "$SESSION" "SET ROLE NONE" >/dev/null
# Don't assert the compiled default here: the stateless-test default profile
# (tests/config/users.d/limits.yaml) manages max_result_rows, so after SET ROLE NONE the
# value is environment-dependent. Assert instead that both role_a's value (111) and the
# default role's value (333) are gone.
http_session_query "$SESSION" "SELECT getSetting('max_result_rows') NOT IN (111, 333)"
http_session_query "$SESSION" "SELECT count() FROM system.current_roles"

echo "### 4. SET ROLE DEFAULT applies the default roles' profile"
SESSION="${UNIQUE_NAME}_s4"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_B}" >/dev/null
http_session_query "$SESSION" "SET ROLE DEFAULT" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('max_result_rows')"
http_session_query "$SESSION" "SELECT role_name = '${ROLE_A}' OR role_name = '${ROLE_B}' OR role_name = '${ROLE_DEFAULT}' FROM system.current_roles ORDER BY role_name"

echo "### 5. Stale-profile cleanup: settings of the previous role revert to defaults"
SESSION="${UNIQUE_NAME}_s5"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_A}" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('max_block_size')"
http_session_query "$SESSION" "SET ROLE ${ROLE_B}" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('max_result_rows')"
http_session_query "$SESSION" "SELECT getSetting('max_block_size')"

echo "### 6. Constraints are replaced, not merged (role_a MAX=200 <-> role_b value 222)"
SESSION="${UNIQUE_NAME}_s6"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_A}" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_B}" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('max_result_rows')"
http_session_query "$SESSION" "SET max_result_rows = 999" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('max_result_rows')"
http_session_query "$SESSION" "SET ROLE ${ROLE_A}" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('max_result_rows')"
echo "-- SET max_result_rows = 999 under role_a must fail with a constraint violation:"
expect_http_code "Code: 452" "$SESSION" "SET max_result_rows = 999"

echo "### 7. readonly guard (readonly = 1): SET ROLE fails, session intact"
echo "-- SET ROLE role_a with readonly = 1 must fail with READONLY:"
SESSION="${UNIQUE_NAME}_s7a"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_B}" >/dev/null
http_session_query "$SESSION" "SET readonly = 1" >/dev/null
expect_http_code "Code: 164" "$SESSION" "SET ROLE ${ROLE_A}"
echo "-- role and settings unchanged after the failed SET ROLE:"
SESSION="${UNIQUE_NAME}_s7b"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_B}" >/dev/null
http_session_query "$SESSION" "SET max_result_rows = 777" >/dev/null
http_session_query "$SESSION" "SET readonly = 1" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_A}" >/dev/null
http_session_query "$SESSION" "SELECT role_name = '${ROLE_A}' OR role_name = '${ROLE_B}' OR role_name = '${ROLE_DEFAULT}' FROM system.current_roles ORDER BY role_name"
http_session_query "$SESSION" "SELECT getSetting('max_result_rows')"

echo "### 8. readonly guard (readonly = 2): SET ROLE fails the same way"
SESSION="${UNIQUE_NAME}_s8"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_session_query "$SESSION" "SET readonly = 2" >/dev/null
expect_http_code "Code: 164" "$SESSION" "SET ROLE ${ROLE_B}"

echo "### 9. A profile setting readonly=1 locks out further SET ROLE (fail-closed)"
SESSION="${UNIQUE_NAME}_s9"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_RO}" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('readonly')"
echo "-- any further SET ROLE now fails with READONLY (even SET ROLE DEFAULT):"
expect_http_code "Code: 164" "$SESSION" "SET ROLE DEFAULT"

echo "### 10. Non-granted role: fails before settings are touched"
SESSION="${UNIQUE_NAME}_s10"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_session_query "$SESSION" "SET max_result_rows = 999" >/dev/null
expect_http_code "Code: 512" "$SESSION" "SET ROLE ${ROLE_NOT_GRANTED}"
echo "-- settings are unchanged after the failed SET ROLE:"
http_session_query "$SESSION" "SELECT getSetting('max_result_rows')"
http_session_query "$SESSION" "SELECT count() FROM system.current_roles"

echo "### 11. Flag self-preservation across SET ROLE switches"
SESSION="${UNIQUE_NAME}_s11"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_A}" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_B}" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('force_settings_profile_on_set_role')"
http_session_query "$SESSION" "SELECT getSetting('max_result_rows')"

echo "### 12. Default off: explicit session SET survives SET ROLE (unchanged behavior)"
SESSION="${UNIQUE_NAME}_s12"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 0" >/dev/null
http_session_query "$SESSION" "SET max_result_rows = 999" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_A}" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('max_result_rows')"

echo "### 13. Custom settings are reset by SET ROLE too"
SESSION="${UNIQUE_NAME}_s13"
http_session_query "$SESSION" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_session_query "$SESSION" "SET ${CUSTOM_SETTING} = 5" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('${CUSTOM_SETTING}')"
http_session_query "$SESSION" "SET ROLE ${ROLE_B}" >/dev/null
echo "-- getSetting('custom_qux') after SET ROLE (expected: UNKNOWN_SETTING):"
expect_http_code "Code: 115" "$SESSION" "SELECT getSetting('${CUSTOM_SETTING}')"

echo "### 14. HTTP GET forces readonly=2 on the query context: SET ROLE fails closed"
echo "-- GET (readonly=2 implied) with the flag enabled per-request:"
OUT=$($CLICKHOUSE_CURL -u "$AUTH" -sS -G "$CLICKHOUSE_URL&force_settings_profile_on_set_role=1" --data-urlencode "query=SET ROLE ${ROLE_B}" 2>&1)
if echo "$OUT" | grep -q "Code: 164"; then echo "Code: 164"; else echo "no error (expected Code: 164): $(echo "$OUT" | head -1)"; fi
echo "-- GET (readonly=2 implied), flag enabled via session: still READONLY:"
OUT=$($CLICKHOUSE_CURL -u "$AUTH" -sS -G "$CLICKHOUSE_URL&session_id=${UNIQUE_NAME}_sess" --data-urlencode "query=SET force_settings_profile_on_set_role = 1" 2>&1)
OUT=$($CLICKHOUSE_CURL -u "$AUTH" -sS -G "$CLICKHOUSE_URL&session_id=${UNIQUE_NAME}_sess" --data-urlencode "query=SET ROLE ${ROLE_B}" 2>&1)
if echo "$OUT" | grep -q "Code: 164"; then echo "Code: 164"; else echo "no error (expected Code: 164): $(echo "$OUT" | head -1)"; fi

echo "### 15. HTTP POST with ?readonly=1 URL param: guard sees the per-request value"
echo "-- POST with the flag and readonly=1 (per-request): SET ROLE fails with READONLY:"
OUT=$($CLICKHOUSE_CURL -u "$AUTH" -sS "$CLICKHOUSE_URL&session_id=${UNIQUE_NAME}_sess3&force_settings_profile_on_set_role=1&readonly=1" --data-binary "SET ROLE ${ROLE_B}" 2>&1)
if echo "$OUT" | grep -q "Code: 164"; then echo "Code: 164"; else echo "no error (expected Code: 164): $(echo "$OUT" | head -1)"; fi
echo "-- the same POST without readonly: SET ROLE succeeds:"
OUT=$($CLICKHOUSE_CURL -u "$AUTH" -sS "$CLICKHOUSE_URL&session_id=${UNIQUE_NAME}_sess3&force_settings_profile_on_set_role=1" --data-binary "SET ROLE ${ROLE_B}" 2>&1)
if echo "$OUT" | grep -qE "Code: [0-9]+"; then echo "$OUT" | grep -oE "Code: [0-9]+" | head -1; else echo "ok"; fi
echo "-- and the profile was applied to the session (max_result_rows = 222):"
OUT=$($CLICKHOUSE_CURL -u "$AUTH" -sS "$CLICKHOUSE_URL&session_id=${UNIQUE_NAME}_sess3" --data-binary "SELECT getSetting('max_result_rows')" 2>&1 | head -1)
echo "$OUT" | grep -oE "^[0-9]+$|Code: [0-9]+"

echo "### 16. Flag off (default): SET ROLE performs no readonly check (existing behavior)"
echo "-- SET readonly = 1 then SET ROLE role_b succeeds today (only SET, not SET ROLE, checks readonly):"
SESSION="${UNIQUE_NAME}_s16"
http_session_query "$SESSION" "SET readonly = 1" >/dev/null
http_session_query "$SESSION" "SET ROLE ${ROLE_B}" >/dev/null
http_session_query "$SESSION" "SELECT getSetting('max_result_rows')"

$CLICKHOUSE_CLIENT -q "DROP USER ${USER1}"
$CLICKHOUSE_CLIENT -q "DROP ROLE ${ROLE_A}, ${ROLE_B}, ${ROLE_RO}, ${ROLE_DEFAULT}, ${ROLE_NOT_GRANTED}"
$CLICKHOUSE_CLIENT -q "DROP SETTINGS PROFILE ${PROFILE_A}, ${PROFILE_B}, ${PROFILE_RO}, ${PROFILE_DEFAULT}"
