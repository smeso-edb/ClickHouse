#!/usr/bin/env bash

# Tests the `force_settings_profile_on_set_role` settings with the HTTP `role` query
# parameter: when the setting is enabled, the settings profile of the
# roles given via `?role=...` parameters must be applied to the request's query context
# (overwriting explicit per-request settings, resetting stale ones, replacing
# constraints), and the request must fail closed with READONLY when `readonly` is
# nonzero (including GET/HEAD, where readonly=2 is implied). The `role` parameter stays
# per-request: nothing persists into the HTTP session. With the flag off, behavior is
# unchanged (except error precedence: the settings pipeline runs before role validation).

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Avoid carrying the test harness's log_comment URL parameter into HTTP sessions.
export CLICKHOUSE_LOG_COMMENT=
# shellcheck source=../shell_config.sh
. "$CUR_DIR"/../shell_config.sh

UNIQUE_NAME="${CLICKHOUSE_TEST_UNIQUE_NAME:-force_settings_profile_on_set_role_http_param}"

USER1="${UNIQUE_NAME}_user"
USER2="${UNIQUE_NAME}_user2"
ROLE_A="${UNIQUE_NAME}_role_a"
ROLE_B="${UNIQUE_NAME}_role_b"
ROLE_RO="${UNIQUE_NAME}_role_ro"
ROLE_DEFAULT="${UNIQUE_NAME}_role_default"
ROLE_NOT_GRANTED="${UNIQUE_NAME}_role_not_granted"
ROLE_FMT="${UNIQUE_NAME}_role_fmt"
ROLE_CONSTRAINED="${UNIQUE_NAME}_role_constrained"
PROFILE_A="${UNIQUE_NAME}_profile_a"
PROFILE_B="${UNIQUE_NAME}_profile_b"
PROFILE_RO="${UNIQUE_NAME}_profile_ro"
PROFILE_DEFAULT="${UNIQUE_NAME}_profile_default"
PROFILE_FMT="${UNIQUE_NAME}_profile_fmt"
PROFILE_CONSTRAINED="${UNIQUE_NAME}_profile_constrained"

SHOW_CURRENT_ROLES_QUERY="SELECT role_name FROM system.current_roles ORDER BY role_name ASC"
SHOW_ONE_ROLE_QUERY="SELECT role_name FROM system.current_roles ORDER BY role_name ASC LIMIT 1"

$CLICKHOUSE_CLIENT -q "DROP USER IF EXISTS ${USER1}, ${USER2}"
$CLICKHOUSE_CLIENT -q "DROP ROLE IF EXISTS ${ROLE_A}, ${ROLE_B}, ${ROLE_RO}, ${ROLE_DEFAULT}, ${ROLE_NOT_GRANTED}, ${ROLE_FMT}, ${ROLE_CONSTRAINED}"
# Roles first, profiles last: a leftover role keeps its profile referenced, so dropping the
# profile first would silently fail (stderr suppressed) and the CREATE below would collide.
$CLICKHOUSE_CLIENT -q "DROP SETTINGS PROFILE IF EXISTS ${PROFILE_A}, ${PROFILE_B}, ${PROFILE_RO}, ${PROFILE_DEFAULT}, ${PROFILE_FMT}, ${PROFILE_CONSTRAINED}" 2>/dev/null

