
$script:Sb = @{
    Pid = 0; Level = 0L; Verified = $false; NextUi = [DateTime]::MinValue
    Selected = 0L; Rows = @(); Invulnerable = @{}; Originals = @{}; Queue = (New-Object System.Collections.Queue)
    NextSpawn = [DateTime]::MinValue; Busy = $false; History = @(); Events = @(); Seen = @{}
    PendingGod = @{}; PendingBoss = @{}; PendingCustom = @{}; PendingSelfCustom = $null; CustomProfiles = @{}; CustomDrafts = @{}; CustomAppliedMax = @{}; NextCustomProfile = [DateTime]::MinValue; ShipSystems = @{}; CustomShipChoiceStates = @(); CustomShipListSignature = ''; CustomShipListBusy = $false; CustomPersistentBusy = $false; CustomUiLoading = $false; Favorites = @(); Recent = @(); SessionStart = [DateTime]::UtcNow
    LocalPlayerState = 0L; LocalTeam = -1; LocalController = 0L; LocalClassPtr = 0L; LastPlayerPawn = 0L; LastPlayerPawnToken = ''; DesiredRespawnShip = ''
    Wave = $null; Sample = $null; Loss = 0.0; Peak = 0.0; MonitorStart = [DateTime]::UtcNow
    WorldSettings = 0L; EntityRows = @(); NextNames = @{}; UsedBotNames = @{}; LastError = ''; UiBusy = $false; DebugFollow = $true
    MapRows = @(); MapHits = @(); MapSectorHits = @(); MapSectorByPawn = @{}; MapSectorNames = @{}; MapBounds = @{}
    MapKnown = @{}; MapMaxHp = @{}; MapRosterScroll = @{ Allies = 0; Enemies = 0 }; MapZoom = 1.0; MapTargetZoom = 1.0; MapZoomAnchor = $null; MapPanX = 0.0; MapPanY = 0.0; MapDrag = $false; MapDragPoint = $null; MapNextInteractionPaint = [DateTime]::MinValue; MapFocusSector = ''
    NextMap = [DateTime]::MinValue; NativeMap = $null; NextNativeMap = [DateTime]::MinValue; GNames = 0L; FNameCache = @{}
}
$script:SbDataDir = Join-Path $PSScriptRoot 'data'
$script:SbLogFile = Join-Path $script:SbDataDir 'trainer-debug.log'
$script:SbBuildHash = '22E5A945A219DABC5ECFE72AABCF0C302E858C9B78320B633CEE179A034C1E48'
function Sb-Log([string]$Message) {
    $line = ('{0:HH:mm:ss}  {1}' -f [DateTime]::Now, $Message)
    $script:Sb.Events = @(@($script:Sb.Events) + $line | Select-Object -Last 5000)
    try { if(-not(Test-Path -LiteralPath $script:SbDataDir)){[void](New-Item -ItemType Directory -Path $script:SbDataDir -Force)};Add-Content -LiteralPath $script:SbLogFile -Value $line -Encoding UTF8 } catch {}
    if ($null -ne $sbMessage) { $sbMessage.Text = $Message }
    if ($null -ne $sbLog) {
        $oldStart=$sbLog.SelectionStart;$oldLength=$sbLog.SelectionLength
        $prefix=if($sbLog.TextLength-gt0){[Environment]::NewLine}else{''}
        $sbLog.AppendText($prefix+$line)
        if($script:Sb.DebugFollow){$sbLog.SelectionStart=$sbLog.TextLength;$sbLog.SelectionLength=0;$sbLog.ScrollToCaret()}
        else{$sbLog.Select([Math]::Min($oldStart,$sbLog.TextLength),[Math]::Min($oldLength,[Math]::Max(0,$sbLog.TextLength-$oldStart)))}
    }
}
function Sb-Run([scriptblock]$Action) {
    try { & $Action } catch { Sb-Log ('Error: ' + $_.Exception.Message) }
}
function Sb-Token([int64]$Object) {
    if (-not (Is-PlausiblePointer $Object)) { return '' }
    $b = Read-Bytes ([IntPtr]($Object + 0xC)) 20
    if ($null -eq $b -or $b.Length -ne 20) { return '' }
    $cls = [BitConverter]::ToUInt64($b,4)
    if (-not (Is-PlausiblePointer $cls)) { return '' }
    return ('{0:X}:{1}' -f $Object, [BitConverter]::ToString($b))
}
function Sb-GetLocalContext {
    $live = Get-LocalPlayerStateInfo
    if ($null -ne $live) {
        $level = Read-U64 ([IntPtr]([int64]$live.Ship + $UOBJECT_OUTER_OFFSET))
        if (-not (Is-PlausiblePointer $level)) { $level = [uint64]$script:Sb.Level }
        $controller = Read-U64 ([IntPtr]([int64]$live.Ship + $PAWN_CONTROLLER_OFFSET))
        if (-not (Is-PlausiblePointer $controller)) { $controller = [uint64]0 }
        $pawnToken = Sb-Token ([int64]$live.Ship)
        $script:Sb.LocalPlayerState = [int64]$live.PlayerState
        $script:Sb.LocalTeam = [int]$live.Team
        $script:Sb.LocalController = [int64]$controller
        $script:Sb.LocalClassPtr = [int64]$live.ClassPtr
        $script:Sb.LastPlayerPawn = [int64]$live.Ship
        if (-not [string]::IsNullOrWhiteSpace($pawnToken)) { $script:Sb.LastPlayerPawnToken = $pawnToken }
        return [pscustomobject]@{
            Ship=[int64]$live.Ship; PlayerState=[int64]$live.PlayerState; Team=[int]$live.Team
            Controller=[int64]$controller; ClassPtr=[uint64]$live.ClassPtr; Level=[int64]$level
            Alive=$true; WorldContext=[int64]$live.Ship
        }
    }

    # During death the Pawn is gone, but the PlayerState/controller normally survive.
    # Reuse only a context that was validated while the player's Pawn was alive.
    $ps = [int64]$script:Sb.LocalPlayerState
    if (-not (Is-PlausiblePointer $ps) -or (Sb-Token $ps) -eq '') { return $null }
    $team = Read-U8 ([IntPtr]($ps + $PLAYERSTATE_TEAM_OFFSET))
    if ($null -eq $team -or [int]$team -lt 0 -or [int]$team -gt 16) { return $null }

    $controller = [int64]$script:Sb.LocalController
    if (Is-PlausiblePointer $controller) {
        $backPs = Read-U64 ([IntPtr]($controller + $CONTROLLER_PLAYERSTATE_OFFSET))
        if ($null -eq $backPs -or [uint64]$backPs -ne [uint64]$ps) { $controller = 0L }
    }
    if (-not (Is-PlausiblePointer $controller)) {
        $owner = Read-U64 ([IntPtr]($ps + $ACTOR_OWNER_OFFSET))
        if (Is-PlausiblePointer $owner) {
            $backPs = Read-U64 ([IntPtr]([int64]$owner + $CONTROLLER_PLAYERSTATE_OFFSET))
            if ($null -ne $backPs -and [uint64]$backPs -eq [uint64]$ps) {
                $controller = [int64]$owner
                $script:Sb.LocalController = $controller
            }
        }
    }
    $script:Sb.LocalTeam = [int]$team
    $worldContext = if (Is-PlausiblePointer $controller) { [int64]$controller } else { $ps }
    return [pscustomobject]@{
        Ship=0L; PlayerState=$ps; Team=[int]$team; Controller=[int64]$controller
        ClassPtr=[uint64]$script:Sb.LocalClassPtr; Level=[int64]$script:Sb.Level
        Alive=$false; WorldContext=[int64]$worldContext
    }
}
function Sb-Require {
    if (-not (Connect-Server)) { throw 'Start a local solo match first.' }
    if (-not $script:Sb.Verified -or $script:Sb.Pid -ne $script:ConnectedProcessId) { throw 'Waiting for server build verification.' }
    $s = Sb-GetLocalContext
    if ($null -eq $s) { throw 'Player context unavailable. If the trainer was opened while dead, respawn once so it can cache your PlayerState.' }
    if ($s.Alive -and [int64]$s.Level -ne $script:Sb.Level) { throw 'The match changed. Wait for the list to refresh.' }
    return $s
}
function Sb-Ship([int64]$State) {
    if ($State -le 0) { return $null }
    $local = Sb-GetLocalContext
    if ($null -eq $local) { return $null }
    if ($State -ne [int64]$local.PlayerState -and $script:PlayerStateAddresses -notcontains $State) { return $null }
    $pawn = Resolve-ShipFromPlayerState $State
    if (-not (Is-PlausiblePointer $pawn)) { return $null }
    $pt = Sb-Token $pawn
    if ($pt -eq '') { return $null }
    $hc = Read-U64 ([IntPtr]([int64]$pawn + $SHIP_HEALTH_COMPONENT_OFFSET))
    if (-not (Is-PlausiblePointer $hc)) { return $null }
    $hp = Read-F32 ([IntPtr]([int64]$hc + 0x298))
    $max = Read-F32 ([IntPtr]([int64]$hc + 0x30C))
    if ($null -eq $hp -or [single]::IsNaN($hp) -or [single]::IsInfinity($hp) -or $hp -lt 0 -or $hp -gt 100000000) { return $null }
    if ($null -eq $max -or [single]::IsNaN($max) -or [single]::IsInfinity($max) -or $max -le 0 -or $max -gt 100000000) { $max = $null }
    $ctrl = Read-U64 ([IntPtr]([int64]$pawn + $PAWN_CONTROLLER_OFFSET))
    $team = Read-U8 ([IntPtr]($State + $PLAYERSTATE_TEAM_OFFSET))
    return [pscustomobject]@{ PlayerState=$State; Pawn=[int64]$pawn; Controller=[int64]$ctrl; Health=[int64]$hc; Token=$pt; StateToken=(Sb-Token $State); HP=$hp; MaxHP=$max; Team=$team; IsPlayer=($State -eq [int64]$local.PlayerState) }
}
function Sb-Selected {
    [void](Sb-Require)
    $s = Sb-Ship $script:Sb.Selected
    if ($null -eq $s) { throw 'Select a live ship in the inspector.' }
    return $s
}
function Sb-Vector([int64]$Address) {
    $b = Read-Bytes ([IntPtr]$Address) 12
    if ($null -eq $b) { return $null }
    $a = @([BitConverter]::ToSingle($b,0),[BitConverter]::ToSingle($b,4),[BitConverter]::ToSingle($b,8))
    foreach ($v in $a) { if ([single]::IsNaN($v) -or [single]::IsInfinity($v) -or [Math]::Abs($v) -gt 1e10) { return $null } }
    return ,$a
}
function Sb-NativeError([string]$Action) {
    return ('{0} failed (native error {1}).' -f $Action,[NativeMemoryV4]::LastTrainerActionError)
}
function Sb-CurrentShip($s) {
    [void](Sb-Require)
    $now = Sb-Ship $s.PlayerState
    if ($null -eq $now -or $now.Token -ne $s.Token -or $now.HP -le 0) { throw 'Ship no longer alive.' }
    return $now
}
function Sb-Heal($s) {
    $now=Sb-CurrentShip $s
    $ok=[NativeMemoryV4]::SetShipHealthNative($script:ProcessHandle,[uint64]$script:ModuleBase.ToInt64(),[uint64]$now.Health,[single]10000000)
    if(-not $ok){throw (Sb-NativeError 'Heal')}
}
function Sb-God($s,[bool]$Enable) {
    $now=Sb-CurrentShip $s
    if (-not (Write-U8 ([IntPtr]($now.Health+0x4CE)) ([byte]$(if($Enable){1}else{0})))) { throw 'Could not change invulnerability.' }
    if($Enable){$script:Sb.Invulnerable[$now.StateToken]=@{State=$now.PlayerState;StateToken=$now.StateToken;PawnToken=$now.Token}}
    else{$script:Sb.Invulnerable.Remove($now.StateToken)}
    if($now.IsPlayer){
        $script:GodEnabled=$Enable
        if($Enable){$script:LockedHealth=[single]$now.HP;$script:LastHealthAddress=$now.Health+0x298;$godButton.Text='PLAYER GOD MODE: ON';$godButton.BackColor=[Drawing.Color]::FromArgb(45,125,72)}
        else{$godButton.Text='PLAYER GOD MODE: OFF';$godButton.BackColor=[Drawing.Color]::FromArgb(55,60,68)}
    }
}
function Sb-ClearGod {
    foreach($key in @($script:Sb.Invulnerable.Keys)){
        $e=$script:Sb.Invulnerable[$key];$s=Sb-Ship $e.State
        if($null -ne $s -and $s.StateToken -eq $e.StateToken -and $s.Token -eq $e.PawnToken){[void](Write-U8 ([IntPtr]($s.Health+0x4CE)) 0)}
    }
    $script:Sb.Invulnerable=@{}
    $script:GodEnabled=$false
    if($null -ne $godButton){$godButton.Text='PLAYER GOD MODE: OFF';$godButton.BackColor=[Drawing.Color]::FromArgb(55,60,68)}
}
function Sb-Kill($s) {
    $target=Sb-CurrentShip $s;$local=Sb-Require
    if($script:Sb.Invulnerable.ContainsKey($target.StateToken)){[void](Write-U8 ([IntPtr]($target.Health+0x4CE)) 0);$script:Sb.Invulnerable.Remove($target.StateToken)}
    if($target.IsPlayer){$script:GodEnabled=$false;$godButton.Text='PLAYER GOD MODE: OFF';$godButton.BackColor=[Drawing.Color]::FromArgb(55,60,68)}
    $ok=[NativeMemoryV4]::KillShipWithDamageNative($script:ProcessHandle,[uint64]$script:ModuleBase.ToInt64(),[uint64]$target.Health,[uint64]$local.PlayerState)
    if(-not$ok){throw(Sb-NativeError 'Kill target')}
    $script:Sb.Invulnerable.Remove($target.StateToken)
}
function Sb-SetDifficulty($s,[int]$Difficulty) {
    $now=Sb-CurrentShip $s
    if($now.IsPlayer){throw 'AI difficulty applies only to bots.'}
    if($Difficulty -lt 0 -or $Difficulty -gt 9 -or -not(Is-PlausiblePointer $now.Controller)){throw 'Invalid bot difficulty.'}
    $ok=[NativeMemoryV4]::SetBotDifficultyNative($script:ProcessHandle,[uint64]$script:ModuleBase.ToInt64(),[uint64]$now.Controller,[byte]$Difficulty)
    if(-not $ok){throw (Sb-NativeError 'Set AI difficulty')}
}
function Sb-WriteSetting([int64]$Object,[int]$Offset,[single]$Value,[string]$Label) {
    [void](Sb-Require)
    if ([single]::IsNaN($Value) -or [single]::IsInfinity($Value)) { throw 'Invalid numeric value.' }
    $token = Sb-Token $Object
    if ($token -eq '') { throw 'Object unavailable.' }
    $old = Read-F32 ([IntPtr]($Object + $Offset))
    if ($null -eq $old -or [single]::IsNaN($old) -or [single]::IsInfinity($old)) { throw 'Current value unavailable.' }
    $key = $token + ':' + $Offset
    if (-not $script:Sb.Originals.ContainsKey($key)) { $script:Sb.Originals[$key] = @{ Object=$Object; Token=$token; Offset=$Offset; Value=[single]$old; Label=$Label } }
    if (-not (Write-F32 ([IntPtr]($Object + $Offset)) $Value)) { throw ('Could not change ' + $Label) }
}
function Sb-Restore([int64]$Object=0) {
    [int]$restored = 0
    foreach ($key in @($script:Sb.Originals.Keys)) {
        $e = $script:Sb.Originals[$key]
        if ($Object -ne 0 -and $e.Object -ne $Object) { continue }
        if ($script:Sb.Pid -eq $script:ConnectedProcessId -and (Sb-Token $e.Object) -eq $e.Token) {
            if (-not (Write-F32 ([IntPtr]($e.Object + $e.Offset)) $e.Value)) { Sb-Log ('Restore failed: ' + $e.Label); continue }
            $restored++
        }
        $script:Sb.Originals.Remove($key)
    }
    return $restored
}

function Sb-RestoreSelected($s) {
    $now = Sb-CurrentShip $s
    [bool]$godWasOn = $script:Sb.Invulnerable.ContainsKey($now.StateToken)
    if ($godWasOn) { Sb-God $now $false }
    [int]$restored = Sb-Restore ([int64]$now.Pawn)
    if ($restored -gt 0 -or $godWasOn) {
        Sb-Log ('Normal settings restored for the selected ship ({0} value(s), God Mode off).' -f $restored)
    } else {
        Sb-Log 'No reversible direct setting was active on this ship. Status-effect Custom Stats end on its next normal respawn.'
    }
}
function Sb-ApplyLastStandBoss($s,[string]$ShipName) {
    $now=Sb-CurrentShip $s
    $isEndeavor=($ShipName -eq 'Endeavor')

    if($isEndeavor){
        Sb-Log 'Boss status: Endeavor variant (+7500 MaxHealth, -0.15 refire, -0.10 secondary CD, +1 damage)'
    } else {
        Sb-Log ('Boss status: standard '+$ShipName+' (+10000 MaxHealth, -0.15 refire, -0.50 secondary CD, +1 damage)')
    }

    $ok=[NativeMemoryV4]::ApplyLastStandBossStatusNative(
        $script:ProcessHandle,
        [uint64]$script:ModuleBase.ToInt64(),
        [uint64]$now.Pawn,
        [byte]$now.Team,
        [bool]$isEndeavor)

    if(-not $ok){
        throw (Sb-NativeError 'Last Stand Boss / AddSimpleStatusEffect')
    }

    Sb-Log ('Boss status effect added through StatusEffectReceiverComponent: '+$ShipName)
}

function Sb-GetCustomStatsConfig {
    $names = New-Object 'System.Collections.Generic.List[string]'
    $values = New-Object 'System.Collections.Generic.List[single]'
    $systemRates = New-Object 'single[]' 9
    $targetMaxHealth = [single]$sbCustomHP.Value

    function Add-RealModifier([string]$Name,[single]$Value) {
        if ([Math]::Abs([double]$Value) -gt 0.000001) {
            $names.Add($Name)
            $values.Add($Value)
        }
    }

    # These names come from the real game/boss/native systems.
    Add-RealModifier 'DamageModifier' ([single]([decimal]$sbCustomDamage.Value / 100))
    for($i=1;$i -le 9;$i++) {
        $control = Get-Variable -Scope Script -Name ('sbCustomSubsystemCD'+$i) -ValueOnly
        $systemRates[$i-1]=[single]([decimal]$control.Value / 100)
    }
    Add-RealModifier 'CaptureRateModifier' ([single]([decimal]$sbCustomCapture.Value / 100))
    Add-RealModifier 'EnergyRegenRateModifier' ([single]([decimal]$sbCustomEnergyRegen.Value / 100))
    Add-RealModifier 'MaxThrustSpeedModifier' ([single]([decimal]$sbCustomForward.Value / 100))
    Add-RealModifier 'MaxReverseThrustSpeedModifier' ([single]([decimal]$sbCustomReverse.Value / 100))
    Add-RealModifier 'MaxStrafeSpeedModifier' ([single]([decimal]$sbCustomStrafe.Value / 100))
    Add-RealModifier 'MaxVerticalSpeedModifier' ([single]([decimal]$sbCustomVertical.Value / 100))
    Add-RealModifier 'MaxYawSpeedModifier' ([single]([decimal]$sbCustomTurn.Value / 100))

    $primaryRate=[single]([decimal]$sbCustomPrimaryCD.Value / 100)
    $secondaryRate=[single]([decimal]$sbCustomSecondaryCD.Value / 100)
    $hasSystemRate=@($systemRates|Where-Object{[Math]::Abs([double]$_)-gt0.000001}).Count-gt0
    if ($targetMaxHealth -le 0 -and $names.Count -eq 0 -and [Math]::Abs([double]$primaryRate)-le0.000001 -and [Math]::Abs([double]$secondaryRate)-le0.000001 -and -not$hasSystemRate) { throw 'Set at least one Custom Stats value.' }
    return [pscustomobject]@{
        Names=[string[]]$names.ToArray();Values=[single[]]$values.ToArray()
        PrimaryRate=$primaryRate;SecondaryRate=$secondaryRate;SystemRates=[single[]]$systemRates
        TargetMaxHealth=$targetMaxHealth
        Persistent=[bool]$sbCustomEveryRespawn.Checked
    }
}

function Sb-ExpandCustomStatsConfig($Cfg,[string]$ShipName) {
    $names=New-Object 'System.Collections.Generic.List[string]'
    $values=New-Object 'System.Collections.Generic.List[single]'
    for($i=0;$i-lt$Cfg.Names.Count;$i++){$names.Add([string]$Cfg.Names[$i]);$values.Add([single]$Cfg.Values[$i])}
    $systems=@($script:Sb.ShipSystems[$ShipName])

    function Add-ShipRate($Entry,[single]$Rate,[string]$Position) {
        if([Math]::Abs([double]$Rate)-le0.000001){return}
        if($null-eq$Entry-or[string]::IsNullOrWhiteSpace([string]$Entry.modifier)){throw ('No compatible rate modifier for '+$ShipName+' '+$Position+'.')}
        $names.Add([string]$Entry.modifier)
        $values.Add([single](-$Rate))
    }

    Add-ShipRate ($systems|Where-Object{$_.position-eq'primary'}|Select-Object -First 1) ([single]$Cfg.PrimaryRate) 'primary weapon'
    Add-ShipRate ($systems|Where-Object{$_.position-eq'secondary'}|Select-Object -First 1) ([single]$Cfg.SecondaryRate) 'secondary weapon'
    for($i=1;$i-le9;$i++){
        $rate=if($i-le$Cfg.SystemRates.Count){[single]$Cfg.SystemRates[$i-1]}else{[single]0}
        Add-ShipRate ($systems|Where-Object{$_.position-eq'system'-and[int]$_.slot-eq$i}|Select-Object -First 1) $rate ('system '+$i)
    }
    return [pscustomobject]@{Names=[string[]]$names.ToArray();Values=[single[]]$values.ToArray()}
}

function Sb-ApplyCustomStats($s,$Cfg,[string]$TargetLabel) {
    $now=Sb-CurrentShip $s
    $shipName=Get-ShipNameFromPlayerState $now.PlayerState $now.Pawn
    $expanded=Sb-ExpandCustomStatsConfig $Cfg $shipName
    $names=New-Object 'System.Collections.Generic.List[string]'
    $values=New-Object 'System.Collections.Generic.List[single]'
    for($i=0;$i-lt$expanded.Names.Count;$i++){$names.Add([string]$expanded.Names[$i]);$values.Add([single]$expanded.Values[$i])}
    $maxKey=[string]$now.Token
    $oldMax=$script:Sb.CustomAppliedMax[$maxKey]
    $targetMax=if($null-ne$Cfg.PSObject.Properties['TargetMaxHealth']){[single]$Cfg.TargetMaxHealth}else{[single]0}
    $maxPlan=$null
    if($targetMax-gt0){
        if($null-eq$now.MaxHP){throw 'Current maximum HP is unavailable.'}
        $currentMax=[double]$now.MaxHP
        $baseMax=$currentMax
        if($null-ne$oldMax){
            $tolerance=[Math]::Max(1.0,[Math]::Abs([double]$oldMax.Target)*0.002)
            if([Math]::Abs($currentMax-[double]$oldMax.Target)-le$tolerance){$baseMax=$currentMax-[double]$oldMax.Delta}
            elseif([Math]::Abs($currentMax-[double]$oldMax.Base)-le$tolerance){$baseMax=$currentMax}
            else{$baseMax=$currentMax-[double]$oldMax.Delta}
        }
        $delta=[single]([double]$targetMax-$baseMax)
        $names.Add('MaxHealth');$values.Add($delta)
        $maxPlan=@{Base=[single]$baseMax;Delta=$delta;Target=$targetMax}
    }elseif($null-ne$oldMax){
        $names.Add('MaxHealth');$values.Add([single]0)
    }
    $ok=[NativeMemoryV4]::ApplyCustomStatusNative(
        $script:ProcessHandle,
        [uint64]$script:ModuleBase.ToInt64(),
        [uint64]$now.Pawn,
        [byte]$now.Team,
        [string[]]$names.ToArray(),
        [single[]]$values.ToArray())

    if(-not $ok){throw (Sb-NativeError 'Custom Stats / AddSimpleStatusEffect')}
    if($null-ne$maxPlan){$script:Sb.CustomAppliedMax[$maxKey]=$maxPlan}else{$script:Sb.CustomAppliedMax.Remove($maxKey)}
    $pairs=@()
    for($i=0;$i-lt$names.Count;$i++){$pairs+=('{0}={1}' -f $names[$i],$values[$i])}
    Sb-Log ('Custom Stats applied to '+$TargetLabel+' ['+$shipName+']: '+($pairs -join ', '))
}

