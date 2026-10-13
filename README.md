# chroot-action

Run the steps of a GitHub Actions job on an OpenBSD VM from
[chroot.dev](https://chroot.dev). The VM is created for the job and
removed when it ends.

```yaml
jobs:
  openbsd:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          persist-credentials: false

      - uses: chroot-dev/chroot-action@v1
        with:
          ssh-key: ${{ secrets.CHROOT_SSH_KEY }}
          setup: doas pkg_add -I go

      - shell: chroot {0}
        run: go test ./...
```

## Key

You need a [chroot.dev account](https://chroot.dev/man/account/). Give CI
a key of its own, restricted with `--ci`:

    ssh-keygen -t ed25519 -N '' -C ci -f chroot-ci
    ssh chroot.dev ssh-key add --ci --from ci-go < chroot-ci.pub
    echo NONCE | ssh-keygen -Y sign -n add-key@chroot.dev -f chroot-ci |
        ssh chroot.dev ssh-key add
    gh secret set CHROOT_SSH_KEY < chroot-ci

`NONCE` is the challenge the first `ssh-key add` prints. Give `--from`
once for each [template](#templates) used with `from:`, or leave it out.

The key can only create VMs, copy those templates, and reach, inspect and
remove the VMs it created. Nothing else of the account is open to it.

A key's restriction cannot be changed. To restrict an existing CI key, or
to change its templates, add a new key with `--ci`, update the secret,
then remove the old key by the fingerprint `ssh chroot.dev ssh-key ls`
shows. Removing a key from the account does not remove it from the
`authorized_keys` of VMs created while it was there, nor of their copies:
make the templates again once the old key is gone.

Secrets are not available to pull requests from forks, so the action fails
there. Do not work around it with `pull_request_target`: it would run
untrusted code with your key.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `ssh-key` | | Private Ed25519 key. Required. |
| `image` | `base` | Image the VM starts from. |
| `from` | | VM to copy instead of creating one. |
| `setup` | | Script run once on the first boot. |
| `cpus` | | Number of cpus. |
| `memory` | | Memory in MiB, or with an `M` or `G` suffix. |
| `disk` | | Data disk in GiB, or with a `G` or `T` suffix. |
| `sync` | `in` | `in`, `both` or `none`. |
| `env` | | Runner variables to pass to each step. |

Values other than `ssh-key`, `setup` and `env` are one line of ASCII: a
newline or other control character fails the step. `env` takes names
separated by spaces, tabs or newlines.

The output `vm-name` is the name of the VM.

## Steps on the VM

A step with `shell: chroot {0}` runs as `puffy`, who has `doas`, with
`sh -e -o pipefail` in `~/work`. Before the step, the workspace is copied
there; with `sync: both`, `~/work` is also copied back after it, even if
the step failed.

What comes back is output of the VM: a later step that runs it, or a
local `uses: ./...` action in the workspace, runs the VM's code. `.git`
does not come back, so commits and tags made on the VM stay there.
Symlinks that are absolute or whose `..` may lead out of `~/work` are
dropped with a warning, and setuid and setgid bits are cleared on files.

The step sees `CI=true`, `CHROOT_WORKSPACE`, the `GITHUB_*` variables
except the file-command paths (`GITHUB_ENV`, `GITHUB_PATH`,
`GITHUB_OUTPUT`, `GITHUB_STATE`, `GITHUB_STEP_SUMMARY`), and those named
in `env`:

```yaml
      - uses: chroot-dev/chroot-action@v1
        with:
          ssh-key: ${{ secrets.CHROOT_SSH_KEY }}
          env: CC CFLAGS

      - shell: chroot {0}
        env:
          CC: clang
          CFLAGS: -O2 -Wall
        run: make
```

## Templates

Instead of installing packages on every run, prepare a VM once and copy it
for each job; the copy resumes in a fraction of a second:

    ssh chroot.dev new -n ci-go -w -s /dev/stdin <<'EOF'
    doas pkg_add -I go
    EOF

```yaml
      - uses: chroot-dev/chroot-action@v1
        with:
          ssh-key: ${{ secrets.CHROOT_SSH_KEY }}
          from: ci-go
```

## Limits

- Linux runners only.
- Each job's VM counts against the account's plan.
- `sync: both` copies all of `~/work` back after every step, without
  `.git` and unsafe symlinks. Those files are output of the VM: a later
  step that runs them, or a local `uses: ./...` action, runs the VM's
  code.

## License

ISC, see [LICENSE](LICENSE).