$CLICKHOUSE_CLIENT -q "
CREATE SETTINGS PROFILE ${PROFILE_A} SETTINGS max_result_rows = 111 MAX 200, max_block_size = 678;
CREATE SETTINGS PROFILE ${PROFILE_B} SETTINGS max_result_rows = 222, max_insert_block_size = 345;
CREATE SETTINGS PROFILE ${PROFILE_RO} SETTINGS readonly = 1;
CREATE SETTINGS PROFILE ${PROFILE_DEFAULT} SETTINGS max_result_rows = 333;
CREATE SETTINGS PROFILE ${PROFILE_FMT} SETTINGS default_format = 'JSONEachRow', database = '${CLICKHOUSE_DATABASE}', http_allow_database_as_path = 1, http_allow_table_as_file = 1;
CREATE SETTINGS PROFILE ${PROFILE_CONSTRAINED} SETTINGS max_execution_time MAX 10;
CREATE ROLE ${ROLE_A} SETTINGS PROFILE ${PROFILE_A};
CREATE ROLE ${ROLE_B} SETTINGS PROFILE ${PROFILE_B};
CREATE ROLE ${ROLE_RO} SETTINGS PROFILE ${PROFILE_RO};
CREATE ROLE ${ROLE_DEFAULT} SETTINGS PROFILE ${PROFILE_DEFAULT};
CREATE ROLE ${ROLE_FMT} SETTINGS PROFILE ${PROFILE_FMT};
CREATE ROLE ${ROLE_CONSTRAINED} SETTINGS PROFILE ${PROFILE_CONSTRAINED};
CREATE ROLE ${ROLE_NOT_GRANTED};
CREATE USER ${USER1} NOT IDENTIFIED;
CREATE USER ${USER2} NOT IDENTIFIED;
GRANT ${ROLE_A}, ${ROLE_B}, ${ROLE_RO}, ${ROLE_DEFAULT}, ${ROLE_FMT} TO ${USER1};
GRANT ${ROLE_B}, ${ROLE_CONSTRAINED} TO ${USER2};
GRANT SELECT ON system.numbers TO ${USER1}, ${USER2};
SET DEFAULT ROLE ${ROLE_DEFAULT} TO ${USER1};
SET DEFAULT ROLE ${ROLE_CONSTRAINED} TO ${USER2};
"

AUTH="${USER1}:"
AUTH2="${USER2}:"

# Run one HTTP query (POST) and print the response body.
function http_query()
{
    local auth="$1"
    local url="$2"
    local query="$3"
    $CLICKHOUSE_CURL -u "$auth" -sS "$url" --data-binary "$query"
}

# Print "Code: N (expected Code: N)" if the response body carries that error code, or a
# failure marker otherwise. Also prints the marker when the expected code is absent.
function expect_code()
{
    local expected="$1"
    local out="$2"
    local code
    code=$(echo "$out" | grep -oE "Code: [0-9]+" | head -1)
    if [ -z "$code" ]; then
        echo "no error (expected ${expected})"
    else
        echo "${code} (expected ${expected})"
    fi
}

echo "### 1. Flag on via URL param: the new role's profile is applied to the request"
http_query "$AUTH" "$CLICKHOUSE_URL&role=${ROLE_A}&force_settings_profile_on_set_role=1" "SELECT getSetting('max_result_rows')"
http_query "$AUTH" "$CLICKHOUSE_URL&role=${ROLE_A}&force_settings_profile_on_set_role=1" "$SHOW_ONE_ROLE_QUERY"

echo "### 2. Explicit URL setting is overwritten by the new role's profile"
http_query "$AUTH" "$CLICKHOUSE_URL&max_result_rows=999&role=${ROLE_A}&force_settings_profile_on_set_role=1" "SELECT getSetting('max_result_rows')"

echo "### 3. Flag off (default): explicit URL setting survives (unchanged behavior)"
http_query "$AUTH" "$CLICKHOUSE_URL&max_result_rows=999&role=${ROLE_A}" "SELECT getSetting('max_result_rows')"

echo "### 4. GET request with the flag and a role parameter fails with READONLY (readonly=2 implied)"
OUT=$($CLICKHOUSE_CURL -u "$AUTH" -sS -G "$CLICKHOUSE_URL&role=${ROLE_A}&force_settings_profile_on_set_role=1" --data-urlencode "query=SELECT getSetting('max_result_rows')" 2>&1)
expect_code "Code: 164" "$OUT"

echo "### 5. POST with ?readonly=1, the flag and a role parameter fails with READONLY"
OUT=$(http_query "$AUTH" "$CLICKHOUSE_URL&readonly=1&role=${ROLE_A}&force_settings_profile_on_set_role=1" "SELECT 1" 2>&1)
expect_code "Code: 164" "$OUT"

echo "### 6. Non-granted role fails with SET_NON_GRANTED_ROLE"
OUT=$(http_query "$AUTH" "$CLICKHOUSE_URL&role=${ROLE_NOT_GRANTED}&force_settings_profile_on_set_role=1" "SELECT 1" 2>&1)
expect_code "Code: 512" "$OUT"

