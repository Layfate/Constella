# Security policy

Constella handles client requests (Network), replicated state (Replication) and player data (Data), so security problems matter here.

## Reporting a vulnerability

Please report vulnerabilities **privately**, not in a public issue: open the repository's **Security** tab and choose **Report a vulnerability**. Include:

- the module and version (`Constella.Version`);
- what an attacker can do, for example bypass validation, crash a server, read or corrupt another player's data;
- the smallest steps or code that show it.

You'll get a reply within a week. A fix is released as soon as it's ready, with credit in the changelog unless you'd rather stay anonymous.

## Supported versions

Until 1.0, only the latest release gets security fixes.

## Scope

In scope: anything a client can do to a server through Constella's remotes, data loss or corruption through Data, and leaks of server-only information to clients.

Out of scope: problems in your own handlers or validation rules, and Roblox engine issues (report those to Roblox).