function Sb-CustomTargetInfo([int64]$PlayerState) {
    $s=Sb-Ship $PlayerState
    if($null-ne$s){
        $ship=Get-ShipNameFromPlayerState $s.PlayerState $s.Pawn
        $pilot=Get-PlayerStateName $s.PlayerState
        return [pscustomobject]@{PlayerState=[int64]$s.PlayerState;StateToken=[string]$s.StateToken;PawnToken=[string]$s.Token;Ship=[string]$ship;Pilot=[string]$pilot;Alive=$true}
    }
    $cached=@($script:Sb.MapRows|Where-Object{[int64]$_.PlayerState-eq$PlayerState}|Select-Object -First 1)
    if($cached.Count-gt0){$r=$cached[0];return [pscustomobject]@{PlayerState=$PlayerState;StateToken=[string]$r.StateToken;PawnToken='';Ship=[string]$r.Name;Pilot=[string]$r.Pilot;Alive=$false}}
    return $null
}

function Sb-RefreshCustomShipList {
    if($null-eq$sbCustomShipList){return}
    $choices=@();$seen=@{}
    foreach($r in @($script:Sb.MapRows)){
        $key=[string][int64]$r.PlayerState;if($seen.ContainsKey($key)){continue};$seen[$key]=$true
        $display=('{0} | {1} | {2}'-f$r.Side,$r.DisplayName,$(if($r.IsAlive){'LIVE'}else{[string]$r.Status}))
        $choices+=,[pscustomobject]@{PlayerState=[int64]$r.PlayerState;Display=$display;Sort=('{0}|{1}'-f$(switch([string]$r.Side){'Player'{'0'}'Ally'{'1'}default{'2'}}),$r.DisplayName)}
    }
    $local=Sb-GetLocalContext
    foreach($s in @($script:Sb.Rows)){
        $key=[string][int64]$s.PlayerState;if($seen.ContainsKey($key)){continue};$seen[$key]=$true
        $ship=Get-ShipNameFromPlayerState $s.PlayerState $s.Pawn;$pilot=Get-PlayerStateName $s.PlayerState
        $name=if([string]::IsNullOrWhiteSpace([string]$pilot)-or$pilot-eq$ship){[string]$ship}else{([string]$pilot+' / '+[string]$ship)}
        $side=if($s.IsPlayer){'Player'}elseif($null-ne$local-and$s.Team-eq$local.Team){'Ally'}else{'Enemy'}
        $choices+=,[pscustomobject]@{PlayerState=[int64]$s.PlayerState;Display=('{0} | {1} | LIVE'-f$side,$name);Sort=('{0}|{1}'-f$(switch($side){'Player'{'0'}'Ally'{'1'}default{'2'}}),$name)}
    }
    $choices=@($choices|Sort-Object Sort)
    $signature=(@($choices|ForEach-Object{([string]$_.PlayerState+':'+$_.Display)})-join '|')
    if($signature-ne$script:Sb.CustomShipListSignature){
        $script:Sb.CustomShipListBusy=$true;$sbCustomShipList.BeginUpdate()
        try{
            $sbCustomShipList.Items.Clear();$script:Sb.CustomShipChoiceStates=@($choices|ForEach-Object{[int64]$_.PlayerState})
            foreach($choice in $choices){[void]$sbCustomShipList.Items.Add([string]$choice.Display)}
            $script:Sb.CustomShipListSignature=$signature
        }finally{$sbCustomShipList.EndUpdate();$script:Sb.CustomShipListBusy=$false}
    }
    $selectedIndex=[Array]::IndexOf([int64[]]$script:Sb.CustomShipChoiceStates,[int64]$script:Sb.Selected)
    if($sbCustomShipList.SelectedIndex-ne$selectedIndex){$script:Sb.CustomShipListBusy=$true;try{$sbCustomShipList.SelectedIndex=$selectedIndex}finally{$script:Sb.CustomShipListBusy=$false}}
}

function Sb-SetCustomRateControl($Entry,$Label,$Box,[string]$Prefix) {
    if($null-eq$Entry){$Label.Visible=$false;$Box.Visible=$false;$Box.Value=0;return}
    $type=[string]$Entry.type
    $Label.Visible=$true;$Box.Visible=$true
    if($type-eq'weapon'){
        if($Box.Value-gt80){$Box.Value=80};$Box.Maximum=80;$Box.Enabled=$true
        $Label.ForeColor=[Drawing.Color]::FromArgb(235,92,72)
        $Label.Text=($Prefix+[string]$Entry.name+' [WEAPON / FIRE RATE] %')
    }elseif($type-eq'ability'){
        $Box.Maximum=100;$Box.Enabled=$true
        $Label.ForeColor=[Drawing.Color]::FromArgb(232,156,44)
        $Label.Text=($Prefix+[string]$Entry.name+' [ABILITY / COOLDOWN] %')
    }else{
        $Box.Value=0;$Box.Maximum=100;$Box.Enabled=$false
        $Label.ForeColor=[Drawing.Color]::FromArgb(145,155,165)
        $Label.Text=($Prefix+[string]$Entry.name+' [PASSIVE]')
    }
}

function Sb-ReadCustomDraft {
    $rates=New-Object 'decimal[]' 9
    foreach($i in 1..9){$rates[$i-1]=[decimal](Get-Variable -Scope Script -Name ('sbCustomSubsystemCD'+$i) -ValueOnly).Value}
    return [pscustomobject]@{
        MaxHP=[decimal]$sbCustomHP.Value;Damage=[decimal]$sbCustomDamage.Value;Capture=[decimal]$sbCustomCapture.Value;EnergyRegen=[decimal]$sbCustomEnergyRegen.Value
        Forward=[decimal]$sbCustomForward.Value;Reverse=[decimal]$sbCustomReverse.Value;Strafe=[decimal]$sbCustomStrafe.Value;Vertical=[decimal]$sbCustomVertical.Value;Turn=[decimal]$sbCustomTurn.Value
        Primary=[decimal]$sbCustomPrimaryCD.Value;Secondary=[decimal]$sbCustomSecondaryCD.Value;Systems=[decimal[]]$rates
    }
}

function Sb-DraftFromConfig($Cfg) {
    function ModifierPercent([string]$Name) {
        $index=[Array]::IndexOf([string[]]$Cfg.Names,$Name)
        if($index-lt0){return [decimal]0}
        return [decimal]([double]$Cfg.Values[$index]*100)
    }
    $rates=New-Object 'decimal[]' 9
    foreach($i in 0..8){if($i-lt$Cfg.SystemRates.Count){$rates[$i]=[decimal]([double]$Cfg.SystemRates[$i]*100)}}
    return [pscustomobject]@{
        MaxHP=$(if($null-ne$Cfg.PSObject.Properties['TargetMaxHealth']){[decimal]$Cfg.TargetMaxHealth}else{[decimal]0})
        Damage=(ModifierPercent 'DamageModifier');Capture=(ModifierPercent 'CaptureRateModifier');EnergyRegen=(ModifierPercent 'EnergyRegenRateModifier')
        Forward=(ModifierPercent 'MaxThrustSpeedModifier');Reverse=(ModifierPercent 'MaxReverseThrustSpeedModifier');Strafe=(ModifierPercent 'MaxStrafeSpeedModifier');Vertical=(ModifierPercent 'MaxVerticalSpeedModifier');Turn=(ModifierPercent 'MaxYawSpeedModifier')
        Primary=[decimal]([double]$Cfg.PrimaryRate*100);Secondary=[decimal]([double]$Cfg.SecondaryRate*100);Systems=[decimal[]]$rates
    }
}

function Sb-SetCustomNumber($Control,$Value) {
    $v=[decimal]$Value
    if($v-lt$Control.Minimum){$v=$Control.Minimum}elseif($v-gt$Control.Maximum){$v=$Control.Maximum}
    $Control.Value=$v
}

function Sb-LoadCustomDraft($Draft) {
    $previousLoading=[bool]$script:Sb.CustomUiLoading
    $script:Sb.CustomUiLoading=$true
    try{
        if($null-eq$Draft){$Draft=[pscustomobject]@{MaxHP=0;Damage=0;Capture=0;EnergyRegen=0;Forward=0;Reverse=0;Strafe=0;Vertical=0;Turn=0;Primary=0;Secondary=0;Systems=(New-Object 'decimal[]' 9)}}
        Sb-SetCustomNumber $sbCustomHP $Draft.MaxHP;Sb-SetCustomNumber $sbCustomDamage $Draft.Damage;Sb-SetCustomNumber $sbCustomCapture $Draft.Capture;Sb-SetCustomNumber $sbCustomEnergyRegen $Draft.EnergyRegen
        Sb-SetCustomNumber $sbCustomForward $Draft.Forward;Sb-SetCustomNumber $sbCustomReverse $Draft.Reverse;Sb-SetCustomNumber $sbCustomStrafe $Draft.Strafe;Sb-SetCustomNumber $sbCustomVertical $Draft.Vertical;Sb-SetCustomNumber $sbCustomTurn $Draft.Turn
        Sb-SetCustomNumber $sbCustomPrimaryCD $Draft.Primary;Sb-SetCustomNumber $sbCustomSecondaryCD $Draft.Secondary
        foreach($i in 1..9){$value=if($i-le$Draft.Systems.Count){$Draft.Systems[$i-1]}else{0};Sb-SetCustomNumber (Get-Variable -Scope Script -Name ('sbCustomSubsystemCD'+$i) -ValueOnly) $value}
    }finally{$script:Sb.CustomUiLoading=$previousLoading}
}

function Sb-SaveCurrentCustomDraft {
    if($script:Sb.CustomUiLoading-or[int64]$script:Sb.Selected-le0){return}
    $script:Sb.CustomDrafts[[string][int64]$script:Sb.Selected]=Sb-ReadCustomDraft
}

function Sb-UpdateCustomTargetUi {
    if($null-eq$sbCustomTarget){return}
    $previousLoading=[bool]$script:Sb.CustomUiLoading;$script:Sb.CustomUiLoading=$true
    try{
        Sb-RefreshCustomShipList
        $t=Sb-CustomTargetInfo ([int64]$script:Sb.Selected)
        if($null-eq$t){
            $sbCustomTarget.Text='TARGET: select a ship in TEAMS or MAP'
            $sbCustomProfileStatus.Text='No valid target selected.'
            $script:Sb.CustomPersistentBusy=$true;try{$sbCustomEveryRespawn.Checked=$false}finally{$script:Sb.CustomPersistentBusy=$false}
            $sbCustomPrimaryLabel.Text='PRIMARY: select a ship';$sbCustomSecondaryLabel.Text='SECONDARY: select a ship'
            $sbCustomPrimaryCD.Enabled=$false;$sbCustomSecondaryCD.Enabled=$false
            foreach($i in 1..9){$label=Get-Variable -Scope Script -Name ('sbCustomSubsystemLabel'+$i) -ValueOnly;$box=Get-Variable -Scope Script -Name ('sbCustomSubsystemCD'+$i) -ValueOnly;$label.Visible=$false;$box.Visible=$false}
            Sb-LoadCustomDraft $null
            return
        }
        $pilot=if([string]::IsNullOrWhiteSpace($t.Pilot)){'Unknown pilot'}else{$t.Pilot}
        $sbCustomTarget.Text=('TARGET: {0} / {1} / {2}'-f$pilot,$t.Ship,$(if($t.Alive){'LIVE'}else{'WAITING TO RESPAWN'}))
        $profile=$script:Sb.CustomProfiles[[string]$t.PlayerState]
        $sbCustomProfileStatus.Text=if($null-eq$profile){'Profile: none'}else{('Profile: armed | '+$(if($profile.Persistent){'EVERY RESPAWN'}else{'NEXT RESPAWN ONLY'}))}
        $script:Sb.CustomPersistentBusy=$true;try{$sbCustomEveryRespawn.Checked=($null-ne$profile-and[bool]$profile.Persistent)}finally{$script:Sb.CustomPersistentBusy=$false}
        $systems=@($script:Sb.ShipSystems[[string]$t.Ship])
        Sb-SetCustomRateControl ($systems|Where-Object{$_.position-eq'primary'}|Select-Object -First 1) $sbCustomPrimaryLabel $sbCustomPrimaryCD 'PRIMARY: '
        Sb-SetCustomRateControl ($systems|Where-Object{$_.position-eq'secondary'}|Select-Object -First 1) $sbCustomSecondaryLabel $sbCustomSecondaryCD 'SECONDARY: '
        foreach($i in 1..9){
            $label=Get-Variable -Scope Script -Name ('sbCustomSubsystemLabel'+$i) -ValueOnly
            $box=Get-Variable -Scope Script -Name ('sbCustomSubsystemCD'+$i) -ValueOnly
            $system=$systems|Where-Object{$_.position-eq'system'-and[int]$_.slot-eq$i}|Select-Object -First 1
            Sb-SetCustomRateControl $system $label $box ('SYSTEM '+$i+': ')
        }
        $draft=$script:Sb.CustomDrafts[[string]$t.PlayerState]
        if($null-eq$draft-and$null-ne$profile){$draft=Sb-DraftFromConfig $profile.Config}
        Sb-LoadCustomDraft $draft
    }finally{$script:Sb.CustomUiLoading=$previousLoading}
}

function Sb-ArmSelectedCustom {
    [void](Sb-Require)
    $t=Sb-CustomTargetInfo ([int64]$script:Sb.Selected)
    if($null-eq$t){throw 'Select a ship in TEAMS or MAP first.'}
    $cfg=Sb-GetCustomStatsConfig
    $cfg.Persistent=$false
    $script:Sb.CustomProfiles[[string]$t.PlayerState]=@{
        StateToken=[string]$t.StateToken;LastPawnToken=[string]$t.PawnToken;CandidateToken='';ReadyAfter=[DateTime]::MinValue
        Config=$cfg;Persistent=$false;Ship=[string]$t.Ship;Pilot=[string]$t.Pilot
    }
    Sb-Log ('Custom Stats armed once for '+$t.Pilot+' / '+$t.Ship+' next respawn')
    Sb-UpdateCustomTargetUi
}

function Sb-SetSelectedPersistent([bool]$Enabled) {
    if($script:Sb.CustomPersistentBusy){return}
    $t=Sb-CustomTargetInfo ([int64]$script:Sb.Selected)
    if($null-eq$t){throw 'Select a ship in TEAMS or MAP first.'}
    $key=[string]$t.PlayerState
    if(-not$Enabled){
        if($script:Sb.CustomProfiles.ContainsKey($key)-and[bool]$script:Sb.CustomProfiles[$key].Persistent){$script:Sb.CustomProfiles.Remove($key);Sb-Log ('Every-respawn profile disabled for '+$t.Pilot+' / '+$t.Ship)}
        Sb-UpdateCustomTargetUi
        return
    }
    $cfg=Sb-GetCustomStatsConfig
    $script:Sb.CustomProfiles[$key]=@{
        StateToken=[string]$t.StateToken;LastPawnToken=[string]$t.PawnToken;CandidateToken='';ReadyAfter=[DateTime]::MinValue
        Config=$cfg;Persistent=$true;Ship=[string]$t.Ship;Pilot=[string]$t.Pilot
    }
    Sb-Log ('Every-respawn profile enabled for '+$t.Pilot+' / '+$t.Ship)
    Sb-UpdateCustomTargetUi
}

function Sb-RefreshSelectedPersistentConfig {
    if($script:Sb.CustomUiLoading){return}
    Sb-SaveCurrentCustomDraft
    if($script:Sb.CustomPersistentBusy -or $null -eq $sbCustomEveryRespawn -or -not $sbCustomEveryRespawn.Checked){return}
    $t=Sb-CustomTargetInfo ([int64]$script:Sb.Selected)
    if($null-eq$t){return}
    $key=[string]$t.PlayerState
    if(-not$script:Sb.CustomProfiles.ContainsKey($key)-or-not[bool]$script:Sb.CustomProfiles[$key].Persistent){return}
    try{$script:Sb.CustomProfiles[$key].Config=Sb-GetCustomStatsConfig}catch{}
}

function Sb-ApplySelectedCustomNow {
    [void](Sb-Require)
    $t=Sb-CustomTargetInfo ([int64]$script:Sb.Selected)
    if($null-eq$t){throw 'Select a ship in TEAMS or MAP first.'}
    if(-not$t.Alive){throw 'Selected ship is dead or waiting to respawn.'}
    $s=Sb-Ship ([int64]$t.PlayerState)
    if($null-eq$s-or$s.HP-le0){throw 'Selected ship is not currently alive.'}
    $cfg=Sb-GetCustomStatsConfig
    Sb-ApplyCustomStats $s $cfg ($t.Pilot+' / '+$t.Ship+' live')
    if($sbCustomEveryRespawn.Checked){
        $script:Sb.CustomProfiles[[string]$t.PlayerState]=@{
            StateToken=[string]$t.StateToken;LastPawnToken=[string]$t.PawnToken;CandidateToken='';ReadyAfter=[DateTime]::MinValue
            Config=$cfg;Persistent=$true;Ship=[string]$t.Ship;Pilot=[string]$t.Pilot
        }
        Sb-Log 'Live Custom Stats also armed for every future respawn.'
    }
    Sb-UpdateCustomTargetUi
}

function Sb-ClearSelectedCustom {
    $key=[string][int64]$script:Sb.Selected
    if($script:Sb.CustomProfiles.ContainsKey($key)){$script:Sb.CustomProfiles.Remove($key);Sb-Log 'Custom Stats profile removed from selected ship.'}else{Sb-Log 'Selected ship has no Custom Stats profile.'}
    Sb-UpdateCustomTargetUi
}

function Sb-ProcessCustomProfiles {
    $now=[DateTime]::UtcNow
    if($now-lt$script:Sb.NextCustomProfile){return}
    $script:Sb.NextCustomProfile=$now.AddMilliseconds(100)
    foreach($key in @($script:Sb.CustomProfiles.Keys)){
        $e=$script:Sb.CustomProfiles[$key];$ps=[int64]$key
        if((Sb-Token $ps)-ne[string]$e.StateToken){$script:Sb.CustomProfiles.Remove($key);Sb-Log ('Custom Stats profile removed: player state changed for '+$e.Ship);continue}
        $s=Sb-Ship $ps
        if($null-eq$s-or$s.HP-le0){$e.CandidateToken='';$e.ReadyAfter=[DateTime]::MinValue;continue}
        if([string]$s.Token-eq[string]$e.LastPawnToken){continue}
        if([string]$e.CandidateToken-ne[string]$s.Token){$e.CandidateToken=[string]$s.Token;$e.ReadyAfter=$now.AddMilliseconds(1200);continue}
        if($now-lt[DateTime]$e.ReadyAfter){continue}
        $receiver=Read-U64 ([IntPtr](([int64]$s.Pawn)+0x650))
        if(-not(Is-PlausiblePointer ([int64]$receiver))){continue}
        $persistent=[bool]$e.Persistent;$cfg=$e.Config;$label=($e.Pilot+' / '+$e.Ship+' after respawn')
        try{
            Sb-ApplyCustomStats $s $cfg $label
            if($persistent){$e.LastPawnToken=[string]$s.Token;$e.CandidateToken='';$e.ReadyAfter=[DateTime]::MinValue}else{$script:Sb.CustomProfiles.Remove($key)}
            Sb-Log ('Custom Stats respawn profile applied: '+$label)
        }catch{$e.ReadyAfter=$now.AddMilliseconds(750);Sb-Log ('Custom Stats respawn profile retry scheduled: '+$_.Exception.Message)}
    }
}

function Sb-ArmCustomForRespawn {
    $local=Sb-Require
    $cfg=Sb-GetCustomStatsConfig

    $oldPawn=[int64]0
    if($local.Alive){
        $s=Sb-Ship ([int64]$local.PlayerState)
        if($null-ne$s){$oldPawn=[int64]$s.Pawn}
    }
    if($oldPawn -le 0){$oldPawn=[int64]$script:Sb.LastPlayerPawn}

    $script:Sb.PendingSelfCustom=@{
        OldPawn=$oldPawn
        Config=$cfg
        Until=[DateTime]::UtcNow.AddMinutes(10)
        WaitingLogged=$false
    }
    Sb-Log 'Custom Stats armed for your next respawn.'
}

# Exact desiredShipIndex values from the supplied Firing_Range_Ships_and_GUIDs DataTable.
# The asset stores FiringRangeIndex as 1..36; the runtime uses the zero-based row index.
$script:FIRING_RANGE_ROW_INDEX=@{
    'Aegis'=0
    'Basilisk'=1
    'Black Widow'=2
    'Brawler'=3
    'Centurion'=4
    'Colossus'=5
    'Destroyer'=6
    'Displacer'=7
    'Disruptor'=8
    'Endeavor'=9
    'Enforcer'=10
    'Equalizer'=11
    'Executioner'=12
    'Furion'=13
    'Ghost'=14
    'Gladiator'=15
    'Guardian'=16
    'Hunter'=17
    'Infiltrator'=18
    'Interceptor'=19
    'Leviathan'=20
    'Overseer'=21
    'Paladin'=22
    'Paragon'=23
    'Persecutor'=24
    'Pioneer'=25
    'Protector'=26
    'Punisher'=27
    'Raider'=28
    'Ranger'=29
    'Raven'=30
    'Reaper'=31
    'Sentinel'=32
    'Superlifter'=33
    'Venturer'=34
    'Watchman'=35
}
function Sb-ChangeShipNow([string]$ShipName) {
    $local=Sb-Require
    if (-not $local.Alive) {
        throw 'CHANGE SHIP NOW must be used while your current ship is alive.'
    }
    if (-not $SHIP_GUIDS.Contains($ShipName)) {
        throw 'Choose a known ship.'
    }
    if (-not $script:FIRING_RANGE_ROW_INDEX.ContainsKey($ShipName)) {
        throw ('No DataTable index for '+$ShipName+'.')
    }
    if (-not (Is-PlausiblePointer $local.Controller)) {
        throw 'Local player controller unavailable.'
    }

    $guid=([string]$SHIP_GUIDS[$ShipName]).ToUpperInvariant()
    $index=[int]$script:FIRING_RANGE_ROW_INDEX[$ShipName]
    $oldPawn=[int64]$local.Ship

    $forcedBefore=Read-U8 ([IntPtr](([int64]$local.PlayerState)+0x4BD))
    Sb-Log ('CHANGE SHIP NOW v18 FIX: '+$ShipName+
        ' | index='+$index+
        ' | bUseForcedLoadout before='+$forcedBefore+
        ' | requesting game respawn...')

    $ok=[NativeMemoryV4]::ChangeShipViaForceRespawnCoreNative(
        $script:ProcessHandle,
        [uint64]$script:ModuleBase.ToInt64(),
        [uint64]$local.Controller,
        [int]$index,
        [string]$guid)

    if(-not $ok) {
        throw ('Ship-change RPC sequence failed for {0} (native error {1}).' -f
            $ShipName,[NativeMemoryV4]::LastTrainerActionError)
    }

    $verified=$false
    $newPawn=[int64]0
    $liveGuid=''
    $actualName=''
    $deadline=[DateTime]::UtcNow.AddSeconds(6)

    while([DateTime]::UtcNow -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50

        $now=Get-LocalPlayerStateInfo
        if($null -eq $now) {
            continue
        }

        $candidate=[int64]$now.Ship
        if($candidate -le 0 -or $candidate -eq $oldPawn) {
            continue
        }

        $newPawn=$candidate
        $pawnKey=('{0:X}' -f [uint64]$newPawn)
        if($script:ShipGuidCache.ContainsKey($pawnKey)) {
            [void]$script:ShipGuidCache.Remove($pawnKey)
        }

        $g=Get-NativeShipGuid $newPawn
        if([string]::IsNullOrWhiteSpace($g)) {
            continue
        }

        $liveGuid=([string]$g).ToUpperInvariant()
        if($GUID_TO_SHIP.ContainsKey($liveGuid)) {
            $actualName=[string]$GUID_TO_SHIP[$liveGuid]
        }

        if($liveGuid -eq $guid) {
            $verified=$true
            break
        }
    }

    if(-not $verified) {
        $actual='GUID unavailable'
        if(-not [string]::IsNullOrWhiteSpace($liveGuid)) {
            $actual=$liveGuid
        }
        if(-not [string]::IsNullOrWhiteSpace($actualName)) {
            $actual=$actualName+' / '+$liveGuid
        }

        if($newPawn -gt 0) {
            throw ('Respawn happened, but the new Pawn could not be verified as {0}. Live result: {1}.' -f
                $ShipName,$actual)
        }

        throw ('Ship-change request was accepted, but no replacement Pawn appeared within 6 seconds for '+$ShipName+'.')
    }

    $script:Sb.DesiredRespawnShip=$ShipName

    if($null -ne $sbRespawnCurrent) {
        $sbRespawnCurrent.Text=('VERIFIED: '+$ShipName+' | live Pawn GUID')
    }

    $forcedAfter=Read-U8 ([IntPtr](([int64]$local.PlayerState)+0x4BD))
    $newPawnHex=('{0:X}' -f [uint64]$newPawn)
    Sb-Log ('CHANGE SHIP NOW VERIFIED: '+$ShipName+
        ' | new Pawn=0x'+$newPawnHex+
        ' | live GUID='+$liveGuid+
        ' | bUseForcedLoadout='+$forcedAfter)
}

