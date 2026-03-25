# Get-LingeringSessions.ps1

A PowerShell script that uses the Windows `NetWkstaUserEnum` API to detect lingering user sessions on Windows servers and workstations. The script compares sessions found via `NetWkstaUserEnum` with active logon sessions, running processes, and SMB sessions to identify stale or lingering sessions that may need cleanup.

## Features

- **Complete Enumeration**: Uses `NetWkstaUserEnum` to retrieve ALL user sessions (including machine accounts)
- **Multi-Method Comparison**: Compares results across multiple detection methods:
  - NetWkstaUserEnum (Windows NetAPI)
  - Win32_LogonSession (WMI)
  - Active Processes
  - SMB Sessions
- **Lingering Session Detection**: User-level check: if the target user appears in `NetWkstaUserEnum` but has no matching WMI logon sessions and no running processes, the script flags a lingering state
- **Remote-aware**: When `-TargetServer` is not the local computer, Sections 2–4 use WinRM/CIM (`Invoke-Command` for processes); Section 1 still uses `NetWkstaUserEnum` to the named server
- **Flexible identity matching**: Treats `DOMAIN\User`, `user@domain`, exact string, SAM-only, and `*\Sam` style SMB/process names as matches where appropriate
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

For remote targets, **Section 1** (`NetWkstaUserEnum`) uses the Windows NetAPI against `SERVER01`. **Sections 2–4** query that same host via **WinRM** (WMI/CIM and `Invoke-Command`). Ensure the WinRM client firewall rule is enabled on your machine, that the target allows remote WMI/CIM and PowerShell remoting where needed, and that you run with a principal that has rights comparable to your BloodHound collector (often a domain admin or delegated collection account). **SMB sessions** (Section 4) use a CIM session to the target; if that fails, Section 4 may be empty while other sections still succeed.

If you cannot use WinRM to the server, run the script **on the server** (local session or scheduled task) with `-TargetServer` omitted or set to the local computer name; Section 1 alone can still confirm whether `NetWkstaUserEnum` reports the user.

### Parameters

- **`-TargetUser`** (Required): User to match — typically `DOMAIN\Username`; `user@domain.com` is also accepted
- **`-TargetServer`** (Optional): The server or workstation to query. Defaults to local computer (`$env:COMPUTERNAME`). Use `.` or `localhost` for local

## Example Output

```
================================================================================
LINGERING SESSION DETECTION REPORT
================================================================================
Target Server: DC01-SERVER-22
Target User: TESTDOMAIN\Administrator
Query mode: Local

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
(User-level summary and NetWkstaUserEnum rows for the target user.)

ACTIVE USER STATE (not lingering by this heuristic):
  NetWkstaUserEnum row count for user: 1
  Has WMI logon session: True (1 session(s))
  Has running processes: True (28 process(es))
  Has SMB session (informational): False

NetWkstaUserEnum detail:
(table of matching rows)

================================================================================
SUMMARY
================================================================================
NetWkstaUserEnum Sessions: 13 total
Active Logon Sessions: 1
Running Processes: 28
SMB Sessions: 0

Note: NetWkstaUserEnum may show sessions that do not appear in other methods.
      Section 5 flags a lingering user state when that happens without logon/processes.
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
**This is the key section.** It applies a **user-level** heuristic (not per duplicate NetWkstaUserEnum row):

- The target user appears in `NetWkstaUserEnum` (Section 1), and
- There is **no** matching WMI logon session (Section 2), and
- There are **no** running processes for that identity (Section 3)

→ then the script reports a **lingering user state** and lists all NetWkstaUserEnum rows for that user. SMB (Section 4) is informational only. If the user has any active logon or any process, the script reports **active user state** and still shows the NetWkstaUserEnum rows for comparison (BloodHound `HasSession` is driven by that API, not by WMI alone).

## What is a Lingering Session?

A **lingering user state** (as reported here) means the account appears in `NetWkstaUserEnum` but:
- Has no corresponding active WMI logon session for that identity, and
- Has no running processes under that identity

It may be a stale cached entry, a session that did not fully log off, or similar. `NetWkstaUserEnum` can also return **duplicate rows** for the same user; the script does not try to map each row to a distinct logon (that data is not in level 1).

Such stale entries can consume resources, retain cached credentials, or indicate incomplete session cleanup.

## BloodHound and timing

SharpHound/BloodHound `HasSession` edges reflect **collection-time** data. A session can disappear between the last BloodHound run and when you run this script, or still be visible here after the graph was collected. Compare timestamps and collection scope when reconciling differences.

## Error Codes

If the script encounters errors, common return codes from `NetWkstaUserEnum`:
- **5**: Access Denied - Run as Administrator
- **53**: Network path not found - Check server name
- **87**: Invalid parameter - Internal error
- **234**: More data available (handled automatically)

## Notes

- Machine accounts (ending with `$`) are filtered out when analyzing user sessions
- The script handles multiple buffer reads automatically if there are many sessions
- **Run as Administrator** for reliable results: Section 3 needs elevation to list process owners; without it, Section 5 may show LINGERING with a warning that checks were incomplete—always read Section 1 for NetWkstaUserEnum facts regardless
- Remote queries need NetAPI access for Section 1 and WinRM/CIM (and remoting permissions) for Sections 2–3; use the same class of credentials you use for session collection where possible
- Avoid smart quotes when editing the script in some editors; PowerShell can mis-parse strings that contain Unicode apostrophes inside host strings

## License

This script is provided as-is for security research and system administration purposes.

## Contributing

Feel free to submit issues or pull requests if you find bugs or have suggestions for improvements.

