# StressTestEA v2 – MT5 High-Frequency Order Stress Tester

> **DEMO / STRESS-TEST USE ONLY.**
> This EA sends market orders as aggressively as the broker and platform
> allow.  It does **not** bypass broker protections, margin rules, stop-out
> logic, trading permissions, or server validation.

---

## What's New in v2

| Feature | Description |
|---------|-------------|
| **OrderSendAsync** | Non-blocking order sending — fire requests without waiting for server response |
| **Latency measurement** | `GetMicrosecondCount()` tracks per-request latency (µs precision) |
| **Broker throttle detection** | Counts consecutive `TOO_MANY_REQUESTS` responses |
| **Adaptive slowdown** | Auto-increases inter-attempt pause when broker throttles; recovers gradually |
| **RPS rolling stats** | Requests-per-second computed over a configurable sliding window |
| **Rejection histogram** | Breakdown of rejection counts by retcode for post-analysis |
| **Rolling throughput CSV** | Periodic STATS CSV rows with RPS, avg latency, throttle state |
| **Auto-close on margin** | Closes oldest position when margin level drops below threshold |
| **Stop-out proximity alerts** | Reads `ACCOUNT_MARGIN_SO_CALL` / `ACCOUNT_MARGIN_SO_SO` levels |
| **Phone push notifications** | `SendNotification()` on margin critical + emergency stop |
| **Enhanced CSV** | `CSV2` format adds `latency_us` and `attempt_count` fields |
| **Extended ACCT2** | Account snapshots now include SO_CALL and SO_STOPOUT levels |

---

## File Structure

```
Experts/
  StressTestEA/
    StressTestEA.mq5           ← Main EA v2.00 (attach to chart)
    README.md                  ← This file
    Modules/
      Config.mqh               ← All input parameters (30 inputs, 10 groups)
      Logger.mqh               ← Print logging, CSV/CSV2 events, retcode decoder
      SymbolInfo.mqh           ← Symbol cache, margin proximity helpers
      PositionManager.mqh      ← Position counting, close-oldest, margin-triggered close
      TradeEngine.mqh          ← Order send (sync/async), retry, latency, throttle
```

---

## Where to Place Files in MT5

1. Open MetaTrader 5.
2. **File → Open Data Folder** (or press `Ctrl+Shift+D`).
3. Navigate to `MQL5/Experts/`.
4. Copy the entire `StressTestEA/` folder there so you have:
   ```
   MQL5/Experts/StressTestEA/StressTestEA.mq5
   MQL5/Experts/StressTestEA/Modules/*.mqh
   ```

---

## How to Compile

1. In MetaTrader 5, press **F4** to open MetaEditor.
2. In the Navigator panel, open `Experts/StressTestEA/StressTestEA.mq5`.
3. Press **F7** (or click **Compile**).
4. Verify **0 errors** in the output panel.  Warnings about unused variables
   are harmless.
5. Switch back to MT5 (`Alt+Tab` or the MT5 icon in the taskbar).

---

## How to Attach to a Chart

1. In MT5, open a chart of the symbol you want to stress-test
   (e.g. EURUSD M1).
2. In the **Navigator** panel (Ctrl+N), expand **Expert Advisors**.
3. Find `StressTestEA` and **drag it onto the chart**, or double-click it.
4. In the properties dialog:
   - **Common** tab: check **Allow Algo Trading**.
   - **Inputs** tab: adjust parameters as needed (see below).
5. Click **OK**.
6. Make sure the **AutoTrading** button in the toolbar is **enabled**
   (green icon, not red).
7. The EA will start executing on the next tick / timer event.

---

## Input Parameters Reference

### Groups 1-7 (Core — same as v1)

| Group | Parameter | Default | Description |
|-------|-----------|---------|-------------|
| General | MagicNumber | 777777 | Unique ID to filter this EA's positions |
| General | TradeComment | StressEA | Comment tag on orders |
| General | DebugMode | false | Verbose `[DEBUG]` logging |
| General | CSVLogging | true | CSV event lines in Journal tab |
| Trade Mode | TradeMode | Both | BuyOnly / SellOnly / Alternate / Both |
| Execution | TickExecution | true | Run trade cycle on every tick |
| Execution | TimerExecution | true | Run trade cycle on timer |
| Execution | TimerMs | 100 | Timer interval in milliseconds |
| Execution | MaxReqPerCycle | 5 | Max order attempts per cycle |
| Execution | PauseBetweenMs | 50 | Delay between attempts within a cycle |
| Execution | BurstMode | false | Skip inter-attempt pause |
| Volume | LotSize | 0.01 | Fixed lot size per order |
| Limits | MaxOpenTotal | 50 | Max total open positions |
| Limits | MaxOpenBuy | 25 | Max simultaneous buy positions |
| Limits | MaxOpenSell | 25 | Max simultaneous sell positions |
| Mgmt | CloseOldest | false | Close oldest position when at limit |
| Mgmt | ReEntryAfterClose | false | Immediately open new order after close |
| Mgmt | Slippage | 50 | Max slippage in points |
| Safety | MaxSpreadPts | 100 | Skip trading if spread exceeds (0=off) |
| Safety | MinFreeMargin | 10.0 | Minimum free margin to trade |
| Safety | EmergencyStopPct | 50.0 | Halt if equity drops this % from start |
| Safety | MaxRetries | 3 | Retry count for requote/timeout |