function Sb-QueueShip([string]$Ship,[string]$Side,[int]$Difficulty,[int]$Count,[bool]$God=$false,[bool]$Boss=$false,$Custom=$null) {

    [void](Sb-Require)
    if (-not $SHIP_GUIDS.Contains($Ship)) { throw 'Choose a known ship.' }
    if ($Side -notin @('Ally','Enemy')) { throw 'Team must be Ally or Enemy.' }
    if ($Difficulty -lt 0 -or $Difficulty -gt 9 -or $Count -lt 1 -or $Count -gt 40) { throw 'Invalid count or difficulty.' }
    if ($script:Sb.Queue.Count + $Count -gt 40) { throw 'The spawn queue is limited to 40 ships.' }
    for ($i=0; $i -lt $Count; $i++) { $script:Sb.Queue.Enqueue([pscustomobject]@{Ship=$Ship;Side=$Side;Difficulty=$Difficulty;God=$God;Boss=$Boss;Custom=$Custom}) }
    Sb-Log ('Queued {0} {1} ({2})' -f $Count,$Ship,$Side)
}
function Sb-GetEnemyTeamCached($Local) {
    $counts=@{}
    foreach($psRaw in @($script:PlayerStateAddresses)){
        $ps=[int64]$psRaw
        if($ps -le 0 -or $ps -eq [int64]$Local.PlayerState){continue}
        $t=Read-U8 ([IntPtr]($ps+$PLAYERSTATE_TEAM_OFFSET))
        if($null-eq$t){continue}
        $ti=[int]$t
        if($ti -lt 0 -or $ti -gt 16 -or $ti -eq [int]$Local.Team){continue}
        if(-not$counts.ContainsKey($ti)){$counts[$ti]=0}
        $counts[$ti]=[int]$counts[$ti]+1
    }
    if($counts.Count -gt 0){
        $best=$counts.GetEnumerator()|Sort-Object -Property @{Expression={$_.Value};Descending=$true},@{Expression={$_.Key};Descending=$false}|Select-Object -First 1
        $script:LastEnemyTeamId=[int]$best.Key
        return [int]$script:LastEnemyTeamId
    }
    if($script:LastEnemyTeamId -ge 0 -and $script:LastEnemyTeamId -ne [int]$Local.Team){return [int]$script:LastEnemyTeamId}
    if([int]$Local.Team -eq 1){$script:LastEnemyTeamId=2}
    elseif([int]$Local.Team -eq 2){$script:LastEnemyTeamId=1}
    elseif([int]$Local.Team -eq 0){$script:LastEnemyTeamId=1}
    else{$script:LastEnemyTeamId=([int]$Local.Team -bxor 1)}
    return [int]$script:LastEnemyTeamId
}

