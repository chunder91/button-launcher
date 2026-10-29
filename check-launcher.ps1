# Static scope checker for Launcher.ps1 (runs on pwsh, no Windows needed)
param([string]$Path = '/workspace/button-launcher/Launcher.ps1')
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tok, [ref]$err)
$issues = New-Object System.Collections.ArrayList
if ($err) { $err | % { [void]$issues.Add("PARSE: line $($_.Extent.StartLineNumber): $($_.Message)") } }
$FA = [System.Management.Automation.Language.FunctionDefinitionAst]
$SBE = [System.Management.Automation.Language.ScriptBlockExpressionAst]
function Get-Ancestor($n, $type) { $p = $n.Parent; while ($p) { if ($p -is $type) { return $p }; $p = $p.Parent }; $null }

# 1. Function definitions
$defs = @{}
foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $name = $f.Name -replace '^global:', ''
    $nested = [bool](Get-Ancestor $f $FA)
    $defs[$name] = [pscustomobject]@{ Line = $f.Extent.StartLineNumber; Global = $f.Name -like 'global:*'; Nested = $nested; Parent = (Get-Ancestor $f $FA) }
    if (-not $nested -and -not ($f.Name -like 'global:*')) { [void]$issues.Add("SCOPE: top-level function '$name' (line $($f.Extent.StartLineNumber)) is not global: - event handlers can't see it") }
}

# 2. Calls: unknown commands, and top-level calls before definition
$builtin = @{}; Get-Command -CommandType Cmdlet, Function, Alias, Application -ErrorAction SilentlyContinue | % { $builtin[$_.Name] = $true }
$winOnly = 'Unblock-File','Get-CimInstance','Get-Service','Restart-Service','Set-ItemProperty','New-Item','Start-Process'
$firstTop = @{}
foreach ($c in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $n = $c.GetCommandName(); if (-not $n) { continue }
    $line = $c.Extent.StartLineNumber
    $inFunc = Get-Ancestor $c $FA; $inSb = Get-Ancestor $c $SBE
    if ($defs.ContainsKey($n)) {
        $d = $defs[$n]
        if ($d.Nested -and $inSb -and -not ($inFunc -eq $d.Parent)) { [void]$issues.Add("SCOPE: nested helper '$n' called from a handler at line $line") }
        if (-not $inFunc -and -not $inSb) {
            if (-not $firstTop.ContainsKey($n)) { $firstTop[$n] = $line }
            if ($line -lt $d.Line) { [void]$issues.Add("ORDER: '$n' called at top level line $line before its definition at line $($d.Line)") }
        }
    } elseif (-not $builtin.ContainsKey($n) -and $n -notin $winOnly -and $n -notmatch '\.(exe|cmd)$') {
        [void]$issues.Add("UNKNOWN: '$n' at line $line is not defined anywhere")
    }
}

# 3. Variables in handler scriptblocks (everything passed as { ... } to .Add_*, AddHook, timers, menu clicks)
$auto = '_','this','true','false','null','args','PSItem','sender','e','input','MyInvocation','env','LASTEXITCODE','Error','PSScriptRoot','handled'
foreach ($sb in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) {
    $closure = $sb.Parent -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $sb.Parent.Member.Value -eq 'GetNewClosure'
    $assigned = @{}
    foreach ($a in $sb.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        $l = $a.Left; if ($l -is [System.Management.Automation.Language.ConvertExpressionAst]) { $l = $l.Child }
        if ($l -is [System.Management.Automation.Language.VariableExpressionAst]) { $assigned[$l.VariablePath.UserPath] = $true } }
    foreach ($pp in $sb.FindAll({ $args[0] -is [System.Management.Automation.Language.ParameterAst] }, $true)) { $assigned[$pp.Name.VariablePath.UserPath] = $true }
    foreach ($fe in $sb.FindAll({ $args[0] -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { $assigned[$fe.Variable.VariablePath.UserPath] = $true }
    foreach ($v in $sb.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        $vp = $v.VariablePath
        if ($vp.IsGlobal -or $vp.DriveName -eq 'env' -or $vp.IsScript) { continue }
        $n = $vp.UserPath
        if ($n -in $auto -or $assigned[$n]) { continue }
        $inFn = Get-Ancestor $v $FA; $outerFn = Get-Ancestor $sb $FA
        if ($inFn -and $inFn -ne $outerFn) { continue }   # belongs to a function defined inside the block
        if (-not $closure -and $outerFn) {
            # non-closure block inside a function reading a local: invisible when the event fires later
            $parentSb = Get-Ancestor $sb $SBE
            if (-not $parentSb) { [void]$issues.Add("CAPTURE: `$$n read at line $($v.Extent.StartLineNumber) in a handler without .GetNewClosure()") }
        }
        if (-not $outerFn -and -not $closure) { [void]$issues.Add("CAPTURE: `$$n read at line $($v.Extent.StartLineNumber) in a top-level handler (not `$global:)") }
    }
}

# 4. Globals read but never assigned
$gAssigned = @{}; $gRead = @{}
foreach ($v in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] -and $args[0].VariablePath.IsGlobal }, $true)) {
    $n = $v.VariablePath.UserPath -replace '^global:', ''
    $par = $v.Parent
    if ($par -is [System.Management.Automation.Language.AssignmentStatementAst] -and $par.Left -eq $v) { if (-not $gAssigned[$n]) { $gAssigned[$n] = $v.Extent.StartLineNumber } }
    elseif (-not $gRead[$n]) { $gRead[$n] = $v.Extent.StartLineNumber }
}
foreach ($n in $gRead.Keys) {
    if (-not $gAssigned[$n]) { [void]$issues.Add("GLOBAL: `$global:$n read (line $($gRead[$n])) but never assigned") }
    elseif ($gAssigned[$n] -gt $gRead[$n] -and -not (Get-Ancestor ($ast.Find({ $args[0].Extent.StartLineNumber -eq $gRead[$n] }, $true)) $FA)) { [void]$issues.Add("GLOBAL: `$global:$n first read at line $($gRead[$n]) before assignment at $($gAssigned[$n])") }
}

"Functions defined: $($defs.Count)   Top-level calls checked: $($firstTop.Count)   Globals: $(@($gAssigned.Keys).Count)"
"Globals assigned: " + (($gAssigned.GetEnumerator() | Sort-Object Value | % { "$($_.Key)@$($_.Value)" }) -join ', ')
if ($issues.Count) { "ISSUES ($($issues.Count)):"; $issues | Sort-Object -Unique } else { 'NO ISSUES' }
