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
    'System.Windows.Controls.TextBox'            = $ctl + ('Text MaxLength TextWrapping CaretBrush IsReadOnly AcceptsReturn SelectionBrush TextAlignment' -split ' ')
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
            } elseif ($l -is [System.Management.Automation.Language.MemberExpressionAst] -and $l.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and $l.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $n = $l.Expression.VariablePath.UserPath; $t = $types[$n]
                if ($t -and $global:WpfProps.ContainsKey($t) -and $global:WpfProps[$t] -notcontains $l.Member.Value) {
                    [void]$bad.Add(('{0}: ${1}.{2} on {3} (line {4})' -f $fn.Name, $n, $l.Member.Value, $t, $a.Extent.StartLineNumber)) } } } }
    return $bad
}
# Parameters or assignments named after PowerShell automatic variables ($input is the pipeline enumerator, never the argument).
function global:Find-AutomaticVarMisuse($ast) {
    $auto = 'input', 'args', 'this', '_', 'psitem', 'myinvocation', 'psboundparameters', 'pscmdlet', 'host', 'error', 'executioncontext', 'home', 'pid', 'pwd', 'true', 'false', 'null', 'foreach', 'switch', 'psscriptroot', 'pscommandpath'
    $bad = New-Object System.Collections.ArrayList
    foreach ($p in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
        if ($p.Name.VariablePath.UserPath.ToLowerInvariant() -in $auto) { [void]$bad.Add(('parameter ${0} (line {1})' -f $p.Name.VariablePath.UserPath, $p.Extent.StartLineNumber)) } }
    foreach ($a in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and $x.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
        if ($a.Left.VariablePath.UserPath.ToLowerInvariant() -in $auto) { [void]$bad.Add(('assignment ${0} (line {1})' -f $a.Left.VariablePath.UserPath, $a.Extent.StartLineNumber)) } }
    return $bad
}
