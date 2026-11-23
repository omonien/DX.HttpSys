# Lint-Delphi113.ps1 - flags language features newer than Delphi 11.3 and
# typographic dashes in the benchmark sources, until a real 11.3 build exists.
#
#   ./Lint-Delphi113.ps1                 (default: benchmarks/)
#   ./Lint-Delphi113.ps1 -Path ..\..\src
#
# Checks in .pas/.dpr/.inc:
#   - multiline string literals (''' , Delphi 12)
#   - conditional expressions "if ... then ... else" on the right side of := or
#     inside parentheses/arguments (Delphi 13)
#   - "is not" and "not in" operators (Delphi 13)
#   - NameOf( (Delphi 13)
#   - inline assembler blocks without a {$IFDEF PUREPASCAL} style fallback (warning only)
# Checks in .pas/.dpr/.md/.ps1/.js: en dash and em dash characters (U+2013, U+2014).
# Exit code 1 when an error was found.

param([string]$Path = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$errors = 0; $warnings = 0
$enDash = [string][char]0x2013
$emDash = [string][char]0x2014

$rules = @(
    @{ Name = 'multiline string (Delphi 12)'; Pattern = "'''" },
    @{ Name = 'conditional expression (Delphi 13)'; Pattern = '(:=|\(|,)\s*if\b[^;]*\bthen\b[^;]*\belse\b' },
    @{ Name = '"is not" operator (Delphi 13)'; Pattern = '\bis\s+not\b' },
    @{ Name = '"not in" operator (Delphi 13)'; Pattern = '\bnot\s+in\b' },
    @{ Name = 'NameOf (Delphi 13)'; Pattern = '\bNameOf\s*\(' }
)

$files = Get-ChildItem -Path $Path -Recurse -File -Include *.pas, *.dpr, *.inc, *.md, *.ps1, *.js |
    Where-Object { $_.FullName -notmatch '[\\/](results|build|libs)[\\/]' }
foreach ($f in $files) {
    $lines = @(Get-Content -LiteralPath $f.FullName -Encoding utf8)
    $isPascal = $f.Extension -in @('.pas', '.dpr', '.inc')
    $inBrace = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if ($line.Contains($enDash) -or $line.Contains($emDash)) {
            Write-Host ("ERROR {0}:{1}: typographic dash" -f $f.FullName, ($i + 1)); $errors++
        }
        if (-not $isPascal) { continue }
        # Strip // comments and string literals before matching code rules.
        $code = $line -replace "'([^']|'')*'", "''"
        $c = $code.IndexOf('//')
        if ($c -ge 0) { $code = $code.Substring(0, $c) }
        if ($line.Contains("'''")) { $code = "'''" }
        if ($code.Trim().StartsWith('///') -or $code.Trim().StartsWith('{')) { continue }
        foreach ($r in $rules) {
            if ($code -match $r.Pattern) {
                Write-Host ("ERROR {0}:{1}: {2}: {3}" -f $f.FullName, ($i + 1), $r.Name, $line.Trim()); $errors++
            }
        }
        if ($code -match '^\s*asm\b') {
            Write-Host ("WARN  {0}:{1}: inline assembler, make sure a Pascal fallback exists" -f $f.FullName, ($i + 1)); $warnings++
        }
    }
}
Write-Host ("Lint finished: {0} files, {1} errors, {2} warnings" -f $files.Count, $errors, $warnings)
if ($errors -gt 0) { exit 1 }
exit 0
