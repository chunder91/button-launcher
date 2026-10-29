# Settable WPF properties per type (from the .NET Framework 4.8 reference), used by the box tests to catch
# "The property 'X' cannot be found on this object" without Windows. Only types the launcher creates are listed.
$fe = 'Margin Width Height MinWidth MinHeight MaxWidth MaxHeight HorizontalAlignment VerticalAlignment Visibility IsEnabled Opacity IsHitTestVisible ToolTip Cursor Focusable FocusVisualStyle Tag Style ContextMenu RenderTransform RenderTransformOrigin LayoutTransform ClipToBounds Resources DataContext Name UseLayoutRounding SnapsToDevicePixels OpacityMask Effect Clip CacheMode FlowDirection AllowDrop Language Uid' -split ' '
$ctl = $fe + ('Background Foreground BorderBrush BorderThickness Padding FontFamily FontSize FontWeight FontStyle FontStretch HorizontalContentAlignment VerticalContentAlignment IsTabStop TabIndex Template' -split ' ')
$cc = $ctl + 'Content'
$pnl = $fe + 'Background'
$shp = $fe + ('Fill Stroke StrokeThickness StrokeDashArray StrokeDashCap StrokeLineJoin Stretch' -split ' ')
$global:WpfProps = @{
    'System.Windows.Window'                      = $cc + ('Title SizeToContent ResizeMode ShowInTaskbar WindowStartupLocation Owner Topmost WindowStyle AllowsTransparency Left Top DialogResult Icon ShowActivated WindowState' -split ' ')
    'System.Windows.Controls.Border'             = $fe + ('Background BorderBrush BorderThickness CornerRadius Padding Child' -split ' ')
    'System.Windows.Controls.TextBlock'          = $fe + ('Text Background Foreground FontFamily FontSize FontWeight FontStyle TextWrapping TextTrimming TextAlignment Padding LineHeight LineStackingStrategy' -split ' ')
    'System.Windows.Controls.StackPanel'         = $pnl + 'Orientation'
    'System.Windows.Controls.Grid'               = $pnl + 'ShowGridLines'
    'System.Windows.Controls.DockPanel'          = $pnl + 'LastChildFill'
    'System.Windows.Controls.Canvas'             = $pnl
    'System.Windows.Controls.Primitives.UniformGrid' = $pnl + ('Columns Rows' -split ' ')
    'System.Windows.Controls.Button'             = $cc + ('IsDefault IsCancel Command ClickMode' -split ' ')
    'System.Windows.Controls.CheckBox'           = $cc + ('IsChecked IsThreeState' -split ' ')
    'System.Windows.Controls.RadioButton'        = $cc + ('IsChecked GroupName' -split ' ')
    'System.Windows.Controls.Label'              = $cc
    'System.Windows.Controls.TextBox'            = $ctl + ('Text MaxLength TextWrapping CaretBrush IsReadOnly AcceptsReturn SelectionBrush TextAlignment CaretIndex' -split ' ')
    'System.Windows.Controls.PasswordBox'        = $ctl + ('MaxLength CaretBrush PasswordChar SelectionBrush Password' -split ' ')
    'System.Windows.Controls.ComboBox'           = $ctl + ('SelectedItem SelectedIndex IsEditable ItemsSource Text MaxDropDownHeight' -split ' ')
    'System.Windows.Controls.MenuItem'           = $ctl + ('Header IsCheckable IsChecked Icon InputGestureText Command StaysOpenOnClick ItemsSource' -split ' ')
    'System.Windows.Controls.ContextMenu'        = $ctl + ('Placement PlacementTarget IsOpen HasDropShadow StaysOpen' -split ' ')
    'System.Windows.Controls.Separator'          = $ctl
    'System.Windows.Controls.Image'              = $fe + ('Source Stretch StretchDirection' -split ' ')
    'System.Windows.Controls.Primitives.Popup'   = $fe + ('Child IsOpen StaysOpen PlacementTarget Placement AllowsTransparency HorizontalOffset VerticalOffset PopupAnimation' -split ' ')
    'System.Windows.Shapes.Rectangle'            = $shp + ('RadiusX RadiusY' -split ' ')
    'System.Windows.Shapes.Ellipse'              = $shp
}
# Every "$v.Prop = ..." where $v was last set by "New-Object <listed type>" in the same function: Prop must exist on that type.
function global:Find-WpfPropMisuse($ast) {
    $bad = New-Object System.Collections.ArrayList
    foreach ($fn in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $types = @{}
        $asg = @($fn.Body.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) | Sort-Object { $_.Extent.StartOffset })
        foreach ($a in $asg) {
            $l = $a.Left
            if ($l -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $n = $l.VariablePath.UserPath; $types.Remove($n)
                if ($a.Right.Extent.Text -match '^New-Object\s+(System\.Windows\.[\w.]+)\s*$') { $types[$n] = $Matches[1] }
                elseif ($a.Right.Extent.Text -match '^\[pscustomobject\]\s*@\{') {   # custom objects: only the keys in the literal (plus Add-Member/Set-Prop) can be set
                    $h = $a.Right.Find({ param($y) $y -is [System.Management.Automation.Language.HashtableAst] }, $true)
                    if ($h) { $types[$n] = 'pscustomobject'; $types["$n#keys"] = @($h.KeyValuePairs | ForEach-Object { [string]$_.Item1.Extent.Text.Trim("'", '"') }) } }
            } elseif ($l -is [System.Management.Automation.Language.MemberExpressionAst] -and $l.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $l.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $n = $l.Expression.VariablePath.UserPath; $t = $types[$n]
                if ($t -eq 'pscustomobject') {
                    $added = $fn.Body.Extent.Text -match ('(Add-Member[^\r\n]*\b{0}\b|Set-Prop \${1} [''"]?{0}\b)' -f [regex]::Escape($l.Member.Value), [regex]::Escape($n))
                    if ($types["$n#keys"] -notcontains $l.Member.Value -and -not $added) { [void]$bad.Add(('{0}: ${1}.{2} on a [pscustomobject] without that key (line {3})' -f $fn.Name, $n, $l.Member.Value, $a.Extent.StartLineNumber)) }
                    continue }
                if ($t -and $global:WpfProps.ContainsKey($t) -and $global:WpfProps[$t] -notcontains $l.Member.Value) {
                    [void]$bad.Add(('{0}: ${1}.{2} on {3} (line {4})' -f $fn.Name, $n, $l.Member.Value, $t, $a.Extent.StartLineNumber)) } } } }
    return $bad
}
# Parameters or assignments named after PowerShell automatic variables ($input is the pipeline enumerator, never the argument).
function global:Find-AutomaticVarMisuse($ast) {
    $auto = 'input', 'args', 'this', '_', 'psitem', 'myinvocation', 'psboundparameters', 'pscmdlet', 'host', 'error', 'executioncontext', 'home', 'pid', 'pwd', 'true', 'false', 'null', 'foreach', 'switch', 'psscriptroot', 'pscommandpath', 'matches', 'event', 'sender', 'eventargs'
    $bad = New-Object System.Collections.ArrayList
    foreach ($p in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
        if ($p.Name.VariablePath.UserPath.ToLowerInvariant() -in $auto) { [void]$bad.Add(('parameter ${0} (line {1})' -f $p.Name.VariablePath.UserPath, $p.Extent.StartLineNumber)) } }
    foreach ($a in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and $x.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        if ($a.Left.VariablePath.UserPath.ToLowerInvariant() -in $auto) { [void]$bad.Add(('assignment ${0} (line {1})' -f $a.Left.VariablePath.UserPath, $a.Extent.StartLineNumber)) } }
    return $bad
}
# v1.4.0 laptop bug (4:38 PM, "The property 'busy' cannot be found on this object"): .GetNewClosure() copies only the variables
# that are LOCAL to the scope it runs in. A closure made inside another closure does not see what the outer closure captured,
# so $ds inside the Test button's $onDone was $null. Every variable a closure reads must be a param/assignment/foreach variable
# of the scope that creates it (or of the closure itself), or be $global:/$script:/$env:-qualified or automatic.
function global:Get-ClosureScopeBlock($node) {   # nearest enclosing function body or GetNewClosure'd block (plain blocks such as ForEach-Object run in that scope)
    $p = $node.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.ScriptBlockAst]) {
            if ($p.Parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $null -eq $p.Parent) { return $p }
            if ((Test-ClosureBlock $p.Parent)) { return $p } }
        $p = $p.Parent }
    return $null
}
function global:Test-ClosureBlock($sbe) {
    return ($sbe -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and $sbe.Parent -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $sbe.Parent.Expression -eq $sbe -and $sbe.Parent.Member.Extent.Text -eq 'GetNewClosure')
}
function global:Get-ScopeLocals($block) {   # names defined directly in this scope (not inside nested functions or closures)
    $names = @{}
    $own = { param($x) $s = Get-ClosureScopeBlock $x; return ($s -eq $block) }
    if ($block.ParamBlock) { foreach ($p in $block.ParamBlock.Parameters) { $names[$p.Name.VariablePath.UserPath.ToLowerInvariant()] = 1 } }
    if ($block.Parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $block.Parent.Parameters) { foreach ($p in $block.Parent.Parameters) { $names[$p.Name.VariablePath.UserPath.ToLowerInvariant()] = 1 } }
    foreach ($a in $block.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
        if (-not (& $own $a)) { continue }
        foreach ($v in @($a.Left) + @($a.Left.FindAll({ param($y) $y -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))) {
            if ($v -is [System.Management.Automation.Language.VariableExpressionAst] -and ($a.Left -eq $v -or $a.Left -is [System.Management.Automation.Language.ConvertExpressionAst] -or $a.Left -is [System.Management.Automation.Language.ArrayLiteralAst])) { $names[$v.VariablePath.UserPath.ToLowerInvariant()] = 1 } } }
    foreach ($f in $block.FindAll({ param($x) $x -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)) { if (& $own $f) { $names[$f.Variable.VariablePath.UserPath.ToLowerInvariant()] = 1 } }
    foreach ($r in $block.FindAll({ param($x) $x -is [System.Management.Automation.Language.ConvertExpressionAst] -and $x.Type.TypeName.Name -eq 'ref' -and $x.Child -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) { if (& $own $r) { $names[$r.Child.VariablePath.UserPath.ToLowerInvariant()] = 1 } }
    return $names
}
function global:Find-ClosureCaptureMisses($ast) {
    $auto = '_', 'this', 'args', 'true', 'false', 'null', 'psitem', 'sender', 'e', 'matches', 'input', 'event', 'eventargs', 'eventsubscriber', 'lastexitcode', 'error', 'psscriptroot', 'pscommandpath', 'host', 'pid', 'home', 'pwd', 'myinvocation', 'psboundparameters', 'executioncontext', 'erroractionpreference', 'shellid', 'pscmdlet'
    $bad = New-Object System.Collections.ArrayList
    foreach ($sbe in $ast.FindAll({ param($x) Test-ClosureBlock $x }, $true)) {
        $outer = Get-ClosureScopeBlock $sbe; if (-not $outer) { continue }
        $have = Get-ScopeLocals $outer; $mine = Get-ScopeLocals $sbe.ScriptBlock
        $seen = @{}
        foreach ($v in $sbe.ScriptBlock.FindAll({ param($x) $x -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            if ((Get-ClosureScopeBlock $v) -ne $sbe.ScriptBlock) { continue }   # inside a nested closure: checked on its own
            $vp = $v.VariablePath; if (-not $vp.IsUnqualified -and -not $vp.IsLocal) { continue }
            $n = $vp.UserPath.ToLowerInvariant() -replace '^local:', ''
            $q = $v.Parent; $inner = $false   # a param of a plain inner block (a delegate such as an HwndSourceHook) is that block's own
            while ($q -and $q -ne $sbe.ScriptBlock) { if ($q -is [System.Management.Automation.Language.ScriptBlockAst] -and $q.ParamBlock -and @($q.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $vp.UserPath }).Count) { $inner = $true; break }; $q = $q.Parent }
            if ($inner) { continue }
            if ($n -in $auto -or $mine.ContainsKey($n) -or $have.ContainsKey($n) -or $seen.ContainsKey($n)) { continue }
            $seen[$n] = 1
            $fn = $sbe; while ($fn -and -not ($fn -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $fn = $fn.Parent }
            [void]$bad.Add(('{0}: ${1} not captured by the closure at line {2}' -f $(if ($fn) { $fn.Name } else { '<script>' }), $vp.UserPath, $sbe.Extent.StartLineNumber)) } }
    return $bad
}