function Sb-NewBotName {
    $first=@('Alex','Aria','Blake','Cass','Dante','Elena','Flynn','Hana','Iris','Jace','Kael','Lena','Marek','Nadia','Orion','Petra','Quinn','Rhea','Silas','Talia','Vera','Wade','Yara','Zane')
    $call=@('Aegis','Comet','Drifter','Echo','Falcon','Ghost','Havoc','Icarus','Javelin','Kestrel','Lancer','Meteor','Nomad','Onyx','Phantom','Raptor','Specter','Tempest','Vortex','Warden','Zenith')
    for($i=0;$i-lt100;$i++){$name=('{0}_{1}'-f(Get-Random -InputObject $first),(Get-Random -InputObject $call));if(-not$script:Sb.UsedBotNames.ContainsKey($name)){$script:Sb.UsedBotNames[$name]=$true;return $name}}
    $name=('{0}_{1}_{2}'-f(Get-Random -InputObject $first),(Get-Random -InputObject $call),(Get-Random -InputObject $call));$script:Sb.UsedBotNames[$name]=$true;return $name
}
function Sb-SpawnNext {
    if ($script:Sb.Busy -or $script:Sb.Queue.Count -eq 0 -or [DateTime]::UtcNow -lt $script:Sb.NextSpawn) { return }
    if ($script:Sb.PendingCustom.Count -gt 0) { return }
    if ($script:PlayerStateAddresses.Count -ge 60) { $script:Sb.Queue.Clear(); $script:Sb.Wave=$null; Sb-Log 'Spawn queue and waves stopped: 60-player limit.'; return }
    $local = Sb-Require
    $q = $script:Sb.Queue.Dequeue()
    $script:Sb.Busy = $true
    try {
        $team = if ($q.Side -eq 'Ally') { [int]$local.Team } else { Sb-GetEnemyTeamCached $local }
        if ($team -lt 0 -or $team -gt 16) { throw 'Team unavailable.' }
        $name = Sb-NewBotName
        $before = if($local.Alive){Get-DirectPlayerStateSnapshot}else{$null}
        $ctrl = [NativeMemoryV4]::SpawnBotByGuidNative($script:ProcessHandle,[uint64]$script:ModuleBase.ToInt64(),[uint64]$local.WorldContext,[byte]$team,[byte]$q.Difficulty,$name,[string]$SHIP_GUIDS[$q.Ship])
        if ($ctrl -le 0 -and $null -ne $before) { $ctrl = Recover-NewSpawnController $before $team }
        if ($ctrl -le 0) { throw (Get-SpawnErrorText ([NativeMemoryV4]::LastSpawnError)) }
        Register-TrackedAlly $ctrl $q.Ship $team $name
        $script:PendingSpawnControllers = @(@($script:PendingSpawnControllers) + [pscustomobject]@{Controller=$ctrl;Name=$name;AddedAt=[DateTime]::UtcNow})
        $entry = [pscustomobject]@{Time=[DateTime]::Now.ToString('s');Ship=$q.Ship;Side=$q.Side;Difficulty=$q.Difficulty;Controller=[int64]$ctrl;Token=(Sb-Token $ctrl)}
        $script:Sb.History = @(@($script:Sb.History) + $entry | Select-Object -Last 200)
        $script:Sb.Recent = @(@($q.Ship) + @($script:Sb.Recent | Where-Object { $_ -ne $q.Ship }) | Select-Object -First 5)
        if ($q.God) { $script:Sb.PendingGod[[string]$ctrl] = @{Token=$entry.Token;Until=[DateTime]::UtcNow.AddSeconds(30)} }
        if ($q.Boss) { $script:Sb.PendingBoss[[string]$ctrl] = @{Token=$entry.Token;Ship=[string]$q.Ship;Until=[DateTime]::UtcNow.AddSeconds(30)} }
        if ($null -ne $q.Custom) { $script:Sb.PendingCustom[[string]$ctrl] = @{Token=$entry.Token;Ship=[string]$q.Ship;Config=$q.Custom;ReadyAfter=[DateTime]::UtcNow.AddMilliseconds(1200);Until=[DateTime]::UtcNow.AddSeconds(30)} }
        $script:NextRosterRefreshAt = [DateTime]::UtcNow
        Sb-Log ('Spawned {0} / {1} / {2} / {3}' -f $q.Ship,$q.Side,(Get-BotDifficultyName $q.Difficulty),$name)
    } catch {
        $script:Sb.Queue.Clear()
        $script:Sb.Wave = $null
        throw
    } finally { $script:Sb.Busy=$false; $script:Sb.NextSpawn=[DateTime]::UtcNow.AddMilliseconds(900) }
}
function Sb-Clone([int]$Count) {
    $s = Sb-Selected
    $name = Get-ShipNameFromPlayerState $s.PlayerState $s.Pawn
    $local = Sb-Require
    $diff = if ($s.IsPlayer) { 4 } else { Read-U8 ([IntPtr]($s.Controller + $BOT_DIFFICULTY_TYPE_OFFSET)) }
    if ($null -eq $diff -or $diff -gt 9) { throw 'Bot difficulty unavailable.' }
    $side = if ($s.Team -eq $local.Team) {'Ally'} else {'Enemy'}
    Sb-QueueShip $name $side $diff $Count $false
}
function Sb-Undo {
    [void](Sb-Require)
    for ($i=$script:Sb.History.Count-1; $i -ge 0; $i--) {
        $e = $script:Sb.History[$i]
        if ($e.Token -eq '' -or (Sb-Token $e.Controller) -ne $e.Token) { continue }
        $row = @(@(Get-LiveAllyRows) + @(Get-LiveEnemyRows) | Where-Object { $_.Controller -eq $e.Controller }) | Select-Object -First 1
        if ($null -eq $row) { continue }
        if (-not (Invoke-DeleteAllyRow $row)) { throw 'Could not undo the last spawn.' }
        $script:Sb.History = @($script:Sb.History | Where-Object { $_ -ne $e })
        Sb-Log ('Undid spawn: ' + $e.Ship)
        return
    }
    throw 'No live sandbox spawn to undo.'
}
function Sb-Batch([string]$Action,[string]$Side) {
    $local = Sb-Require
    $count=0
    foreach ($ps in @($script:PlayerStateAddresses)) {
        $s = Sb-Ship $ps
        if ($null -eq $s -or $s.IsPlayer) { continue }
        if ($Side -eq 'Ally' -and $s.Team -ne $local.Team) { continue }
        if ($Side -eq 'Enemy' -and $s.Team -eq $local.Team) { continue }
        switch ($Action) {
            'Heal' { Sb-Heal $s }
            'God' { Sb-God $s $true }
            'Ungod' { Sb-God $s $false }
        }
        $count++
    }
    Sb-Log ('{0}: {1} ships' -f $Action,$count)
}
function Sb-Battle([int]$Allies,[int]$Enemies,[bool]$RandomShips,[bool]$RandomDifficulties,[int]$Difficulty,$Custom=$null) {
    [void](Sb-Require)
    if ($Allies -lt 0 -or $Enemies -lt 0 -or $Allies+$Enemies -gt 40 -or $script:Sb.Queue.Count+$Allies+$Enemies -gt 40) { throw 'Maximum 40 ships per battle queue.' }
    foreach ($side in @('Ally','Enemy')) {
        $count = if ($side -eq 'Ally') {$Allies} else {$Enemies}
        for ($i=0; $i -lt $count; $i++) {
            $ship = if ($RandomShips) { Get-Random -InputObject @($SHIP_GUIDS.Keys) } else { [string]$sbSpawnShip.SelectedItem }
            $d = if ($RandomDifficulties) { Get-Random -Minimum 0 -Maximum 10 } else { $Difficulty }
            Sb-QueueShip $ship $side $d 1 $false $false $Custom
        }
    }
}
function Sb-Export([object]$Value,[string]$Name) {
    if (-not (Test-Path -LiteralPath $script:SbDataDir)) { [void](New-Item -ItemType Directory -Path $script:SbDataDir -Force) }
    $dest = Join-Path $script:SbDataDir ($Name + '-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmssfff') + '.json')
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $dest -Encoding UTF8
    Sb-Log ('Saved: ' + $dest)
    return $dest
}
function Sb-Describe($s) {
    $pos = Sb-Vector ($s.Pawn + 0x858)
    $local=Sb-GetLocalContext
    $side=if($s.IsPlayer){'Player'}elseif($null -ne $local -and $s.Team -eq $local.Team){'Ally'}else{'Enemy'}
    return [pscustomobject]@{
        Ship=(Get-ShipNameFromPlayerState $s.PlayerState $s.Pawn); Pilot=(Get-PlayerStateName $s.PlayerState); Side=$side
        Difficulty=$(if ($s.IsPlayer) {'Player'} else {Get-ActualBotDifficultyName $s.Controller})
        HP=$s.HP; MaxHP=$s.MaxHP; Position=$pos
        Invulnerable=$script:Sb.Invulnerable.ContainsKey($s.StateToken)
    }
}
function Sb-ReadFName([int]$Index,[int]$Number=0) {
    if($Index-lt0){return ''}
    $cacheKey=[string]$Index
    $name=$script:Sb.FNameCache[$cacheKey]
    if([string]::IsNullOrWhiteSpace([string]$name)){
        if(-not(Is-PlausiblePointer $script:Sb.GNames)){
            $g=Read-U64 ([IntPtr]($script:ModuleBase.ToInt64()+$GNAMES_OFFSET))
            if(-not(Is-PlausiblePointer $g)){return ''}
            $script:Sb.GNames=[int64]$g
        }
        $chunk=Read-U64 ([IntPtr]($script:Sb.GNames+(([int64]$Index-shr14)*8)))
        if(-not(Is-PlausiblePointer $chunk)){return ''}
        $entry=Read-U64 ([IntPtr]([int64]$chunk+(($Index-band0x3FFF)*8)))
        if(-not(Is-PlausiblePointer $entry)){return ''}
        $header=Read-U8 ([IntPtr][int64]$entry)
        if($null-eq$header){return ''}
        $bytes=Read-Bytes ([IntPtr]([int64]$entry+0x10)) 256
        if($null-eq$bytes){return ''}
        try{
            if(($header-band1)-ne0){$name=([Text.Encoding]::Unicode.GetString($bytes)).Split([char]0)[0]}
            else{$name=([Text.Encoding]::ASCII.GetString($bytes)).Split([char]0)[0]}
        }catch{return ''}
        if([string]::IsNullOrWhiteSpace([string]$name)){return ''}
        $script:Sb.FNameCache[$cacheKey]=[string]$name
    }
    if($Number-gt0){return('{0}_{1}'-f$name,($Number-1))}
    return [string]$name
}
function Sb-UObjectName([int64]$Object) {
    if(-not(Is-PlausiblePointer $Object)){return ''}
    $index=Read-I32 ([IntPtr]($Object+0x18));if($null-eq$index-or$index-lt0){return ''}
    $number=Read-I32 ([IntPtr]($Object+0x1C));if($null-eq$number){$number=0}
    return Sb-ReadFName ([int]$index) ([int]$number)
}
function Sb-ActorPosition([int64]$Actor) {
    if(-not(Is-PlausiblePointer $Actor)){return $null}
    $root=Read-U64 ([IntPtr]($Actor+$ACTOR_ROOT_COMPONENT_OFFSET))
    if(-not(Is-PlausiblePointer $root)){return $null}
    return Sb-Vector ([int64]$root+$SCENE_COMPONENT_WORLD_LOCATION_OFFSET)
}
function Sb-ActorYaw([int64]$Actor) {
    if(-not(Is-PlausiblePointer $Actor)){return $null}
    $root=Read-U64 ([IntPtr]($Actor+$ACTOR_ROOT_COMPONENT_OFFSET))
    if(-not(Is-PlausiblePointer $root)){return $null}
    $yaw=Read-F32 ([IntPtr]([int64]$root+0x16C))
    if($null-eq$yaw-or[single]::IsNaN($yaw)-or[single]::IsInfinity($yaw)-or[Math]::Abs([double]$yaw)-gt100000){return $null}
    return [double]$yaw
}
function Sb-SectorKey([string]$Name) {
    if($Name-match'(?i)T1Jump'){return 'T1JUMP'}
    if($Name-match'(?i)T2Jump'){return 'T2JUMP'}
    if($Name-match'(?i)T1Base'){return 'T1BASE'}
    if($Name-match'(?i)T2Base'){return 'T2BASE'}
    if($Name-match'(?i)Alpha'){return 'ALPHA'}
    if($Name-match'(?i)Beta'){return 'BETA'}
    if($Name-match'(?i)Gamma'){return 'GAMMA'}
    return ''
}
function Sb-SectorName([string]$Key,[int]$LocalTeam) {
    switch($Key){
        'ALPHA'{return 'Alpha'}'BETA'{return 'Beta'}'GAMMA'{return 'Gamma'}
        'T1JUMP'{return 'Team 1 Jump'}'T2JUMP'{return 'Team 2 Jump'}
        'T1BASE'{if($LocalTeam-eq1){return 'Home Base'}else{return 'Enemy Base'}}
        'T2BASE'{if($LocalTeam-eq2){return 'Home Base'}else{return 'Enemy Base'}}
    }
    return $Key
}
function Sb-ScanNativeMap([int]$LocalTeam) {
    $world=[int64]$script:CurrentWorldAddress
    if(-not(Is-PlausiblePointer $world)-and$null-ne$script:Sb.NativeMap-and(Is-PlausiblePointer ([int64]$script:Sb.NativeMap.World))){$world=[int64]$script:Sb.NativeMap.World}
    if(-not(Is-PlausiblePointer $world)){
        $live=Get-LocalPlayerStateInfo
        if($null-ne$live){$level=Read-U64 ([IntPtr]([int64]$live.Ship+$UOBJECT_OUTER_OFFSET));$world=[int64](Read-U64 ([IntPtr]([int64]$level+$LEVEL_OWNING_WORLD_OFFSET)))}
    }
    if(-not(Is-PlausiblePointer $world)){return $null}
    if($null-ne$script:Sb.NativeMap-and$script:Sb.NativeMap.World-eq$world-and[DateTime]::UtcNow-lt$script:Sb.NextNativeMap){return $script:Sb.NativeMap}
    $gameState=Read-U64 ([IntPtr]([int64]$world+$WORLD_GAMESTATE_OFFSET));$gameStateClass=if(Is-PlausiblePointer $gameState){Get-PawnClassName ([int64]$gameState)}else{''};$mode=if($gameStateClass-match'(?i)Horde'){'LastStand'}else{'Conquest'}
    $levelsData=[int64](Read-U64 ([IntPtr]([int64]$world+$WORLD_LEVELS_OFFSET)));$levelsNum=Read-I32 ([IntPtr]([int64]$world+$WORLD_LEVELS_OFFSET+8));$levelsMax=Read-I32 ([IntPtr]([int64]$world+$WORLD_LEVELS_OFFSET+12))
    if(-not(Is-PlausiblePointer $levelsData)-or$null-eq$levelsNum-or$levelsNum-lt1-or$levelsNum-gt64-or$levelsMax-lt$levelsNum-or$levelsMax-gt128){return $script:Sb.NativeMap}
    $sectorByKey=@{};$rawObjects=@();$seenActors=@{}
    for($li=0;$li-lt$levelsNum;$li++){
        $level=Read-U64 ([IntPtr]([int64]$levelsData+$li*8));if(-not(Is-PlausiblePointer $level)){continue}
        $levelOuter=Read-U64 ([IntPtr]([int64]$level+$UOBJECT_OUTER_OFFSET));$levelName=Sb-UObjectName ([int64]$levelOuter)
        if($mode-eq'Conquest'-and$levelName-notmatch'(?i)^Map_ActionConquest_(T1Jump|T2Jump|Beta_Design|Alpha_Design|Gamma_Design|T1Base_Design|T2Base_Design)'){continue}
        $actorData=Read-U64 ([IntPtr]([int64]$level+$LEVEL_ACTORS_OFFSET));$actorNum=Read-I32 ([IntPtr]([int64]$level+$LEVEL_ACTORS_OFFSET+8));$actorMax=Read-I32 ([IntPtr]([int64]$level+$LEVEL_ACTORS_OFFSET+12))
        if(-not(Is-PlausiblePointer $actorData)-or$null-eq$actorNum-or$actorNum-lt1-or$actorNum-gt6000-or$actorMax-lt$actorNum-or$actorMax-gt10000){continue}
        for($ai=0;$ai-lt$actorNum;$ai++){
            $actor=Read-U64 ([IntPtr]([int64]$actorData+$ai*8));if(-not(Is-PlausiblePointer $actor)){continue}
            $actorKey=('A{0:X}'-f[uint64]$actor);if($seenActors.ContainsKey($actorKey)){continue};$seenActors[$actorKey]=$true
            $name=Sb-UObjectName ([int64]$actor);if([string]::IsNullOrWhiteSpace($name)){continue}
            $kind=''
            if($mode-eq'LastStand'){
                if($name-match'(?i)(LastStand.*Core|BaseCore|HomeBase.*Core)'){$kind='Base'}
                elseif($name-match'(?i)(LastStand.*Turret|BaseTurret|TurretLastStand)'){$kind='Station'}
                elseif($name-match'(?i)(Horde.*Mine|Mine.*Horde)'){$kind='Mine'}
                else{continue}
            }
            elseif($name-match'(?i)^BP_Sector_'){$kind='Sector'}
            elseif($name-match'(?i)^JD_'){$kind='Jump'}
            elseif($name-match'(?i)^BP_MiningFacility_CapZone_C(?:_\d+)?$'){$kind='Mine'}
            elseif($name-match'(?i)^BP_ForwardStation_CapZone_C(?:_\d+)?$'){$kind='Station'}
            elseif($name-match'(?i)^BP_GammaStation_CapZone_C(?:_\d+)?$'){$kind='Gamma'}
            elseif($name-match'(?i)^BP_HomeBase_CapZone(?:_C|2)(?:_\d+)?$'){$kind='Base'}
            else{continue}
            $pos=Sb-ActorPosition ([int64]$actor);if($null-eq$pos){continue}
            if($kind-eq'Sector'){
                $key=Sb-SectorKey $name;if([string]::IsNullOrWhiteSpace($key)){continue}
                if(-not$sectorByKey.ContainsKey($key)){$sectorByKey[$key]=[pscustomobject]@{Key=$key;Name=(Sb-SectorName $key $LocalTeam);Address=[int64]$actor;Position=$pos}}
            }else{$rawObjects+=,[pscustomobject]@{Kind=$kind;Name=$name;Address=[int64]$actor;Position=$pos}}
        }
    }
    if($mode-eq'LastStand'){
        $anchor=@($rawObjects|Where-Object{$_.Kind-eq'Base'}|Select-Object -First 1)
        $center=if($anchor.Count-gt0){$anchor[0].Position}else{$null}
        if($null-eq$center){$local=Sb-GetLocalContext;if($null-ne$local-and$local.Alive){$center=Sb-ActorPosition ([int64]$local.Ship)}}
        if($null-eq$center){$center=@(0.0,0.0,0.0)}
        $sectorByKey['LASTSTAND']=[pscustomobject]@{Key='LASTSTAND';Name='Last Stand';Address=0L;Position=$center}
    }
    $sectors=@($sectorByKey.Values)
    if(($mode-eq'Conquest'-and$sectors.Count-lt5)-or$sectors.Count-lt1){$script:Sb.NativeMap=[pscustomobject]@{World=$world;Mode=$mode;LocalTeam=$LocalTeam;Sectors=$sectors;Objects=@();Jumps=@();ScannedAt=[DateTime]::UtcNow};$script:Sb.NextNativeMap=[DateTime]::UtcNow.AddSeconds(1);return $script:Sb.NativeMap}
    $objects=@();$jumps=@();$seenPositions=@{}
    foreach($o in $rawObjects){
        $sector=Sb-NativeSectorForPosition $o.Position $sectors;if($null-eq$sector){continue}
        $dedupe=('{0}:{1}:{2}:{3}'-f$o.Kind,$sector.Key,[Math]::Round([double]$o.Position[0]),[Math]::Round([double]$o.Position[1]))
        if($seenPositions.ContainsKey($dedupe)){continue};$seenPositions[$dedupe]=$true
        $item=[pscustomobject]@{Kind=$o.Kind;Name=$o.Name;Address=$o.Address;Position=$o.Position;SectorKey=$sector.Key}
        if($o.Kind-eq'Jump'){$jumps+=,$item}else{$objects+=,$item}
    }
    $map=[pscustomobject]@{World=$world;Mode=$mode;LocalTeam=$LocalTeam;Sectors=$sectors;Objects=$objects;Jumps=$jumps;ScannedAt=[DateTime]::UtcNow}
    $script:Sb.NativeMap=$map;$script:Sb.NextNativeMap=[DateTime]::MaxValue
    return $map
}
function Sb-NativeSectorForPosition($Position,[object[]]$Sectors) {
    if($null-eq$Position-or$null-eq$Sectors-or$Sectors.Count-eq0){return $null}
    $best=$null;[double]$bestDistance=[double]::MaxValue
    foreach($sector in $Sectors){$dx=[double]$Position[0]-[double]$sector.Position[0];$dy=[double]$Position[1]-[double]$sector.Position[1];$distance=$dx*$dx+$dy*$dy;if($distance-lt$bestDistance){$bestDistance=$distance;$best=$sector}}
    return $best
}
function Sb-UpdateNativeBounds([object[]]$Rows,$Map) {
    $script:Sb.MapBounds=@{}
    foreach($sector in @($Map.Sectors)){
        [double]$half=if($sector.Key-eq'LASTSTAND'){75000}elseif($sector.Key-in@('ALPHA','BETA')){23000}elseif($sector.Key-in@('T1JUMP','T2JUMP')){10000}else{17000}
        $points=@($Map.Objects|Where-Object{$_.SectorKey-eq$sector.Key}|ForEach-Object{$_.Position})+@($Map.Jumps|Where-Object{$_.SectorKey-eq$sector.Key}|ForEach-Object{$_.Position})
        foreach($p in $points){$half=[Math]::Max($half,[Math]::Abs([double]$p[0]-[double]$sector.Position[0])*1.22);$half=[Math]::Max($half,[Math]::Abs([double]$p[1]-[double]$sector.Position[1])*1.22)}
        $half=[Math]::Min(75000.0,$half)
        $script:Sb.MapBounds[$sector.Key]=[pscustomobject]@{MinX=[double]$sector.Position[0]-$half;MaxX=[double]$sector.Position[0]+$half;MinY=[double]$sector.Position[1]-$half;MaxY=[double]$sector.Position[1]+$half}
    }
}
function Sb-EffectiveMapMaxHp($s) {
    $key = [string]([int64]$s.PlayerState)
    [double]$hp = [Math]::Max(0,[double]$s.HP)
    [double]$reported = 0
    if ($null -ne $s.MaxHP) { $reported = [double]$s.MaxHP }
    if ([double]::IsNaN($reported) -or [double]::IsInfinity($reported) -or $reported -le 0) { $reported = 0 }
    [double]$candidate = $reported
    if ($candidate -le 0 -and $script:Sb.MapMaxHp.ContainsKey($key)) {
        $cached = $script:Sb.MapMaxHp[$key]
        if ([string]$cached.Token -eq [string]$s.Token) { $candidate = [double]$cached.Value }
    }
    if ($candidate -le 0) { $candidate = [Math]::Max(1,$hp) }
    $script:Sb.MapMaxHp[$key] = [pscustomobject]@{Token=[string]$s.Token;Value=[double]$candidate}
    return [double]$candidate
}
function Sb-MapVisibleRows([object[]]$Rows) {
    [bool]$showAllies = ($null -eq $sbMapFilterAllies -or $sbMapFilterAllies.Checked)
    [bool]$showEnemies = ($null -eq $sbMapFilterEnemies -or $sbMapFilterEnemies.Checked)
    return @($Rows | Where-Object { if ($_.Side -eq 'Enemy') { $showEnemies } else { $showAllies } })
}
function Sb-SortMapRows([object[]]$Rows) {
    $mode = if ($null -ne $sbMapSort -and $null -ne $sbMapSort.SelectedItem) { [string]$sbMapSort.SelectedItem } else { 'Team' }
    switch ($mode) {
        'Sector' { return @($Rows | Sort-Object @{Expression={$_.SectorName}},@{Expression={$_.DisplayName}}) }
        'HP' { return @($Rows | Sort-Object @{Expression={if($_.MaxHP -gt 0){[double]$_.HP/[double]$_.MaxHP}else{0}}},@{Expression={$_.DisplayName}}) }
        'Name' { return @($Rows | Sort-Object @{Expression={$_.DisplayName}}) }
        default { return @($Rows | Sort-Object @{Expression={if($_.Side-eq'Player'){0}elseif($_.Side-eq'Ally'){1}else{2}}},@{Expression={$_.DisplayName}}) }
    }
}
function Sb-UpdateMapSelectedInfo {
    if ($null -eq $sbMapSelectedInfo) { return }
    $r = @($script:Sb.MapRows | Where-Object { [int64]$_.PlayerState -eq [int64]$script:Sb.Selected } | Select-Object -First 1)
    if ($r.Count -eq 0) { $sbMapSelectedInfo.Text = 'Selected: none'; return }
    $row = $r[0]
    $god = if ($row.IsAlive -and $script:Sb.Invulnerable.ContainsKey([string]$row.StateToken)) { 'GOD ON' } else { 'God off' }
    $status = if ($row.IsAlive) { 'LIVE' } else { [string]$row.Status }
    $sbMapSelectedInfo.Text = ('Selected: {0}   |   {1}   |   {2}   |   {3:0}/{4:0} HP   |   {5}   |   {6}' -f $row.DisplayName,$row.Side,$row.SectorName,[double]$row.HP,[double]$row.MaxHP,$status,$god)
}
function Sb-RefreshMapData {
    if($null-eq$sbMapPanel){return}
    $local=Sb-GetLocalContext
    if($null-eq$local-and$script:Sb.LocalTeam-in@(1,2)){$local=[pscustomobject]@{PlayerState=[int64]$script:Sb.LocalPlayerState;Team=[int]$script:Sb.LocalTeam;Alive=$false}}
    if($null-eq$local){if($null-ne$sbMapInfo){$sbMapInfo.Text='Waiting for player context...'};$sbMapPanel.Invalidate();return}
    $map=Sb-ScanNativeMap ([int]$local.Team)
    if($null-eq$map-or@($map.Sectors).Count-lt1-or($map.Mode-eq'Conquest'-and@($map.Sectors).Count-lt5)){if($null-ne$sbMapInfo){$sbMapInfo.Text='Reading native map sectors...'};$sbMapPanel.Invalidate();return}
    $now=[DateTime]::UtcNow;$rows=@();$candidateStates=@(@([int64]$local.PlayerState)+@($script:PlayerStateAddresses)|Where-Object{[int64]$_-gt0}|Sort-Object -Unique);$present=@{}
    foreach($ps in $candidateStates){
        $key=[string]([int64]$ps);$present[$key]=$true;$s=Sb-Ship ([int64]$ps)
        if($null-ne$s){
            $pos=Sb-ActorPosition ([int64]$s.Pawn);if($null-eq$pos){$pos=Sb-Vector ($s.Pawn+0x858)};if($null-eq$pos){continue}
            $sector=Sb-NativeSectorForPosition $pos @($map.Sectors);if($null-eq$sector){continue}
            $side=if($s.IsPlayer){'Player'}elseif($s.Team-eq$local.Team){'Ally'}else{'Enemy'}
            $shipName=Get-ShipNameFromPlayerState $s.PlayerState $s.Pawn;$pilotName=Get-PlayerStateName $s.PlayerState
            $displayName=if([string]::IsNullOrWhiteSpace([string]$pilotName)-or$pilotName-eq$shipName){[string]$shipName}else{([string]$pilotName+' / '+[string]$shipName)}
            $sectorName=[string]$sector.Name;if($sector.Key-in@('ALPHA','BETA')){$sectorNumber=if([double]$pos[1]-ge[double]$sector.Position[1]){2}else{1};$sectorName=('{0} {1}'-f$sectorName,$sectorNumber)}
            $maxHp=Sb-EffectiveMapMaxHp $s
            $row=[pscustomobject]@{PlayerState=[int64]$s.PlayerState;Pawn=[int64]$s.Pawn;Token=$s.Token;StateToken=$s.StateToken;Name=[string]$shipName;Pilot=[string]$pilotName;DisplayName=[string]$displayName;Side=$side;IsPlayer=[bool]$s.IsPlayer;IsAlive=$true;Status='LIVE';HP=[single]$s.HP;MaxHP=[double]$maxHp;Position=$pos;Heading=(Sb-ActorYaw ([int64]$s.Pawn));SectorKey=[string]$sector.Key;SectorName=$sectorName;LastSeen=$now}
            $rows+=,$row;$script:Sb.MapKnown[$key]=[pscustomobject]@{Row=$row;LastSeen=$now}
        } elseif($script:Sb.MapKnown.ContainsKey($key)) {
            $cached=$script:Sb.MapKnown[$key];$old=$cached.Row
            $rows+=,[pscustomobject]@{PlayerState=[int64]$old.PlayerState;Pawn=0L;Token='';StateToken=[string]$old.StateToken;Name=[string]$old.Name;Pilot=[string]$old.Pilot;DisplayName=[string]$old.DisplayName;Side=[string]$old.Side;IsPlayer=[bool]$old.IsPlayer;IsAlive=$false;Status='RESPAWNING';HP=0.0;MaxHP=[double]$old.MaxHP;Position=$old.Position;Heading=$null;SectorKey=[string]$old.SectorKey;SectorName=[string]$old.SectorName;LastSeen=$cached.LastSeen}
        }
    }
    foreach($key in @($script:Sb.MapKnown.Keys)){
        if($present.ContainsKey($key)){continue};$cached=$script:Sb.MapKnown[$key];$age=($now-[DateTime]$cached.LastSeen).TotalSeconds
        if($age-gt30){[void]$script:Sb.MapKnown.Remove($key);[void]$script:Sb.MapMaxHp.Remove($key);continue}
        $old=$cached.Row;$rows+=,[pscustomobject]@{PlayerState=[int64]$old.PlayerState;Pawn=0L;Token='';StateToken=[string]$old.StateToken;Name=[string]$old.Name;Pilot=[string]$old.Pilot;DisplayName=[string]$old.DisplayName;Side=[string]$old.Side;IsPlayer=[bool]$old.IsPlayer;IsAlive=$false;Status='DEAD';HP=0.0;MaxHP=[double]$old.MaxHP;Position=$old.Position;Heading=$null;SectorKey=[string]$old.SectorKey;SectorName=[string]$old.SectorName;LastSeen=$cached.LastSeen}
    }
    $script:Sb.MapRows=@($rows);Sb-UpdateNativeBounds $rows $map;Sb-UpdateMapSelectedInfo
    if($null-ne$sbMapInfo){$liveCount=@($rows|Where-Object{$_.IsAlive}).Count;$waitingCount=$rows.Count-$liveCount;$sbMapInfo.Text=('{0}   |   Live: {1}   Waiting/dead: {2}   Bases/mines: {3}   Jump zones: {4}   |   Wheel: zoom, drag: move, double-click: sector zoom' -f$map.Mode,$liveCount,$waitingCount,@($map.Objects).Count,@($map.Jumps).Count)}
    $sbMapPanel.Invalidate()
}
function Sb-MapLayouts([int]$Width,[int]$Height,[object[]]$Rows) {
    $groups=@($Rows|Group-Object SectorKey|Sort-Object Name)
    if($groups.Count-eq0){return @()}
    $margin=18.0;$top=12.0;$usableW=[Math]::Max(100.0,$Width-2*$margin);$usableH=[Math]::Max(100.0,$Height-$top-18)
    $layouts=@()
    if($groups.Count-eq1){
        $layouts+=[pscustomobject]@{Group=$groups[0];Rect=[Drawing.RectangleF]::new([single]($margin+$usableW*.12),[single]($top+$usableH*.05),[single]($usableW*.76),[single]($usableH*.90))}
        return $layouts
    }
    if($groups.Count-eq5){
        $slots=@(
            [Drawing.RectangleF]::new([single]($margin+$usableW*.37),[single]($top),[single]($usableW*.26),[single]($usableH*.25)),
            [Drawing.RectangleF]::new([single]($margin),[single]($top+$usableH*.27),[single]($usableW*.29),[single]($usableH*.46)),
            [Drawing.RectangleF]::new([single]($margin+$usableW*.36),[single]($top+$usableH*.32),[single]($usableW*.28),[single]($usableH*.36)),
            [Drawing.RectangleF]::new([single]($margin+$usableW*.71),[single]($top+$usableH*.27),[single]($usableW*.29),[single]($usableH*.46)),
            [Drawing.RectangleF]::new([single]($margin+$usableW*.37),[single]($top+$usableH*.75),[single]($usableW*.26),[single]($usableH*.25))
        )
        $assigned=@{};$used=@{}
        foreach($g in $groups){$n=[string]$g.Group[0].SectorName;$slot=if($n-match'(?i)enemy|red'){0}elseif($n-match'(?i)beta'){1}elseif($n-match'(?i)gamma'){2}elseif($n-match'(?i)alpha'){3}elseif($n-match'(?i)home|blue|friendly'){4}else{-1};if($slot-ge0 -and -not $used.ContainsKey($slot)){$assigned[$g.Name]=$slot;$used[$slot]=$true}}
        $free=@(0..4|Where-Object{-not$used.ContainsKey($_)})
        foreach($g in $groups){if(-not$assigned.ContainsKey($g.Name)){$assigned[$g.Name]=$free[0];$free=@($free|Select-Object -Skip 1)};$layouts+=[pscustomobject]@{Group=$g;Rect=$slots[[int]$assigned[$g.Name]]}}
        return $layouts
    }
    $cols=if($groups.Count-le2){2}else{[Math]::Min(3,$groups.Count)};$rowsCount=[Math]::Ceiling($groups.Count/$cols)
    $gap=14.0;$cellW=($usableW-$gap*($cols-1))/$cols;$cellH=($usableH-$gap*($rowsCount-1))/$rowsCount
    for($i=0;$i-lt$groups.Count;$i++){$col=$i%$cols;$row=[Math]::Floor($i/$cols);$layouts+=[pscustomobject]@{Group=$groups[$i];Rect=[Drawing.RectangleF]::new([single]($margin+$col*($cellW+$gap)),[single]($top+$row*($cellH+$gap)),[single]$cellW,[single]$cellH)}}
    return $layouts
}
function Sb-NativeMetrics($Sender) {
    [double]$availableW=[Math]::Max(720,$Sender.ClientSize.Width-16);[double]$availableH=[Math]::Max(320,$Sender.ClientSize.Height-16)
    [double]$rosterW=[Math]::Max(180,[Math]::Min(240,$availableW*.19));[double]$gap=10
    [double]$side=[Math]::Min($availableH,$availableW-($rosterW*2)-($gap*2));$side=[Math]::Max(210,$side)
    [double]$groupW=$side+($rosterW*2)+($gap*2);[double]$groupX=($Sender.ClientSize.Width-$groupW)/2.0;[double]$y=8
    return [pscustomobject]@{
        Side=$side;MapX=$groupX+$rosterW+$gap;MapY=$y
        LeftRoster=[Drawing.RectangleF]::new([single]$groupX,[single]$y,[single]$rosterW,[single]$availableH)
        RightRoster=[Drawing.RectangleF]::new([single]($groupX+$rosterW+$gap+$side+$gap),[single]$y,[single]$rosterW,[single]$availableH)
    }
}
function Sb-NativeBaseLayouts($Sender,$Map) {
    $metrics=Sb-NativeMetrics $Sender;[double]$w=$metrics.Side;[double]$h=$metrics.Side;[double]$x=$metrics.MapX;[double]$y=$metrics.MapY
    if($Map.Mode-eq'LastStand'){return @{'LASTSTAND'=[Drawing.RectangleF]::new([single]($x+$w*.05),[single]($y+$h*.04),[single]($w*.90),[single]($h*.92))}}
    $homeBase=if([int]$Map.LocalTeam-eq2){'T2BASE'}else{'T1BASE'};$enemyBase=if($homeBase-eq'T1BASE'){'T2BASE'}else{'T1BASE'}
    $homeJump=if($homeBase-eq'T1BASE'){'T1JUMP'}else{'T2JUMP'};$enemyJump=if($homeJump-eq'T1JUMP'){'T2JUMP'}else{'T1JUMP'}
    $leftSector=if([int]$Map.LocalTeam-eq2){'ALPHA'}else{'BETA'};$rightSector=if($leftSector-eq'ALPHA'){'BETA'}else{'ALPHA'}
    $r=@{}
    $r[$enemyBase]=[Drawing.RectangleF]::new([single]($x+$w*.37),[single]($y+$h*.01),[single]($w*.26),[single]($h*.21))
    $r[$leftSector]=[Drawing.RectangleF]::new([single]($x+$w*.02),[single]($y+$h*.25),[single]($w*.27),[single]($h*.48))
    $r['GAMMA']=[Drawing.RectangleF]::new([single]($x+$w*.38),[single]($y+$h*.35),[single]($w*.24),[single]($h*.30))
    $r[$rightSector]=[Drawing.RectangleF]::new([single]($x+$w*.71),[single]($y+$h*.25),[single]($w*.27),[single]($h*.48))
    $r[$homeBase]=[Drawing.RectangleF]::new([single]($x+$w*.37),[single]($y+$h*.78),[single]($w*.26),[single]($h*.21))
    $r[$enemyJump]=[Drawing.RectangleF]::new([single]($x+$w*.65),[single]($y+$h*.05),[single]($w*.10),[single]($h*.10))
    $r[$homeJump]=[Drawing.RectangleF]::new([single]($x+$w*.25),[single]($y+$h*.85),[single]($w*.10),[single]($h*.10))
    return $r
}
function Sb-NativeLayouts($Sender,$Map) {
    $base=Sb-NativeBaseLayouts $Sender $Map;$metrics=Sb-NativeMetrics $Sender
    [double]$zoom=[Math]::Max(0.65,[Math]::Min(4.0,[double]$script:Sb.MapZoom));[double]$cx=$metrics.MapX+$metrics.Side/2.0;[double]$cy=$metrics.MapY+$metrics.Side/2.0
    $result=@{}
    foreach($key in @($base.Keys)){
        $rect=$base[$key]
        $result[$key]=[Drawing.RectangleF]::new([single]($cx+($rect.X-$cx)*$zoom+[double]$script:Sb.MapPanX),[single]($cy+($rect.Y-$cy)*$zoom+[double]$script:Sb.MapPanY),[single]($rect.Width*$zoom),[single]($rect.Height*$zoom))
    }
    return $result
}
function Sb-ResetMapView {
    if($null-ne$sbMapZoomTimer){$sbMapZoomTimer.Stop()};$script:Sb.MapZoom=1.0;$script:Sb.MapTargetZoom=1.0;$script:Sb.MapPanX=0.0;$script:Sb.MapPanY=0.0;$script:Sb.MapFocusSector=''
    if($null-ne$sbMapZoomLabel){$sbMapZoomLabel.Text='Zoom x1.00'}
    if($null-ne$sbMapPanel){$sbMapPanel.Invalidate()}
}
function Sb-SetMapZoomAt([double]$NewZoom,[Drawing.Point]$Anchor) {
    if($null-eq$sbMapPanel){return}
    [double]$old=[Math]::Max(0.65,[double]$script:Sb.MapZoom);[double]$next=[Math]::Max(0.65,[Math]::Min(4.0,$NewZoom));if([Math]::Abs($next-$old)-lt0.00001){return}
    $metrics=Sb-NativeMetrics $sbMapPanel;[double]$cx=$metrics.MapX+$metrics.Side/2.0;[double]$cy=$metrics.MapY+$metrics.Side/2.0;[double]$factor=$next/$old
    $script:Sb.MapPanX=([double]$Anchor.X-$cx)-(([double]$Anchor.X-$cx-[double]$script:Sb.MapPanX)*$factor)
    $script:Sb.MapPanY=([double]$Anchor.Y-$cy)-(([double]$Anchor.Y-$cy-[double]$script:Sb.MapPanY)*$factor)
    $script:Sb.MapZoom=$next;$script:Sb.MapFocusSector=''
    if($null-ne$sbMapZoomLabel){$sbMapZoomLabel.Text=('Zoom x{0:0.00}'-f$next)}
    $sbMapPanel.Invalidate()
}
function Sb-FocusMapSector([string]$SectorKey) {
    if($null-eq$sbMapPanel-or$null-eq$script:Sb.NativeMap){return}
    $metrics=Sb-NativeMetrics $sbMapPanel;$base=Sb-NativeBaseLayouts $sbMapPanel $script:Sb.NativeMap;$rect=$base[$SectorKey];if($null-eq$rect){return}
    [double]$zoom=if($SectorKey-in@('ALPHA','BETA')){1.85}else{2.25};[double]$cx=$metrics.MapX+$metrics.Side/2.0;[double]$cy=$metrics.MapY+$metrics.Side/2.0
    if($null-ne$sbMapZoomTimer){$sbMapZoomTimer.Stop()};$script:Sb.MapZoom=$zoom;$script:Sb.MapTargetZoom=$zoom;$script:Sb.MapPanX=$cx-($cx+(([double]$rect.X+$rect.Width/2.0)-$cx)*$zoom);$script:Sb.MapPanY=$cy-($cy+(([double]$rect.Y+$rect.Height/2.0)-$cy)*$zoom);$script:Sb.MapFocusSector=$SectorKey
    if($null-ne$sbMapZoomLabel){$sbMapZoomLabel.Text=('Zoom x{0:0.00}'-f$zoom)};$sbMapPanel.Invalidate()
}
function Sb-CenterSelectedOnMap {
    if($null-eq$sbMapPanel-or$null-eq$script:Sb.NativeMap){throw 'Map data is not ready yet.'}
    $row=@($script:Sb.MapRows|Where-Object{[int64]$_.PlayerState-eq[int64]$script:Sb.Selected}|Select-Object -First 1);if($row.Count-eq0){throw 'Select a ship first.'}
    $r=$row[0];$metrics=Sb-NativeMetrics $sbMapPanel;$base=Sb-NativeBaseLayouts $sbMapPanel $script:Sb.NativeMap;$pt=Sb-NativePoint $r.Position ([string]$r.SectorKey) $base;if($null-eq$pt){throw 'The selected ship position is unavailable.'}
    [double]$zoom=2.45;[double]$cx=$metrics.MapX+$metrics.Side/2.0;[double]$cy=$metrics.MapY+$metrics.Side/2.0
    $script:Sb.MapZoom=$zoom;$script:Sb.MapPanX=$cx-($cx+(([double]$pt.X-$cx)*$zoom));$script:Sb.MapPanY=$cy-($cy+(([double]$pt.Y-$cy)*$zoom));$script:Sb.MapFocusSector=[string]$r.SectorKey
    if($null-ne$sbMapZoomLabel){$sbMapZoomLabel.Text=('Zoom x{0:0.00}'-f$zoom)};$sbMapPanel.Invalidate();Sb-Log ('Map centered on '+$r.DisplayName)
}
function Sb-NativePoint($Position,[string]$SectorKey,$Layouts,[string]$Layer='Ship') {
    $rect=$Layouts[$SectorKey];$bounds=$script:Sb.MapBounds[$SectorKey]
    if($null-eq$rect-or$null-eq$bounds-or$null-eq$Position){return $null}
    [double]$nx=([double]$Position[0]-$bounds.MinX)/[Math]::Max(1.0,$bounds.MaxX-$bounds.MinX);[double]$ny=([double]$Position[1]-$bounds.MinY)/[Math]::Max(1.0,$bounds.MaxY-$bounds.MinY)
    if($script:Sb.NativeMap.Mode-ne'LastStand'-and[int]$script:Sb.NativeMap.LocalTeam-ne2){$nx=1.0-$nx;$ny=1.0-$ny}
    [double]$zoom=switch($SectorKey){'ALPHA'{2.75}'BETA'{2.75}'T1BASE'{1.15}'T2BASE'{1.15}'GAMMA'{1.35}'LASTSTAND'{1.0}default{1.0}}
    $nx=.5+(($nx-.5)*$zoom);$ny=.5+(($ny-.5)*$zoom)
    if($SectorKey-in@('ALPHA','BETA')){
        $minX=if($Layer-eq'Jump'){.04}else{.06};$minY=if($Layer-eq'Object'){.04}elseif($Layer-eq'Jump'){.06}else{.08}
    }else{$minX=if($Layer-eq'Jump'){.05}else{.09};$minY=if($Layer-eq'Jump'){.08}else{.12}}
    $maxX=1.0-$minX;$maxY=1.0-$minY
    $nx=[Math]::Max($minX,[Math]::Min($maxX,$nx));$ny=[Math]::Max($minY,[Math]::Min($maxY,$ny))
    return [Drawing.PointF]::new([single]($rect.X+$nx*$rect.Width),[single]($rect.Y+$ny*$rect.Height))
}
function Sb-HealthRatio($Row) {
    [double]$hp=[Math]::Max(0,[double]$Row.HP);[double]$max=[double]$Row.MaxHP
    if([double]::IsNaN($max)-or[double]::IsInfinity($max)-or$max-le0){$max=[Math]::Max(1,$hp)}
    return [Math]::Max(0.0,[Math]::Min(1.0,$hp/$max))
}
function Sb-HealthColor([double]$Ratio,[bool]$Alive) {
    if(-not$Alive){return [Drawing.Color]::FromArgb(115,125,132)}
    if($Ratio-le0.25){return [Drawing.Color]::FromArgb(224,70,55)}
    if($Ratio-le0.60){return [Drawing.Color]::FromArgb(238,164,52)}
    return [Drawing.Color]::FromArgb(58,188,103)
}
function Sb-MapGodState($Row) {
    if($script:Sb.Invulnerable.ContainsKey([string]$Row.StateToken)){return $true}
    $key='{0:X}'-f[uint64]$Row.PlayerState
    if($Row.Side-eq'Ally'-and$script:AllyGodEnabled){return -not $script:TeamGodExclusions.Allies.ContainsKey($key)}
    if($Row.Side-eq'Enemy'-and$script:EnemyGodEnabled){return -not $script:TeamGodExclusions.Enemies.ContainsKey($key)}
    return $false
}
function Sb-ToggleMapGod($Row) {
    $s=Sb-Ship ([int64]$Row.PlayerState);if($null-eq$s){throw 'This ship is dead or waiting to respawn.'}
    $key='{0:X}'-f[uint64]$Row.PlayerState;$isOn=Sb-MapGodState $Row
    if($isOn){
        if($Row.Side-eq'Ally'-and$script:AllyGodEnabled){$script:TeamGodExclusions.Allies[$key]=$true;[void]$script:TeamLocks.Remove($key)}
        elseif($Row.Side-eq'Enemy'-and$script:EnemyGodEnabled){$script:TeamGodExclusions.Enemies[$key]=$true;[void]$script:EnemyLocks.Remove($key)}
        if($script:Sb.Invulnerable.ContainsKey([string]$Row.StateToken)){Sb-God $s $false}
        Sb-Log 'Invulnerability disabled.'
    }else{
        if($Row.Side-eq'Ally'){[void]$script:TeamGodExclusions.Allies.Remove($key)}elseif($Row.Side-eq'Enemy'){[void]$script:TeamGodExclusions.Enemies.Remove($key)}
        if(-not(($Row.Side-eq'Ally'-and$script:AllyGodEnabled)-or($Row.Side-eq'Enemy'-and$script:EnemyGodEnabled))){Sb-God $s $true}
        Sb-Log 'Invulnerability enabled.'
    }
}
function Sb-PaintNativeRoster($g,[Drawing.RectangleF]$Rect,[object[]]$Rows,[string]$Title,[Drawing.Color]$Accent,[string]$RosterKey) {
    $panelBrush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(14,23,29));$cardBrush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(27,38,46));$barBack=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(55,65,72));$white=[Drawing.SolidBrush]::new([Drawing.Color]::White);$muted=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(180,195,205));$border=[Drawing.Pen]::new([Drawing.Color]::FromArgb(90,118,132),1);$selected=[Drawing.Pen]::new([Drawing.Color]::Gold,2.2)
    $titleFont=[Drawing.Font]::new('Segoe UI',11,[Drawing.FontStyle]::Bold);$rowFont=[Drawing.Font]::new('Segoe UI',10,[Drawing.FontStyle]::Bold);$smallFont=[Drawing.Font]::new('Segoe UI',9);$buttonFont=[Drawing.Font]::new('Segoe UI',7,[Drawing.FontStyle]::Bold);$fmt=[Drawing.StringFormat]::new();$fmt.Trimming=[Drawing.StringTrimming]::EllipsisCharacter;$fmt.FormatFlags=[Drawing.StringFormatFlags]::NoWrap;$centerFmt=[Drawing.StringFormat]::new();$centerFmt.Alignment=[Drawing.StringAlignment]::Center;$centerFmt.LineAlignment=[Drawing.StringAlignment]::Center
    try{
        $g.FillRectangle($panelBrush,$Rect);$g.DrawRectangle($border,$Rect.X,$Rect.Y,$Rect.Width,$Rect.Height);$g.DrawString($Title,$titleFont,$white,$Rect.X+8,$Rect.Y+7)
        $teamGodOn=if($RosterKey-eq'Allies'){[bool]$script:AllyGodEnabled}else{[bool]$script:EnemyGodEnabled};$godRect=[Drawing.RectangleF]::new([single]($Rect.Right-82),[single]($Rect.Y+6),76,23);$godBrush=[Drawing.SolidBrush]::new($(if($teamGodOn){[Drawing.Color]::FromArgb(45,125,72)}else{[Drawing.Color]::FromArgb(145,55,55)}));try{$g.FillRectangle($godBrush,$godRect);$g.DrawRectangle($border,$godRect.X,$godRect.Y,$godRect.Width,$godRect.Height);$g.DrawString('TEAM GOD',$buttonFont,$white,$godRect,$centerFmt)}finally{$godBrush.Dispose()};$script:Sb.MapHits+=,[pscustomobject]@{Kind='TeamGod';Team=$RosterKey;Rect=[Drawing.Rectangle]::FromLTRB([int]$godRect.Left,[int]$godRect.Top,[int]$godRect.Right,[int]$godRect.Bottom)}
        $ordered=@(Sb-SortMapRows $Rows);[double]$rowHeight=92;[int]$capacity=[Math]::Max(1,[Math]::Floor(($Rect.Height-42)/$rowHeight));[int]$maxOffset=[Math]::Max(0,$ordered.Count-$capacity);[int]$offset=[Math]::Max(0,[Math]::Min($maxOffset,[int]$script:Sb.MapRosterScroll[$RosterKey]));$script:Sb.MapRosterScroll[$RosterKey]=$offset;[int]$shown=[Math]::Min($capacity,[Math]::Max(0,$ordered.Count-$offset));[double]$scrollSpace=if($maxOffset-gt0){11}else{0}
        for($i=0;$i-lt$shown;$i++){
            $r=$ordered[$offset+$i];$y=$Rect.Y+38+$i*$rowHeight;$card=[Drawing.RectangleF]::new($Rect.X+5,[single]$y,$Rect.Width-10-$scrollSpace,[single]($rowHeight-4));$g.FillRectangle($cardBrush,$card);$g.DrawRectangle($(if([int64]$r.PlayerState-eq$script:Sb.Selected){$selected}else{$border}),$card.X,$card.Y,$card.Width,$card.Height)
            $label=if($null-ne$r.PSObject.Properties['DisplayName']-and-not[string]::IsNullOrWhiteSpace([string]$r.DisplayName)){[string]$r.DisplayName}else{[string]$r.Name}
            $g.DrawString($label,$rowFont,$white,[Drawing.RectangleF]::new($card.X+6,$card.Y+4,$card.Width-12,20),$fmt)
            [double]$max=[Math]::Max(1,[double]$r.MaxHP);[double]$ratio=Sb-HealthRatio $r;$details=if($r.IsAlive){('{0}   {1:0}/{2:0} HP'-f[string]$r.SectorName,[double]$r.HP,$max)}else{('{0}   {1}'-f[string]$r.SectorName,[string]$r.Status)}
            $g.DrawString($details,$smallFont,$muted,[Drawing.RectangleF]::new($card.X+6,$card.Y+26,$card.Width-12,18),$fmt);$bar=[Drawing.RectangleF]::new($card.X+6,$card.Y+47,$card.Width-12,12);$g.FillRectangle($barBack,$bar);$healthBrush=[Drawing.SolidBrush]::new((Sb-HealthColor $ratio ([bool]$r.IsAlive)));try{if($ratio-gt0){$fillWidth=[Math]::Max(2,[single]($bar.Width*$ratio));$g.FillRectangle($healthBrush,$bar.X,$bar.Y,$fillWidth,$bar.Height)}}finally{$healthBrush.Dispose()}
            $godOn=Sb-MapGodState $r;$actions=@(@('HEAL','Heal'),@('KILL','Kill'),@('GOD','GodToggle'))
            [double]$gap=4;[double]$buttonWidth=($card.Width-12-$gap*2)/3.0
            for($bi=0;$bi-lt3;$bi++){$br=[Drawing.RectangleF]::new([single]($card.X+6+$bi*($buttonWidth+$gap)),[single]($card.Y+64),[single]$buttonWidth,18);$enabled=[bool]$r.IsAlive;$buttonColor=if($bi-eq2){if($godOn){[Drawing.Color]::FromArgb(45,125,72)}else{[Drawing.Color]::FromArgb(145,55,55)}}elseif($enabled){[Drawing.Color]::FromArgb(55,72,84)}else{[Drawing.Color]::FromArgb(38,45,50)};$bb=[Drawing.SolidBrush]::new($buttonColor);try{$g.FillRectangle($bb,$br);$g.DrawRectangle($border,$br.X,$br.Y,$br.Width,$br.Height);$g.DrawString([string]$actions[$bi][0],$buttonFont,$(if($enabled){$white}else{$muted}),$br,$centerFmt)}finally{$bb.Dispose()};if($enabled){$script:Sb.MapHits+=,[pscustomobject]@{Kind='Action';Action=[string]$actions[$bi][1];Rect=[Drawing.Rectangle]::FromLTRB([int]$br.Left,[int]$br.Top,[int]$br.Right,[int]$br.Bottom);PlayerState=[int64]$r.PlayerState;Name=$label}}}
            $script:Sb.MapHits+=,[pscustomobject]@{Kind='Ship';Rect=[Drawing.Rectangle]::FromLTRB([int]$card.Left,[int]$card.Top,[int]$card.Right,[int]$card.Bottom);PlayerState=[int64]$r.PlayerState;Name=$label}
        }
        if($maxOffset-gt0){$track=[Drawing.RectangleF]::new([single]($Rect.Right-8),[single]($Rect.Y+38),4,[single]($Rect.Height-44));$g.FillRectangle($barBack,$track);[double]$thumbH=[Math]::Max(24,$track.Height*($capacity/[double]$ordered.Count));[double]$thumbY=$track.Y+($track.Height-$thumbH)*($offset/[double]$maxOffset);$thumb=[Drawing.RectangleF]::new($track.X,[single]$thumbY,$track.Width,[single]$thumbH);$g.FillRectangle($muted,$thumb)}
    }finally{$panelBrush.Dispose();$cardBrush.Dispose();$barBack.Dispose();$white.Dispose();$muted.Dispose();$border.Dispose();$selected.Dispose();$titleFont.Dispose();$rowFont.Dispose();$smallFont.Dispose();$buttonFont.Dispose();$fmt.Dispose();$centerFmt.Dispose()}
}
function Sb-PaintNativeMap($Sender,$g,$Map,[object[]]$Rows) {
    if($null-eq$Map-or@($Map.Sectors).Count-lt1-or($Map.Mode-eq'Conquest'-and@($Map.Sectors).Count-lt5)){return $false}
    $visibleRows=@(Sb-SortMapRows (Sb-MapVisibleRows $Rows));$metrics=Sb-NativeMetrics $Sender;$layouts=Sb-NativeLayouts $Sender $Map
    $viewport=[Drawing.RectangleF]::new([single]$metrics.MapX,[single]$metrics.MapY,[single]$metrics.Side,[single]$metrics.Side)
    $fill=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(18,29,36));$border=[Drawing.Pen]::new([Drawing.Color]::FromArgb(150,176,190),1.4);$active=[Drawing.Pen]::new([Drawing.Color]::FromArgb(88,210,240),2.2)
    $white=[Drawing.SolidBrush]::new([Drawing.Color]::White);$gold=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(238,177,54));$cyan=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(70,184,220))
    $zonePen=[Drawing.Pen]::new([Drawing.Color]::FromArgb(190,205,214),1.6);$jumpPen=[Drawing.Pen]::new([Drawing.Color]::FromArgb(225,230,235),1.6);$selectPen=[Drawing.Pen]::new([Drawing.Color]::Gold,2.6);$selectOuter=[Drawing.Pen]::new([Drawing.Color]::FromArgb(90,220,255),2)
    $playerHeading=[Drawing.Pen]::new([Drawing.Color]::FromArgb(255,225,70),2);$allyHeading=[Drawing.Pen]::new([Drawing.Color]::FromArgb(70,185,230),2);$enemyHeading=[Drawing.Pen]::new([Drawing.Color]::FromArgb(225,75,52),2);$deadPen=[Drawing.Pen]::new([Drawing.Color]::FromArgb(190,190,190),2)
    $titleFont=[Drawing.Font]::new('Segoe UI',10,[Drawing.FontStyle]::Bold);$smallFont=[Drawing.Font]::new('Segoe UI',7,[Drawing.FontStyle]::Bold);$fmt=[Drawing.StringFormat]::new();$fmt.Alignment=[Drawing.StringAlignment]::Center
    try{
        $mapState=$g.Save();$g.SetClip($viewport)
        try{
            foreach($sector in @($Map.Sectors)){
                $rect=$layouts[[string]$sector.Key];if($null-eq$rect){continue};$hasPlayer=@($visibleRows|Where-Object{$_.IsPlayer-and$_.SectorKey-eq$sector.Key}).Count-gt0
                $g.FillRectangle($fill,$rect);$g.DrawRectangle($(if($hasPlayer){$active}else{$border}),$rect.X,$rect.Y,$rect.Width,$rect.Height)
                $script:Sb.MapSectorHits+=,[pscustomobject]@{SectorKey=[string]$sector.Key;Rect=[Drawing.Rectangle]::FromLTRB([int]$rect.Left,[int]$rect.Top,[int]$rect.Right,[int]$rect.Bottom)}
                if($sector.Key-in@('ALPHA','BETA')){$baseName=if($sector.Key-eq'ALPHA'){'Alpha'}else{'Beta'};$topNumber=if([int]$Map.LocalTeam-eq2){'1'}else{'2'};$bottomNumber=if($topNumber-eq'1'){'2'}else{'1'};$g.DrawString(($baseName+' '+$topNumber),$titleFont,$white,[Drawing.RectangleF]::new($rect.X,$rect.Y-21,$rect.Width,20),$fmt);$g.DrawString(($baseName+' '+$bottomNumber),$titleFont,$white,[Drawing.RectangleF]::new($rect.X,$rect.Bottom+2,$rect.Width,20),$fmt)}
                else{$label=[string]$sector.Name;$font=if($sector.Key-in@('T1JUMP','T2JUMP')){$smallFont}else{$titleFont};$g.DrawString($label,$font,$white,[Drawing.RectangleF]::new($rect.X,$rect.Y+4,$rect.Width,20),$fmt)}
            }
            foreach($o in @($Map.Objects)){
                if($o.Kind-eq'Mine'-and$null-ne$sbMapFilterMines-and-not$sbMapFilterMines.Checked){continue}
                if($o.Kind-ne'Mine'-and$null-ne$sbMapFilterBases-and-not$sbMapFilterBases.Checked){continue}
                $pt=Sb-NativePoint $o.Position ([string]$o.SectorKey) $layouts 'Object';if($null-eq$pt){continue}
                switch([string]$o.Kind){'Mine'{$g.FillEllipse($gold,$pt.X-4,$pt.Y-4,8,8);$g.DrawEllipse($zonePen,$pt.X-7,$pt.Y-7,14,14)}'Station'{$g.FillRectangle($cyan,$pt.X-4,$pt.Y-4,8,8);$g.DrawRectangle($zonePen,$pt.X-7,$pt.Y-7,14,14)}'Gamma'{$g.DrawEllipse($zonePen,$pt.X-12,$pt.Y-12,24,24);$g.DrawEllipse($zonePen,$pt.X-7,$pt.Y-7,14,14)}'Base'{$g.DrawEllipse($zonePen,$pt.X-13,$pt.Y-13,26,26);$g.DrawEllipse($zonePen,$pt.X-8,$pt.Y-8,16,16)}}
            }
            if($null-eq$sbMapFilterJumps-or$sbMapFilterJumps.Checked){
                foreach($sectorKey in @($Map.Jumps|ForEach-Object{[string]$_.SectorKey}|Sort-Object -Unique)){
                    $sectorJumps=@($Map.Jumps|Where-Object{$_.SectorKey-eq$sectorKey});$jumpPoints=@()
                    if($sectorKey-in@('ALPHA','BETA')){$stations=@($Map.Objects|Where-Object{$_.SectorKey-eq$sectorKey-and$_.Kind-eq'Station'}|ForEach-Object{Sb-NativePoint $_.Position $sectorKey $layouts 'Object'}|Where-Object{$null-ne$_}|Sort-Object Y);if($stations.Count-gt0){$rect=$layouts[$sectorKey];[single]$dx=[Math]::Max(16.0,[double]$rect.Width*.09);[single]$dy=[Math]::Max(16.0,[double]$rect.Height*.05);for($i=0;$i-lt$sectorJumps.Count;$i++){$stationIndex=[Math]::Min($stations.Count-1,[Math]::Floor($i/4));$station=$stations[$stationIndex];$slot=$i%4;$outer=if($stationIndex-eq0){-[double]$dy}else{[double]$dy};switch($slot){0{$jumpPoints+=,[Drawing.PointF]::new([single]($station.X-$dx),[single]($station.Y+$outer))}1{$jumpPoints+=,[Drawing.PointF]::new([single]($station.X+$dx),[single]($station.Y+$outer))}2{$jumpPoints+=,[Drawing.PointF]::new([single]($station.X-$dx*1.35),[single]$station.Y)}3{$jumpPoints+=,[Drawing.PointF]::new([single]($station.X+$dx*1.35),[single]$station.Y)}}}}}
                    if($jumpPoints.Count-eq0){$jumpPoints=@($sectorJumps|ForEach-Object{Sb-NativePoint $_.Position $sectorKey $layouts 'Jump'}|Where-Object{$null-ne$_})}
                    foreach($pt in $jumpPoints){$points=[Drawing.PointF[]]@([Drawing.PointF]::new($pt.X,$pt.Y-6),[Drawing.PointF]::new($pt.X+6,$pt.Y),[Drawing.PointF]::new($pt.X,$pt.Y+6),[Drawing.PointF]::new($pt.X-6,$pt.Y));$g.DrawPolygon($jumpPen,$points)}
                }
            }
            $placements=@();foreach($r in $visibleRows){$pt=Sb-NativePoint $r.Position ([string]$r.SectorKey) $layouts;if($null-ne$pt){$placements+=,[pscustomobject]@{Row=$r;DrawX=[double]$pt.X;DrawY=[double]$pt.Y}}}
            foreach($p in $placements){$r=$p.Row;$x=[int]$p.DrawX;$y=[int]$p.DrawY;if(-not$viewport.Contains([single]$x,[single]$y)){continue}
                $img=$script:Sb.MapIcons[$r.Side];$heading=$r.Heading
                if($r.IsAlive-and$null-ne$img-and$null-ne$heading){[double]$angle=if([int]$Map.LocalTeam-eq2){[double]$heading+90.0}else{[double]$heading-90.0};while($angle-gt180){$angle-=360};while($angle-lt-180){$angle+=360};$state=$g.Save();$g.TranslateTransform([single]$x,[single]$y);$g.RotateTransform([single]$angle);$headingPen=if($r.Side-eq'Enemy'){$enemyHeading}elseif($r.Side-eq'Ally'){$allyHeading}else{$playerHeading};$g.DrawLine($headingPen,0,-8,0,-19);$g.DrawImage($img,-12,-14,24,28);$g.Restore($state)}elseif($null-ne$img){$g.DrawImage($img,$x-12,$y-14,24,28)}else{$g.FillEllipse($white,$x-5,$y-5,10,10)}
                if(-not$r.IsAlive){$g.DrawLine($deadPen,$x-10,$y-10,$x+10,$y+10);$g.DrawLine($deadPen,$x+10,$y-10,$x-10,$y+10)}
                if([int64]$r.PlayerState-eq$script:Sb.Selected){$g.DrawEllipse($selectOuter,$x-19,$y-20,38,40);$g.DrawEllipse($selectPen,$x-15,$y-16,30,32)}
                $mapLabel=[string]$r.DisplayName;$hit=[Drawing.Rectangle]::FromLTRB($x-19,$y-21,$x+19,$y+21);$script:Sb.MapHits+=,[pscustomobject]@{Kind='Ship';Rect=$hit;PlayerState=[int64]$r.PlayerState;Name=$mapLabel}
            }
        }finally{$g.Restore($mapState)}
        $allies=@($visibleRows|Where-Object{$_.Side-in@('Player','Ally')});$enemies=@($visibleRows|Where-Object{$_.Side-eq'Enemy'});Sb-PaintNativeRoster $g $metrics.LeftRoster $allies 'ALLIES' ([Drawing.Color]::FromArgb(55,178,220)) 'Allies';Sb-PaintNativeRoster $g $metrics.RightRoster $enemies 'ENEMIES' ([Drawing.Color]::FromArgb(210,72,52)) 'Enemies'
    }finally{$fill.Dispose();$border.Dispose();$active.Dispose();$white.Dispose();$gold.Dispose();$cyan.Dispose();$zonePen.Dispose();$jumpPen.Dispose();$selectPen.Dispose();$selectOuter.Dispose();$playerHeading.Dispose();$allyHeading.Dispose();$enemyHeading.Dispose();$deadPen.Dispose();$titleFont.Dispose();$smallFont.Dispose();$fmt.Dispose()}
    return $true
}
function Sb-PaintMap($Sender,$EventArgs) {
    $g=$EventArgs.Graphics;$g.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias;$g.Clear([Drawing.Color]::FromArgb(7,14,19))
    $script:Sb.MapHits=@();$script:Sb.MapSectorHits=@();$rows=@($script:Sb.MapRows)
    if($null-ne$script:Sb.NativeMap-and(Sb-PaintNativeMap $Sender $g $script:Sb.NativeMap $rows)){return}
    if($rows.Count-eq0){$font=[Drawing.Font]::new('Segoe UI',12);$brush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(150,160,170));try{$g.DrawString('Waiting for live ship positions...',$font,$brush,22,22)}finally{$font.Dispose();$brush.Dispose()};return}
    $hud=Sb-ReadHudMap;if($null-ne$hud-and(Sb-PaintHudMap $Sender $g $hud $rows)){return}
    $border=[Drawing.Pen]::new([Drawing.Color]::FromArgb(150,176,190),1.4);$playerBorder=[Drawing.Pen]::new([Drawing.Color]::FromArgb(105,215,245),2.2)
    $fill=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(18,29,36));$titleBrush=[Drawing.SolidBrush]::new([Drawing.Color]::White);$nameBrush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(238,242,245));$shadow=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(210,0,0,0));$selectPen=[Drawing.Pen]::new([Drawing.Color]::Gold,2)
    $titleFont=[Drawing.Font]::new('Segoe UI',10,[Drawing.FontStyle]::Bold);$nameFont=[Drawing.Font]::new('Segoe UI',8,[Drawing.FontStyle]::Bold);$fmt=[Drawing.StringFormat]::new();$fmt.Alignment=[Drawing.StringAlignment]::Center
    try{
        foreach($layout in @(Sb-MapLayouts $Sender.ClientSize.Width $Sender.ClientSize.Height $rows)){
            $rect=$layout.Rect;$groupRows=@($layout.Group.Group);$hasPlayer=@($groupRows|Where-Object{$_.IsPlayer}).Count-gt0
            $g.FillRectangle($fill,$rect);$g.DrawRectangle($(if($hasPlayer){$playerBorder}else{$border}),$rect.X,$rect.Y,$rect.Width,$rect.Height)
            $label=[string]$groupRows[0].SectorName;$titleRect=[Drawing.RectangleF]::new($rect.X,$rect.Y+5,$rect.Width,22);$g.DrawString($label,$titleFont,$titleBrush,$titleRect,$fmt)
            $bounds=$script:Sb.MapBounds[$layout.Group.Name];if($null-eq$bounds){continue}
            $inner=[Drawing.RectangleF]::new($rect.X+16,$rect.Y+35,[Math]::Max(20,$rect.Width-32),[Math]::Max(20,$rect.Height-52))
            foreach($r in $groupRows){
                $nx=([double]$r.Position[0]-$bounds.MinX)/[Math]::Max(1.0,$bounds.MaxX-$bounds.MinX);$ny=1.0-(([double]$r.Position[1]-$bounds.MinY)/[Math]::Max(1.0,$bounds.MaxY-$bounds.MinY))
                $nx=[Math]::Max(0.0,[Math]::Min(1.0,$nx));$ny=[Math]::Max(0.0,[Math]::Min(1.0,$ny));$x=[int]($inner.X+$nx*$inner.Width);$y=[int]($inner.Y+$ny*$inner.Height)
                $img=$script:Sb.MapIcons[$r.Side];if($null-ne$img){$g.DrawImage($img,$x-11,$y-12,22,26)}else{$brush=[Drawing.SolidBrush]::new($(if($r.Side-eq'Enemy'){[Drawing.Color]::FromArgb(205,73,53)}elseif($r.Side-eq'Ally'){[Drawing.Color]::FromArgb(70,165,205)}else{[Drawing.Color]::White}));try{$g.FillEllipse($brush,$x-6,$y-6,12,12)}finally{$brush.Dispose()}}
                if([int64]$r.PlayerState-eq$script:Sb.Selected){$g.DrawEllipse($selectPen,$x-14,$y-15,28,30)}
                $size=$g.MeasureString([string]$r.Name,$nameFont);$nameRect=[Drawing.RectangleF]::new([single]($x-[Math]::Max(28,$size.Width/2+4)),[single]($y-29),[single][Math]::Max(56,$size.Width+8),18)
                $g.FillRectangle($shadow,$nameRect);$g.DrawString([string]$r.Name,$nameFont,$nameBrush,$nameRect,$fmt)
                $hit=[Drawing.Rectangle]::FromLTRB([int]$nameRect.Left,[int]$nameRect.Top,[int]$nameRect.Right,[int]($y+15));$script:Sb.MapHits+=,[pscustomobject]@{Rect=$hit;PlayerState=[int64]$r.PlayerState;Name=[string]$r.Name}
            }
        }
    }finally{$border.Dispose();$playerBorder.Dispose();$fill.Dispose();$titleBrush.Dispose();$nameBrush.Dispose();$shadow.Dispose();$selectPen.Dispose();$titleFont.Dispose();$nameFont.Dispose();$fmt.Dispose()}
}
function Sb-MapActionForState([string]$Action,[int64]$State,[int]$Difficulty=-1) {
    if($State-le0){throw 'Select a ship first.'};$script:Sb.Selected=$State;Sb-UpdateMapSelectedInfo
    $row=@($script:Sb.MapRows|Where-Object{[int64]$_.PlayerState-eq$State}|Select-Object -First 1)
    if($Action-eq'Select'){if($row.Count-gt0){Sb-Log ('Selected '+$row[0].DisplayName)};if($null-ne$sbMapPanel){$sbMapPanel.Invalidate()};return}
    if($Action-eq'Center'){Sb-CenterSelectedOnMap;return}
    if($Action-eq'Inspect'){$sbTabs.SelectedTab=$sbInspectTab;Sb-RefreshInspector;return}
    $s=Sb-Ship $State;if($null-eq$s){throw 'This ship is dead or waiting to respawn. Live-ship actions are unavailable.'}
    switch($Action){
        'Heal'{Sb-Heal $s;Sb-Log ('Healed '+$s.PlayerState)}
        'Kill'{Sb-Kill $s;Sb-Log 'Lethal damage applied.'}
        'GodOn'{Sb-God $s $true;Sb-Log 'Invulnerability enabled.'}
        'GodOff'{Sb-God $s $false;Sb-Log 'Invulnerability disabled.'}
        'GodToggle'{if($row.Count-eq0){throw 'Ship information is unavailable.'};Sb-ToggleMapGod $row[0]}
        'Restore'{Sb-RestoreSelected $s}
        'Clone'{Sb-Clone 1}
        'AI'{Sb-SetDifficulty $s $Difficulty;Sb-Log 'Bot difficulty changed.'}
    }
    Sb-UpdateMapSelectedInfo;if($null-ne$sbMapPanel){$sbMapPanel.Invalidate()}
}
function Sb-MapAction([string]$Action,[int]$Difficulty=-1) {
    Sb-MapActionForState $Action ([int64]$sbMapMenu.Tag) $Difficulty
}
function Sb-DeleteSelectedComplete {
    [void](Sb-Require)
    $state=[int64]$script:Sb.Selected
    $row=@(@(Get-LiveAllyRows)+@(Get-LiveEnemyRows)|Where-Object{[int64]$_.PlayerState-eq$state}|Select-Object -First 1)
    if($row.Count-eq0){throw 'Select a live bot.'}
    if(-not(Invoke-DeleteAllyRow $row[0])){throw (Get-ActorDeleteErrorText ([NativeMemoryV4]::LastActorDeleteError))}
    $script:LastRosterSignature='';$script:LastEnemyRosterSignature='';Refresh-AllyRosterUI $true;Refresh-EnemyRosterUI $true;$script:NextRosterRefreshAt=[DateTime]::UtcNow.AddSeconds(2)
    Sb-Log ('Deleted '+$row[0].Ship+' completely.')
}
function Sb-SaveScenario {
    [void](Sb-Require)
    $ships=@()
    foreach ($ps in @($script:PlayerStateAddresses)) {
        $s=Sb-Ship $ps
        if ($null -eq $s -or $s.IsPlayer) { continue }
        $n=Get-ShipNameFromPlayerState $ps $s.Pawn
        if (-not $SHIP_GUIDS.Contains($n)) { continue }
        $local=Sb-GetLocalContext
        $d=Read-U8 ([IntPtr]($s.Controller+$BOT_DIFFICULTY_TYPE_OFFSET))
        if ($null -eq $d -or $d -gt 9) { continue }
        $ships += [pscustomobject]@{Ship=$n;Side=$(if($s.Team -eq $local.Team){'Ally'}else{'Enemy'});Difficulty=[int]$d;Count=1;God=$script:Sb.Invulnerable.ContainsKey($s.StateToken)}
    }
    if ($ships.Count -eq 0) { throw 'No supported bots to save.' }
    [void](Sb-Export ([ordered]@{Version=1;Ships=$ships}) 'scenario')
}
function Sb-LoadScenario {
    [void](Sb-Require)
    $dlg=New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter='Scenario JSON|*.json'; $dlg.InitialDirectory=$script:SbDataDir
    try {
        if ($dlg.ShowDialog() -ne 'OK') { return }
        $f=Get-Item -LiteralPath $dlg.FileName
        if ($f.Length -gt 1048576) { throw 'Scenario file too large.' }
        $obj=Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
        if ($obj.Version -ne 1 -or $null -eq $obj.Ships) { throw 'Unsupported scenario format.' }
        $validated=@(); $total=0
        foreach ($e in @($obj.Ships)) {
            if (-not $SHIP_GUIDS.Contains([string]$e.Ship) -or $e.Side -notin @('Ally','Enemy')) { throw 'Unknown ship or team in scenario.' }
            if ($e.Difficulty -isnot [long] -and $e.Difficulty -isnot [int]) { throw 'Difficulty must be an integer.' }
            if ($e.Count -isnot [long] -and $e.Count -isnot [int]) { throw 'Count must be an integer.' }
            if ($e.Difficulty -lt 0 -or $e.Difficulty -gt 9 -or $e.Count -lt 1 -or $e.Count -gt 40 -or $e.God -isnot [bool]) { throw 'Invalid scenario values.' }
            $total += $e.Count; $validated += $e
        }
        if ($total -lt 1 -or $total+$script:Sb.Queue.Count -gt 40) { throw 'Scenario exceeds the 40-ship queue limit.' }
        $custom=if($null-ne$sbCustomOnSpawn-and$sbCustomOnSpawn.Checked){Sb-GetCustomStatsConfig}else{$null}
        foreach ($e in $validated) { Sb-QueueShip $e.Ship $e.Side $e.Difficulty $e.Count $e.God $false $custom }
    } finally { $dlg.Dispose() }
}
function Sb-Entities {
    [void](Sb-Require)
    $level=$script:Sb.Level
    $data=Read-U64 ([IntPtr]($level+0x28)); $num=Read-I32 ([IntPtr]($level+0x30))
    if (-not (Is-PlausiblePointer $data) -or $num -lt 0 -or $num -gt 12000) { throw 'Actor list unavailable.' }
    $bytes=Read-Bytes ([IntPtr]$data) ($num*8)
    if ($null -eq $bytes) { throw 'Could not read actor list.' }
    $script:Sb.WorldSettings=0L
    for ($i=0; $i -lt $num; $i++) {
        $p=[BitConverter]::ToInt64($bytes,$i*8)
        if (-not (Is-PlausiblePointer $p)) { continue }
        $cl=Get-PawnClassName $p
        if ($cl -eq 'WorldSettings') { $script:Sb.WorldSettings=$p; break }
    }
    if($script:Sb.WorldSettings -le 0){throw 'WorldSettings not found in this level.'}
}
function Sb-EnsureBeamTimeFix {
    [void](Sb-Require)
    $ok=[NativeMemoryV4]::ApplyBeamTimeDilationFix(
        $script:ProcessHandle,
        [uint64]$script:ModuleBase.ToInt64())
    if(-not $ok){throw(Sb-NativeError 'Beam time-dilation repair')}
}
function Sb-MatchTime([single]$Value) {
    [void](Sb-Require)
    if ($Value -lt 0.05 -or $Value -gt 5) { throw 'Match speed must be 0.05 to 5.' }
    Sb-EnsureBeamTimeFix
    if ($script:Sb.WorldSettings -le 0) {
        $candidate=Read-U64 ([IntPtr]($script:Sb.Level+0x300))
        if ((Is-PlausiblePointer $candidate) -and (Get-PawnClassName ([int64]$candidate)) -eq 'WorldSettings') { $script:Sb.WorldSettings=[int64]$candidate }
    }
    if ($script:Sb.WorldSettings -le 0) { Sb-Entities }
    $p=$script:Sb.WorldSettings
    if ($p -le 0 -or (Get-PawnClassName $p) -ne 'WorldSettings') { throw 'WorldSettings not found in this level.' }
    Sb-WriteSetting $p 0x490 $Value 'Match speed'
    Sb-Log ('Match speed x' + $Value)
}
function Sb-RefreshRows {
    $local=Sb-GetLocalContext
    if ($null -eq $local) { return }
    $rows=@()
    foreach ($ps in @(@($local.PlayerState)+@($script:PlayerStateAddresses) | Sort-Object -Unique)) {
        $s=Sb-Ship $ps
        if ($null -eq $s) { continue }
        $rows += $s
    }
    $script:Sb.Rows=$rows
    $topState=0L
    try{if($sbShips.Items.Count-gt0-and$null-ne$sbShips.TopItem-and$null-ne$sbShips.TopItem.Tag){$topState=[int64]$sbShips.TopItem.Tag}}catch{}
    $sbShips.BeginUpdate(); $sbShips.Items.Clear()
    try {
        foreach ($s in $rows) {
            $name=Get-ShipNameFromPlayerState $s.PlayerState $s.Pawn
            $side=if($s.IsPlayer){'Player'}elseif($s.Team -eq $local.Team){'Ally'}else{'Enemy'}
            if ($sbTeamFilter.SelectedItem -ne 'All' -and $side -ne $sbTeamFilter.SelectedItem) { continue }
            $it=New-Object System.Windows.Forms.ListViewItem($name)
            [void]$it.SubItems.Add($side); [void]$it.SubItems.Add(('{0:0}' -f $s.HP)); [void]$it.SubItems.Add($(if($s.IsPlayer){'Player'}else{Get-ActualBotDifficultyName $s.Controller}))
            $it.Tag=$s.PlayerState; [void]$sbShips.Items.Add($it)
            if($s.PlayerState -eq $script:Sb.Selected){$it.Selected=$true}
        }
    } finally { $sbShips.EndUpdate() }
    if($topState-gt0){for($i=0;$i-lt$sbShips.Items.Count;$i++){if([int64]$sbShips.Items[$i].Tag-eq$topState){$sbShips.TopItem=$sbShips.Items[$i];break}}}
    $live=@{}
    foreach($s in $rows){$live[$s.Token]=$true}
    foreach($key in @($live.Keys)){if(-not $script:Sb.Seen.ContainsKey($key)){Sb-Log ('Ship appeared: '+$key.Split(':')[0])}}
    foreach($key in @($script:Sb.Seen.Keys)){if(-not $live.ContainsKey($key)){Sb-Log ('Ship left roster: '+$key.Split(':')[0])}}
    $script:Sb.Seen=$live
    $subtitle.Text=('Ships: {0}  | Queue: {1}  | Session: {2:hh\:mm\:ss}' -f $rows.Count,$script:Sb.Queue.Count,([DateTime]::UtcNow-$script:Sb.SessionStart))
    $sbQueueLabel.Text='Pending: '+$script:Sb.Queue.Count+' | Recent: '+($script:Sb.Recent -join ', ')
}
function Sb-RefreshInspector {
    $s=Sb-Ship $script:Sb.Selected
    if($null -eq $s){
        $cached=@($script:Sb.MapRows|Where-Object{[int64]$_.PlayerState-eq[int64]$script:Sb.Selected}|Select-Object -First 1)
        if($cached.Count-gt0){$r=$cached[0];$sbDetails.Text=('Ship: {0}\r\nPilot: {1}\r\nSide: {2}\r\nStatus: {3}\r\nLast sector: {4}\r\nHP: 0 / {5:0}\r\n\r\nThis ship is dead or waiting to respawn. Live actions are disabled until a new Pawn appears.' -f$r.Name,$r.Pilot,$r.Side,$r.Status,$r.SectorName,[double]$r.MaxHP).Replace('\r\n',[Environment]::NewLine)}else{$sbDetails.Text='Select a ship, or click SELECT PLAYER.'};return
    }
    $d=Sb-Describe $s
    $position=if($null -eq $d.Position){'Unavailable'}else{'X {0:0}   Y {1:0}   Z {2:0}' -f $d.Position[0],$d.Position[1],$d.Position[2]}
    $sbDetails.Text=('Ship: {0}\r\nPilot: {1}\r\nSide: {2}\r\nAI: {3}\r\nHP: {4:0} / {5:0}\r\nPosition: {6}\r\nInvulnerable: {7}' -f $d.Ship,$d.Pilot,$d.Side,$d.Difficulty,$d.HP,$d.MaxHP,$position,$d.Invulnerable).Replace('\r\n',[Environment]::NewLine)
    if(-not $s.IsPlayer){$diff=Read-U8 ([IntPtr]($s.Controller+$BOT_DIFFICULTY_TYPE_OFFSET));if($null -ne $diff -and $diff -le 9 -and -not $sbAiDiff.Focused){$sbAiDiff.SelectedIndex=[int]$diff}}
}
function Sb-Tick {
    if($script:Sb.UiBusy){return}
    $script:Sb.UiBusy=$true
    try {
        if($script:Sb.MapDrag-and-not[Windows.Forms.Control]::MouseButtons.HasFlag([Windows.Forms.MouseButtons]::Left)){$script:Sb.MapDrag=$false;$script:Sb.MapDragPoint=$null;if($null-ne$sbMapPanel){$sbMapPanel.Capture=$false;$sbMapPanel.Cursor='Hand';$sbMapPanel.Invalidate()}}
        if($script:ConnectedProcessId -le 0 -or $script:ProcessHandle -eq [IntPtr]::Zero){return}
        $local=Sb-GetLocalContext
        if($null -eq $local){return}
        $level=if($local.Alive){[int64]$local.Level}else{[int64]$script:Sb.Level}
        if($script:Sb.Pid -ne $script:ConnectedProcessId -or $script:Sb.Level -ne $level){
            if(-not $local.Alive){return}
            $script:Sb.Verified=$false; $script:Sb.Invulnerable=@{}; $script:Sb.Originals=@{}; $script:Sb.Queue.Clear(); $script:Sb.PendingGod=@{}; $script:Sb.PendingBoss=@{}; $script:Sb.PendingCustom=@{}; $script:Sb.PendingSelfCustom=$null; $script:Sb.CustomProfiles=@{};$script:Sb.CustomDrafts=@{};$script:Sb.CustomAppliedMax=@{};$script:Sb.UsedBotNames=@{};$script:Sb.NextCustomProfile=[DateTime]::MinValue;$script:Sb.CustomShipChoiceStates=@();$script:Sb.CustomShipListSignature='';$script:Sb.Wave=$null; $script:Sb.DesiredRespawnShip=''
            $script:Sb.History=@(); $script:Sb.Seen=@{}; $script:Sb.Selected=[int64]$local.PlayerState; $script:Sb.EntityRows=@(); $script:Sb.WorldSettings=0L
            $script:Sb.MapRows=@();$script:Sb.MapHits=@();$script:Sb.MapSectorHits=@();$script:Sb.MapKnown=@{};$script:Sb.MapMaxHp=@{};$script:Sb.MapRosterScroll=@{Allies=0;Enemies=0};$script:Sb.MapSectorByPawn=@{};$script:Sb.MapSectorNames=@{};$script:Sb.MapBounds=@{};$script:Sb.MapZoom=1.0;$script:Sb.MapTargetZoom=1.0;$script:Sb.MapZoomAnchor=$null;$script:Sb.MapPanX=0.0;$script:Sb.MapPanY=0.0;$script:Sb.MapFocusSector='';$script:Sb.NativeMap=$null;$script:Sb.NextNativeMap=[DateTime]::MinValue;$script:Sb.GNames=0L;$script:Sb.FNameCache=@{};$script:Sb.NextMap=[DateTime]::MinValue
            $script:Sb.Pid=$script:ConnectedProcessId; $script:Sb.Level=$level; $script:Sb.SessionStart=[DateTime]::UtcNow
            $file=$script:ServerProcess.MainModule.FileName
            $actual=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
            if($actual -ne $script:SbBuildHash){throw 'Unsupported spserver build. Sandbox writes disabled.'}
            $script:Sb.Verified=$true; Sb-Log 'Solo server verified.'
        }
        if(-not $script:Sb.Verified){return}
        foreach($key in @($script:Sb.Invulnerable.Keys)){$e=$script:Sb.Invulnerable[$key];$s=Sb-Ship $e.State;if($null -eq $s -or $s.StateToken -ne $e.StateToken -or $s.Token -ne $e.PawnToken -or $s.HP -le 0){$script:Sb.Invulnerable.Remove($key)}}
        foreach($key in @($script:Sb.PendingGod.Keys)){
            $e=$script:Sb.PendingGod[$key]; $ctrl=[int64]$key
            if([DateTime]::UtcNow -gt $e.Until -or (Sb-Token $ctrl) -ne $e.Token){$script:Sb.PendingGod.Remove($key);continue}
            $ps=Read-U64 ([IntPtr]($ctrl+$CONTROLLER_PLAYERSTATE_OFFSET)); $s=Sb-Ship $ps
            if($null -ne $s -and $s.HP -gt 0){Sb-God $s $true;$script:Sb.PendingGod.Remove($key)}
        }
        foreach($key in @($script:Sb.PendingBoss.Keys)){
            $e=$script:Sb.PendingBoss[$key]; $ctrl=[int64]$key
            if([DateTime]::UtcNow -gt $e.Until -or (Sb-Token $ctrl) -ne $e.Token){
                Sb-Log ('Last Stand Boss buff timed out for '+$e.Ship)
                $script:Sb.PendingBoss.Remove($key)
                continue
            }
            $ps=Read-U64 ([IntPtr]($ctrl+$CONTROLLER_PLAYERSTATE_OFFSET)); $s=Sb-Ship $ps
            if($null -ne $s -and $s.HP -gt 0){
                Sb-ApplyLastStandBoss $s ([string]$e.Ship)
                $script:Sb.PendingBoss.Remove($key)
                Sb-Log ('Last Stand Boss buff applied: '+$e.Ship)
            }
        }
        foreach($key in @($script:Sb.PendingCustom.Keys)){
            $e=$script:Sb.PendingCustom[$key]; $ctrl=[int64]$key
            if([DateTime]::UtcNow -gt $e.Until -or (Sb-Token $ctrl) -ne $e.Token){
                Sb-Log ('Custom Stats timed out for '+$e.Ship)
                $script:Sb.PendingCustom.Remove($key)
                continue
            }
            if([DateTime]::UtcNow-lt[DateTime]$e.ReadyAfter){continue}
            $ps=Read-U64 ([IntPtr]($ctrl+$CONTROLLER_PLAYERSTATE_OFFSET)); $s=Sb-Ship $ps
            if($null -ne $s -and $s.HP -gt 0){
                Sb-ApplyCustomStats $s $e.Config ([string]$e.Ship)
                if([bool]$e.Config.Persistent){
                    $pilot=Get-PlayerStateName $s.PlayerState
                    $script:Sb.CustomProfiles[[string]$s.PlayerState]=@{StateToken=[string]$s.StateToken;LastPawnToken=[string]$s.Token;CandidateToken='';ReadyAfter=[DateTime]::MinValue;Config=$e.Config;Persistent=$true;Ship=[string]$e.Ship;Pilot=[string]$pilot}
                    Sb-Log ('Every-respawn Custom Stats profile kept for '+$pilot+' / '+$e.Ship)
                }
                $script:Sb.PendingCustom.Remove($key)
            }
        }
        if($null -ne $script:Sb.PendingSelfCustom){
            $e=$script:Sb.PendingSelfCustom

            if([DateTime]::UtcNow -gt $e.Until){
                Sb-Log 'Custom Stats next-respawn request timed out.'
                $script:Sb.PendingSelfCustom=$null
            } else {
                $me=Sb-Ship ([int64]$local.PlayerState)

                $isReplacement=(
                    $null -ne $me -and
                    $me.HP -gt 0 -and
                    [int64]$me.Pawn -gt 0 -and
                    ([int64]$e.OldPawn -le 0 -or [int64]$me.Pawn -ne [int64]$e.OldPawn)
                )

                if($isReplacement){
                    $receiver=Read-U64 ([IntPtr](([int64]$me.Pawn)+0x650))
                    $liveGuid=Get-NativeShipGuid ([int64]$me.Pawn)
                    if($null-eq$liveGuid){$liveGuid=''}
                    $liveGuid=([string]$liveGuid).ToUpperInvariant()

                    $ready=(
                        (Is-PlausiblePointer ([int64]$receiver)) -and
                        -not [string]::IsNullOrWhiteSpace($liveGuid)
                    )

                    if($ready){
                        $confirm=Sb-Ship ([int64]$local.PlayerState)
                        $confirmReceiver=if($null-ne$confirm){Read-U64 ([IntPtr](([int64]$confirm.Pawn)+0x650))}else{0}
                        $confirmGuid=if($null-ne$confirm){Get-NativeShipGuid ([int64]$confirm.Pawn)}else{''}
                        if($null-eq$confirmGuid){$confirmGuid=''}
                        $confirmGuid=([string]$confirmGuid).ToUpperInvariant()

                        if($null-ne$confirm -and
                           [int64]$confirm.Pawn -eq [int64]$me.Pawn -and
                           [int64]$confirmReceiver -eq [int64]$receiver -and
                           $confirmGuid -eq $liveGuid -and
                           $confirm.HP -gt 0){

                            # One-shot safety: remove the pending request before
                            # entering native code, so a failed call cannot loop.
                            $cfg=$e.Config
                            $script:Sb.PendingSelfCustom=$null
                            try {
                                Sb-ApplyCustomStats $confirm $cfg 'player after respawn'
                            } catch {
                                Sb-Log ('Custom Stats auto-apply stopped after one failed native call: '+$_.Exception.Message)
                            }
                        }
                    } elseif(-not [bool]$e.WaitingLogged){
                        $e.WaitingLogged=$true
                        Sb-Log 'Custom Stats: new Pawn detected; waiting only for receiver/GUID readiness...'
                    }
                }
            }
        }
        Sb-ProcessCustomProfiles
        Sb-SpawnNext
        if($null -ne $script:Sb.Wave -and $script:Sb.Queue.Count -eq 0 -and [DateTime]::UtcNow -ge $script:Sb.Wave.Next){
            $w=$script:Sb.Wave
            if($w.Current -ge $w.Total){$script:Sb.Wave=$null;Sb-Log 'All scheduled waves spawned.'}
            else {
                $w.Current++; $count=[Math]::Min(20,$w.Base+$w.Step*($w.Current-1))
                for($i=0;$i -lt $count;$i++){ $name=if($w.RandomShips){Get-Random -InputObject @($SHIP_GUIDS.Keys)}else{$w.Ship};$difficulty=if($w.RandomDifficulties){Get-Random -Minimum 0 -Maximum 10}else{$w.Difficulty};Sb-QueueShip $name 'Enemy' $difficulty 1 $false $false $w.Custom }
                $w.Next=[DateTime]::UtcNow.AddSeconds($w.Delay); Sb-Log ('Wave '+$w.Current+'/'+$w.Total)
            }
        }
        $mapInteracting=$script:Sb.MapDrag-or($null-ne$sbMapZoomTimer-and$sbMapZoomTimer.Enabled)
        if(-not$mapInteracting-and[DateTime]::UtcNow -ge $script:Sb.NextUi){
            $script:Sb.NextUi=[DateTime]::UtcNow.AddSeconds(1)
            Sb-RefreshRows
            if($sbTabs.SelectedTab -eq $sbInspectTab){Sb-RefreshInspector}
            if($sbTabs.SelectedTab -eq $sbStatsTab){Sb-RefreshMapData;Sb-UpdateCustomTargetUi}
        }
        if([DateTime]::UtcNow -ge $script:Sb.NextMap){
            $script:Sb.NextMap=[DateTime]::UtcNow.AddMilliseconds($(if($mapInteracting){450}else{150}))
            Sb-RefreshMapData
        }
    } catch {
        if($script:Sb.LastError -ne $_.Exception.Message){$script:Sb.LastError=$_.Exception.Message;Sb-Log $script:Sb.LastError}
    } finally {$script:Sb.UiBusy=$false}
}
function Sb-Control([string]$Type,$Parent,[string]$Text,[int]$X,[int]$Y,[int]$W,[int]$H) {
    $c=New-Object ('System.Windows.Forms.'+$Type)
    $c.Text=$Text; $c.Location=New-Object System.Drawing.Point($X,$Y);$c.Size=New-Object System.Drawing.Size($W,$H)
    $c.Font=New-Object System.Drawing.Font('Segoe UI',9)
    $c.BackColor=[Drawing.Color]::FromArgb(38,43,51);$c.ForeColor=[Drawing.Color]::White
    $Parent.Controls.Add($c)
    return $c
}
function Sb-Button($Parent,[string]$Text,[int]$X,[int]$Y,[int]$W,[scriptblock]$Action) {
    $c=Sb-Control 'Button' $Parent $Text $X $Y $W 34
    $c.FlatStyle='Flat';$c.Tag=$Action;$c.Add_Click({Sb-Log ('Action: '+$this.Text);Sb-Run $this.Tag})
    return $c
}
function Sb-Combo($Parent,[int]$X,[int]$Y,[int]$W,[object[]]$Items) {
    $c=Sb-Control 'ComboBox' $Parent '' $X $Y $W 28
    $c.DropDownStyle='DropDownList';$c.MaxDropDownItems=18
    [void]$c.Items.AddRange($Items);if($c.Items.Count -gt 0){$c.SelectedIndex=0}
    return $c
}
function Sb-Number($Parent,[int]$X,[int]$Y,[decimal]$Min,[decimal]$Max,[decimal]$Value,[int]$Decimals=0,[int]$Width=125) {
    $c=Sb-Control 'NumericUpDown' $Parent '' $X $Y $Width 28
    $c.Minimum=$Min;$c.Maximum=$Max;$c.DecimalPlaces=$Decimals;$c.Value=$Value
    if($Decimals -gt 0){$c.Increment=[decimal]0.05}
    return $c
}
function Sb-Tab([string]$Name) {
    $p=New-Object System.Windows.Forms.TabPage($Name);$p.BackColor=$form.BackColor;$p.ForeColor=$form.ForeColor;$p.AutoScroll=$true
    [void]$sbTabs.TabPages.Add($p);return $p
}
$form.Text='Fractured Space - Solo Sandbox (v20)'
$form.Size=New-Object Drawing.Size(1600,960);$form.MinimumSize=New-Object Drawing.Size(1500,760);$form.FormBorderStyle='Sizable';$form.MaximizeBox=$true
$sbWorkspace=Sb-Control 'SplitContainer' $form '' 12 115 1558 750
$sbWorkspace.Anchor='Top,Bottom,Left,Right';$sbWorkspace.Orientation='Vertical';$sbWorkspace.SplitterWidth=6;$sbWorkspace.Panel1MinSize=600;$sbWorkspace.Panel2MinSize=720;$sbWorkspace.SplitterDistance=800
$sbWorkspace.Panel1.BackColor=$form.BackColor;$sbWorkspace.Panel2.BackColor=$form.BackColor
$sbTabs=Sb-Control 'TabControl' $sbWorkspace.Panel1 '' 0 0 620 750
$sbTabs.Dock='Fill'
$sbTeamsTab=Sb-Tab 'TEAMS'
foreach($c in @($form.Controls | Where-Object { $_ -ne $sbWorkspace -and $_.Top -ge 112 })){
    $form.Controls.Remove($c);$sbTeamsTab.Controls.Add($c);$c.Top-=112
}
$sbInspectTab=$sbTeamsTab
$sbSpawnTab=Sb-Tab 'SPAWNER / SCENARIOS'
$sbStatsTab=Sb-Tab 'CUSTOM STATS / RESPAWN'
$sbScenarioTab=$sbSpawnTab
$sbDebugTab=Sb-Tab 'DEBUG'
$sbMessage=Sb-Control 'Label' $form 'Start a local solo match.' 15 873 1550 38
$sbMessage.Anchor='Bottom,Left,Right'
$sbLog=Sb-Control 'TextBox' $sbDebugTab '' 15 55 1510 625
$sbLog.Anchor='Top,Bottom,Left,Right'
$sbLog.Multiline=$true
$sbLog.ReadOnly=$true
$sbLog.MaxLength=2000000
$sbLog.ScrollBars='Vertical'
$sbLog.WordWrap=$false
$sbLog.BackColor=[Drawing.Color]::FromArgb(22,26,31)
$sbLog.ForeColor=[Drawing.Color]::Gainsboro
$sbLog.Font=New-Object System.Drawing.Font('Consolas',8.5)
[void](Sb-Control 'Label' $sbDebugTab 'Actions and errors. Saved to data\trainer-debug.log' 15 15 700 25)
$sbDebugFollow=Sb-Control 'CheckBox' $sbDebugTab 'FOLLOW NEW LOGS' 710 12 190 28;$sbDebugFollow.Checked=$true
$sbDebugFollow.Add_CheckedChanged({$script:Sb.DebugFollow=$this.Checked;if($this.Checked){$sbLog.SelectionStart=$sbLog.TextLength;$sbLog.SelectionLength=0;$sbLog.ScrollToCaret()}})
$sbLog.Add_MouseWheel({if($script:Sb.DebugFollow){$script:Sb.DebugFollow=$false;$sbDebugFollow.Checked=$false}})
$sbLog.Add_MouseDown({if($_.Button-eq[Windows.Forms.MouseButtons]::Left-and$_.X-ge($sbLog.ClientSize.Width-24)){$script:Sb.DebugFollow=$false;$sbDebugFollow.Checked=$false}})
$sbLog.Add_KeyDown({if($_.KeyCode-in@('Up','Down','PageUp','PageDown','Home')){$script:Sb.DebugFollow=$false;$sbDebugFollow.Checked=$false}})
[void](Sb-Button $sbDebugTab 'BOTTOM' 915 12 190 {$script:Sb.DebugFollow=$true;$sbDebugFollow.Checked=$true;$sbLog.SelectionStart=$sbLog.TextLength;$sbLog.SelectionLength=0;$sbLog.ScrollToCaret();$sbLog.Focus()})
[void](Sb-Button $sbDebugTab 'COPY LOG' 1120 12 190 {if(-not[string]::IsNullOrWhiteSpace($sbLog.Text)){[Windows.Forms.Clipboard]::SetText($sbLog.Text)}})
[void](Sb-Button $sbDebugTab 'CLEAR LOG' 1325 12 190 {$script:Sb.Events=@();$sbLog.Clear()})
$sbMapHost=$sbWorkspace.Panel2
$sbMapInfo=Sb-Control 'Label' $sbMapHost 'Waiting for live ship positions...' 10 6 735 24
$sbMapInfo.Anchor='Top,Left,Right';$sbMapInfo.ForeColor=[Drawing.Color]::FromArgb(175,185,195)
$sbMapToolbar=Sb-Control 'FlowLayoutPanel' $sbMapHost '' 8 30 735 62
$sbMapToolbar.Anchor='Top,Left,Right';$sbMapToolbar.WrapContents=$true;$sbMapToolbar.AutoScroll=$false;$sbMapToolbar.FlowDirection='LeftToRight';$sbMapToolbar.Padding=New-Object Windows.Forms.Padding(2,2,2,0)
$mapFilterLabel=New-Object Windows.Forms.Label;$mapFilterLabel.Text='SHOW';$mapFilterLabel.AutoSize=$false;$mapFilterLabel.Size=New-Object Drawing.Size(45,25);$mapFilterLabel.TextAlign='MiddleLeft';$sbMapToolbar.Controls.Add($mapFilterLabel)
function Sb-MapFilterBox([string]$Text,[int]$Width){$c=New-Object Windows.Forms.CheckBox;$c.Text=$Text;$c.Checked=$true;$c.AutoSize=$false;$c.Size=New-Object Drawing.Size($Width,25);$c.Margin=New-Object Windows.Forms.Padding(2,1,2,1);$c.BackColor=$sbMapToolbar.BackColor;$c.ForeColor=[Drawing.Color]::White;$c.Add_CheckedChanged({if($null-ne$sbMapPanel){$sbMapPanel.Invalidate()}});$sbMapToolbar.Controls.Add($c);return $c}
$sbMapFilterAllies=Sb-MapFilterBox 'Allies' 67;$sbMapFilterEnemies=Sb-MapFilterBox 'Enemies' 78;$sbMapFilterBases=Sb-MapFilterBox 'Bases/stations' 112;$sbMapFilterMines=Sb-MapFilterBox 'Mines' 65;$sbMapFilterJumps=Sb-MapFilterBox 'Jump zones' 92
$sortLabel=New-Object Windows.Forms.Label;$sortLabel.Text='SORT';$sortLabel.AutoSize=$false;$sortLabel.Size=New-Object Drawing.Size(42,25);$sortLabel.TextAlign='MiddleRight';$sbMapToolbar.Controls.Add($sortLabel)
$sbMapSort=New-Object Windows.Forms.ComboBox;$sbMapSort.DropDownStyle='DropDownList';$sbMapSort.Size=New-Object Drawing.Size(105,26);[void]$sbMapSort.Items.AddRange(@('Team','Sector','HP','Name'));$sbMapSort.SelectedItem='Team';$sbMapSort.Add_SelectedIndexChanged({if($null-ne$sbMapPanel){$sbMapPanel.Invalidate()}});$sbMapToolbar.Controls.Add($sbMapSort)
$sbMapZoomLabel=New-Object Windows.Forms.Label;$sbMapZoomLabel.Text='Zoom x1.00';$sbMapZoomLabel.AutoSize=$false;$sbMapZoomLabel.Size=New-Object Drawing.Size(90,25);$sbMapZoomLabel.TextAlign='MiddleCenter';$sbMapToolbar.Controls.Add($sbMapZoomLabel)
$sbMapResetView=New-Object Windows.Forms.Button;$sbMapResetView.Text='RESET VIEW';$sbMapResetView.Size=New-Object Drawing.Size(105,27);$sbMapResetView.FlatStyle='Flat';$sbMapResetView.Add_Click({Sb-ResetMapView});$sbMapToolbar.Controls.Add($sbMapResetView)
$sbMapCenterSelected=New-Object Windows.Forms.Button;$sbMapCenterSelected.Text='CENTER SELECTED';$sbMapCenterSelected.Size=New-Object Drawing.Size(145,27);$sbMapCenterSelected.FlatStyle='Flat';$sbMapCenterSelected.Add_Click({Sb-Run {Sb-CenterSelectedOnMap}});$sbMapToolbar.Controls.Add($sbMapCenterSelected)
$sbMapSelectedInfo=Sb-Control 'Label' $sbMapHost 'Selected: none' 10 94 735 32
$sbMapSelectedInfo.Anchor='Top,Left,Right';$sbMapSelectedInfo.AutoEllipsis=$true;$sbMapSelectedInfo.Font=New-Object Drawing.Font('Segoe UI',9,[Drawing.FontStyle]::Bold);$sbMapSelectedInfo.ForeColor=[Drawing.Color]::FromArgb(235,205,95)
$sbMapPanel=Sb-Control 'Panel' $sbMapHost '' 8 127 735 612
$sbMapPanel.Anchor='Top,Bottom,Left,Right';$sbMapPanel.BackColor=[Drawing.Color]::FromArgb(7,14,19);$sbMapPanel.Cursor='Hand'
$sbMapPanel.TabStop=$true
$sbMapZoomTimer=New-Object Windows.Forms.Timer;$sbMapZoomTimer.Interval=33;$sbMapZoomTimer.Add_Tick({$target=[double]$script:Sb.MapTargetZoom;$current=[double]$script:Sb.MapZoom;$difference=$target-$current;if([Math]::Abs($difference)-lt0.005){Sb-SetMapZoomAt $target $script:Sb.MapZoomAnchor;$sbMapZoomTimer.Stop();return};Sb-SetMapZoomAt ($current+$difference*.42) $script:Sb.MapZoomAnchor})
$doubleBuffer=[Windows.Forms.Control].GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic')
if($null-ne$doubleBuffer){$doubleBuffer.SetValue($sbMapPanel,$true,$null)}
$script:Sb.MapIcons=@{}
$mapIconDir='C:\Program Files (x86)\Steam\steamapps\common\Space\spacegame\Content\UIResources\frontend\hud\widgets\minimap\images'
foreach($pair in @(@('Player','medium-player.png'),@('Ally','medium-ally.png'),@('Enemy','medium-enemy.png'))){
    $iconPath=Join-Path $mapIconDir $pair[1]
    if(Test-Path -LiteralPath $iconPath){try{$script:Sb.MapIcons[$pair[0]]=[Drawing.Image]::FromFile($iconPath)}catch{}}
}
$sbMapMenu=New-Object Windows.Forms.ContextMenuStrip
$sbMapMenu.BackColor=[Drawing.Color]::FromArgb(38,43,51);$sbMapMenu.ForeColor=[Drawing.Color]::White
$mapCenter=$sbMapMenu.Items.Add('CENTER ON SHIP');$mapCenter.Add_Click({Sb-Run {Sb-MapAction 'Center'}})
$mapInspect=$sbMapMenu.Items.Add('OPEN IN TEAMS');$mapInspect.Add_Click({Sb-Run {Sb-MapAction 'Inspect'}})
$mapCustom=$sbMapMenu.Items.Add('OPEN IN CUSTOM STATS');$mapCustom.Add_Click({$script:Sb.Selected=[int64]$sbMapMenu.Tag;$sbTabs.SelectedTab=$sbStatsTab;Sb-UpdateCustomTargetUi})
[void]$sbMapMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$mapHeal=$sbMapMenu.Items.Add('HEAL FULL');$mapHeal.Add_Click({Sb-Run {Sb-MapAction 'Heal'}})
$mapKill=$sbMapMenu.Items.Add('KILL');$mapKill.Add_Click({Sb-Run {Sb-MapAction 'Kill'}})
$mapGodOn=$sbMapMenu.Items.Add('GOD ON');$mapGodOn.Add_Click({Sb-Run {Sb-MapAction 'GodOn'}})
$mapGodOff=$sbMapMenu.Items.Add('GOD OFF');$mapGodOff.Add_Click({Sb-Run {Sb-MapAction 'GodOff'}})
$mapRestore=$sbMapMenu.Items.Add('RESTORE NORMAL');$mapRestore.Add_Click({Sb-Run {Sb-MapAction 'Restore'}})
$mapClone=$sbMapMenu.Items.Add('CLONE');$mapClone.Add_Click({Sb-Run {Sb-MapAction 'Clone'}})
$sbMapAi=New-Object Windows.Forms.ToolStripMenuItem('APPLY AI')
for($i=0;$i-lt10;$i++){$aiItem=New-Object Windows.Forms.ToolStripMenuItem((Get-BotDifficultyName $i));$aiItem.Tag=$i;$aiItem.Add_Click({$d=[int]$this.Tag;Sb-Run {Sb-MapAction 'AI' $d}});[void]$sbMapAi.DropDownItems.Add($aiItem)}
[void]$sbMapMenu.Items.Add($sbMapAi)
$sbMapMenu.Add_Opening({$s=Sb-Ship ([int64]$sbMapMenu.Tag);$live=($null -ne $s);foreach($item in @($mapHeal,$mapKill,$mapGodOn,$mapGodOff,$mapRestore,$mapClone)){$item.Enabled=$live};$sbMapAi.Enabled=($live -and -not $s.IsPlayer);if($live){$god=$script:Sb.Invulnerable.ContainsKey([string]$s.StateToken);$mapGodOn.Enabled=(-not $god);$mapGodOff.Enabled=$god}})
$sbMapPanel.Add_Paint({Sb-PaintMap $this $_})
$sbMapPanel.Add_MouseDown({
    $this.Focus();$hit=$null;$shipHit=$null
    for($hitIndex=$script:Sb.MapHits.Count-1;$hitIndex-ge0;$hitIndex--){$candidate=$script:Sb.MapHits[$hitIndex];if(-not$candidate.Rect.Contains($_.Location)){continue};if($candidate.Kind-in@('Action','TeamGod')){$hit=$candidate;break};if($null-eq$shipHit){$shipHit=$candidate}}
    if($null-eq$hit){$hit=$shipHit}
    if($null-ne$hit){if($hit.Kind-eq'TeamGod'){try{if($hit.Team-eq'Allies'){Toggle-AlliedBotGodMode}else{Toggle-EnemyBotGodMode}}catch{Sb-Log ('Error: '+$_.Exception.Message)};$sbMapPanel.Invalidate();return};$script:Sb.Selected=[int64]$hit.PlayerState;Sb-UpdateMapSelectedInfo;$sbMapPanel.Invalidate();if($_.Button-eq[Windows.Forms.MouseButtons]::Right){$sbMapMenu.Tag=[int64]$hit.PlayerState;$sbMapMenu.Show($sbMapPanel,$_.Location)}elseif($hit.Kind-eq'Action'){$mapActionName=[string]$hit.Action;$mapTargetState=[int64]$hit.PlayerState;try{Sb-MapActionForState $mapActionName $mapTargetState}catch{Sb-Log ('Error: '+$_.Exception.Message)}};return}
    if($_.Button-eq[Windows.Forms.MouseButtons]::Left){$script:Sb.MapDrag=$true;$script:Sb.MapDragPoint=$_.Location;$this.Capture=$true;$sbMapPanel.Cursor='SizeAll'}
})
$sbMapPanel.Add_MouseMove({if($script:Sb.MapDrag-and$null-ne$script:Sb.MapDragPoint){$script:Sb.MapPanX+=$_.X-$script:Sb.MapDragPoint.X;$script:Sb.MapPanY+=$_.Y-$script:Sb.MapDragPoint.Y;$script:Sb.MapDragPoint=$_.Location;$script:Sb.MapFocusSector='';if([DateTime]::UtcNow-ge$script:Sb.MapNextInteractionPaint){$script:Sb.MapNextInteractionPaint=[DateTime]::UtcNow.AddMilliseconds(33);$sbMapPanel.Invalidate()}}})
$sbMapPanel.Add_MouseUp({$script:Sb.MapDrag=$false;$script:Sb.MapDragPoint=$null;$this.Capture=$false;$sbMapPanel.Cursor='Hand';$sbMapPanel.Invalidate()})
$sbMapPanel.Add_MouseCaptureChanged({if(-not$this.Capture-and-not[Windows.Forms.Control]::MouseButtons.HasFlag([Windows.Forms.MouseButtons]::Left)){$script:Sb.MapDrag=$false;$script:Sb.MapDragPoint=$null;$this.Cursor='Hand';$this.Invalidate()}})
$sbMapPanel.Add_MouseLeave({if(-not[Windows.Forms.Control]::MouseButtons.HasFlag([Windows.Forms.MouseButtons]::Left)){$script:Sb.MapDrag=$false;$script:Sb.MapDragPoint=$null;$sbMapPanel.Cursor='Hand'}})
$sbMapPanel.Add_MouseWheel({$metrics=Sb-NativeMetrics $sbMapPanel;$mouseX=[single]$_.X;$mouseY=[single]$_.Y;$rosterKey=if($metrics.LeftRoster.Contains($mouseX,$mouseY)){'Allies'}elseif($metrics.RightRoster.Contains($mouseX,$mouseY)){'Enemies'}else{''};if($rosterKey){$delta=if($_.Delta-gt0){-1}else{1};$script:Sb.MapRosterScroll[$rosterKey]=[Math]::Max(0,[int]$script:Sb.MapRosterScroll[$rosterKey]+$delta);$sbMapPanel.Invalidate();return};$base=if($sbMapZoomTimer.Enabled){[double]$script:Sb.MapTargetZoom}else{[double]$script:Sb.MapZoom};$factor=[Math]::Pow(1.18,[double]$_.Delta/120.0);$script:Sb.MapTargetZoom=[Math]::Max(0.65,[Math]::Min(4.0,$base*$factor));$script:Sb.MapZoomAnchor=$_.Location;$sbMapZoomTimer.Start()})
$sbMapPanel.Add_MouseEnter({$this.Focus()})
$sbMapPanel.Add_MouseDoubleClick({$sectorHit=$null;for($i=$script:Sb.MapSectorHits.Count-1;$i-ge0;$i--){if($script:Sb.MapSectorHits[$i].Rect.Contains($_.Location)){$sectorHit=$script:Sb.MapSectorHits[$i];break}};if($null-ne$sectorHit){Sb-FocusMapSector ([string]$sectorHit.SectorKey)}})
$sbMapPanel.Add_Resize({$this.Invalidate()})
$sbShipDetailsLabel=Sb-Control 'Label' $sbInspectTab 'SHIPS' 15 92 90 23
$sbTeamFilter=Sb-Combo $sbInspectTab 110 87 120 @('All','Player','Ally','Enemy')
$sbSelectPlayerButton=Sb-Button $sbInspectTab 'SELECT PLAYER' 240 84 150 {$l=Sb-Require;$script:Sb.Selected=[int64]$l.PlayerState;Sb-RefreshInspector}
$sbShips=Sb-Control 'ListView' $sbInspectTab '' 15 125 760 220
$sbShips.View='Details';$sbShips.FullRowSelect=$true;$sbShips.MultiSelect=$false;$sbShips.HideSelection=$false
foreach($col in @(@('Ship',250),@('Team',80),@('HP',110),@('Difficulty',135))){[void]$sbShips.Columns.Add($col[0],$col[1])}
$sbShips.Anchor='Top,Left,Right'
$sbShips.Add_SelectedIndexChanged({if($sbShips.SelectedItems.Count-gt0){$script:Sb.Selected=[int64]$sbShips.SelectedItems[0].Tag;Sb-RefreshInspector}})
$sbDetails=Sb-Control 'TextBox' $sbInspectTab '' 15 355 760 125
$sbDetails.Multiline=$true;$sbDetails.ReadOnly=$true;$sbDetails.ScrollBars='Vertical';$sbDetails.Font=New-Object Drawing.Font('Consolas',9)
$sbDetails.Anchor='Top,Left,Right'
$sbHealButton=Sb-Button $sbInspectTab 'HEAL FULL' 15 490 100 {Sb-Heal (Sb-Selected);Sb-Log 'Ship healed.'}
$sbKillButton=Sb-Button $sbInspectTab 'KILL' 125 490 80 {Sb-Kill (Sb-Selected);Sb-Log 'Lethal damage applied.'}
$sbGodOnButton=Sb-Button $sbInspectTab 'GOD ON' 215 490 90 {Sb-God (Sb-Selected) $true;Sb-Log 'Invulnerability enabled.'}
$sbGodOffButton=Sb-Button $sbInspectTab 'GOD OFF' 315 490 90 {Sb-God (Sb-Selected) $false;Sb-Log 'Invulnerability disabled.'}
$sbCloneButton=Sb-Button $sbInspectTab 'CLONE' 415 490 90 {Sb-Clone ([int]$sbCloneCount.Value)}
$sbCloneCount=Sb-Number $sbInspectTab 515 493 1 40 1 0 70
$sbRestoreButton=Sb-Button $sbInspectTab 'RESTORE NORMAL' 595 490 180 {Sb-RestoreSelected (Sb-Selected)}
$sbDifficultyLabel=Sb-Control 'Label' $sbInspectTab 'Bot difficulty' 15 540 100 23
$sbAiDiff=Sb-Combo $sbInspectTab 120 537 180 @('Easy 1','Easy 2','Easy 3','Medium 1','Medium 2','Medium 3','Hard 1','Hard 2','Hard 3','Milcho Bot')
$sbApplyAiButton=Sb-Button $sbInspectTab 'APPLY AI' 310 534 110 {Sb-SetDifficulty (Sb-Selected) $sbAiDiff.SelectedIndex;Sb-Log 'Bot difficulty changed.'}
$sbDeleteSelectedButton=Sb-Button $sbInspectTab 'DELETE SELECTED' 15 580 160 {Sb-DeleteSelectedComplete}
$sbDeleteAllAlliesButton=Sb-Button $sbInspectTab 'DELETE ALL ALLIES' 185 580 180 {Invoke-DeleteAllAllies}
$sbDeleteAllEnemiesButton=Sb-Button $sbInspectTab 'DELETE ALL ENEMIES' 375 580 190 {Invoke-DeleteAllEnemies}
$sbSpawnShip=Sb-Combo $sbSpawnTab 15 50 300 @($SHIP_GUIDS.Keys)
$sbSpawnShip.SelectedItem='Punisher'
$sbSpawnSide=Sb-Combo $sbSpawnTab 330 50 120 @('Ally','Enemy')
$sbSpawnDiff=Sb-Combo $sbSpawnTab 465 50 180 @('Easy 1','Easy 2','Easy 3','Medium 1','Medium 2','Medium 3','Hard 1','Hard 2','Hard 3','Milcho Bot');$sbSpawnDiff.SelectedIndex=4
$sbSpawnCount=Sb-Number $sbSpawnTab 660 50 1 40 1
$sbSpawnGod=Sb-Control 'CheckBox' $sbSpawnTab 'Individual God Mode' 795 50 210 28
[void](Sb-Button $sbSpawnTab 'QUEUE SPAWN' 15 100 170 {
    $cfg=if($sbCustomOnSpawn.Checked){Sb-GetCustomStatsConfig}else{$null}
    Sb-QueueShip ([string]$sbSpawnShip.SelectedItem) ([string]$sbSpawnSide.SelectedItem) $sbSpawnDiff.SelectedIndex ([int]$sbSpawnCount.Value) $sbSpawnGod.Checked $false $cfg
})
[void](Sb-Button $sbSpawnTab 'CANCEL QUEUE / WAVES' 200 100 240 {$script:Sb.Queue.Clear();$script:Sb.Wave=$null;Sb-Log 'Queue and waves stopped.'})
[void](Sb-Button $sbSpawnTab 'UNDO LAST SPAWN' 455 100 200 {Sb-Undo})
$sbQueueLabel=Sb-Control 'Label' $sbSpawnTab 'Pending: 0' 15 150 995 55
[void](Sb-Button $sbSpawnTab 'ADD FAVORITE' 15 290 170 {$n=[string]$sbSpawnShip.SelectedItem;if($SHIP_GUIDS.Contains($n)){$script:Sb.Favorites=@(@($script:Sb.Favorites)+$n|Sort-Object -Unique);$sbFavorites.Items.Clear();[void]$sbFavorites.Items.AddRange([object[]]$script:Sb.Favorites);Sb-SaveFavorites}})
$sbFavorites=Sb-Combo $sbSpawnTab 200 293 300 @()
[void](Sb-Button $sbSpawnTab 'USE FAVORITE' 515 290 170 {$sbSpawnShip.SelectedItem=$sbFavorites.SelectedItem})
[void](Sb-Button $sbSpawnTab 'REMOVE FAVORITE' 700 290 180 {$script:Sb.Favorites=@($script:Sb.Favorites|Where-Object{$_ -ne $sbFavorites.SelectedItem});$sbFavorites.Items.Clear();[void]$sbFavorites.Items.AddRange([object[]]$script:Sb.Favorites);Sb-SaveFavorites})
function Sb-SaveFavorites {
    if(-not(Test-Path -LiteralPath $script:SbDataDir)){[void](New-Item -ItemType Directory -Path $script:SbDataDir -Force)}
    ConvertTo-Json -InputObject @($script:Sb.Favorites) | Set-Content -LiteralPath (Join-Path $script:SbDataDir 'favorites.json') -Encoding UTF8
}

