# Ubinux-ng Branch Management

This document defines the branch model for ubinux-ng work in this
repository.

## Goals

- Keep long-lived ubinux-ng patches in one reusable branch.
- Keep each stable release line rebased on the latest upstream stable tag.
- Avoid mixing stable release history into the ubinux-ng common patch stack.

## Branch Roles

### `ubinuxng-main`

- Purpose: maintain ubinux-ng common patches not merged upstream yet.
- Base: `origin/main`.
- Update policy: periodically rebase onto `origin/main`.
- Content policy:
  - include long-lived, cross-release patches;
  - exclude one-off stable-only workarounds;
  - exclude local-only test/debug tweaks unless they are generally useful.

### `ubinuxng-<stable-major>-dev`

- Purpose: monthly development and validation for one stable line.
- Base: latest upstream stable tag for that major line.
- Example: `ubinuxng-4593-dev` rebases onto latest `stable-4593.x.y` tag.
- Update policy: rebase to each new stable tag for that major line.
- Content policy:
  - cherry-pick required common patches from `ubinuxng-main`;
  - keep stable-line-specific fixes here when they are not common enough
    for `ubinuxng-main`.

## Release Model

- Do not maintain a `prod` branch.
- Release tags are the production source of truth.
- A release is cut from `ubinuxng-<stable-major>-dev` and published as a tag.

## Patch Flow

1. Land reusable patches in `ubinuxng-main` (based on `origin/main`).
2. Cherry-pick needed patches into `ubinuxng-<stable-major>-dev`.
3. Rebase `ubinuxng-<stable-major>-dev` onto latest stable tag.
4. Validate and cut release tag.

## Naming Notes

- Release tag format:

```text
ubinuxng-<stable-version>-<yyyymm>
```

- Example:

```text
ubinuxng-4593.2.2-202606
```



- Stable major can be derived from `STABLE_VERSION` with:

```bash
STABLE_MAJOR="${STABLE_VERSION%%.*}"
```

- Recommended dev branch format:

```text
ubinuxng-<stable-major>-dev
```

## Concrete Examples

### Example A: common patch from `origin/main` to two stable lines

Suppose upstream has:

- `origin/main`
- `stable-4593.2.6`
- `stable-4757.1.3`

And we need one reusable patch: `build_library: fix SBOM CPE mapping`.

1. Update `ubinuxng-main` on top of `origin/main`:

```bash
git checkout ubinuxng-main
git fetch origin
git rebase origin/main
# add or cherry-pick common patch here
git push --force-with-lease ubinux ubinuxng-main
```

2. Move `ubinuxng-4593-dev` to latest `stable-4593` tag:

```bash
git checkout ubinuxng-4593-dev
git fetch origin
git rebase stable-4593.2.6
git cherry-pick <common-patch-sha-from-ubinuxng-main>
```

3. Move `ubinuxng-4757-dev` to latest `stable-4757` tag:

```bash
git checkout ubinuxng-4757-dev
git fetch origin
git rebase stable-4757.1.3
git cherry-pick <common-patch-sha-from-ubinuxng-main>
```

Result:

- same reusable patch is shared from `ubinuxng-main`;
- each stable dev branch stays on its own latest stable tag;
- no stable history is merged into `ubinuxng-main`.

### Example B: stable-only hotfix

Suppose a workaround is only needed on `4593.2.2` due to a
kernel/toolchain combination and is not useful for other lines.

- Keep the fix only in `ubinuxng-4593-dev`.
- Do not add it to `ubinuxng-main`.
- Release with a tag from `ubinuxng-4593-dev`.

Tag format should include stable base and release month:

```text
ubinuxng-<stable-version>-<yyyymm>
```

For example:

```text
ubinuxng-4593.2.2-202606
```

Command example:

```bash
git checkout ubinuxng-4593-dev
git fetch origin
git rebase stable-4593.2.2
# run validation here
git tag ubinuxng-4593.2.2-202606
git push ubinux ubinuxng-4593-dev
git push ubinux ubinuxng-4593.2.2-202606
```

This keeps `ubinuxng-main` clean and focused on truly reusable patches.
