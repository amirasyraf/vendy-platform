#!/usr/bin/env bash
set -euo pipefail
# Container inventory (containers/<name>/catalog-info.yaml), written by container-stage.yml.
# `validate` is pure: no network or inventory writes. Other actions commit and push.
# See vendy/CONTRACTS.md §12. Workflow concurrency serializes one container.
# shellcheck source=scripts/team-guard.sh
source "$(dirname "$0")/team-guard.sh"
fail() { echo "$*" >&2; exit 1; }
action=${1:?validate, register, configure, finalize or delete}
[[ "${NAME:?}" =~ ^[a-z][a-z0-9-]{2,20}$ ]] || fail 'Invalid container name'
root=${INVENTORY_ROOT:-.}
file="$root/containers/$NAME/catalog-info.yaml"
team_of() { yq -r '.spec.owner' "$file" | sed 's#^group:default/##'; }

if [[ "$action" == validate ]]; then
  [[ "${STAGE:?}" =~ ^(register|configure|destroy|finalize)$ ]] || fail 'Invalid stage'
  [[ "${REQUEST_ID:?}" =~ ^[a-zA-Z0-9_-]{1,100}$ ]] || fail 'Invalid request ID'
  [[ "${RUN_KEY:?}" =~ ^[1-9][0-9]*\.$STAGE\.[1-9][0-9]*$ ]] || fail 'Invalid run key'
  [[ "${REQUESTED_BY:?}" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,99}$ ]] || fail 'Invalid requester'
  [[ "${REQUESTER_TEAMS:?}" =~ ^[a-z][a-z0-9-]*(,[a-z][a-z0-9-]*)*$ ]] || fail 'Invalid requester teams'
  params=${PARAMS_JSON:-'{}'}
  [[ $(printf %s "$params" | wc -c) -le 40960 ]] || fail 'params_json exceeds 40 KiB'
  jq -se 'length == 1 and (.[0] | type == "object")' <<< "$params" >/dev/null || fail 'params_json must be one object'
  case "$STAGE" in
    register|configure) jq -e 'keys == ["spec"] and (.spec|type=="object")' <<< "$params" >/dev/null || fail 'Expected {spec}' ;;
    finalize) jq -e 'keys == ["outcome"] and (.outcome == "ready" or .outcome == "failed")' <<< "$params" >/dev/null || fail 'Expected {outcome}' ;;
    destroy) jq -e '. == {}' <<< "$params" >/dev/null || fail 'Expected {}' ;;
  esac
  noop=false
  spec=''
  if [[ "$STAGE" == register || "$STAGE" == configure ]]; then
    spec=$(jq -c '.spec' <<< "$params" | python3 scripts/container_spec.py)
    team_guard "$(jq -r '.owner' <<< "$spec")" "$REQUESTER_TEAMS"
  fi
  if [[ "$STAGE" == register ]]; then
    if [[ -f "$file" ]]; then
      [[ "$(yq -r '.metadata.annotations."cf/request-id"' "$file")" == "$REQUEST_ID" ]] || fail 'Container belongs to a different request'
      noop=true
    else
      [[ ! -e "$root/containers/$NAME" ]] || fail 'Container directory exists without inventory'
    fi
  elif [[ ! -f "$file" ]]; then
    [[ "$STAGE" == destroy || "$STAGE" == finalize ]] || fail 'Unknown container'
    noop=true
  elif [[ "$(yq -r '.metadata.annotations."cf/request-id"' "$file")" != "$REQUEST_ID" ]]; then
    [[ "$STAGE" == finalize ]] || fail 'Container belongs to a different request'
    noop=true
  else
    team_guard "$(team_of)" "$REQUESTER_TEAMS"
    if [[ "$STAGE" == configure ]]; then
      # Platform, architecture and owner are immutable.
      jq -e --argjson old "$(yq -o=json '.spec' "$file")" \
        '[.owner, .container.platform, .container.arch] == [$old.owner, $old.container.platform, $old.container.arch]' <<< "$spec" >/dev/null \
        || fail 'Modify cannot change the owner, platform or architecture'
    fi
  fi
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      echo "noop=$noop"
      echo "spec_json=$spec"
      echo "outcome=$(jq -r '.outcome // ""' <<< "$params")"
    } >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