$shipSystemsFile=Join-Path $script:SbDataDir 'ship-systems.json'
try{if(Test-Path -LiteralPath $shipSystemsFile){$rawSystems=Get-Content -LiteralPath $shipSystemsFile -Raw|ConvertFrom-Json;foreach($p in $rawSystems.PSObject.Properties){$script:Sb.ShipSystems[[string]$p.Name]=@($p.Value)}}else{Sb-Log 'ship-systems.json missing; real system labels unavailable.'}}catch{Sb-Log ('Could not load ship system names: '+$_.Exception.Message)}

$sbCustomTarget=Sb-Control 'Label' $sbStatsTab 'TARGET: select a ship in TEAMS or MAP' 15 12 1510 27
$sbCustomTarget.Anchor='Top,Left,Right';$sbCustomTarget.Font=New-Object Drawing.Font('Segoe UI',11,[Drawing.FontStyle]::Bold);$sbCustomTarget.ForeColor=[Drawing.Color]::FromArgb(235,205,95)
[void](Sb-Control 'Label' $sbStatsTab 'SHIP' 15 44 50 22)
$sbCustomShipList=Sb-Combo $sbStatsTab 70 39 620 @()
$sbCustomShipList.Add_SelectedIndexChanged({
    if($script:Sb.CustomShipListBusy){return}
    $index=$this.SelectedIndex
    if($index-ge0-and$index-lt$script:Sb.CustomShipChoiceStates.Count){$script:Sb.Selected=[int64]$script:Sb.CustomShipChoiceStates[$index];Sb-UpdateCustomTargetUi}
})
$sbCustomProfileStatus=Sb-Control 'Label' $sbStatsTab 'Profile: none' 710 42 815 23
$sbCustomProfileStatus.Anchor='Top,Left,Right';$sbCustomProfileStatus.ForeColor=[Drawing.Color]::FromArgb(175,195,205)
$sbCustomOnSpawn=Sb-Control 'CheckBox' $sbStatsTab 'Apply to queued/generated ships' 20 70 310 26
$sbCustomEveryRespawn=Sb-Control 'CheckBox' $sbStatsTab 'Force these stats on every respawn' 350 70 340 26
$sbCustomEveryRespawn.Add_CheckedChanged({
    if($script:Sb.CustomPersistentBusy){return}
    try{Sb-SetSelectedPersistent $this.Checked}catch{
        $script:Sb.CustomPersistentBusy=$true;try{$this.Checked=$false}finally{$script:Sb.CustomPersistentBusy=$false}
        Sb-Log ('Error: '+$_.Exception.Message)
    }
})
[void](Sb-Control 'Label' $sbStatsTab 'GENERAL MODIFIERS' 20 103 650 24)
[void](Sb-Control 'Label' $sbStatsTab 'SELECTED SHIP SYSTEMS' 740 103 650 24)

