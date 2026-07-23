# CBS Component Format

This is the authoring reference for the components in this repository, as
consumed by the CBS build tooling (`cbsbuild` / the CBS service, the Rust
`cbscore` implementation). It covers how a component is laid out, what each
YAML file means, how conditional content works, and — importantly — how a
component pins which OS releases may build which of its versions.

## Directory layout

Each component is one directory under `components/`:

```text
components/
  ceph/
    cbs.component.yaml      # the component manifest (schema v2)
    images/
      index.yaml            # version-range → recipe-directory selection
      v19/
        image.yaml          # the image recipe
        ganesha.repo        # aux files referenced by the recipe
        fix-ganesha.sh      #   (repo files, post scripts, ...)
        ...
      v20/ ...
      v21/ ...
    patches/                # patches applied to the source tree
    scripts/
      get_version.sh        # backend-independent version probe
      rpm/                  # rpm-backend build scripts
        install_deps.sh
        build_rpms.sh
        get_release_rpm.sh
```

The build tooling is pointed at one or more such trees via its config
(`paths.components`, a list — later trees can overlay extra components for
local development). The CBS server ships the tree to workers as a tarball;
nothing in a component may assume a fixed absolute location.

## The component manifest — `cbs.component.yaml`

```yaml
schema-version: 2
name: ceph
# Upstream is the default source repository; override it per descriptor
# component entry or with -o ceph=<uri> when building from a fork.
repo: gh://ceph/ceph

targets:
  - versions: { before: "19.2.5" }
    supported: [el9]
    default: el9
  - versions: { from: "19.2.5" }
    supported: [el10]
    default: el10

build:
  get-version: scripts/get_version.sh
  backends:
    rpm:
      deps: scripts/rpm/install_deps.sh
      build: scripts/rpm/build_rpms.sh
      release-package: scripts/rpm/get_release_rpm.sh

images:
  path: images/
```

Field by field:

- **`schema-version`** — must be `2`. Older manifests are rejected loudly
  with a migration hint; newer ones are rejected as not-understood.
- **`name`** — the component name; must match how descriptors refer to it.
- **`repo`** — the default source repository. `gh://owner/repo` is shorthand
  for GitHub over https; `ssh://` forms are accepted for private sources.
  Forks are a per-build override, never a baked-in default.
- **`targets`** — the version→OS matrix, described in its own section below.
  The key is optional: a component without it is *target-agnostic* (it builds
  wherever it's told, and cannot provide the build's default OS).
- **`build.get-version`** — script that prints the component's version when
  run inside the source tree; backend-independent.
- **`build.backends.<kind>`** — per-package-backend scripts (`rpm` today,
  `deb` reserved). Every OS listed anywhere in `targets.supported` must have
  a backend block matching its package kind, validated at load time.
- **`images.path`** — the image recipes tree, usually `images/`.

## The version→OS targets matrix

The matrix answers one question: **for a given component version, which
target OSes may build it, and which is the default?** Each row scopes a
version range:

```yaml
targets:
  - versions: { before: "19.2.5" }   # ..19.2.4 — el9 only
    supported: [el9]
    default: el9
  - versions: { from: "19.2.5" }     # 19.2.5.. — el10 only
    supported: [el10]
    default: el10
```

Semantics and rules (all enforced when the manifest loads — a bad matrix
never reaches a build):

- **Ranges are half-open** `[from, before)`: `from` is inclusive, `before`
  exclusive. A row with neither bound covers all versions.
- **Patch-granular, numeric comparison.** Bounds compare as the numeric
  `(major, minor, patch)` tuple, so `19.2.4 < 19.2.5 < 20.0` — the boundary
  can sit on a point release, which is exactly how the ceph el9→el10 cutover
  is expressed above.
- **Rows must be pairwise disjoint** and every bound must parse as a
  version; a typo must not silently become "all versions".
- **`default` must be a member of `supported`.**
- **Optional `arches:`** on a row restricts the architectures that may build
  that range (default: no restriction).
- A version that falls in **no row fails loudly** at descriptor-create time.
- A **non-version-shaped ref** (a branch name, say) selects the *highest*
  declared range, with a warning — dev branches land in the row of the line
  they fork from.

At build time this is enforcement, not advice: the default OS for a build
comes from the primary component's matching row, and *every* component that
declares a matrix vetoes unsupported combinations — an explicit
`--target el10` for `v19.2.4` fails with "unsupported", it does not
quietly build.

The example above is the current real policy for ceph: releases up to
19.2.4 build on el9 images only; 19.2.5 and everything after (20.x, the
21.x dev line, and onwards) require el10 — until a future OS forces the
next row.

### Moving the boundary / adding rows

- **New cutover point** (e.g. some future line moves to el11): close the
  last row with a `before:` and add the new row `{ from: ... }`.
