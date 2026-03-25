# PowerShell script to get lingering sessions using NetWkstaUserEnum
# This uses the NetAPI32.dll NetWkstaUserEnum function to enumerate user sessions

param(
    [string]$TargetServer = $env:COMPUTERNAME,
    [Parameter(Mandatory=$true)]
    [string]$TargetUser
)

# Define the NetAPI structures and functions using Add-Type
$NetApiSource = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class NetWkstaUserApi
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WKSTA_USER_INFO_1
    {
        public IntPtr wkui1_username;
        public IntPtr wkui1_logon_domain;
        public IntPtr wkui1_oth_domains;
        public IntPtr wkui1_logon_server;
    }

    [DllImport("netapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int NetWkstaUserEnum(
        string servername,
        int level,
        out IntPtr bufptr,
        int prefmaxlen,
        out int entriesread,
        out int totalentries,
        ref int resume_handle
    );

    [DllImport("netapi32.dll")]
    public static extern int NetApiBufferFree(IntPtr buffer);
}
"@

# Add the type definition
try {
    Add-Type -TypeDefinition $NetApiSource -ErrorAction Stop
} catch {
    if ($_.Exception.Message -notmatch "already exists") {
        Write-Error "Failed to add type definition: $_"
        exit 1
    }
}

function Get-NetWkstaUserSessions {
    param(
        [string]$ServerName = $env:COMPUTERNAME
    )

    $sessions = @()
    $resumeHandle = 0
    $ERROR_MORE_DATA = 234
    $ERROR_SUCCESS = 0
    $result = $ERROR_SUCCESS

    do {
        $bufptr = [IntPtr]::Zero
        $entriesread = 0
        $totalentries = 0

        try {
            # Call NetWkstaUserEnum with level 1
            $result = [NetWkstaUserApi]::NetWkstaUserEnum(
                $ServerName,
                1,  # Level 1 returns WKSTA_USER_INFO_1
                [ref]$bufptr,
                -1, # MAX_PREFERRED_LENGTH
                [ref]$entriesread,
                [ref]$totalentries,
                [ref]$resumeHandle
            )

            # Process results if we got data (SUCCESS or MORE_DATA)
            if (($result -eq $ERROR_SUCCESS -or $result -eq $ERROR_MORE_DATA) -and $bufptr -ne [IntPtr]::Zero) {
                # Calculate the size of WKSTA_USER_INFO_1 structure
                $structSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][NetWkstaUserApi+WKSTA_USER_INFO_1])
                
                for ($i = 0; $i -lt $entriesread; $i++) {
                    $offset = $i * $structSize
                    $structPtr = [IntPtr]($bufptr.ToInt64() + $offset)
                    
                    # Marshal the structure
                    $userInfo = [System.Runtime.InteropServices.Marshal]::PtrToStructure(
                        $structPtr,
                        [type][NetWkstaUserApi+WKSTA_USER_INFO_1]
                    )
                    
                    # Marshal string pointers to actual strings
                    $username = if ($userInfo.wkui1_username -ne [IntPtr]::Zero) {
                        [System.Runtime.InteropServices.Marshal]::PtrToStringUni($userInfo.wkui1_username)
                    } else { "" }
                    
                    $logonDomain = if ($userInfo.wkui1_logon_domain -ne [IntPtr]::Zero) {
                        [System.Runtime.InteropServices.Marshal]::PtrToStringUni($userInfo.wkui1_logon_domain)
                    } else { "" }
                    
                    $othDomains = if ($userInfo.wkui1_oth_domains -ne [IntPtr]::Zero) {
                        [System.Runtime.InteropServices.Marshal]::PtrToStringUni($userInfo.wkui1_oth_domains)
                    } else { "" }
                    
                    $logonServer = if ($userInfo.wkui1_logon_server -ne [IntPtr]::Zero) {
                        [System.Runtime.InteropServices.Marshal]::PtrToStringUni($userInfo.wkui1_logon_server)
                    } else { "" }
                    
                    $sessions += [PSCustomObject]@{
                        Username      = $username
                        LogonDomain   = $logonDomain
                        OtherDomains  = $othDomains
                        LogonServer   = $logonServer
                        FullName      = if ($logonDomain) {
                                          "$logonDomain\$username"
                                        } else {
                                          $username
                                        }
                    }
                }
                
                # Free the buffer after processing
                if ($bufptr -ne [IntPtr]::Zero) {
                    [NetWkstaUserApi]::NetApiBufferFree($bufptr) | Out-Null
                    $bufptr = [IntPtr]::Zero
                }
            } elseif ($result -ne $ERROR_SUCCESS -and $result -ne $ERROR_MORE_DATA) {
                # Get human-readable error message
                $errorMsg = try {
                    $exception = New-Object System.ComponentModel.Win32Exception($result)
                    $exception.Message
                } catch {
                    "Error code: $result"
                }
                Write-Warning "NetWkstaUserEnum failed: $errorMsg"
                Write-Warning "Common error codes: 5=Access Denied, 53=Network path not found, 87=Invalid parameter"
                break
            }
        }
        catch {
            Write-Warning "Error processing NetWkstaUserEnum buffer: $_"
            if ($bufptr -ne [IntPtr]::Zero) {
                [NetWkstaUserApi]::NetApiBufferFree($bufptr) | Out-Null
            }
            break
        }
        
        # Continue loop if we got MORE_DATA (more entries to retrieve)
    } while ($result -eq $ERROR_MORE_DATA)

    return $sessions
}

