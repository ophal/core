# Ophal - An experimental Lua based CMS/CMF

## What is Ophal?

Ophal aimed to become a highly scalable web platform, easy to maintain, learn, extend and open to improvements.

## Development

Development workflow and release policy: [docs/branching-and-releases.md](docs/branching-and-releases.md).

## Dependencies

Ophal has the following dependencies:

- Seawolf (http://github.com/ophal/seawolf)
- LuaSocket
- LPEG
- LuaFilesystem
- LuaDBI
- luuid
- dkjson
- LuaCrypto (only if user module is enabled)

## CLI

The repository includes a small `ophal` command-line entrypoint:

```sh
./ophal help
./ophal cache clear
./ophal sha256 mypassword
./ophal install check
./ophal install init ./mysite --site-name "My Site"
./ophal migrate
./ophal migrate status
./ophal module enable comment
./ophal module disable comment
```

`install check` verifies required Lua dependencies and reports local config
state. `install init` scaffolds `settings.lua`, `vault.lua`, and the files
directory for a new local site.

`module enable/disable` persists local overrides in `settings/modules.lua`,
which is ignored by git by default so it can stay workspace-specific.

`migrate` applies registered framework and module migrations and initializes the
local migration tracking table when needed.