case "$action" in
  register)
    [[ ! -e "$root/containers/$NAME" ]] || fail 'Container directory already exists'
    spec=$(python3 scripts/container_spec.py <<< "${SPEC_JSON:?}")
    mkdir -p "$root/containers/$NAME"
    jq -n --arg name "$NAME" --arg user "${REQUESTED_BY:?}" --arg request "${REQUEST_ID:?}" \
      --arg requested_at "$(date -u +%FT%TZ)" --arg domain "${APPS_DOMAIN:?}" --argjson spec "$spec" \
      '{apiVersion:"backstage.io/v1alpha1",kind:"Resource",metadata:{name:$name,title:$name,
        description:("\($spec.container.image) on \($spec.container.platform) \($spec.container.arch) for team \($spec.owner | sub("^group:default/";""))"),
        annotations:{"cf/status":"deploying","cf/url":(if $spec.container.public then "https://\($name).\($domain)" else "" end),
          "cf/requested-by":$user,"cf/requested-at":$requested_at,"cf/request-id":$request}},spec:$spec}' \
      | yq -P '.' > "$file"
    ;;
  configure)
    spec=$(python3 scripts/container_spec.py <<< "${SPEC_JSON:?}")
    url=''
    if [[ "$(jq -r '.container.public' <<< "$spec")" == true ]]; then url="https://$NAME.${APPS_DOMAIN:?}"; fi
    export spec url
    yq -i '.spec.container = (strenv(spec) | from_json | .container) | .metadata.annotations."cf/url" = strenv(url) | .metadata.annotations."cf/status" = "deploying"' "$file"
    ;;
  finalize)
    [[ "${OUTCOME:?}" == ready || "$OUTCOME" == failed ]] || exit 1
    [[ -f "$file" ]] || exit 0
    timestamp=$(date -u +%FT%TZ)
    timestamp_key="cf/$OUTCOME-at"
    export OUTCOME timestamp timestamp_key
    yq -i '.metadata.annotations."cf/status" = strenv(OUTCOME) | .metadata.annotations[strenv(timestamp_key)] = (.metadata.annotations[strenv(timestamp_key)] // strenv(timestamp))' "$file"
    ;;
  delete)
    [[ -e "$root/containers/$NAME" ]] || exit 0
    git -C "$root" rm -rq -- "containers/$NAME"
    ;;
  *) fail 'Unknown inventory action' ;;
esac
if [[ "$action" != delete ]]; then
  run_url="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
  export GITHUB_RUN_ID run_url
  yq -i '.metadata.annotations."cf/run-id" = strenv(GITHUB_RUN_ID) | .metadata.annotations."cf/run-url" = strenv(run_url)' "$file"
  git -C "$root" add -- "containers/$NAME"
fi
git -C "$root" config user.name 'compute-factory[bot]'
git -C "$root" config user.email 'compute-factory[bot]@users.noreply.github.com'
if ! git -C "$root" diff --cached --quiet; then git -C "$root" commit -qm "container($NAME): $action ${OUTCOME:-}"; fi
pushed=false
for attempt in 1 2 3 4 5 6 7 8; do
  if git -C "$root" pull -q --rebase --autostash origin main && git -C "$root" push -q origin HEAD:main; then
    pushed=true
    break
  fi
  echo "Concurrent inventory push; retry $attempt/8" >&2
  sleep $((attempt + RANDOM % (attempt * 2 + 1)))
done
[[ "$pushed" == true ]] || fail 'Inventory push failed'
bash scripts/refresh.sh "resource:default/$NAME"
if [[ "$action" == register || "$action" == delete ]]; then bash scripts/refresh.sh 'location:default/cf-containers'; fi
