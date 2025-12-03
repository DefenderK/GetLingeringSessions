# Get-LingeringSessions.ps1

A PowerShell script that uses the Windows `NetWkstaUserEnum` API to detect lingering user sessions on Windows servers and workstations. The script compares sessions found via `NetWkstaUserEnum` with active logon sessions, running processes, and SMB sessions to identify stale or lingering sessions that may need cleanup.

## Features

- **Complete Enumeration**: Uses `NetWkstaUserEnum` to retrieve ALL user sessions (including machine accounts)
- **Multi-Method Comparison**: Compares results across multiple detection methods:
  - NetWkstaUserEnum (Windows NetAPI)
  - Win32_LogonSession (WMI)
  - Active Processes
  - SMB Sessions
- **Lingering Session Detection**: Automatically identifies sessions that appear in `NetWkstaUserEnum` but have no active logon sessions or running processes
- **Detailed Reporting**: Clear section-by-section breakdown with explanations

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Administrator privileges (recommended, especially for remote servers)
- Access to the target server/workstation

## Usage

### Basic Usage

1. Download the script to your target system (or git clone)
2. Open PowerShell as Administrator
3. Navigate to the script directory
4. Unblock the file (required for downloaded scripts):
   ```powershell
   Unblock-File -Path ".\Get-LingeringSessions.ps1"
   ```
5. Run the script:
   ```powershell
   .\Get-LingeringSessions.ps1 -TargetUser "DOMAIN\Username"
   ```

### Query Remote Server

```powershell
.\Get-LingeringSessions.ps1 -TargetServer "SERVER01" -TargetUser "DOMAIN\Username"
```

### Parameters

- **`-TargetUser`** (Required): The user account to search for in `DOMAIN\Username` format
- **`-TargetServer`** (Optional): The server or workstation to query. Defaults to local computer (`$env:COMPUTERNAME`)

## Example Output

```
================================================================================
LINGERING SESSION DETECTION REPORT
================================================================================
Target Server: DC01-SERVER-22
Target User: TESTDOMAIN\Administrator

================================================================================
SECTION 1: NetWkstaUserEnum - ALL SESSIONS
================================================================================
WHAT THIS SHOWS: Complete list of ALL user sessions returned by the Windows
                 NetWkstaUserEnum API. This includes:
                 - Active user logon sessions
                 - Machine account sessions (computer$ accounts)
                 - Cached/stale sessions that may not appear elsewhere
                 - Network logon sessions

Total sessions found: 13

ALL SESSIONS (including machine accounts):

Username        LogonDomain OtherDomains LogonServer    FullName
--------        ----------- ------------ -----------    --------
DC01-SERVER-22$ TESTDOMAIN                               TESTDOMAIN\DC01-SERVER-22$
Administrator   TESTDOMAIN                DC01-SERVER-22 TESTDOMAIN\Administrator
DC01-SERVER-22$ TESTDOMAIN                               TESTDOMAIN\DC01-SERVER-22$
...

Sessions matching 'TESTDOMAIN\Administrator' (excluding machine accounts):

Username      LogonDomain OtherDomains LogonServer    FullName
--------      ----------- ------------ -----------    --------
Administrator TESTDOMAIN                DC01-SERVER-22 TESTDOMAIN\Administrator

================================================================================
SECTION 2: Win32_LogonSession - ACTIVE LOGON SESSIONS
================================================================================
WHAT THIS SHOWS: Currently active logon sessions visible to WMI.
                 These represent sessions that are actively logged on.
                 LogonType meanings:
                 2 = Interactive, 3 = Network, 10 = RemoteInteractive (RDP)

Active logon sessions found: 1

LogonId LogonType LogonTypeName          StartTime                 User
------- --------- -------------          ---------                 ----
381678         10 RemoteInteractive (RDP) 20251010031554.997710-420 TESTDOMAIN\Administrator

================================================================================
SECTION 3: PROCESSES - ACTIVE PROCESSES RUNNING AS USER
================================================================================
WHAT THIS SHOWS: All processes currently running with the target user's
                 security context. Active sessions will have processes.

Active processes found: 28

Name                      Id UserName
----                      -- --------
explorer                6816 TESTDOMAIN\Administrator
powershell              2160 TESTDOMAIN\Administrator
...

================================================================================
SECTION 4: SMB SESSIONS - NETWORK FILE SHARING SESSIONS
================================================================================
WHAT THIS SHOWS: Active SMB (Server Message Block) file sharing sessions.
                 These represent network file share connections.

No SMB sessions found for 'TESTDOMAIN\Administrator'

================================================================================
SECTION 5: LINGERING SESSION ANALYSIS
================================================================================
WHAT THIS SHOWS: Sessions that appear in NetWkstaUserEnum but are NOT
                 found in active logon sessions or processes.
                 These are LINGERING sessions that may need cleanup.

ACTIVE SESSION DETECTED:
  User: TESTDOMAIN\Administrator
  Logon Server: DC01-SERVER-22
  Has Active Logon Session: True
  Has Running Processes: True (28 processes)
  Has SMB Session: False
  Status: ACTIVE (Not lingering)

No lingering sessions detected.
All sessions found in NetWkstaUserEnum have corresponding active logons or processes.

================================================================================
SUMMARY
================================================================================
NetWkstaUserEnum Sessions: 13 total
Active Logon Sessions: 1
Running Processes: 28
SMB Sessions: 0

Note: NetWkstaUserEnum may show sessions that don't appear in other methods.
      These are the 'lingering' sessions that Section 5 identifies.
```

## Understanding the Output

### Section 1: NetWkstaUserEnum
Shows **all** sessions returned by the Windows NetAPI, including:
- User logon sessions
- Machine account sessions (computer$ accounts) - these are normal
- Potentially stale/cached sessions

### Section 2: Win32_LogonSession
Shows currently **active** logon sessions. If a session appears here, it's actively logged on.

### Section 3: Processes
Shows processes running as the target user. Active sessions will have processes.

### Section 4: SMB Sessions
Shows network file sharing connections. May be empty if no file shares are connected.

### Section 5: Lingering Session Analysis
**This is the key section** - it identifies sessions that:
- ✅ Appear in `NetWkstaUserEnum` (Section 1)
- ❌ Do NOT have an active logon session (Section 2)
- ❌ Do NOT have running processes (Section 3)

These are **lingering sessions** that may need cleanup.

## What is a Lingering Session?

A lingering session is a user session that appears in `NetWkstaUserEnum` but:
- Has no corresponding active logon session
- Has no running processes
- May be a stale cached session or a session that didn't properly log off

These sessions can:
- Consume system resources
- Pose security risks if credentials are cached
- Indicate improper session cleanup

## Error Codes

If the script encounters errors, common return codes from `NetWkstaUserEnum`:
- **5**: Access Denied - Run as Administrator
- **53**: Network path not found - Check server name
- **87**: Invalid parameter - Internal error
- **234**: More data available (handled automatically)

## Notes

- Machine accounts (ending with `$`) are filtered out when analyzing user sessions
- The script handles multiple buffer reads automatically if there are many sessions
- Administrator privileges are recommended for best results
- Remote queries require appropriate network access and permissions

## License

This script is provided as-is for security research and system administration purposes.

## Contributing

Feel free to submit issues or pull requests if you find bugs or have suggestions for improvements.