### Groups 8-10 (New in v2)

| Group | Parameter | Default | Description |
|-------|-----------|---------|-------------|
| Async & Latency | UseAsync | false | Use `OrderSendAsync` (non-blocking sends) |
| Async & Latency | AdaptiveSlowdown | true | Auto slow-down on broker throttle |
| Async & Latency | ThrottleThreshold | 3 | Consecutive throttle hits before slowdown |
| Async & Latency | SlowdownMultiplier | 2.0 | Pause multiplier when throttled |
| Margin Safety | MarginAutoClose | false | Auto-close oldest when margin critical |
| Margin Safety | MarginWarningPct | 200.0 | Margin level % below which to alert |
| Margin Safety | NotifyOnCritical | false | Send phone push on margin critical |
| Statistics | StatsIntervalSec | 10 | Stats reporting interval (seconds) |
| Statistics | RPSWindowSec | 60 | Rolling window for RPS calculation |

### Recommended Presets

| Scenario | TimerMs | MaxReq | Burst | Async | Adaptive | Notes |
|----------|---------|--------|-------|-------|----------|-------|
| Ultra-aggressive | 50 | 10 | ON | ON | ON | Max throughput, async fire-and-forget |
| Moderate | 200 | 3 | OFF | OFF | ON | Balanced load, sync with retry |
| Conservative | 1000 | 1 | OFF | OFF | ON | Gentle probing |
| Latency benchmark | 200 | 1 | OFF | OFF | OFF | Isolate per-request latency |
| Throttle test | 50 | 20 | ON | ON | ON | Deliberately trigger broker throttle |

---

## v2 Features In Detail

### OrderSendAsync (Non-Blocking)

When `UseAsync = true`, orders are sent via `OrderSendAsync()` which returns
immediately after dispatching the request. The actual result arrives later
in `OnTradeTransaction()`. This allows the EA to fire orders rapidly without
blocking on server round-trips.

- Async results are resolved via a pending map (`request_id` → `send_timestamp`)
- Latency is measured from send to `OnTradeTransaction` callback
- CSV2 events: `ASYNC_SENT` when dispatched, `ASYNC_OK` / `ASYNC_FAIL` when resolved

### Latency Measurement

Every order request is timed using `GetMicrosecondCount()`:
- **Sync mode**: measures from pre-send to post-`OrderSend()` return
- **Async mode**: measures from pre-`OrderSendAsync()` to `OnTradeTransaction()` callback
- Average latency is reported in STATS CSV and OnDeinit summary
- Per-request latency is in every `CSV2` line (`latency_us` field)

### Broker Throttle Detection & Adaptive Slowdown

When the broker returns `TRADE_RETCODE_TOO_MANY_REQUESTS` (10024):
1. A throttle counter increments
2. When counter reaches `ThrottleThreshold`, the adaptive multiplier
   increases by `SlowdownMultiplier` (caps at 10x)
3. All inter-attempt pauses and retry backoffs are multiplied
4. On successful sends, the multiplier gradually recovers (x0.9 decay)
5. Throttle counter decreases every 30s of clean operation

### Margin Safety & Stop-Out Proximity

The EA reads broker stop-out levels at startup:
- `ACCOUNT_MARGIN_SO_CALL` — margin call level (warning)
- `ACCOUNT_MARGIN_SO_SO` — stop-out level (forced liquidation)

When `MarginAutoClose = true` and margin level drops below `MarginWarningPct`:
- Closes up to 3 oldest positions per check
- Logs warnings with current level, SO call, SO stop-out

When `NotifyOnCritical = true`:
- Sends push notification via `SendNotification()` (max once per 60s)
- Also sends notification on emergency equity stop
- Requires MetaQuotes ID configured: **Tools → Options → Notifications**

### Statistics Engine

Every `StatsIntervalSec` seconds, the EA reports:
- Total attempts / accepted / rejected
- Rolling RPS (requests per second) over the window
- Average latency in microseconds
- Throttle hit count and adaptive multiplier
- Position count, equity, margin level
- Full rejection histogram by retcode

---

## How to Run on VPS

### MT5 Built-In Virtual Hosting

1. Attach the EA to a chart and configure inputs.
2. In the **Navigator**, right-click the chart → **Virtual Hosting → Subscribe**.
3. Follow the MQL5.community wizard to rent a hosted VM.
4. MT5 migrates the chart + EA automatically.

### External VPS

1. Install MT5 on the VPS (Windows Server / VPS).
2. Copy the `StressTestEA/` folder to `MQL5/Experts/`.
3. Compile and attach as described above.
4. The EA runs 24/7 on the VPS.

