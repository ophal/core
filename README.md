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
```

`install`, `migrate`, and `module enable/disable` are reserved command shapes
for the operations roadmap and currently return an explicit "not implemented"
status instead of silently doing nothing.
