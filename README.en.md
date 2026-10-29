# Quota Board

[中文](README.md)

A macOS menu-bar app for remaining quota. It reads the Claude, Codex, Cursor, and Grok logins already on this machine, and Codex accounts on `sub2api`, `new-api`, and CPA. The panel is one dark screen: each card shows the tightest window, when it resets, and the next billing day.

The quota endpoints are the ones those clients already use. The fields are not a stable public API. A failed read keeps the last successful result on the card.

## Run

macOS 14 and Swift 6. `swift run` has to disable the sandbox, or it cannot read the logins in your home directory. The built binary itself has no App Sandbox.

```sh
swift run --disable-sandbox QuotaBoard --self-test
swift run --disable-sandbox QuotaBoard --dump
swift build --disable-sandbox
"$(swift build --disable-sandbox --show-bin-path)/QuotaBoard"
```

The panel uses SwiftUI. A Command Line Tools `swift` fails with a missing `SwiftUIMacros` plugin. Point the developer directory at Xcode, then run the commands above:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"
```

`--self-test` checks parsing, sorting, meters, remaining value, and reset-feed documents. It does not open the menu bar or use the network. `--dump` prints one reading in the terminal. The last command leaves the app in the menu bar.

The menu bar still shows the window that expires soonest and its remaining percent, and it follows the system appearance. The panel is a warm plate around one dark screen. Meter bars light by what remains; a full bar is unused. 70% used turns amber and 90% turns red. The app reads quota every 5 minutes. Refresh in the panel reads again immediately. The app has no Dock icon.

The screen has two pages. Quota can switch between a list and a chart. A list card is the name, the meters, a note, then the billing day. Windows that reset at the same moment share one countdown. The chart lines the accounts up as a meter bridge, with a log-scaled reset timeline underneath. The timeline stays hidden when nothing resets in the future. Reset notices are a placeholder and do not call a feed. Panel appearance can follow the system, or stay light or dark. That choice changes only the panel.

## Local logins

- Claude: `~/.claude/.credentials.json`, and the Keychain item `Claude Code-credentials`. When the login expires, the app exchanges the existing refresh token and writes the new login back after a successful refresh.
- Codex: `$CODEX_HOME/auth.json`, or `~/.codex/auth.json`. The local reader uses that one file.
- Cursor: `cursorAuth/accessToken` and `cursorAuth/stripeMembershipType` in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`.
- Grok: `$GROK_HOME/auth.json`, or `~/.grok/auth.json`. When the login expires, open `grok` once and let it refresh the login.

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

`accounts.json` stores Codex `hidden`, `names`, and `sort`. `sort` is `expiry` or `name`. A missing value sorts by expiry. A name can be at most 32 characters. A removed account stays hidden after refresh. Restore it from “已隐藏” at the bottom of the list. The chart only says how many are hidden. Claude, Cursor, and Grok card menus contain only the billing day.

Remaining value uses built-in monthly USD list prices, checked around 2026-10-29. The prices exclude tax and ignore annual discounts. A card shows a value only when its plan matches. The total at the top of the screen appears only when at least one card has a price. Value is the monthly price times the tightest window's remaining share, shown as a whole unit.

| Platform | Plan | Per month |
| --- | --- | --- |
| Claude | Pro / Max 5x / Max 20x | $20 / $100 / $200 |
| Codex | Go / Plus / Pro 100 / Pro 200 / Pro 500 | $8 / $20 / $100 / $200 / $500 |
| Cursor and Grok | Plus / Premium / Super / Ultra | $8 / $30 / $100 / $200 |
| Legacy Cursor | Pro / Pro+ | $20 / $60 |
| Legacy Grok | SuperGrok | $30 |

A Claude card that only says Max has no price, because Max 5x and Max 20x differ. Team, Enterprise, and per-seat team plans also have no single monthly price. Free is $0.

`fees.json` can replace a built-in price. The sample is `fees.example.json`. It marks the local Claude account as Max 20x at $200. An `accounts` key is the same account id as in `billing.json`, and it wins over the plan price. A `plans` key is the plan name trimmed, lowercased, with spaces replaced by `-` and `+` replaced by `-plus`. That override applies to every platform. A number is US dollars. An object is `{"amount": 200, "currency": "USD"}`.

The reset-notices page is a placeholder. The panel does not request a feed. Quota Board does not read x.com.

## Releases

Pushing a `v*` tag makes GitHub Actions build a universal macOS binary and publish it on [Releases](https://github.com/yixian-huang/quota-board/releases).

The archive contains `QuotaBoard` and `QuotaBoard_QuotaBoard.bundle` beside it. Keep them in the same directory. A browser download may be blocked by macOS. From that same directory, run `xattr -d com.apple.quarantine QuotaBoard`, then open it again.

## License

[MIT](LICENSE)
