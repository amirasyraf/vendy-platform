# Vendy platform

This repo runs the AWS and Azure VM stages for Vendy. It holds the request and modify templates,
Terraform modules, Ansible playbooks, and VM inventory. The portal decides which stage runs next.
GitHub Actions runs one stage per dispatch, serializes stages for the same VM, and writes the
result back here.

**The inventory is public.** Files under `vms/` and `containers/` and their Git history can include VM metadata,
public IP addresses, and requester-supplied tags. Team permissions in the portal don't hide
those files. Use dummy request data and never commit secrets.

## How to use it

Launch and manage VMs from the [Vendy portal](https://idp.amirasyraf.dev). Use the run page to
follow progress or retry a failed stage. Editing an inventory file does not change the running VM.
For example, change a VM's size or software through **Modify**, not by pushing YAML.

If a stage fails, open its GitHub run from the portal. A `Validate inputs` error needs an input or
configuration fix; it won't go away on retry. Don't dispatch a second copy of an active stage
by hand.

## Where to make changes

| Change | Start here |
|---|---|
| VM request or modify form | [`catalog/templates`](catalog/templates) |
| Supported clouds, OS releases, or sizes | [`terraform/platforms`](terraform/platforms) |
| Software choices | [`ansible/software-catalog.json`](ansible/software-catalog.json) |
| Guest configuration or updates | [Ansible playbooks](ansible/README.md) |
| Stage inputs, ordering, or recovery | [Platform reference](REFERENCE.md), shared `CONTRACTS.md` in the sibling `vendy` checkout |

## Extending and checking

Run the offline inventory checks from this checkout:

```sh
mise trust
mise install
mise exec -- bash scripts/test.sh
```

The check uses a temporary Git repo. It does not call a cloud provider or dispatch Actions.
For changes to Terraform, the workflow, or playbooks, also run the
[checks for those files](REFERENCE.md#extending-and-checking). Verify new guest behavior on a
matching disposable VM before using Actions.