echo "### 7. Unknown role name fails with UNKNOWN_ROLE"
OUT=$(http_query "$AUTH" "$CLICKHOUSE_URL&role=${UNIQUE_NAME}_nonexistent&force_settings_profile_on_set_role=1" "SELECT 1" 2>&1)
expect_code "Code: 511" "$OUT"

echo "### 8. Multiple role parameters: the merged profile is applied"
echo "-- role_a and role_b each manage their own setting; both must be in force:"
http_query "$AUTH" "$CLICKHOUSE_URL&role=${ROLE_A}&role=${ROLE_B}&force_settings_profile_on_set_role=1" "SELECT getSetting('max_block_size')"
http_query "$AUTH" "$CLICKHOUSE_URL&role=${ROLE_A}&role=${ROLE_B}&force_settings_profile_on_set_role=1" "SELECT getSetting('max_insert_block_size')"
http_query "$AUTH" "$CLICKHOUSE_URL&role=${ROLE_A}&role=${ROLE_B}&force_settings_profile_on_set_role=1" "$SHOW_CURRENT_ROLES_QUERY"

echo "### 8b. Profile-managed readonly applies for the rest of the request (POST only)"
echo "-- ?role=role_ro with the flag: the new role's profile replaces the old roles' readonly = 0:"
http_query "$AUTH" "$CLICKHOUSE_URL&role=${ROLE_RO}&force_settings_profile_on_set_role=1" "SELECT getSetting('readonly')"
echo "-- a query-level change of a non-readonly-changeable setting in the same request fails READONLY:"
OUT=$(http_query "$AUTH" "$CLICKHOUSE_URL&role=${ROLE_RO}&force_settings_profile_on_set_role=1" "SELECT 1 SETTINGS max_block_size = 12345" 2>&1)
expect_code "Code: 164" "$OUT"

echo "### 9. Session isolation: the role parameter does not persist roles or settings"
SESSION="${UNIQUE_NAME}_s9"
http_query "$AUTH" "$CLICKHOUSE_URL&session_id=${SESSION}" "SET max_result_rows = 888" >/dev/null
echo "-- request with the role parameter and the flag (role_a's profile: 111):"
http_query "$AUTH" "$CLICKHOUSE_URL&session_id=${SESSION}&role=${ROLE_A}&force_settings_profile_on_set_role=1" "SELECT getSetting('max_result_rows')"
echo "-- follow-up request without the role parameter: default role and the session's own setting (888):"
http_query "$AUTH" "$CLICKHOUSE_URL&session_id=${SESSION}" "SELECT getSetting('max_result_rows')"
http_query "$AUTH" "$CLICKHOUSE_URL&session_id=${SESSION}" "$SHOW_ONE_ROLE_QUERY"

echo "### 10. Flag enabled in the session, role parameter only in the URL: profile applied"
SESSION="${UNIQUE_NAME}_s10"
http_query "$AUTH" "$CLICKHOUSE_URL&session_id=${SESSION}" "SET force_settings_profile_on_set_role = 1" >/dev/null
http_query "$AUTH" "$CLICKHOUSE_URL&session_id=${SESSION}&role=${ROLE_A}" "SELECT getSetting('max_result_rows')"

echo "### 11. Stale per-request settings are reset by the switch (max_block_size not managed by profile B)"
echo "-- ?max_block_size=5678 with role_b: the stale value is reset (getSetting != 5678):"
OUT=$(http_query "$AUTH" "$CLICKHOUSE_URL&max_block_size=5678&role=${ROLE_B}&force_settings_profile_on_set_role=1" "SELECT getSetting('max_block_size') != 5678")
echo "$OUT"

