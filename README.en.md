# Quota Board

[中文](README.md)

A macOS menu-bar app for remaining quota. It reads the Claude, Codex, Cursor, and Grok logins already on this machine, and Codex accounts on `sub2api`, `new-api`, and CPA. Each card shows the tightest window, when it resets, and the next billing day.

The quota endpoints are the ones those clients already use. The fields are not a stable public API. A failed read keeps the last successful result on the card.

## Run

macOS 14 and Swift 6. `swift run` has to disable the sandbox, or it cannot read the logins in your home directory. The built binary itself has no App Sandbox.

```sh
swift run --disable-sandbox QuotaBoard --self-test
swift run --disable-sandbox QuotaBoard --dump
swift build --disable-sandbox
"$(swift build --disable-sandbox --show-bin-path)/QuotaBoard"
```

`--self-test` checks parsing and sorting. It does not open the menu bar or use the network. `--dump` prints one reading in the terminal. The last command leaves the app in the menu bar.

The menu bar shows the window that expires soonest and its remaining percent. Open it for the cards. The app reads every 5 minutes. Refresh in the panel reads again immediately. The app has no Dock icon.

## Local logins

- Claude: `~/.claude/.credentials.json`, and the Keychain item `Claude Code-credentials`. When the login expires, the app exchanges the existing refresh token and writes the new login back after a successful refresh.
- Codex: `$CODEX_HOME/auth.json`, or `~/.codex/auth.json`. The local reader uses that one file.
- Cursor: `cursorAuth/accessToken` and `cursorAuth/stripeMembershipType` in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`.
- Grok: `$GROK_HOME/auth.json`, or `~/.grok/auth.json`. When the login expires, the app launches `grok` once and lets it refresh itself.

## Gateways

Configuration lives in `~/.quota-board/upstreams.json`. The sample in the repo is `upstreams.example.json`. `QUOTA_BOARD_UPSTREAMS` can point at another file.

`baseURL` is the site root. `kind` is `sub2api`, `new-api`, or `cpa`. `new-api` requires `userID`. The Keychain service defaults to `quota-board`; set `keychainService` to use another one.

Admin credentials go in the Keychain, not in the config file. These commands prompt for the password:

```sh
security add-generic-password -U -s quota-board -a sub2api -w
security add-generic-password -U -s quota-board -a new-api -w
security add-generic-password -U -s quota-board -a cpa -w
```

sub2api uses an admin API key in the `x-api-key` header. An admin JWT still in the Keychain is sent as `Authorization: Bearer`. The app sends only one of the two. new-api uses an admin access token, and CPA a management key. The app requests the account list and usage only.

One subscription that shows up both locally and on these gateways becomes one card. A local login or a new-api reading wins over sub2api, then CPA.

## Local settings

Billing days, and Codex card names, hidden accounts, and sort order, live in `~/.quota-board/`.

In `billing.json` the key is the account id and the value is `yyyy-MM-dd`. Automatic billing days come from Cursor `billingCycleEnd`, Grok `billingPeriodEnd`, and the Codex subscription end. Claude has none. The card menu can change a day. A manual day wins; clearing it restores the automatic day.

`accounts.json` stores Codex `hidden`, `names`, and `sort`. `sort` is `expiry` or `name`. A missing value sorts by expiry. A name can be at most 32 characters. A removed account stays hidden after refresh. Restore it from “已隐藏” at the bottom of the panel. Claude, Cursor, and Grok card menus contain only the billing day.

## Releases

Pushing a `v*` tag makes GitHub Actions build a universal macOS binary and publish it on [Releases](https://github.com/yixian-huang/quota-board/releases).

The archive contains `QuotaBoard` and `QuotaBoard_QuotaBoard.bundle` beside it. Keep them in the same directory. A browser download may be blocked by macOS. From that same directory, run `xattr -d com.apple.quarantine QuotaBoard`, then open it again.

## License

[MIT](LICENSE)
