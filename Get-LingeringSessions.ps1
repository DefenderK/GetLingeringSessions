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
                Write-Warning "NetWkstaUserEnum failed with error code: $result"
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

# Main execution
Write-Host "`n" -NoNewline
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "LINGERING SESSION DETECTION REPORT" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host "Target Server: $TargetServer" -ForegroundColor Yellow
Write-Host "Target User: $TargetUser`n" -ForegroundColor Yellow

# Collect all data first
$wkstaSessions = @()
$logonSessions = @()
$processes = @()
$smbSessions = @()

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
        
        # Filter for target user (excluding machine accounts)
        $targetSessions = $wkstaSessions | Where-Object { 
            $_.FullName -eq $TargetUser -and -not $_.Username.EndsWith('$')
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
    $allLogonSessions = Get-WmiObject Win32_LogonSession -ErrorAction SilentlyContinue
    
    $logonSessions = $allLogonSessions |
        ForEach-Object {
            $session = $_
            $users = $session.GetRelated('Win32_Account')
            foreach ($user in $users) {
                $fullName = "$($user.Domain)\$($user.Name)"
                if ($fullName -eq $TargetUser) {
                    [PSCustomObject]@{
                        LogonId       = $session.LogonId
                        LogonType     = $session.LogonType
                        LogonTypeName = switch ($session.LogonType) {
                            2  { "Interactive" }
                            3  { "Network" }
                            4  { "Batch" }
                            5  { "Service" }
                            7  { "Unlock" }
                            8  { "NetworkCleartext" }
                            9  { "NewCredentials" }
                            10 { "RemoteInteractive (RDP)" }
                            11 { "CachedInteractive" }
                            default { "Unknown ($($session.LogonType))" }
                        }
                        StartTime     = $session.StartTime
                        User          = $fullName
                    }
                }
            }
        }
    
    if ($logonSessions) {
        Write-Host "Active logon sessions found: $($logonSessions.Count)" -ForegroundColor Green
        $logonSessions | Format-Table -AutoSize
    } else {
        Write-Host "No active logon sessions found for '$TargetUser'" -ForegroundColor Yellow
        Write-Host "(This could indicate a lingering session if found in Section 1)" -ForegroundColor Red
    }
} catch {
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
    $processes = Get-Process -IncludeUserName -ErrorAction SilentlyContinue |
        Where-Object { $_.UserName -eq $TargetUser }
    
    if ($processes) {
        Write-Host "Active processes found: $($processes.Count)" -ForegroundColor Green
        $processes | Select-Object Name, Id, UserName | Format-Table -AutoSize
    } else {
        Write-Host "No processes found running as '$TargetUser'" -ForegroundColor Yellow
        Write-Host "(This could indicate a lingering session if found in Section 1)" -ForegroundColor Red
    }
} catch {
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
    $smbSessions = Get-SmbSession -ErrorAction SilentlyContinue |
        Where-Object { $_.ClientUserName -eq $TargetUser }
    
    if ($smbSessions) {
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
Write-Host "WHAT THIS SHOWS: Sessions that appear in NetWkstaUserEnum but are NOT" -ForegroundColor White
Write-Host "                 found in active logon sessions or processes." -ForegroundColor White
Write-Host "                 These are LINGERING sessions that may need cleanup." -ForegroundColor White
Write-Host ""

# Get target user sessions from NetWkstaUserEnum (excluding machine accounts)
$targetWkstaSessions = $wkstaSessions | Where-Object { 
    $_.FullName -eq $TargetUser -and -not $_.Username.EndsWith('$')
}

if ($targetWkstaSessions) {
    $lingeringSessions = @()
    
    foreach ($wkstaSession in $targetWkstaSessions) {
        # Check if this session appears in active logon sessions
        $hasActiveLogon = $logonSessions.Count -gt 0
        $hasProcesses = $processes.Count -gt 0
        $hasSmbSession = $smbSessions.Count -gt 0
        
        # A session is "lingering" if it's in NetWkstaUserEnum but has no active logon or processes
        if (-not $hasActiveLogon -and -not $hasProcesses) {
            $lingeringSessions += [PSCustomObject]@{
                Username      = $wkstaSession.Username
                LogonDomain   = $wkstaSession.LogonDomain
                LogonServer   = $wkstaSession.LogonServer
                FullName      = $wkstaSession.FullName
                Status        = "LINGERING - No active logon or processes"
                HasActiveLogon = $hasActiveLogon
                HasProcesses   = $hasProcesses
                HasSmbSession  = $hasSmbSession
            }
        } else {
            # Show active sessions for comparison
            Write-Host "ACTIVE SESSION DETECTED:" -ForegroundColor Green
            Write-Host "  User: $($wkstaSession.FullName)" -ForegroundColor Green
            Write-Host "  Logon Server: $($wkstaSession.LogonServer)" -ForegroundColor Green
            Write-Host "  Has Active Logon Session: $hasActiveLogon" -ForegroundColor Green
            Write-Host "  Has Running Processes: $hasProcesses ($($processes.Count) processes)" -ForegroundColor Green
            Write-Host "  Has SMB Session: $hasSmbSession" -ForegroundColor Green
            Write-Host "  Status: ACTIVE (Not lingering)" -ForegroundColor Green
            Write-Host ""
        }
    }
    
    if ($lingeringSessions.Count -gt 0) {
        Write-Host "*** LINGERING SESSIONS FOUND ***" -ForegroundColor Red
        Write-Host "The following sessions appear in NetWkstaUserEnum but have NO active" -ForegroundColor Red
        Write-Host "logon sessions or running processes. These may need to be cleaned up:" -ForegroundColor Red
        Write-Host ""
        $lingeringSessions | Format-Table -AutoSize
        Write-Host ""
        Write-Host "RECOMMENDATION: Investigate these sessions. They may be:" -ForegroundColor Yellow
        Write-Host "  - Stale cached sessions" -ForegroundColor Yellow
        Write-Host "  - Sessions that didn't properly log off" -ForegroundColor Yellow
        Write-Host "  - Network logon sessions that are no longer active" -ForegroundColor Yellow
    } else {
        Write-Host "No lingering sessions detected." -ForegroundColor Green
        Write-Host "All sessions found in NetWkstaUserEnum have corresponding active logons or processes." -ForegroundColor Green
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
Write-Host "Note: NetWkstaUserEnum may show sessions that don't appear in other methods." -ForegroundColor Yellow
Write-Host "      These are the 'lingering' sessions that Section 5 identifies." -ForegroundColor Yellow

