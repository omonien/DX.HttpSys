# Delphi Coding Standards

These rules apply to ALL Delphi source files in this project.
Follow them without exception unless explicitly told otherwise.

---

## File Encoding

- Always use **UTF-8 with BOM** for `.pas`, `.dpr`, `.dpk` files.
  The BOM bytes are `EF BB BF`. Without BOM, Delphi treats the file as ANSI.
- Always use **CRLF** (`\r\n`) line endings. LF-only files cause Delphi compilation errors.
- When writing files with Python: `open(path, 'w', encoding='utf-8-sig', newline='')`.
  Use `utf-8-sig` — it adds exactly one BOM. Never add BOM bytes manually when using `utf-8-sig`.
- In `.dfm` and `.fmx` files, all non-ASCII characters MUST use `#NNNN` notation:
  `'Stra'#223'e'` not `'Straße'`, `'M'#252'nchen'` not `'München'`.

---

## Project Language

**English** — applies uniformly to identifiers, comments, documentation and commit messages.
(The `docs/PRD.md` design document is German; everything else is English.)

---

## Unit Header

Every `.pas` file MUST begin with this XML Doc header before the `unit` keyword:

```pascal
/// <summary>
///   UnitName — Brief one-line description.
/// </summary>
/// <remarks>
///   Additional context, design decisions, dependencies.
/// </remarks>
/// <author>Olaf Monien</author>
/// <created>YYYY-MM-DD</created>
/// <license>MIT</license>
unit UnitName;
```

---

## Naming Conventions

| Element | Prefix | Example |
|---------|--------|---------|
| Classes / Records / Enums | `T` | `TDXHttpSysServer` |
| Interfaces | `I` | `IDXHttpSysRequestHandler` |
| Exceptions | `E` | `EDXHttpSysNotSupported` |
| Method parameters | `A` | `APort: Word` |
| Local variables | `L` | `LRequest: TDXHttpSysRequest` |
| Class fields | `F` | `FThreadPool: TDXHttpSysThreadPool` |
| Constants | `c` / `sc` / `rs` | `cDefaultThreadCount`, `scServerHeader` |

- Components: TypePrefix + Name, no variable prefix (`ButtonLogin`, `EditUserName`).
- Form units end `.Form.pas`, data modules end `.DM.pas`.
- Procedures start with verbs (`StartServer`); functions use `Get`/`Is`/`Can`/`Find`.
- Enums are scoped (`{$SCOPEDENUMS ON}`), no prefix, always fully qualified.

---

## Code Formatting

- 2-space indentation, never tabs; 120-character maximum line length.
- `begin`/`end` on the same line as a method header; on new lines for `if`/`for`/`while`/`try`.
- Use `FreeAndNil` for class fields. Never leave `except` blocks empty. Always type-qualify exceptions.
- Wrap Windows-only code in `{$IFDEF MSWINDOWS}` — the core must still *compile* on macOS/Linux
  (API pointers are `nil`; `TDXHttpSysServer.Start` raises `EDXHttpSysNotSupported`).

---

## Project Layout

```
src/Core/        Framework-agnostic HTTP.sys engine (RTL only)
src/Adapters/    WiRL + WebBroker adapters
src/*.dpk/.dproj Runtime packages (Core, WiRL, WebBroker)
demo/            Demo applications (Standalone, WiRL, WebBroker)
tests/           DUnitX console test runner
libs/DUnitX/     Test framework (git submodule)
build/           Build output ONLY (git-ignored)
build-scripts/   DelphiBuildDPROJ.ps1
docs/            PRD + Delphi Style Guide
```

---

## Output Paths

- Executables / BPL: `..\build\$(Platform)\$(Config)`
- DCU / DCP: `..\build\$(Platform)\$(Config)\dcu`
- Never use flat output paths. Never commit build output to VCS.

---

## DPROJ Rules

- Do not edit DPROJ manually for structural changes — use the `delphi-project` skill tools
  (`dproj_normalize.py`, `dproj_validate.py`).
- Use relative search paths only (`..\libs\DUnitX\Source`, `..\src\Core`). No drive letters or
  `%USERPROFILE%` paths. Machine-specific settings belong in the git-ignored `.dproj.user`.
- `IncludeVerInfo=true`; version numbers consistent (`Major.Minor.Release.Build`). Start at `1.0.0.0`.

---

## Testing (DUnitX)

- Fixtures use `[TestFixture]`; tests `[Test]`; `[Setup]`/`[TearDown]`; `[TestCase(...)]` for params.
- Register fixtures with `TDUnitX.RegisterTestFixture(...)` in the `initialization` section.
- DUnitX lives in `libs/DUnitX/` (git submodule) — search path `..\libs\DUnitX\Source`.
- New features get comprehensive unit tests; bugfixes get a regression test.

---

## Build

```powershell
build-scripts\DelphiBuildDPROJ.ps1 -ProjectFile src\DX.HttpSys.Core.dproj
build-scripts\DelphiBuildDPROJ.ps1 -ProjectFile src\DX.HttpSys.Core.dproj -Platform Win64
```

The script auto-detects the newest installed Delphi version.

---

## Generics and Modern Delphi

- `TObjectList<T>` (OwnsObjects=True) for owning collections; `TList<T>` / `TDictionary<K,V>` otherwise.
- Prefer inline variable declarations (`var LX := ...`).
- Always define interface GUIDs: `['{...}']`.
