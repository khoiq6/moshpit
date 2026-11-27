# Release acceptance checklist (VPS Pro)

Status: **NOT READY FOR RELEASE**. Do not dispatch IPA packaging until every required item below has a recorded passing result. A successful compilation does not establish feature completeness.

- [ ] Native direct Windows RDP (NLA, trusted certificate, no mandatory gateway)
- [ ] Physical mouse, direct touch, relative trackpad, right click, drag, scroll, zoom, hardware/IME keyboard
- [ ] Measured frame rate, input latency, bandwidth; adaptive performance and automatic RDP reconnect
- [ ] Linux and Windows CPU/RAM/disk, process and listening-port dashboard using actual server data
- [ ] Linux and Windows file browsing/upload/download/edit/extract, safe overwrite with confirmation and recovery
- [ ] Multiple saved VPS and simultaneous terminal sessions; switch without losing state
- [ ] AI workspace, saved commands, authenticated GitHub Actions and artifact management
- [ ] Explicit clipboard sync controls and privacy checks; no background clipboard reads without user action
- [ ] Full app authentication coverage, including modal/prompt windows, background snapshots and re-entry
- [ ] Unit/integration tests, real Windows and Linux test servers, physical iPhone Wi-Fi/5G measurements
- [ ] Vietnamese copy and layout review; no regression in original SSH/Mosh or signing

Existing experimental code is not acceptance evidence. Record tested OS/device, commit, configuration, measured results, failures and fixes here. Keep packaging manual on this branch. Existing runs created before this change may still finish.
