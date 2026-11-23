# Vendy platform reference

POC VM stage executor for AWS and Azure (Ubuntu 26.04, Windows Server 2025), with Git as inventory and
Ansible configuration.
The binding cross-repository interfaces are in `../vendy/CONTRACTS.md`.

## Lifecycle

The IDP `vms` backend owns stage ordering, automatic retries/backoff, manual retry/skip,
and run state in its database. GitHub Actions **executes exactly one stage per dispatch**
through `.github/workflows/stage.yml`. There is no supported direct lifecycle pipeline.

Provision runs execute register → provision → baseline → optional software → optional mock
AD join → access → finalize. Modify runs persist the new desired compute/configuration
(`configure`), then apply only what changed (provision for a size change, software, AD join), then
finalize. Re-apply runs execute the fry stages again against the persisted spec. Power runs
(start/stop/reboot) and OS-update runs are one stage each and never write `cf/status`. Destroy runs
remove infrastructure/state/inventory; only their failure path finalizes. The IDP handles inapplicable-stage skips, not GitHub Actions.
Transient failures do not mark the VM failed: only the orchestrator's terminal `finalize`
with `outcome: failed` writes that status. Failed VMs remain for diagnosis.

Each dispatch supplies `stage`, `name`, `request_id`, `run_key`, `requested_by`,
`requester_teams` and optional `params_json` (object, at most 40 KiB). The nested or merged VM
spec has a separate limit of 32,768 characters at `scripts/spec.py`. The run title is
`stage <stage> <name> by <requested_by> [<run_key>]`; the suffix is dispatch recovery identity.
`run_key` is `<positive run id>.<stage>.<positive attempt>`, `request_id` is a stable incarnation
matching `^[a-zA-Z0-9_-]{1,100}$`, and names match `^[a-z][a-z0-9-]{2,20}$`.

One 20-minute job (40 for `os-update`: Windows updates) checks out executor code at the dispatched commit (`github.sha`), then
`Load current inventory` checks out current `main` separately under `.current-inventory`.
Workflow concurrency opens before either checkout, so a queued destroy sees registration
committed while it was waiting, not the dispatch-time snapshot. `INVENTORY_ROOT` points all
inventory reads/writes/Git commits at that separate checkout (default `.` for local scripts).
Terraform, Ansible, validators and helpers still execute from the pinned executor checkout.
Inventory retrieval failures are transient and never misclassified as validation failures.
The `Validate inputs` step
does all local input/spec/identity/team checks before mutations. Failure there is permanent;
tool setup, OIDC, cleanup-check HTTP, AWS, SSH and Git writes happen later and are retryable.
Concurrency `vm-<name>` serializes all attempts for a VM. Distinct VMs run concurrently.
The workflow has only `contents: write` and `id-token: write` permissions.

