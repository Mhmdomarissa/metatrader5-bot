# StressTestEA – MT5 Rapid-Fire Order Stress Tester

> **DEMO / STRESS-TEST USE ONLY.**
> This EA sends market orders as aggressively as the broker and platform
> allow.  It does **not** bypass broker protections, margin rules, stop-out
> logic, trading permissions, or server validation.

---

## File Structure

```
Experts/
  StressTestEA/
    StressTestEA.mq5           ← Main EA (attach to chart)
    README.md                  ← This file
    Modules/
      Config.mqh               ← All input parameters
      Logger.mqh               ← Print logging, CSV events, retcode decoder
      SymbolInfo.mqh           ← Symbol property cache & helpers
      PositionManager.mqh      ← Position counting & close-oldest
      TradeEngine.mqh          ← Order build, send, retry, classify
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

### Recommended Presets

| Scenario | TimerMs | MaxReq | Burst | Pause | Retries | Notes |
|----------|---------|--------|-------|-------|---------|-------|
| Ultra-aggressive | 50 | 10 | ON | 0 | 0 | Max throughput |
| Moderate | 200 | 3 | OFF | 100 | 2 | Balanced load |
| Conservative | 1000 | 1 | OFF | 500 | 3 | Gentle probing |
| Netting rapid-cycle | 50 | 2 | ON | 0 | 1 | BUY+SELL = open/close loop |

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
   - **Trade** tab: all open positions (filtered by magic if you check comments).
   - **History** tab: closed deals with profit/loss.
   - **Messages** tab: push notifications (if configured).
4. The phone app shows **live positions and equity** but does not show
   EA logs.  Use CSV logging + VPS file access for detailed monitoring.

### Optional: Push Notifications

Add `SendNotification("message")` calls in the EA code to receive
push alerts on your phone.  Requires configuring your MetaQuotes ID
in MT5: **Tools → Options → Notifications**.

---

## Known Limits of Broker / Server-Side Rejection

| Rejection | Retcode | EA Behavior |
|-----------|---------|-------------|
| **Requote** | 10004 | Retries with fresh price (up to MaxRetries) |
| **Price changed** | 10020 | Retries with fresh price |
| **Timeout** | 10008 | Retries with escalating backoff |
| **Too many requests** | 10024 | Retries with 500ms+ backoff |
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

### Trade Events (CSV)
```
CSV,2026.03.08 12:00:01,ATTEMPT,EURUSD,BUY,0.0100,1.09500,0,None,try_1
CSV,2026.03.08 12:00:01,ACCEPTED,EURUSD,BUY,0.0100,1.09502,10009,Done,ticket=12345
CSV,2026.03.08 12:00:01,REJECTED,EURUSD,SELL,0.0100,1.09498,10019,NoMoney,NoMoney
CSV,2026.03.08 12:00:02,RETRY,EURUSD,BUY,0.0100,1.09500,10004,Requote,try_1_sleep_100ms
CSV,2026.03.08 12:00:03,CLOSE,EURUSD,SELL,0.0100,1.09510,10009,Done,ticket=12340
```

### Account Snapshots (ACCT)
```
ACCT,2026.03.08 12:00:10,10000.00,9985.50,120.00,9865.50,8321.25,12
```

### Extracting CSV from MT5 Logs

1. In MT5: **View → Journal** or **View → Experts**.
2. Right-click → **Open** to find the log file.
3. Filter lines starting with `CSV,` or `ACCT,` using grep/Excel/Python.

---

## Disclaimer

This EA is designed for **demo account stress testing only**.  It will
consume margin rapidly and may trigger stop-out on live accounts.
The authors assume no liability for financial losses.  Always test on
a demo account first.
