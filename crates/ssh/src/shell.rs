//! Command lines any login shell parses the same way (B138): `sh`, dash,
//! bash, zsh — and fish, which the others' rules don't fit.
//!
//! sshd runs an exec request as `<login shell> -c <command>`. Moshpit's
//! commands are POSIX sh; fish refuses `$?` and `$$` ("$? is not the exit
//! status. In fish, please use $status."), has no `while … do … done`, and
//! inside single quotes takes `\'` and `\\` as escapes, so a quoted value
//! ending in `\` never closes its quote (fish 3.7.1 and 4.6.0). So every
//! exec request goes out as `sh -c <payload>` ([`portable`]), and every
//! quoted word keeps `'` and `\` outside its quotes ([`quote`]) — the one
//! form that reads the same in all five. `harness/shells.py` runs every
//! command line the app builds through all of them.
//!
//! The app's own copies: `Shell.quote` and `Shell.portable`
//! (`Moshpit/Services/Shell.swift`); moshpit-herdr's and moshpit-install's
//! `quote` are this one too.

/// `value` as one shell word, whatever it holds, in any login shell: wrapped
/// in single quotes, with each `'` closed, escaped and reopened (`'\''`)
/// and each `\` likewise (`'\\'`). Inside the quotes nothing is left that
/// any of the five reads specially — not `$`, a backtick, a newline or a
/// glob in POSIX shells; not `\` in fish. By `char`: `'` and `\` are one
/// byte of UTF-8 and never part of another character.
pub fn quote(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('\'');
    for c in value.chars() {
        match c {
            '\'' => out.push_str(r"'\''"),
            '\\' => out.push_str(r"'\\'"),
            c => out.push(c),
        }
    }
    out.push('\'');
    out
}

/// `script`, a POSIX sh script, as a command line any login shell runs as
/// that script: `sh -c <script quoted>`. The login shell parses one word;
/// sh parses the rest.
pub fn portable(script: &str) -> String {
    format!("sh -c {}", quote(script))
}

/// The FFI run(String) ABI is shared with older clients, so a versioned
/// envelope selects Windows without changing the generated bindings.
/// Only one base64 word may cross the Windows login shell; never interpolate
/// arbitrary text, credentials, metacharacters or paths into that command line.
pub const POWERSHELL_PREFIX: &str = "@moshpit/ps-v1:";

pub fn borrowed_line(command: &str) -> Option<String> {
    let Some(encoded) = command.strip_prefix(POWERSHELL_PREFIX) else {
        return Some(portable(command));
    };
    let body = encoded.trim_end_matches('=');
    let padding = encoded.len() - body.len();
    if body.is_empty() || encoded.len() > 24_000 || encoded.len() % 4 != 0
        || padding > 2 || !body.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
    {
        return None;
    }
    Some(format!("powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand {encoded}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quote_keeps_quotes_and_backslashes_outside() {
        assert_eq!(quote("plain"), "'plain'");
        assert_eq!(quote("it's"), r"'it'\''s'");
        assert_eq!(quote(r"a\"), r"'a'\\''");
        assert_eq!(quote(r"\'"), r"''\\''\'''");
        assert_eq!(quote(""), "''");
    }

    #[test]
    fn powershell_envelope_is_one_validated_argument() {
        assert_eq!(borrowed_line("echo hello"), Some(portable("echo hello")));
        assert_eq!(
            borrowed_line("@moshpit/ps-v1:ZQB4AGkAdAAgADAA"),
            Some("powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand ZQB4AGkAdAAgADAA".to_owned())
        );
        for value in ["", "aaaa;whoami", "aaaa bbbb", "ab=c", "a===", "aa", "aaaa\n"] {
            assert_eq!(borrowed_line(&format!("{POWERSHELL_PREFIX}{value}")), None, "{value:?}");
        }
    }

    #[test]
    fn portable_is_one_word_for_the_login_shell() {
        assert_eq!(
            portable(r#"herdr x; echo "rc=$?""#),
            r#"sh -c 'herdr x; echo "rc=$?"'"#
        );
    }
}
