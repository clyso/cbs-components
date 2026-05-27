# Components for CBS builds

This repository contains the components that are consumed by [CBS](https://github.com/clyso/cbs).

The various components can be found under the `components/` directory
at the repository's root.

Components are packaged as tar files using `scripts/gen-package.sh`.

## Installing Components

The component directories must live in the CBS installation directory,
by default at `~/.local/share/cbsd-rs/<deployment>/components/`, where
`<deployment>` should be `default` if not otherwise specified.

The latest component release can be installed in this directory by running

<!-- markdownlint-disable MD013 -->

```bash
curl -L \
  https://github.com/clyso/cbs-components/releases/latest/download/cbs-components.tar | \
  tar -C ~/.local/share/cbsd-rs/<deployment>/components/ -xf -
```

## Contributing

- DCO (Developer Certificate of Origin) required on all commits
- GPG-signed commits required
- Commit style follows Ceph project conventions

## LICENSE

```text
This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.
```

The GPLv3 license file can be found in [LICENSE](./LICENSE).
