# VPS Pro (experimental)
From Home, tap + then VPS workspace. Connect a host through its normal terminal before using tools.

- Linux: measured CPU from two /proc/stat samples, memory from MemAvailable, root filesystem from df. Poll every 10 seconds only while the dashboard is shown. Read-only process and listening-port lists. Explicit restart confirmation (sudo -n shutdown -r +1).
- Windows: existing SSH shell preset; PowerShell resource/process/port commands copied on demand, not background executed because the existing host exec is POSIX. No live Windows metrics yet.
- File manager reuses Moshpit's existing file browser and SSH channel. Code editor supports UTF-8 up to 1 MiB, saves a new file, never replaces the original. Windows SFTP requires real testing.
- GitHub: public Actions run listing with status and links, opens repository/commits in GitHub. Authenticated mutations and downloading private artifacts are not implemented.
- Device authentication is opt-in for the workspace only. It does not lock the rest of the app, its prompt window, notifications or extensions.
- AI/quick command buttons copy text without executing it. Existing terminal sessions remain the way to manage AI agents. Clipboard is manual only; never read in background. Linux SSH/Mosh reconnection and iPad split view remain upstream features.
- RDP remains HTTPS Guacamole. The gateway needs setup; native RDP, adaptive bitrate/FPS, native custom mouse, automatic RDP reconnect, Windows background exec, automatic clipboard sync, full-app lock, simultaneous multi-window terminals and private GitHub management are not implemented.
- Tests and iPhone performance measurements are required before use in production.
