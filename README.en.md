# Quota Board

[中文](README.md)

A macOS menu-bar app for remaining quota. It reads the Claude, Codex, Cursor, and Grok logins already on this machine, and Codex accounts on `sub2api`, `new-api`, and CPA. Each card shows the tightest window, when it resets, and the next billing day.

The quota endpoints are the ones those clients already use. The fields are not a stable public API. A failed read keeps the last successful result on the card.

## Menu bar and panel

The menu bar shows the official icon of the platform whose quota refreshes soonest, and the remaining percent of that window. With no future reset, it shows the window with the least remaining quota. Before the first reading it says “读取中”. When every reading failed it says “额度不可用”.

Open the menu bar for the panel:

- The remaining percent sits at the right of the title. The “…” next to the name sets the billing day. Codex cards can also be renamed or removed there.
- The billing day sits beside the caption “账单日”, for example “10月16日”. An empty day says “未设置”.
- Each usage window is its own row. A reset already in the past says “已重置”. A card with one window shows the percent only in the title.
- Cards start sorted by quota reset, nearest first. Cards with no future reset come after those. The header can switch to name order.
- Refresh in the panel reads again immediately. Otherwise it reads every 5 minutes.
- Quit from the bottom of the panel. The app has no Dock icon.

Cards use the same official icons as the menu bar. Cursor follows light or dark appearance. The mark in the panel header belongs to Quota Board.

## Requirements

macOS 14 and Swift 6. The Swift command-line tools are enough.

`swift run` has to disable the sandbox, or it cannot read the logins in your home directory. The built binary itself has no App Sandbox.

## Run

```sh
swift run --disable-sandbox QuotaBoard --self-test
swift run --disable-sandbox QuotaBoard
```

The self-test checks parsing and sorting. It does not open the menu bar or use the network.

Print one reading in the terminal:

```sh
swift run --disable-sandbox QuotaBoard --dump
```

To leave the app running in the menu bar, build it and start the binary:

```sh
swift build --disable-sandbox
"$(swift build --disable-sandbox --show-bin-path)/QuotaBoard"
```

## Where logins come from

- Claude: `~/.claude/.credentials.json`, and the Keychain item `Claude Code-credentials`. When the login expires, the app exchanges the existing refresh token and writes the new login back after a successful refresh.
- Codex: `$CODEX_HOME/auth.json`, or `~/.codex/auth.json`. The local reader uses that one file.
- Cursor: `cursorAuth/accessToken` and `cursorAuth/stripeMembershipType` in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`.
- Grok: `$GROK_HOME/auth.json`, or `~/.grok/auth.json`. When the login expires, the app launches `grok` once and lets it refresh itself.

## Codex from a gateway

Configuration lives in `~/.quota-board/upstreams.json`. The sample in the repo is `upstreams.example.json`. `QUOTA_BOARD_UPSTREAMS` can point at another file.

```json
{
  "upstreams": [
    {
      "kind": "sub2api",
      "name": "sub2api",
      "baseURL": "https://your-sub2api.example",
      "keychainAccount": "sub2api"
    },
    {
      "kind": "new-api",
      "name": "new-api",
      "baseURL": "https://your-new-api.example",
      "userID": "1",
      "keychainAccount": "new-api"
    },
    {
      "kind": "cpa",
      "name": "cpa",
      "baseURL": "https://your-cpa.example",
      "keychainAccount": "cpa"
    }
  ]
}
```

`baseURL` is the site root. `kind` is `sub2api`, `new-api`, or `cpa`. `new-api` requires `userID`. The Keychain service defaults to `quota-board`; set `keychainService` to use another one.

Admin credentials go in the Keychain, not in the config file. These commands prompt for the password:

```sh
security add-generic-password -U -s quota-board -a sub2api -w
security add-generic-password -U -s quota-board -a new-api -w
security add-generic-password -U -s quota-board -a cpa -w
```

sub2api uses an admin JWT, new-api an admin access token, and CPA a management key. The app requests the account list and usage only. It does not download login files, read channel secrets, or spend reset allowances.

One subscription that shows up both locally and on these gateways becomes one card. Matching uses the account id, user id, or email, and those values are not displayed. A channel name that looks like an email is not used as a title. A local login or a new-api reading wins over sub2api, then CPA.

With several Codex cards, the title is the name from the gateway. A name that looks like an email, a long account id, or the word “Codex” is shown as “Codex” or “Codex 2”. A single card is titled “Codex”.

Pro 200 has no 5-hour window. sub2api may still return one. The row is hidden when the plan is Pro 200, or when `codex_5h_window_minutes` is 0 or less. Other plans keep it when the minute count is greater than 0. A missing minute count keeps a 5-hour window that is already present.

## Billing day

The quota reset time is on each window. It chooses the menu-bar icon and the default card order. The billing day is the subscription date, on its own line.

Automatic sources:

- Cursor uses `billingCycleEnd`.
- Grok uses `billingPeriodEnd`. The weekly quota reset stays on the window row.
- Codex uses the subscription end in the local login token, sub2api `subscription_expires_at`, or `chatgpt_subscription_active_until` in the CPA token.
- The Claude usage endpoint has no billing day.

Set a missing day from the card menu. A day that was read automatically can be edited too. A manual day wins; clearing it restores the automatic day. A past day moves forward to the same day next month. A short month uses the last day of that month.

Days are stored in `~/.quota-board/billing.json`. The key is the account’s stable identity, and the value is `yyyy-MM-dd`:

```json
{
  "claude": "2026-11-01",
  "acct:acct-a": "2026-10-16"
}
```

Local Claude, Cursor, and Grok use the card id. A merged Codex account uses a key starting with `acct:`, `user:`, or `mail:`. Without those, the key starts with `row:`.

## Names, hiding, and sort

Codex cards can be renamed or removed from the menu next to the name. A name can be at most 32 characters. The saved name is used on the card and in the menu bar. Clearing it restores the gateway name.

A removed account stays out of the menu bar and the panel. Refresh does not bring it back. “已隐藏” at the bottom of the panel restores it.

These choices live in `~/.quota-board/accounts.json`:

```json
{
  "hidden": ["acct:old"],
  "names": {
    "acct:work": "公司号"
  },
  "sort": "expiry"
}
```

`sort` is `expiry` or `name`. A missing or unknown value sorts by expiry. `expiry` orders cards by the nearest quota reset. `name` orders them by the name on the card.

Claude, Cursor, and Grok card menus contain only the billing day.

## Releases

Pushing a `v*` tag makes GitHub Actions build a universal macOS binary and publish it on [Releases](https://github.com/yixian-huang/quota-board/releases). The first version is [0.0.1](https://github.com/yixian-huang/quota-board/releases/tag/v0.0.1).

The archive contains `QuotaBoard` and `QuotaBoard_QuotaBoard.bundle` beside it. Keep them in the same directory:

```sh
unzip QuotaBoard-macos.zip
./QuotaBoard
```

A browser download may be blocked by macOS. From that same directory, run `xattr -d com.apple.quarantine QuotaBoard`, then open it again.

## License

[MIT](LICENSE)
