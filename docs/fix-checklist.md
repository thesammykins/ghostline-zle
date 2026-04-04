# Fix Checklist

- [x] Create and maintain this checklist document while working
- [x] Replace deprecated `session.destroy()` usage with `session.disconnect()`
- [x] Pass `workingDirectory` into SDK session creation paths
- [x] Make shell requests send explicit model and full live context
- [x] Reuse the shared payload builder for autofix
- [x] Preserve alternate command candidates through daemon/ZLE transport
- [x] Make daemon/ZLE response framing safe for multiline text
- [x] Parse newline-delimited alias context correctly
- [x] Refresh daemon state or retry on stale port failures
- [x] Fix dry validation for commands with leading env assignments
- [x] Add regression tests for the changed runtime behavior
- [x] Run project checks and fix failures
- [x] Sync the finished plugin into `~/.dotfiles`