- **A range that may build on two OSes** during a transition:
  `supported: [el9, el10]` with the preferred one as `default`.
- Whatever the matrix says, the recipes must carry matching content — see
  `when:` below. The matrix decides *whether* an OS is allowed; the recipe
  decides *what* that OS's image contains. Keep them in sync.

## Image recipes

### Recipe selection — `images/index.yaml`

```yaml
schema-version: 1
recipes:
  - { versions: { from: "17.2", before: "18.0" }, recipe: v17 }
  - { versions: { from: "18.0", before: "19.0" }, recipe: v18 }
  - { versions: { from: "19.0", before: "20.0" }, recipe: v19 }
  - { versions: { from: "20.0", before: "21.0" }, recipe: v20 }
  - { versions: { from: "21.0" }, recipe: v21 }
```

Selection is an explicit range lookup — there is no proximity ranking and
no symlink aliasing. The range rules are identical to the targets matrix
(half-open, disjoint, parseable bounds, non-version refs pick the highest
row with a warning). The selected version is the one *measured from the
source tree at build time*, so a dev branch builds with the recipe of its
base line. As sugar, an images tree containing a bare `image.yaml` and no
`index.yaml` is a single unbounded recipe.

When a new major line starts: add a recipe directory, add its row, and
close the previously-unbounded row with a `before:`.

### The recipe — `image.yaml`

A recipe describes one container image, in four parts:

```yaml
config:            # env / labels / annotations stamped into the image
  env:
    FROM_IMAGE: "{{ base_image }}"
  labels:
    CEPH_REF: "{{ git_ref }}"
  annotations:
    com.clyso.ces.ceph.version: "{{ git_ref }}"

pre:               # before package installation
  keys:            # GPG keys imported with rpm --import
    - "{{ artifacts_url }}/keys/release.asc"
  packages:        # bootstrap packages (names or package URLs)
    - epel-release
  repos:           # repositories, each optionally conditional
    - name: ganesha
      source: file://ganesha.repo        # file:// = copied from recipe dir
      dest: /etc/yum.repos.d/ganesha.repo
      when:
        os: [el9, el10]
    - name: tcmu-runner
      source: https://shaman.ceph.com/api/repos/tcmu-runner/main/latest/rocky/{{ os_version }}/repo?arch={{ arch }}
      dest: /etc/yum.repos.d/tcmu-runner.repo
      when:
        os: el10
    - name: python-scikit-learn
      source: copr://tchaikov/python-scikit-learn   # copr:// = dnf copr enable
      when:
        os: el9
  scripts:         # scripts run in the container before install
    - name: disable rpm docs install
      run: setup-no-docs.sh

packages:
  required:
    - section: ceph            # sections group packages; each optionally
      packages: [ceph-mon]     #   conditional via when:
    - section: crimson
      when:
        feature: crimson       # feature gate — enabled per build
      packages: [ceph-crimson-osd]

post:              # scripts run after package installation
  - name: fix-jaraco
    run: fix-jaraco.sh
    when:
      os: el9
```

Repo `source` schemes: `file://` (a file shipped in the recipe directory,
copied to `dest`), `http(s)://` (a `.repo` file downloaded to `dest`), and
`copr://` (enabled with `dnf copr enable`; rpm-only — a copr entry that
survives filtering for a non-rpm target is a validation error).

Things the recipe does **not** contain:

- **The release package.** The backend injects the component's own release
  rpm from the release descriptor; never hand-author its URL in `pre`.
- **Artifact locations.** Bucket/key URLs come from deployment config via
  `{{ artifacts_url }}` — a recipe must render anywhere a deployment points.

### `when:` — conditional content

Every `pre.repos` entry, `pre.scripts` entry, package section, and `post`
step takes an optional `when:` clause with four axes:

| Axis      | Values                      | Matches                          |
| --------- | --------------------------- | -------------------------------- |
| `os`      | `el9`, `el10`, ...          | the build's target OS            |
| `family`  | `el` (someday `deb`)        | the target OS family             |
| `arch`    | `x86_64`, `aarch64`         | the build architecture           |
| `feature` | free-form strings           | any enabled build feature        |

- Each axis takes a scalar or a list; a list matches by membership
  (`os: [el9, el10]`).
- A `when:` with several axes is a **conjunction** — all present axes must
  match. An absent axis matches everything; an entry without `when:` is
  unconditional.
- There is deliberately no negation or disjunction — express those with a
  second list entry or a separate recipe directory.

Filtering happens once, producing a flat plan for the build's exact
target; an empty plan is an error, so an OS the matrix allows but the
recipe ignores fails loudly rather than building an empty image.