---

## How to Monitor from the MT5 Phone App

1. Install **MetaTrader 5** from App Store / Google Play.
2. Log in with the **same trading account** (same broker, same login).
3. You will see:
   - **Trade** tab: all open positions.
   - **History** tab: closed deals with profit/loss.
   - **Messages** tab: push notifications (if `NotifyOnCritical = true`).
4. Use CSV logging + VPS file access for detailed monitoring.

### Push Notification Setup

1. In MT5 desktop: **Tools → Options → Notifications**.
2. Enter your **MetaQuotes ID** (shown in the phone app under Settings).
3. Enable `NotifyOnCritical = true` in the EA inputs.
4. You'll receive alerts when margin becomes critical or emergency stop triggers.

---

## Known Limits of Broker / Server-Side Rejection

| Rejection | Retcode | EA Behavior |
|-----------|---------|-------------|
| **Requote** | 10004 | Retries with fresh price (up to MaxRetries) |
| **Price changed** | 10020 | Retries with fresh price |
| **Timeout** | 10008 | Retries with escalating backoff |
| **Too many requests** | 10024 | Retries with 500ms+ backoff; triggers adaptive slowdown |
| **No money** | 10019 | Logs REJECTED, skips (no retry) |
| **Market closed** | 10018 | Skips cycle until market reopens |
| **Trade disabled** | 10017 | Skips (server or symbol level) |
| **Invalid volume** | 10014 | Logs REJECTED (check lot size) |
| **Position limit** | varies | Broker-enforced max positions |
| **Stop-out** | server-side | Broker auto-closes positions; EA continues normally |
| **Spread widening** | n/a | EA skips if spread > MaxSpreadPts |

### Broker-Specific Typical Limits

- **Request rate**: 5–30 orders/second (varies by broker).
- **Max open positions**: 100–1000 (broker-dependent).
- **Max volume per order**: Symbol-specific (`SYMBOL_VOLUME_MAX`).
- **Margin requirements**: Vary by symbol, leverage, account type.
- **Stop-out level**: Typically 20–50% margin level (broker-configured).

### Netting vs Hedging

- **Hedging accounts**: Each order creates an independent position.
  Position limits work as expected.
- **Netting accounts**: Only one net position per symbol.  Repeated
  same-direction orders increase volume; opposite direction orders
  reduce or flip the position.  Position count stays 0 or 1 per symbol.
  Alternate/Both mode on netting creates a rapid open-close cycle,
  which is ideal for order throughput testing.

---

## Log Formats

### Trade Events – v1 compat format (CSV)
```
CSV,2026.03.08 12:00:01,ATTEMPT,EURUSD,BUY,0.0100,1.09500,0,None,try_1
CSV,2026.03.08 12:00:01,ACCEPTED,EURUSD,BUY,0.0100,1.09502,10009,Done,ticket=12345
```

### Trade Events – v2 format (CSV2, with latency & attempts)
```
CSV2,2026.03.08 12:00:01,ATTEMPT,EURUSD,BUY,0.0100,1.09500,0,None,0,1,try_1
CSV2,2026.03.08 12:00:01,ACCEPTED,EURUSD,BUY,0.0100,1.09502,10009,Done,1234,1,ticket=12345
CSV2,2026.03.08 12:00:01,ASYNC_SENT,EURUSD,BUY,0.0100,1.09500,10008,Placed,89,1,req_id=5001
CSV2,2026.03.08 12:00:02,ASYNC_OK,EURUSD,BUY,0.0100,1.09502,10009,Done,15234,1,req_id=5001 ticket=12345
```

### Account Snapshots – v2 (ACCT2, with SO levels)
```
ACCT2,2026.03.08 12:00:10,10000.00,9985.50,120.00,9865.50,8321.25,100.00,50.00,12
```
Fields: Time, Balance, Equity, Margin, FreeMargin, MarginLevel, SOCallLevel, SOStopOutLevel, Positions

### Stats Snapshots (STATS)
```
STATS,2026.03.08 12:00:10,500,480,20,8.00,1234,0,1.00
```
Fields: Time, Attempts, Accepted, Rejected, RPS, AvgLatencyUs, ThrottleCount, AdaptiveMultiplier

### Rejection Histogram (REJECT)
```
REJECT,2026.03.08 12:00:10,10024,TooManyReq,5
REJECT,2026.03.08 12:00:10,10004,Requote,12
```

### Extracting CSV from MT5 Logs

1. In MT5: **View → Journal** or **View → Experts**.
2. Right-click → **Open** to find the log file.
3. Filter lines starting with `CSV2,`, `STATS,`, `ACCT2,`, or `REJECT,` using grep/Excel/Python.

---

## Disclaimer

This EA is designed for **demo account stress testing only**.  It will
consume margin rapidly and may trigger stop-out on live accounts.
The authors assume no liability for financial losses.  Always test on
a demo account first.