echo "### 12. Constraints are replaced: query-level settings are checked against the new role's constraints"
echo "-- within the new constraint (max_result_rows = 150 < 200): succeeds:"
http_query "$AUTH" "$CLICKHOUSE_URL&role=${ROLE_A}&force_settings_profile_on_set_role=1" "SELECT count() FROM (SELECT number FROM system.numbers LIMIT 300) SETTINGS max_result_rows = 150"
echo "-- over the new constraint (max_result_rows = 250 > 200): fails with a constraint violation:"
OUT=$(http_query "$AUTH" "$CLICKHOUSE_URL&role=${ROLE_A}&force_settings_profile_on_set_role=1" "SELECT count() FROM (SELECT number FROM system.numbers LIMIT 300) SETTINGS max_result_rows = 250" 2>&1)
expect_code "Code: 452" "$OUT"

echo "### 13. Constraint-check ordering (documented limitation): URL settings are checked against the pre-role constraints"
echo "-- user2's default profile constrains max_execution_time MAX 10; the new role (role_b) does not manage it."
echo "-- ?max_execution_time=20 is checked against the old (constrained) profile and fails even though role_b would not constrain it:"
OUT=$(http_query "$AUTH2" "$CLICKHOUSE_URL&max_execution_time=20&role=${ROLE_B}&force_settings_profile_on_set_role=1" "SELECT 1" 2>&1)
expect_code "Code: 452" "$OUT"

echo "### 14. Response-shaping settings are overwritten by the new role's profile"
echo "-- ?default_format=TabSeparated is overwritten by role_fmt's default_format=JSONEachRow:"
http_query "$AUTH" "$CLICKHOUSE_URL&role=${ROLE_FMT}&force_settings_profile_on_set_role=1&default_format=TabSeparated" "SELECT 1"
echo "-- X-ClickHouse-Format: TabSeparated (output_format) is overwritten by role_fmt's default_format=JSONEachRow:"
$CLICKHOUSE_CURL -u "$AUTH" -sS -H "X-ClickHouse-Format: TabSeparated" "$CLICKHOUSE_URL&role=${ROLE_FMT}&force_settings_profile_on_set_role=1" --data-binary "SELECT 1"
# The URL override must be a database whose name differs from the normalized test database
# name ("default"), so a regression (the override surviving the switch) shows up as "system"
# instead of the expected normalized profile value.
echo "-- ?database=system is overwritten by role_fmt's database=<the test database> (the response"
echo "-- itself comes in the profile's default_format=JSONEachRow, like the two cases above):"
http_query "$AUTH" "$CLICKHOUSE_URL&role=${ROLE_FMT}&force_settings_profile_on_set_role=1&database=system" "SELECT currentDatabase()"

echo "### 15. Path-derived format still wins over the new role's profile"
$CLICKHOUSE_CLIENT -q "DROP TABLE IF EXISTS ${CLICKHOUSE_DATABASE}.${UNIQUE_NAME}_hits"
$CLICKHOUSE_CLIENT -q "CREATE TABLE ${CLICKHOUSE_DATABASE}.${UNIQUE_NAME}_hits (a UInt32, b String) ENGINE=Memory"
$CLICKHOUSE_CLIENT -q "INSERT INTO ${CLICKHOUSE_DATABASE}.${UNIQUE_NAME}_hits VALUES (1,'one'),(2,'two')"
$CLICKHOUSE_CLIENT -q "GRANT SELECT ON ${CLICKHOUSE_DATABASE}.${UNIQUE_NAME}_hits TO ${USER1}"
BASE_URL="${CLICKHOUSE_PORT_HTTP_PROTO}://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT_HTTP}"
echo "-- POST /<the test database>/<table>.CSV with role_fmt (default_format=JSONEachRow): the path wins, output is CSV"
echo "-- (POST, not GET: a GET would hit the READONLY guard, like scenario 4):"
$CLICKHOUSE_CURL -u "$AUTH" -sS -X POST -H "Content-Length: 0" "${BASE_URL}/${CLICKHOUSE_DATABASE}/${UNIQUE_NAME}_hits.CSV?role=${ROLE_FMT}&force_settings_profile_on_set_role=1" --data-binary ""
$CLICKHOUSE_CLIENT -q "DROP TABLE ${CLICKHOUSE_DATABASE}.${UNIQUE_NAME}_hits"