$gx1=20;$gn1=220;$gx2=380;$gn2=580;$glw=190;$sy=135;$dy=42
[void](Sb-Control 'Label' $sbStatsTab 'Max HP (0 = unchanged)' $gx1 ($sy+3) $glw 22);$sbCustomHP=Sb-Number $sbStatsTab $gn1 $sy 0 1000000 0
[void](Sb-Control 'Label' $sbStatsTab 'Damage bonus %' $gx2 ($sy+3) $glw 22);$sbCustomDamage=Sb-Number $sbStatsTab $gn2 $sy -100 1000 0
$sy+=$dy
[void](Sb-Control 'Label' $sbStatsTab 'Capture speed bonus %' $gx1 ($sy+3) $glw 22);$sbCustomCapture=Sb-Number $sbStatsTab $gn1 $sy -100 1000 0
[void](Sb-Control 'Label' $sbStatsTab 'Energy regen bonus %' $gx2 ($sy+3) $glw 22);$sbCustomEnergyRegen=Sb-Number $sbStatsTab $gn2 $sy -100 1000 0
$sy+=$dy
[void](Sb-Control 'Label' $sbStatsTab 'Forward speed bonus %' $gx1 ($sy+3) $glw 22);$sbCustomForward=Sb-Number $sbStatsTab $gn1 $sy -100 1000 0
[void](Sb-Control 'Label' $sbStatsTab 'Reverse speed bonus %' $gx2 ($sy+3) $glw 22);$sbCustomReverse=Sb-Number $sbStatsTab $gn2 $sy -100 1000 0
$sy+=$dy
[void](Sb-Control 'Label' $sbStatsTab 'Strafe speed bonus %' $gx1 ($sy+3) $glw 22);$sbCustomStrafe=Sb-Number $sbStatsTab $gn1 $sy -100 1000 0
[void](Sb-Control 'Label' $sbStatsTab 'Vertical speed bonus %' $gx2 ($sy+3) $glw 22);$sbCustomVertical=Sb-Number $sbStatsTab $gn2 $sy -100 1000 0
$sy+=$dy
[void](Sb-Control 'Label' $sbStatsTab 'Turn/Yaw speed bonus %' $gx1 ($sy+3) $glw 22);$sbCustomTurn=Sb-Number $sbStatsTab $gn1 $sy -100 1000 0

