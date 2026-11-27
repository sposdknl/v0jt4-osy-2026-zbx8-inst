#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "CHYBA: radek ${LINENO}: ${BASH_COMMAND}" >&2' ERR

API="http://127.0.0.1/zabbix/api_jsonrpc.php"
ADMIN_PASS="${ZBX_ADMIN_PASSWORD:-}"
[[ -n "$ADMIN_PASS" ]] || { echo "Chybi ZBX_ADMIN_PASSWORD" >&2; exit 1; }
TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "Pouziti: $0 <soubor|adresar>" >&2; exit 1; }

command -v jq >/dev/null || { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y jq >/dev/null; }

api() {
  local auth=()
  [[ -n "${3:-}" ]] && auth=(-H "Authorization: Bearer $3")
  curl -fsS "${auth[@]}" -H 'Content-Type: application/json-rpc' \
    -d "$(jq -n --arg m "$1" --argjson p "$2" '{jsonrpc:"2.0",method:$m,params:$p,id:1}')" "$API"
}

TOKEN="$(api user.login "$(jq -n --arg p "$ADMIN_PASS" '{username:"Admin",password:$p}')" | jq -er '.result')"

RULES='{
  "host_groups":        {"createMissing": true},
  "template_groups":    {"createMissing": true},
  "hosts":              {"createMissing": true, "updateExisting": true},
  "templates":          {"createMissing": true, "updateExisting": true},
  "templateLinkage":    {"createMissing": true},
  "items":              {"createMissing": true, "updateExisting": true},
  "triggers":           {"createMissing": true, "updateExisting": true},
  "graphs":             {"createMissing": true, "updateExisting": true},
  "discoveryRules":     {"createMissing": true, "updateExisting": true},
  "httptests":          {"createMissing": true, "updateExisting": true},
  "valueMaps":          {"createMissing": true, "updateExisting": true},
  "templateDashboards": {"createMissing": true, "updateExisting": true}
}'

if [[ -d "$TARGET" ]]; then
  FILE="$(find "$TARGET" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort | head -n1)"
  [[ -n "$FILE" ]] || FILE="$(find "$TARGET" -maxdepth 1 -type f \( -name '*.json' -o -name '*.xml' \) | sort | head -n1)"
else
  FILE="$TARGET"
fi
[[ -n "$FILE" && -f "$FILE" ]] || { echo "Exportni soubor nenalezen v $TARGET" >&2; exit 1; }

case "${FILE##*.}" in
  yaml|yml) fmt=yaml ;;
  xml)      fmt=xml ;;
  json)     fmt=json ;;
  *) echo "Nepodporovana pripona: $FILE" >&2; exit 1 ;;
esac

echo "==> Importuji $FILE ($fmt)"
params="$(jq -n --arg fmt "$fmt" --argjson rules "$RULES" --rawfile src "$FILE" \
          '{format:$fmt, rules:$rules, source:$src}')"
resp="$(api configuration.import "$params" "$TOKEN")"
if jq -e '.error' <<<"$resp" >/dev/null; then
  echo "Import selhal: $(jq -c '.error' <<<"$resp")" >&2
  exit 1
fi
echo "OK"
