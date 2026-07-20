# Security Policy

SnipKey watches what you type (to detect abbreviations) and types on your behalf
(to insert expansions), using macOS Accessibility. It has **no networking code** —
nothing you type leaves your Mac, and there is no account or server. Your snippet
library is a plain JSON file on disk.

## Reporting a vulnerability

Please report security issues privately, not as a public issue:

- Email **dkdannyboy@gmail.com** with "SnipKey security" in the subject, or
- Use GitHub's **[Report a vulnerability](https://github.com/dkdannyboy/snipkey/security/advisories/new)**
  (Security → Advisories).

Include the SnipKey version, macOS version, and steps to reproduce. I'll acknowledge
the report and keep you updated on the fix.

## Supported versions

Only the latest release receives security fixes. Please update before reporting.

## Scope

In scope: anything that could let another process or a malicious snippet read data
it shouldn't, run unintended code, or exfiltrate keystrokes/clipboard. Out of scope:
the fact that SnipKey needs Accessibility permission (every text expander does), and
behavior that requires the attacker to already control your Mac.