function Test-TargetServerIsLocal {
    param([string]$ServerName)
    $n = if ($ServerName) { $ServerName.Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($n)) { return $true }
    if ($n -in @('.', 'localhost', '127.0.0.1')) { return $true }
    if ($n -ieq $env:COMPUTERNAME) { return $true }
    try {
        $dnsShort = ([System.Net.Dns]::GetHostEntry('localhost').HostName -split '\.')[0]
        if ($n -ieq $dnsShort) { return $true }
    } catch { }
    return $false
}

function Get-TargetUserIdentity {
    param([string]$Raw)
    $t = $Raw.Trim()
    if ($t -match '^([^\\]+)\\(.+)$') {
        return [PSCustomObject]@{
            Domain    = $matches[1]
            Sam       = $matches[2]
            Canonical = "$($matches[1])\$($matches[2])"
        }
    }
    if ($t -match '^([^@]+)@(.+)$') {
        return [PSCustomObject]@{
            Domain    = $matches[2]
            Sam       = $matches[1]
            Canonical = "$($matches[2])\$($matches[1])"
        }
    }
    return [PSCustomObject]@{
        Domain    = ''
        Sam       = $t
        Canonical = $t
    }
}

function Test-IdentityMatch {
    param(
        [string]$Candidate,
        [PSCustomObject]$Identity,
        [string]$RawOriginal
    )
    if ([string]::IsNullOrWhiteSpace($Candidate)) { return $false }
    if ($Candidate -ieq $RawOriginal.Trim()) { return $true }
    if ($Identity.Canonical -and ($Candidate -ieq $Identity.Canonical)) { return $true }
    if ($Identity.Sam -and ($Candidate -ieq $Identity.Sam)) { return $true }
    if ($Identity.Sam) {
        $suffix = "\$($Identity.Sam)"
        if ($Candidate.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-LogonSessionsForTargetUser {
    param(
        [string]$ComputerName,
        [bool]$IsLocal,
        [PSCustomObject]$Identity,
        [string]$RawTargetUser
    )

    $cimParams = @{ ClassName = 'Win32_LogonSession'; ErrorAction = 'SilentlyContinue' }
    if (-not $IsLocal) { $cimParams['ComputerName'] = $ComputerName }

    $allLogonSessions = Get-CimInstance @cimParams
    if (-not $allLogonSessions) { return @() }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($session in @($allLogonSessions)) {
        $users = @()
        try {
            $users = @(Get-CimAssociatedInstance -InputObject $session -ResultClassName Win32_Account -ErrorAction SilentlyContinue)
            if ($users.Count -eq 0) {
                $users = @(Get-CimAssociatedInstance -InputObject $session -ResultClassName Win32_UserAccount -ErrorAction SilentlyContinue)
            }
        } catch { }
        foreach ($user in $users) {
            $fullName = "$($user.Domain)\$($user.Name)"
            if (Test-IdentityMatch -Candidate $fullName -Identity $Identity -RawOriginal $RawTargetUser) {
                $out.Add([PSCustomObject]@{
                    LogonId       = $session.LogonId
                    LogonType     = $session.LogonType
                    LogonTypeName = switch ($session.LogonType) {
                        2  { 'Interactive' }
                        3  { 'Network' }
                        4  { 'Batch' }
                        5  { 'Service' }
                        7  { 'Unlock' }
                        8  { 'NetworkCleartext' }
                        9  { 'NewCredentials' }
                        10 { 'RemoteInteractive (RDP)' }
                        11 { 'CachedInteractive' }
                        default { "Unknown ($($session.LogonType))" }
                    }
                    StartTime     = $session.StartTime
                    User          = $fullName
                })
            }
        }
    }
    return $out
}

$script:IsLocalTarget = Test-TargetServerIsLocal -ServerName $TargetServer
$script:TargetUserIdentity = Get-TargetUserIdentity -Raw $TargetUser

# Main execution
Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "LINGERING SESSION DETECTION REPORT" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "Target Server: $TargetServer" -ForegroundColor Yellow
Write-Host "Target User: $TargetUser" -ForegroundColor Yellow
if (-not $script:IsLocalTarget) {
    Write-Host "Query mode: Remote (Sections 2-4 use WinRM/CIM to $TargetServer where applicable)" -ForegroundColor DarkYellow
} else {
    Write-Host "Query mode: Local" -ForegroundColor DarkYellow
}
Write-Host ""

# Collect all data first
$wkstaSessions = @()
$logonSessions = @()
$processes = @()
$smbSessions = @()
$script:LogonQueryFailed = $false
$script:ProcessQueryFailed = $false

# ============================================================================
# SECTION 1: NetWkstaUserEnum - ALL SESSIONS (Complete Enumeration)
# ============================================================================
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "SECTION 1: NetWkstaUserEnum - ALL SESSIONS" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "WHAT THIS SHOWS: Complete list of ALL user sessions returned by the Windows" -ForegroundColor White
Write-Host "                 NetWkstaUserEnum API. This includes:" -ForegroundColor White
Write-Host "                 - Active user logon sessions" -ForegroundColor White
Write-Host "                 - Machine account sessions (computer$ accounts)" -ForegroundColor White
Write-Host "                 - Cached/stale sessions that may not appear elsewhere" -ForegroundColor White
Write-Host "                 - Network logon sessions" -ForegroundColor White
Write-Host ""

try {
    $wkstaSessions = Get-NetWkstaUserSessions -ServerName $TargetServer
    
    if ($wkstaSessions.Count -eq 0) {
        Write-Host "No sessions found via NetWkstaUserEnum" -ForegroundColor Yellow
    } else {
        Write-Host "Total sessions found: $($wkstaSessions.Count)" -ForegroundColor Green
        Write-Host "`nALL SESSIONS (including machine accounts):" -ForegroundColor Yellow
        $wkstaSessions | Format-Table -AutoSize
        
        # Filter for target user (excluding machine accounts); match DOMAIN\User, UPN, or SAM-only
        $targetSessions = $wkstaSessions | Where-Object {
            -not $_.Username.EndsWith('$') -and
            (Test-IdentityMatch -Candidate $_.FullName -Identity $script:TargetUserIdentity -RawOriginal $TargetUser)
        }
        if ($targetSessions) {
            Write-Host "`nSessions matching '$TargetUser' (excluding machine accounts):" -ForegroundColor Green
            $targetSessions | Format-Table -AutoSize
        } else {
            Write-Host "`nNo user sessions found for '$TargetUser' in NetWkstaUserEnum" -ForegroundColor Yellow
        }
    }
} catch {
    Write-Error "Error enumerating sessions: $_"
}

# ============================================================================
# SECTION 2: Win32_LogonSession - ACTIVE LOGON SESSIONS
# ============================================================================
Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "SECTION 2: Win32_LogonSession - ACTIVE LOGON SESSIONS" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "WHAT THIS SHOWS: Currently active logon sessions visible to WMI." -ForegroundColor White
Write-Host "                 These represent sessions that are actively logged on." -ForegroundColor White
Write-Host "                 LogonType meanings:" -ForegroundColor White
Write-Host "                 2 = Interactive, 3 = Network, 10 = RemoteInteractive (RDP)" -ForegroundColor White
Write-Host ""

try {
    $logonSessions = @(Get-LogonSessionsForTargetUser -ComputerName $TargetServer -IsLocal $script:IsLocalTarget -Identity $script:TargetUserIdentity -RawTargetUser $TargetUser)

    if ($logonSessions.Count -gt 0) {
        Write-Host "Active logon sessions found: $($logonSessions.Count)" -ForegroundColor Green
        $logonSessions | Format-Table -AutoSize
    } else {
        Write-Host "No active logon sessions found for '$TargetUser'" -ForegroundColor Yellow
        Write-Host "(This could indicate a lingering session if found in Section 1)" -ForegroundColor Red
    }
} catch {
    $script:LogonQueryFailed = $true
    Write-Warning "Error getting logon sessions: $_"
}

# ============================================================================
# SECTION 3: PROCESSES - ACTIVE PROCESSES RUNNING AS USER
# ============================================================================
Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "SECTION 3: PROCESSES - ACTIVE PROCESSES RUNNING AS USER" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "WHAT THIS SHOWS: All processes currently running with the target user's" -ForegroundColor White
Write-Host "                 security context. Active sessions will have processes." -ForegroundColor White
Write-Host ""

try {
    if ($script:IsLocalTarget) {
        $processes = @(Get-Process -IncludeUserName -ErrorAction SilentlyContinue |
            Where-Object { Test-IdentityMatch -Candidate $_.UserName -Identity $script:TargetUserIdentity -RawOriginal $TargetUser })
    } else {
        $canon = $script:TargetUserIdentity.Canonical
        $sam = $script:TargetUserIdentity.Sam
        $raw = $TargetUser
        try {
            $processes = @(Invoke-Command -ComputerName $TargetServer -ScriptBlock {
                param($Canon, $Sam, $RawOrig)
                Get-Process -IncludeUserName -ErrorAction SilentlyContinue | Where-Object {
                    if (-not $_.UserName) { return $false }
                    $u = $_.UserName
                    if ($u -ieq $RawOrig) { return $true }
                    if ($Canon -and ($u -ieq $Canon)) { return $true }
                    if ($Sam -and ($u -ieq $Sam)) { return $true }
                    if ($Sam) {
                        $i = $u.LastIndexOf('\')
                        if ($i -ge 0 -and ($u.Substring($i + 1) -ieq $Sam)) { return $true }
                    }
                    return $false
                }
            } -ArgumentList $canon, $sam, $raw -ErrorAction Stop)
        } catch {
            $script:ProcessQueryFailed = $true
            Write-Warning "Remote process enumeration failed (requires WinRM and appropriate rights on ${TargetServer}): $_"
            $processes = @()
        }
    }

    if ($processes.Count -gt 0) {
        Write-Host "Active processes found: $($processes.Count)" -ForegroundColor Green
        $processes | Select-Object Name, Id, UserName | Format-Table -AutoSize
    } else {
        Write-Host "No processes found running as '$TargetUser'" -ForegroundColor Yellow
        Write-Host "(This could indicate a lingering session if found in Section 1)" -ForegroundColor Red
    }
} catch {
    $script:ProcessQueryFailed = $true
    Write-Warning "Error getting processes: $_"
}

# ============================================================================
# SECTION 4: SMB SESSIONS - NETWORK FILE SHARING SESSIONS
# ============================================================================
Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "SECTION 4: SMB SESSIONS - NETWORK FILE SHARING SESSIONS" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "WHAT THIS SHOWS: Active SMB (Server Message Block) file sharing sessions." -ForegroundColor White
Write-Host "                 These represent network file share connections." -ForegroundColor White
Write-Host ""

try {
    if ($script:IsLocalTarget) {
        $smbSessions = @(Get-SmbSession -ErrorAction SilentlyContinue |
            Where-Object { Test-IdentityMatch -Candidate $_.ClientUserName -Identity $script:TargetUserIdentity -RawOriginal $TargetUser })
    } else {
        $cimSmb = $null
        $smbSessions = @()
        try {
            $cimSmb = New-CimSession -ComputerName $TargetServer -ErrorAction Stop
            $smbSessions = @(Get-SmbSession -CimSession $cimSmb -ErrorAction SilentlyContinue |
                Where-Object { Test-IdentityMatch -Candidate $_.ClientUserName -Identity $script:TargetUserIdentity -RawOriginal $TargetUser })
        } catch {
            Write-Warning "SMB session query skipped or failed for remote target (requires WinRM/CIM and SMB management on $TargetServer ): $_"
        } finally {
            if ($cimSmb) { Remove-CimSession -CimSession $cimSmb -ErrorAction SilentlyContinue }
        }
    }

    if ($smbSessions.Count -gt 0) {
        Write-Host "SMB sessions found: $($smbSessions.Count)" -ForegroundColor Green
        $smbSessions | Select-Object ClientUserName, ClientComputerName, NumOpens | Format-Table -AutoSize
    } else {
        Write-Host "No SMB sessions found for '$TargetUser'" -ForegroundColor Yellow
    }
} catch {
    Write-Warning "Error getting SMB sessions: $_"
}

# ============================================================================
# SECTION 5: LINGERING SESSION ANALYSIS
# ============================================================================
Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Red
Write-Host "SECTION 5: LINGERING SESSION ANALYSIS" -ForegroundColor Red
Write-Host "================================================================================" -ForegroundColor Red
Write-Host "WHAT THIS SHOWS: User-level check - if the target user appears in NetWkstaUserEnum" -ForegroundColor White
Write-Host "                 (Section 1) but has no matching WMI logon sessions (Section 2)" -ForegroundColor White
Write-Host "                 and no running processes (Section 3), we flag a LINGERING state." -ForegroundColor White
Write-Host "                 NetWkstaUserEnum can return duplicate rows; SMB (Section 4) is informational." -ForegroundColor White
Write-Host ""

# All NetWkstaUserEnum rows for this user (excluding machine accounts)
$targetWkstaSessions = @($wkstaSessions | Where-Object {
    -not $_.Username.EndsWith('$') -and
    (Test-IdentityMatch -Candidate $_.FullName -Identity $script:TargetUserIdentity -RawOriginal $TargetUser)
})

if ($targetWkstaSessions.Count -gt 0) {
    $hasActiveLogon = $logonSessions.Count -gt 0
    $hasProcesses = $processes.Count -gt 0
    $hasSmbSession = $smbSessions.Count -gt 0

    if (-not $hasActiveLogon -and -not $hasProcesses) {
        Write-Host "*** LINGERING USER STATE (NetWkstaUserEnum vs logon/processes) ***" -ForegroundColor Red
        Write-Host "The user appears in NetWkstaUserEnum but has no active WMI logon sessions and no" -ForegroundColor Red
        Write-Host "running processes on $TargetServer for this identity. NetWkstaUserEnum row(s):" -ForegroundColor Red
        Write-Host ""
        $targetWkstaSessions | Format-Table -AutoSize
        Write-Host ""
        if ($script:ProcessQueryFailed -or $script:LogonQueryFailed) {
            Write-Host "IMPORTANT: Section 2 and/or Section 3 did not complete successfully (see warnings above)." -ForegroundColor Yellow
            Write-Host "         Re-run in an elevated PowerShell (Run as Administrator) or fix remote access" -ForegroundColor Yellow
            Write-Host "         before treating this as confirmed lingering." -ForegroundColor Yellow
            Write-Host ""
        }
        Write-Host "Context: Has SMB session (informational): $hasSmbSession" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "RECOMMENDATION: Investigate stale/cached NetWkstaUserEnum entries. They may be:" -ForegroundColor Yellow
        Write-Host "  - Stale cached sessions" -ForegroundColor Yellow
        Write-Host "  - Sessions that did not properly log off" -ForegroundColor Yellow
        Write-Host "  - Network logon sessions that are no longer active" -ForegroundColor Yellow
    } else {
        Write-Host "ACTIVE USER STATE (not lingering by this heuristic):" -ForegroundColor Green
        Write-Host "  NetWkstaUserEnum row count for user: $($targetWkstaSessions.Count)" -ForegroundColor Green
        Write-Host "  Has WMI logon session: $hasActiveLogon ($($logonSessions.Count) session(s))" -ForegroundColor Green
        Write-Host "  Has running processes: $hasProcesses ($($processes.Count) process(es))" -ForegroundColor Green
        Write-Host "  Has SMB session (informational): $hasSmbSession" -ForegroundColor Green
        Write-Host ""
        Write-Host "NetWkstaUserEnum detail:" -ForegroundColor Green
        $targetWkstaSessions | Format-Table -AutoSize
    }
} else {
    Write-Host "No sessions found for '$TargetUser' in NetWkstaUserEnum." -ForegroundColor Yellow
    Write-Host "Nothing to analyze for lingering sessions." -ForegroundColor Yellow
}

# ============================================================================
# SUMMARY
# ============================================================================
Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "NetWkstaUserEnum Sessions: $($wkstaSessions.Count) total" -ForegroundColor White
Write-Host "Active Logon Sessions: $($logonSessions.Count)" -ForegroundColor White
Write-Host "Running Processes: $($processes.Count)" -ForegroundColor White
Write-Host "SMB Sessions: $($smbSessions.Count)" -ForegroundColor White
Write-Host ""
Write-Host "Note: NetWkstaUserEnum may show sessions that do not appear in other methods." -ForegroundColor Yellow
Write-Host "      Section 5 flags a lingering user state when that happens without logon/processes." -ForegroundColor Yellow