| Stage | `params_json` | Effect |
|---|---|---|
| register | `{"spec": <Resource spec>}` | Create inventory with `provisioning`; same incarnation is a no-op, another is rejected |
| provision | `{}` | Mark provisioning, adopt/apply Terraform (a size change is an in-place stop/modify/start), record outputs, mark frying |
| baseline/ad-join/access | `{}` | Mark frying, sign an ephemeral SSH cert, run the corresponding playbook (Windows `access` first ensures the VM's shared password secret, `scripts/vm-password.sh`) |
| software | `{}` or `{"remove":["docker"]}` | As above; also removes deselected catalog packages that are no longer desired |
| configure | `{"compute":{…},"configuration":{"software":[…],"adJoin":bool}}` | Replace desired compute and configuration (platform and image unchanged), without VM contact |
| start/stop/reboot | `{}` | `scripts/power.sh` with the platform's `terraform/platforms/<p>/power.sh`, on `cf/instance-id` after checking its `cf:vm`/`cf:request-id` tags; stop clears `cf/public-ip` (Azure deallocates), start records the current one and waits for SSH, reboot waits for a new boot ID |
| os-update | `{}` | Sign an ephemeral SSH cert, run `ansible/maintain/os-update.yml` (Linux full upgrade, reboot only if required; Windows `win_updates`, rebooting as needed); `cf/status` unchanged |
| destroy | `{}` or `{"demoGeneration":"<uuid>"}` | Check cleanup eligibility if automatic, mark destroying, destroy, delete state, this incarnation's password secret (Windows) and inventory |
| finalize | `{"outcome":"ready"}` or `{"outcome":"failed"}` | Write status and first-only readiness/failure timestamp |

Missing inventory makes destroy/finalize successful no-ops. Finalize for another incarnation,
or automatic cleanup for an outdated incarnation, also does nothing. Other stages reject a
missing/mismatched incarnation. Guards use persisted `spec.owner` (desired owner for register).
`requester_teams` contains comma-separated bare group names; `platform-admins` passes all guards.
Register retry checks both desired and existing owner. No side effects run for a validated no-op.

Every inventory write commits to `main`, retries pull/rebase/push eight times with jitter and
`--autostash`, then best-effort refreshes `resource:default/<name>` in Backstage (10-second
HTTP timeout). Register/delete also refresh `location:default/cf-vms`. `vms/.gitkeep` remains.
Git tracks coarse `cf/status`, connection/instance outputs and request provenance only;
per-stage attempts and errors live in the IDP database, never inventory annotations.
`cf/ready-at` and `cf/failed-at` record their first occurrence and are never reset by later runs.
Fry stages, OS updates, and reboot need a valid inventory SSH target. A stopped VM has an empty
`cf/public-ip`, so those stages fail validation. Reboot polls for a changed boot ID; the loop
targets 10 minutes but an established SSH probe can overrun it, up to the workflow job timeout.

## Templates and progress

`vm-request` has one step, `cf:vm:dispatch`, which submits `{name, specJson}` to
`/api/vms/requests`; authenticated identity, teams and the task ID are derived server-side.
Admission reserves quota and creates the run idempotently by task ID. The run's first stage, the
mock ServiceNow request, runs inside the IDP (not in this repo); its fake RITM number is shown on
the run page, not stored in VM inventory or passed to workflows. The IDP then takes the browser to
the run page; the task also links **Follow Provisioning** (`runUrl`) and **Open VM in Catalog**.

`vm-modify` has one `cf:vm:run` step (`operation: modify`, `compute`, `software`, `adJoin`). The
IDP VM page opens it prefilled with the VM's current configuration; the VM field is read-only.
The action reads the VM with initiating-user credentials, derives identity/teams server-side and
returns `{runId, runUrl}` (**Follow run**). Start, stop, reboot, OS updates, re-apply and destroy
have no templates: the VM page creates those runs directly through the IDP. Live progress, retry and
skip are on `/vms/runs/<id>` and the VM entity page, not streamed into the Scaffolder task. The
request team picker remains `MyGroupsPicker`.

## Configuration and trust

`catalog-info.yaml` is the only per-VM desired state; no `request.yaml` or duplicate desired
annotations. A normalized spec looks like:

```yaml
spec:
  type: vm
  owner: group:default/alpha
  lifecycle: poc
  compute: {platform: aws, os: ubuntu, imageVersion: "26.04", size: S}   # or platform: azure
  configuration: {software: [git, nginx], adJoin: false}
  billing: {costCenter: CC-1234, projectCode: PROJ-5678}
  cloudTags: {environment: test}
```

## Platforms

Each platform is one directory, `terraform/platforms/<p>/` (`aws`, `azure`):

| File | Purpose |
|---|---|
| `platform.json` | `label`; `os` (`{<os>: {label, versions, sshUser, family, minMemoryMiB?, rootVolumeGiB (AWS), galleryImages (Azure)}}`, `family` `linux` or `windows`); `instanceTypePattern`, `excludedInstanceTypePattern`, `instanceIdPattern`; `reservedTagPrefixes`, `forbiddenTagKeyCharacters`; `staticPublicIp` (address kept across stop/start and resize) |
| `sizes.json` | per OS family, XS/S/M/L → instance type (AWS Linux `t3.micro`–`t3.large`, Windows `t3.medium`–`t3.2xlarge`; Azure Linux `Standard_D2ls_v6`, `D2s_v6`, `D4ls_v6`, `D4s_v6`, Windows `D2ls_v6`, `D2s_v6`, `D4s_v6`, `D8s_v6`) |
| `*.tf` | the VM root module (same variables and outputs on every platform) |
| `adopt.sh` | adopt untracked resources of this incarnation into state before apply/destroy |
| `power.sh` | `vm_describe`, `vm_start`, `vm_stop`, `vm_reboot` for `scripts/power.sh` |

`spec.py`, `validate.sh`, `inventory.sh`, Terraform and the IDP (from `main`, via GitHub) read these
files; generic scripts do not name a platform. The workflow logs in to AWS for every cloud stage (SSH
CA, S3 state) and additionally to Azure (`azure/login`, OIDC; Terraform via `ARM_USE_OIDC`) when the
validated platform is `azure`. Azure VMs live in their own resource group `cf-vm-<name>` with fixed
resource names (`cf-<name>`), a static public IP (kept across stop/start and resize) and an NSG
allowing SSH. Azure requires an admin key (Linux) or password (Windows) at launch; it exists only in
Terraform state. The Linux `access` stage disables `authorized_keys`, so only CA certificates log in;
Windows images never accept keys, and `access` replaces the launch password with the team's shared one.
The VM resource is `azurerm_linux_virtual_machine` or `azurerm_windows_virtual_machine` (`count` by
family; a `moved` block keeps pre-Windows state). Login users: `ubuntu`; Windows `Administrator` on AWS,
`cfadmin` on Azure (Azure forbids `Administrator`).

Windows needs at least `minMemoryMiB` (4096): AWS Terraform refuses smaller instance types (Azure has no
size data in Terraform; the IDP picker enforces it there), and AWS uses `rootVolumeGiB` (50) for the
root disk. The shared password is Secrets Manager `compute-factory/vm/<name>` (`{username, password, requestId}`,
tags `cf:poc`, `cf:vm`, `cf:request-id`): created once per incarnation (an older incarnation's secret is
overwritten), deleted on destroy, swept by `./poc down`; the IDP reads it for the owning team.

Launch shows one card per `os.<os>.versions` entry, enables only currently available images and stores
`compute.imageVersion`. The IDP rechecks before admitting a new request, and the register stage
checks availability again. Terraform uses `image_version`: AWS selects the latest managed AMI tagged
with both the OS and the selected release; Azure selects the latest bake from the release's distinct
gallery definition in `os.<os>.galleryImages` (`ubuntu` for 26.04, `windows-2025`). Publish bakes before
advertising a release. Keep gallery mappings and AWS images needed by existing VMs. Legacy specs without
`imageVersion` resolve to the OS's first listed version (Ubuntu 26.04); Modify preserves the original
selection and never re-images.

`scripts/spec.py` validates/normalizes types, supported fields and bounds with the Python standard
library. Supported platforms/OSes are those in the platform directories; software is keys of
`ansible/software-catalog.json` offered for the OS's family (`ansible/README.md`). Compute has exactly
one of `size` (a key of the platform's `sizes.json` map for the OS family)
or `instanceType` (the platform's pattern: e.g. `m7i.large`, no `mac*`; `Standard_D2s_v6`). AWS
Terraform checks x86_64 support and default-subnet AZ availability. The IDP Advanced picker reads the
same maps and live offerings (Azure with vCPU quota). Recorded `cf/instance-type` is the launched
type, not a re-evaluation of a mutable size map.

Configuration defaults to no software/no AD join; billing/tags default to empty objects. Modify
replaces the software list: unchecked catalog packages are removed (`apt` `state: absent`, data and
configuration files stay; Windows `Uninstall-WinGetPackage`). Status writes never alter desired spec or original
`cf/requested-by`/`cf/requested-at`/`cf/request-id`. Ansible `cf_requested_by` and AWS requester
tags come from original persisted provenance, not whoever dispatched the current attempt.

Billing accepts only nonempty `costCenter`/`projectCode` (up to 256 chars), projected as
`cost_center`/`project_code` cloud tags. Both are required by the form/IDP for new requests but
optional in `spec.py` for older specs. These are self-reported, not billing authorization.
Custom tags: at most 40 entries, keys 1–128 chars, string values 0–256 chars. Controls, unknown
spec section fields and reserved tag keys/prefixes (`Name`, `cost_center`, `project_code`,
`cf:`, `billing:` and the platform's `reservedTagPrefixes`, case-insensitive) and keys with the
platform's forbidden characters (Azure `<>%&\?/`) are rejected. Never store secrets in specs or tags.

Backstage stores custom spec fields but does not itself enforce this workflow schema. Git edits
do not trigger reconciliation or Terraform. For a schema change, check all readers and writers
and decide explicitly how existing inventory is handled.

Repository variables: `AWS_ROLE_ARN`, `AWS_REGION` (`ap-southeast-2`),
`TF_STATE_BUCKET` (`cf-tfstate-134584031874-apse2`), `BACKSTAGE_URL`,
`CF_POC_MAINTENANCE` (set to `1` by teardown to skip stage jobs), `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
`AZURE_SUBSCRIPTION_ID`, `AZURE_LOCATION`. Secret: `BACKSTAGE_TOKEN`, subject
`compute-factory-workflows`, restricted to catalog and the `vms` read-only cleanup check.
Missing Backstage config skips refresh but automatic cleanup fails closed.
The IDP must register the optional `cf-vms` glob Location and enable orphan deletion.
Repo writers and dispatch-token holders can impersonate identity inputs: trusted POC admins only.

## Terraform retry safety

S3 state is `vms/<platform>/<name>/terraform.tfstate` (Azure state is in the same AWS bucket), with
native `use_lockfile=true`. The script uses
`init -lockfile=readonly` so provider checksum files do not dirty inventory rebases. Taggable
VM resources carry `cf:poc=true`, `cf:vm`, `cf:team`, and (when nonempty) `cf:request-id`.
Azure subnets and NIC/NSG associations are managed through their owning resource group.

Before either apply or destroy, the platform's `adopt.sh` recovers **untracked** resources into
Terraform state. AWS: any instance/security group with matching `cf:vm`, `cf:request-id` and
`cf:poc=true`. Azure: the fixed-name resources in `cf-vm-<name>` once the group's `cf:vm`/
`cf:request-id`/`cf:poc` tags match (another incarnation's group fails for an operator). For AWS: Instance lookup includes pending,
running, stopping and stopped states. Zero matches permits creation (apply); one is imported;
multiple matches fail for operator recovery rather than guessing. Security-group adoption also
recovers an interrupted apply before instance creation. This does not adopt another incarnation.

Instances ignore AMI and computed subnet changes after creation: a newer bake or reordering/default
subnet availability must not replace an existing VM on retry. Imported SGs ignore `name_prefix`.
Provision creates a saved plan and rejects any delete/replacement action before applying it, so
other unexpected immutable-property drift requires operator recovery rather than recreation.
Resize through IDP **Modify** (it persists the new size, then re-runs `provision`); a changed
instance type is an in-place update. Do not use direct Git edits for resize/network changes; this
POC has no reconciliation flow.

The script lists the exact `.tflock` object and reads its `Created`/`ID`. A lock older than
1,200 seconds (the workflow job timeout) is logged and removed via `terraform force-unlock`;
a younger lock fails safely for retry. Auth/network/malformed-lock errors fail, never bypass locking.
This relies on the shared per-VM concurrency group: external Terraform operators must not run
against an active VM stage or rely on locks beyond that window. Local teardown freezes workflows
first. Untracked-resource discovery, import and stale-lock recovery are script behavior, not
properties of invoking the module directly.

Terraform receives private temporary vars and plan files, removed on exit. Only `name` is required
by the module; `terraform destroy -var name=<name>` remains valid for `./poc down`. Stage destruction
uses the full persisted vars, deletes the state object only after successful destroy, then removes
inventory. Missing state after partial destruction is recovered by the same adoption path.
GitHub Actions authenticates to AWS and Azure with OIDC. The local `poc` operator uses configured
AWS CLI and Azure credentials instead. Requirements: default VPC/subnets, golden AMIs tagged
`cf:managed=true` and `cf:os=<os>` (`ubuntu`, `windows`), Azure gallery versions of
`cf-images/cfimages/ubuntu` and `windows-2025`, and Secrets Manager `compute-factory/ssh-ca`. SSH ingress is public for this POC.

## SSH and demo cleanup

Each fry attempt signs a throwaway key with principal `cf-automation`, key ID `gha-<run-id>`,
validity one hour. The CA private-key file is deleted immediately after signing; ephemeral keys,
certs and vars are removed by an always-run step. No EC2 key pairs or per-VM user keys are stored.
The playbook CLI/variable contract is in `ansible/README.md` and the shared contract §6.3.

Automatic destroy's `demoGeneration` checks
`GET $BACKSTAGE_URL/api/vms/cleanup-check/<name>?generation=…&request_id=…` after validation
and again after tool setup immediately before destructive work. Ineligible returns a successful
no-op; HTTP/auth/network or malformed responses fail closed and remain retryable. Manual destroy
uses `{}` and never contacts this endpoint. Demo expiry is a trigger time, not a termination SLA.

Trusted manual dispatch can execute **one** stage and is not tracked by the orchestrator:

```bash
gh workflow run stage.yml -R amirasyraf/vendy-platform \
  -f stage=baseline -f name=demo-1 -f request_id='persisted-request-id' \
  -f run_key=42.baseline.1 -f requested_by=amirasyraf -f requester_teams=alpha \
  -f 'params_json={}'
```

Don't dispatch manually while the IDP is managing an active run for this VM. This is an operator
tool, not part of the normal VM flow. Shared infrastructure and golden images belong to sibling repos.

## Extending and checking

New platforms need a directory as above with the same variables (`name`, `os`, `size`,
`instance_type`, `team`, `requested_by`, `request_id`, `cloud_tags`) and outputs (`public_ip`,
`ssh_user`, `instance_id`, `instance_type`), a login step in `stage.yml`, a golden image and the
IDP/`./poc` pieces listed in the orchestrator's DESIGN.md §8. New OSes need a golden image, an `os`
entry in each `platform.json`, a `sizes.json` map and `ansible/connection/<family>.yml` for a new family,
Ansible OS-family tasks and catalog columns. New stages require contract and
orchestrator stage-list changes as well as playbooks, workflow allowlists and template enums.

Tool versions are pinned in `mise.toml`. These local checks don't dispatch workflows or apply
infrastructure. Tool, provider, and collection installation may need network access:

```bash
for p in aws azure; do
  mise exec -- terraform -chdir=terraform/platforms/$p fmt -check
  mise exec -- terraform -chdir=terraform/platforms/$p init -backend=false -lockfile=readonly
  mise exec -- terraform -chdir=terraform/platforms/$p validate
done
mise exec -- actionlint
mise exec -- shellcheck scripts/*.sh terraform/platforms/*/*.sh
for script in scripts/*.sh; do bash -n "$script"; done
ansible-galaxy collection install -r ansible/requirements.yml
for playbook in ansible/fry/*.yml ansible/maintain/os-update.yml; do
  ansible-playbook --syntax-check -i localhost, "$playbook"
done
mise exec -- bash scripts/test.sh
```

`scripts/test.sh` uses real jq/yq/Git and an isolated local bare remote to exercise validation
(including both platforms' rules),
inventory idempotency, config unions, provenance, first-time timestamps, missing-inventory
no-ops and separate current-inventory reads/writes from pinned executor code. It does not
invoke AWS/Terraform or prove live recovery behavior. Verify stage execution, SSH, and adoption
separately on authorized disposable resources when those paths change.

## Containers

`containers/<name>/catalog-info.yaml` is written only by `.github/workflows/container-stage.yml`,
one stage per dispatch from the IDP's container orchestrator: `register`, `configure`, `finalize`
and `destroy` (delete). `scripts/container-inventory.sh validate` runs as `Validate inputs` (request
identity, team guard, `scripts/container_spec.py` normalization, immutable owner/platform/arch); the
other actions commit, push with rebase retries and refresh `location:default/cf-containers`. The
cluster itself is changed by the IDP, not by this repo. The `container-request` template receives
the chosen AWS or Azure platform from the portal's picker and displays it with the
`ContainerPlatform` field before dispatching `cf:container:dispatch`. Its output links to the
deployment run, which offers the catalog link once the matching entry is visible.
Contract: vendy CONTRACTS.md §12.