**Convention:** keep OS-specific repos explicitly scoped (`when: os: ...`)
even when only one OS is currently supported — enabling the next OS must be
a deliberate edit to the recipe, never a silent inheritance of another OS's
repositories.

`feature` gates opt-in content (`- section: crimson` above); features are
enabled per build (e.g. `--feature crimson`) and named freely.

### Templating

Recipes are plain YAML first — parsing and filtering happen before any
interpolation, so a variable can never change the document's structure.
After filtering, string values render with `{{ variable }}` substitution
(strict: an undefined variable anywhere in the selected content fails the
build). Available variables:

| Variable           | Example                          |
| ------------------ | -------------------------------- |
| `version`          | `19.2.5`                         |
| `git_ref`          | `v19.2.5`                        |
| `git_sha1`         | the resolved commit              |
| `git_repo_url`     | `https://github.com/ceph/ceph`   |
| `component_name`   | `ceph`                           |
| `target`           | `el10-x86_64`                    |
| `os`               | `el10`                           |
| `os_family`        | `el`                             |
| `os_version`       | `10`                             |
| `arch`             | `x86_64`                         |
| `base_image`       | `quay.io/rockylinux/rockylinux:10` |
| `artifacts_url`    | the deployment's public artifact URL (optional — using it in a deployment that has none is an error) |

Prefer templated URLs (`rocky/{{ os_version }}`) over hardcoded ones inside
OS-scoped entries — it keeps the entry correct if the OS list widens.

## Build scripts and the `CBS_*` environment contract

Backend scripts (`scripts/rpm/*.sh`) receive **no positional arguments**;
the backend injects everything as environment variables. Required variables
should be consumed with `${VAR:?}` so a broken contract fails immediately:

| Variable                 | Meaning                                        |
| ------------------------ | ---------------------------------------------- |
| `CBS_COMPONENT`          | component name                                 |
| `CBS_VERSION`            | the version being built                        |
| `CBS_WORKTREE`           | path to the source tree to build               |
| `CBS_TOPDIR`             | rpmbuild top directory                         |
| `CBS_TARGET`             | full target, e.g. `el10-x86_64`                |
| `CBS_TARGET_OS`          | e.g. `el10`                                    |
| `CBS_TARGET_OS_FAMILY`   | e.g. `el`                                      |
| `CBS_TARGET_OS_VERSION`  | e.g. `10`                                      |
| `CBS_TARGET_ARCH`        | e.g. `x86_64`                                  |
| `CBS_ARTIFACTS_URL`      | the deployment's public artifact URL           |
| `CBS_COMPONENT_REPO_URL` | this build's package repository base URL       |
| `CBS_RELEASE_KEY_URL`    | the release signing key URL                    |

Not every variable is present at every stage: `CBS_WORKTREE`/`CBS_TOPDIR`
exist where the stage has them (a release-package lookup has neither), and
the three `CBS_*_URL` variables appear only when the deployment configures
storage/signing — which is why `${VAR:?}` matters.

As with recipes: never hardcode bucket or key URLs in a script — consume
the injected locations.

## The operator side (for context)

Two things live in the deployment, not in this repository:

- **The targets registry** (`targets.yaml` in the CBS config) maps each OS
  to its base image (`el10 → quay.io/rockylinux/rockylinux:10`), with
  optional named profiles overlaying customer-specific images. Adding a new
  OS to a component's matrix requires the deployment's registry to know
  that OS.
- **`paths.components`** in the CBS config points at one or more trees like
  this repository's `components/`.

## Checklists

**Adding a new major line (e.g. v22):**

1. Create `images/v22/` (start from the previous line's recipe).
2. Close the previously-unbounded index row with `before: "22.0"`, add
   `{ versions: { from: "22.0" }, recipe: v22 }`.
3. If the OS policy changes with it, add a matrix row in
   `cbs.component.yaml` (and close the previous row's range).
4. Run the corpus smoke test (see below).

**Moving the OS boundary (e.g. some line moves to el11):**

1. Split/close the matrix ranges at the exact version (patch-granular
   bounds are fine: `before: "19.2.5"` / `from: "19.2.5"`).
2. Make sure every recipe reachable by the new OS's versions carries
   `when:`-scoped content for it (repos at minimum), and that el-specific
   post steps are scoped to the OSes they apply to.
3. Confirm the deployment targets registry maps the new OS to a base image.
4. Validate with a real build before relying on it — range math is checked
   at load time, repo URLs are not.

**Validating changes:** the cbscore test suite includes a corpus smoke test
that selects, parses, filters, and renders every curated ceph line from a
local copy of this repository:

```bash
# from the cbs repository's cbsd-rs/ directory:
CBS_COMPONENTS_DIR=/path/to/cbs-components/components \
  cargo test -p cbscore ceph_corpus
```