$sbCustomPrimaryLabel=Sb-Control 'Label' $sbStatsTab 'PRIMARY: select a ship' 740 138 610 22
$sbCustomPrimaryCD=Sb-Number $sbStatsTab 1370 135 0 100 0;$sbCustomPrimaryCD.Enabled=$false
$sbCustomSecondaryLabel=Sb-Control 'Label' $sbStatsTab 'SECONDARY: select a ship' 740 180 610 22
$sbCustomSecondaryCD=Sb-Number $sbStatsTab 1370 177 0 100 0;$sbCustomSecondaryCD.Enabled=$false
for($i=1;$i-le9;$i++){
    $rowY=219+(($i-1)*42)
    $label=Sb-Control 'Label' $sbStatsTab ('SYSTEM '+$i+': select a ship') 740 ($rowY+3) 610 22
    $box=Sb-Number $sbStatsTab 1370 $rowY 0 100 0
    Set-Variable -Scope Script -Name ('sbCustomSubsystemLabel'+$i) -Value $label
    Set-Variable -Scope Script -Name ('sbCustomSubsystemCD'+$i) -Value $box
    if($i-gt4){$label.Visible=$false;$box.Visible=$false}
}

$btnY=475
[void](Sb-Button $sbStatsTab 'APPLY NEXT RESPAWN ONCE' 20 $btnY 260 {Sb-ArmSelectedCustom})
[void](Sb-Button $sbStatsTab 'REMOVE PROFILE' 295 $btnY 200 {Sb-ClearSelectedCustom})
[void](Sb-Button $sbStatsTab 'RESET VALUES' 510 $btnY 190 {
    foreach($n in @($sbCustomHP,$sbCustomDamage,$sbCustomPrimaryCD,$sbCustomSecondaryCD,$sbCustomCapture,$sbCustomEnergyRegen,$sbCustomForward,$sbCustomReverse,$sbCustomStrafe,$sbCustomVertical,$sbCustomTurn)){$n.Value=0}
    foreach($i in 1..9){(Get-Variable -Scope Script -Name ('sbCustomSubsystemCD'+$i) -ValueOnly).Value=0}
})
[void](Sb-Button $sbStatsTab 'APPLY NOW (LIVE)' 715 $btnY 210 {Sb-ApplySelectedCustomNow})