echo "### 16. Error precedence with the flag off: URL settings are validated before the role parameter"
echo "-- bad setting value + unknown role: the setting error comes first now:"
OUT=$(http_query "$AUTH" "$CLICKHOUSE_URL&role=${UNIQUE_NAME}_nonexistent&max_result_rows=notanumber" "SELECT 1" 2>&1)
expect_code "Code: 27" "$OUT"
echo "-- constraint violation + unknown role: the setting error comes first now:"
OUT=$(http_query "$AUTH2" "$CLICKHOUSE_URL&role=${UNIQUE_NAME}_nonexistent&max_execution_time=20" "SELECT 1" 2>&1)
expect_code "Code: 452" "$OUT"
echo "-- unknown setting name + unknown role: still the role error (an unknown setting name is"
echo "-- applied after the role handling):"
OUT=$(http_query "$AUTH" "$CLICKHOUSE_URL&role=${UNIQUE_NAME}_nonexistent&unknown_setting_xyz=1" "SELECT 1" 2>&1)
expect_code "Code: 511" "$OUT"
echo "-- plain unknown role (no other settings): still UNKNOWN_ROLE:"
OUT=$(http_query "$AUTH" "$CLICKHOUSE_URL&role=${UNIQUE_NAME}_nonexistent" "SELECT 1" 2>&1)
expect_code "Code: 511" "$OUT"

echo "### 17. SQL-defined handler: the parse-limit workaround survives a flag-on role switch"
echo "-- A handler endpoint pins max_parser_depth/max_parser_backtracks to 0 on the query context so the"
echo "-- stored query parses with unlimited limits. A flag-on role switch resets every changed setting"
echo "-- (incl. that 0) to its default via applySettingsAndReplaceProfiles; the implementation must"
echo "-- snapshot the effective values after the URL settings and re-apply them after the switch."
echo "-- (POST only: a GET would hit the READONLY guard, like scenario 4.)"
HANDLER="${UNIQUE_NAME}_handler"
HANDLER_PATH="/${UNIQUE_NAME}_handler_path"
$CLICKHOUSE_CLIENT -q "DROP HANDLER IF EXISTS ${HANDLER}"
$CLICKHOUSE_CLIENT -q "CREATE HANDLER ${HANDLER} URL '${HANDLER_PATH}' METHODS (POST) AS SELECT getSetting('max_parser_depth')"
echo "-- flag-off control (no role parameter): the handler's max_parser_depth = 0 workaround is in effect:"
$CLICKHOUSE_CURL -u "$AUTH" -sS -X POST "${BASE_URL}${HANDLER_PATH}" --data-binary ''
echo "-- flag on + role parameter: the switch resets changed settings; the snapshot/restore must bring"
echo "-- the handler's 0 back instead of leaving the default (1000):"
$CLICKHOUSE_CURL -u "$AUTH" -sS -X POST "${BASE_URL}${HANDLER_PATH}?role=${ROLE_A}&force_settings_profile_on_set_role=1" --data-binary ''
echo "-- a client per-request override (?max_parser_depth=500, distinct from the default 1000 so a"
echo "-- reset to default is distinguishable) also survives the switch: the snapshot is taken after the"
echo "-- URL settings are applied:"
$CLICKHOUSE_CURL -u "$AUTH" -sS -X POST "${BASE_URL}${HANDLER_PATH}?role=${ROLE_A}&force_settings_profile_on_set_role=1&max_parser_depth=500" --data-binary ''
$CLICKHOUSE_CLIENT -q "DROP HANDLER ${HANDLER}"

$CLICKHOUSE_CLIENT -q "DROP USER ${USER1}"
$CLICKHOUSE_CLIENT -q "DROP USER ${USER2}"
$CLICKHOUSE_CLIENT -q "DROP ROLE ${ROLE_A}, ${ROLE_B}, ${ROLE_RO}, ${ROLE_DEFAULT}, ${ROLE_NOT_GRANTED}, ${ROLE_FMT}, ${ROLE_CONSTRAINED}"
$CLICKHOUSE_CLIENT -q "DROP SETTINGS PROFILE ${PROFILE_A}, ${PROFILE_B}, ${PROFILE_RO}, ${PROFILE_DEFAULT}, ${PROFILE_FMT}, ${PROFILE_CONSTRAINED}"
