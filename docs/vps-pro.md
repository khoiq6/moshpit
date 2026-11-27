# VPS Pro (experimental)
From Home, tap + then VPS workspace. Connect a host through its normal terminal before using tools.

- Linux: measured CPU from two /proc/stat samples, memory from MemAvailable, root filesystem from df. Poll every 10 seconds only while the dashboard is shown. Read-only process and listening-port lists. Explicit restart confirmation (sudo -n shutdown -r +1).
- Windows management uses the Windows SSH preset and authenticated PowerShell commands. Windows must have OpenSSH Server for this path.
- File manager reuses Moshpit's existing file browser and SSH channel. Code editor supports UTF-8 up to 1 MiB, saves a new file, never replaces the original. Windows SFTP requires real testing.
- GitHub: public Actions run listing with status and links, opens repository/commits in GitHub. Authenticated mutations and downloading private artifacts are not implemented.
- Device authentication is opt-in for the workspace only. It does not lock the rest of the app, its prompt window, notifications or extensions.
- AI/quick command buttons copy text without executing it. Existing terminal sessions remain the way to manage AI agents. Clipboard is manual only; never read in background. Linux SSH/Mosh reconnection and iPad split view remain upstream features.
- For the Windows desktop, choose **Windows RDP (direct)**. Enter the VPS IP or hostname and the RDP port (usually 3389) separately, plus a Windows account with Remote Desktop access. The optional HTTPS Guacamole gateway has a separate setup.
- Tests and iPhone performance measurements are required before use in production.

## Windows direct management
The Windows preset records a device-local OS flag. Workspace metrics, processes, TCP/UDP ports and running services now use a validated UTF-16LE PowerShell envelope over the already authenticated SSH connection, not POSIX sh. Restart is explicitly confirmed, uses a 60-second delay, and is never automatically retried. Windows file operations require SFTP; unsupported POSIX fallbacks are refused, including recursive deletion. These paths are not yet verified against a real Windows server.