$infoY=$btnY+50
[void](Sb-Control 'Label' $sbStatsTab 'RED = FIRE RATE (MAX 80%)    YELLOW = COOLDOWN' 20 $infoY 900 28)
$allCustomNumbers=@($sbCustomHP,$sbCustomDamage,$sbCustomPrimaryCD,$sbCustomSecondaryCD,$sbCustomCapture,$sbCustomEnergyRegen,$sbCustomForward,$sbCustomReverse,$sbCustomStrafe,$sbCustomVertical,$sbCustomTurn)
foreach($i in 1..9){$allCustomNumbers+=Get-Variable -Scope Script -Name ('sbCustomSubsystemCD'+$i) -ValueOnly}
foreach($number in $allCustomNumbers){$number.Add_ValueChanged({Sb-RefreshSelectedPersistentConfig})}
Sb-UpdateCustomTargetUi

[void](Sb-Control 'Label' $sbStatsTab 'CHANGE PLAYER SHIP' 20 575 300 26)
[void](Sb-Control 'Label' $sbStatsTab 'Ship' 20 617 80 22)
$sbRespawnShip=Sb-Combo $sbStatsTab 100 612 330 @($SHIP_GUIDS.Keys)
$sbRespawnShip.SelectedItem='Punisher'
[void](Sb-Button $sbStatsTab 'CHANGE SHIP NOW' 450 609 220 {Sb-ChangeShipNow ([string]$sbRespawnShip.SelectedItem)})
$sbRespawnCurrent=Sb-Control 'Label' $sbStatsTab 'Player ship: unchanged' 690 617 700 28

$sbMatchPanel=Sb-Control 'Panel' $form '' 830 8 730 98
$sbMatchPanel.Anchor='Top,Right'
[void](Sb-Control 'Label' $sbMatchPanel 'MATCH SPEED' 10 12 95 22)
$sbMatchSpeed=Sb-Number $sbMatchPanel 105 8 0.05 5 1 2 85
[void](Sb-Button $sbMatchPanel 'APPLY' 200 5 90 {Sb-MatchTime ([single]$sbMatchSpeed.Value)})
[void](Sb-Button $sbMatchPanel 'RESET SPEED' 300 5 160 {Sb-EnsureBeamTimeFix;if($script:Sb.WorldSettings -gt 0){Sb-Restore $script:Sb.WorldSettings;Sb-Log 'Match speed restored.'}})
[void](Sb-Control 'Label' $sbMatchPanel 'BOT ACTIONS' 10 57 95 22)
$sbBatchSide=Sb-Combo $sbMatchPanel 105 52 110 @('All','Ally','Enemy')
[void](Sb-Button $sbMatchPanel 'HEAL' 225 49 90 {Sb-Batch 'Heal' ([string]$sbBatchSide.SelectedItem)})
[void](Sb-Button $sbMatchPanel 'GOD ON' 325 49 100 {Sb-Batch 'God' ([string]$sbBatchSide.SelectedItem)})
[void](Sb-Button $sbMatchPanel 'GOD OFF' 435 49 100 {Sb-Batch 'Ungod' ([string]$sbBatchSide.SelectedItem)})
[void](Sb-Control 'Label' $sbScenarioTab 'BATTLE GENERATOR' 15 350 760 24)
[void](Sb-Control 'Label' $sbScenarioTab 'Allied bots' 15 387 100 22);$sbBattleAllies=Sb-Number $sbScenarioTab 115 384 0 20 4
[void](Sb-Control 'Label' $sbScenarioTab 'Enemy bots' 255 387 100 22);$sbBattleEnemies=Sb-Number $sbScenarioTab 355 384 0 20 5
[void](Sb-Control 'Label' $sbScenarioTab 'Difficulty' 495 387 90 22);$sbBattleDiff=Sb-Combo $sbScenarioTab 585 384 190 @('Easy 1','Easy 2','Easy 3','Medium 1','Medium 2','Medium 3','Hard 1','Hard 2','Hard 3','Milcho Bot');$sbBattleDiff.SelectedIndex=4
$sbRandomShips=Sb-Control 'CheckBox' $sbScenarioTab 'Random ships' 15 423 180 28
$sbRandomDifficulties=Sb-Control 'CheckBox' $sbScenarioTab 'Random difficulties' 210 423 220 28
[void](Sb-Button $sbScenarioTab 'GENERATE BATTLE' 15 465 200 {$cfg=if($sbCustomOnSpawn.Checked){Sb-GetCustomStatsConfig}else{$null};Sb-Battle ([int]$sbBattleAllies.Value) ([int]$sbBattleEnemies.Value) $sbRandomShips.Checked $sbRandomDifficulties.Checked $sbBattleDiff.SelectedIndex $cfg})
$sbPreset=Sb-Combo $sbScenarioTab 230 468 165 @('1v1','3v3','5v5','10v10','20v20','Player vs 10')
[void](Sb-Button $sbScenarioTab 'USE COUNTS' 410 465 120 {
    switch([string]$sbPreset.SelectedItem){
        '1v1'{$sbBattleAllies.Value=0;$sbBattleEnemies.Value=1}
        '3v3'{$sbBattleAllies.Value=2;$sbBattleEnemies.Value=3}
        '5v5'{$sbBattleAllies.Value=4;$sbBattleEnemies.Value=5}
        '10v10'{$sbBattleAllies.Value=9;$sbBattleEnemies.Value=10}
        '20v20'{$sbBattleAllies.Value=19;$sbBattleEnemies.Value=20}
        'Player vs 10'{$sbBattleAllies.Value=0;$sbBattleEnemies.Value=10}
    }
    Sb-Log 'Counts selected. Existing bots are retained; use GENERATE BATTLE to add the scenario.'
})
[void](Sb-Button $sbScenarioTab 'SAVE ROSTER' 545 465 110 {Sb-SaveScenario})
[void](Sb-Button $sbScenarioTab 'LOAD ROSTER' 665 465 110 {Sb-LoadScenario})
[void](Sb-Control 'Label' $sbScenarioTab 'TIMED ENEMY WAVES' 15 525 760 24)
[void](Sb-Control 'Label' $sbScenarioTab 'Waves' 15 562 55 23);$sbWaveTotal=Sb-Number $sbScenarioTab 70 559 1 50 5 0 85
[void](Sb-Control 'Label' $sbScenarioTab 'First' 165 562 45 23);$sbWaveBase=Sb-Number $sbScenarioTab 210 559 1 20 2 0 85
[void](Sb-Control 'Label' $sbScenarioTab 'Added' 305 562 55 23);$sbWaveStep=Sb-Number $sbScenarioTab 360 559 0 10 2 0 85
[void](Sb-Control 'Label' $sbScenarioTab 'Interval' 455 562 65 23);$sbWaveDelay=Sb-Number $sbScenarioTab 520 559 10 3600 60 0 100
[void](Sb-Button $sbScenarioTab 'START WAVES' 15 610 175 {[void](Sb-Require);if($null -eq $sbSpawnShip.SelectedItem){throw 'Select a ship.'};$cfg=if($sbCustomOnSpawn.Checked){Sb-GetCustomStatsConfig}else{$null};$script:Sb.Wave=@{Current=0;Total=[int]$sbWaveTotal.Value;Base=[int]$sbWaveBase.Value;Step=[int]$sbWaveStep.Value;Delay=[int]$sbWaveDelay.Value;Next=[DateTime]::UtcNow;Ship=[string]$sbSpawnShip.SelectedItem;Difficulty=$sbBattleDiff.SelectedIndex;RandomShips=$sbRandomShips.Checked;RandomDifficulties=$sbRandomDifficulties.Checked;Custom=$cfg};Sb-Log 'Timed waves started.'})
[void](Sb-Button $sbScenarioTab 'STOP WAVES / QUEUE' 205 610 220 {$script:Sb.Wave=$null;$script:Sb.Queue.Clear();Sb-Log 'Waves and queue stopped.'})
try {
    $favfile=Join-Path $script:SbDataDir 'favorites.json'
    if(Test-Path -LiteralPath $favfile){$script:Sb.Favorites=@((Get-Content -LiteralPath $favfile -Raw|ConvertFrom-Json)|Where-Object{$SHIP_GUIDS.Contains([string]$_)});[void]$sbFavorites.Items.AddRange([object[]]$script:Sb.Favorites)}
} catch {Sb-Log 'Could not load favorites.'}
$sbTimer=New-Object Windows.Forms.Timer;$sbTimer.Interval=100;$sbTimer.Add_Tick({Sb-Tick})
$form.Add_FormClosing({$sbTimer.Stop();$sbMapZoomTimer.Stop();$script:Sb.Queue.Clear();$script:Sb.Wave=$null;Sb-Run {Sb-ClearGod};Sb-Run {Sb-Restore};foreach($img in @($script:Sb.MapIcons.Values)){if($null-ne$img){$img.Dispose()}}})
$form.Add_Shown({$sbTimer.Start()})

foreach($list in @($allyListView,$enemyListView)){
    $list.Add_SelectedIndexChanged({if($this.SelectedItems.Count-gt0-and$null-ne$this.SelectedItems[0].Tag){$script:Sb.Selected=[int64]$this.SelectedItems[0].Tag.PlayerState;if($sbTabs.SelectedTab-eq$sbStatsTab){Sb-UpdateCustomTargetUi}}})
    $list.Add_DoubleClick({if($this.SelectedItems.Count -gt 0){$script:Sb.Selected=[int64]$this.SelectedItems[0].Tag.PlayerState;$sbTabs.SelectedTab=$sbInspectTab;Sb-Run {Sb-RefreshInspector}}})
}
$sbTabs.Add_SelectedIndexChanged({if($sbTabs.SelectedTab-eq$sbStatsTab){Sb-UpdateCustomTargetUi}})
foreach($button in @($deleteButton,$deleteAllButton,$enemyDeleteButton,$enemyDeleteAllButton)){
    if($null-ne$button){$button.Add_Click({Sb-Log ('Action: '+$this.Text)})}
}
foreach($c in @($spawnSectionLabel,$shipLabel,$shipCombo,$difficultyLabel,$difficultyCombo,$spawnButton,$spawnInfoLabel,$enemySpawnSectionLabel,$enemyShipLabel,$enemyShipCombo,$enemyDifficultyLabel,$enemyDifficultyCombo,$enemySpawnButton,$enemySpawnInfoLabel)){$c.Visible=$false}
foreach($c in @($separator,$allyColumnTitle,$allyButton,$allyInfoLabel,$managerSectionLabel,$allyListView,$deleteButton,$deleteAllButton,$deleteInfoLabel,$enemyColumnTitle,$enemyGodButton,$enemyInfoLabel,$enemyManagerSectionLabel,$enemyListView,$enemyDeleteButton,$enemyDeleteAllButton,$enemyDeleteInfoLabel)){$c.Visible=$false}
$healthLabel.Location=New-Object Drawing.Point(15,8);$healthLabel.Size=New-Object Drawing.Size(760,24);$healthLabel.Anchor='Top,Left,Right'
$godButton.Visible=$false

[void](Sb-Control 'Label' $sbSpawnTab 'Team' 330 18 120 22)
[void](Sb-Control 'Label' $sbSpawnTab 'Difficulty' 465 18 180 22)
[void](Sb-Control 'Label' $sbSpawnTab 'Count' 660 18 115 22)
[void](Sb-Control 'Label' $sbSpawnTab 'Ship' 15 18 120 22)
