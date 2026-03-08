# ProGridEA – MetaTrader 5 Expert Advisor Framework

A production-ready, modular MQL5 Expert Advisor with pluggable strategy logic, comprehensive risk management, structured logging, and full lifecycle support.

---

## Project Structure

```
Experts/ProGridEA/
├── ProGridEA.mq5              ← Main EA file (lifecycle: OnInit/OnTick/OnTimer/OnTradeTransaction)
└── Modules/
    ├── Config.mqh             ← All input parameters grouped by category
    ├── Logger.mqh             ← Structured Print logging with levels (DEBUG/INFO/WARN/ERROR)
    ├── Utils.mqh              ← Pure helpers: price, lot, symbol, bar, permission utilities
    ├── SignalEngine.mqh       ← Strategy logic (default: MA crossover – easily swappable)
    ├── RiskManager.mqh        ← Pre-trade safeguards, lot sizing, drawdown/margin guards
    ├── TradeExec.mqh          ← MqlTradeRequest builder, OrderCheck, OrderSend, retcode handling
    └── PositionMgr.mqh        ← Trailing stop, break-even, duplicate detection, modify SL/TP
```

### Module Responsibilities

| Module | Purpose |
|---|---|
| **Config.mqh** | Centralises every `input` parameter. Grouped into General, Strategy, Risk, Safeguards, Session, Trail/BE, Timer sections so MetaEditor's optimiser renders them cleanly. |
| **Logger.mqh** | `LogDebug/Info/Warn/Error` wrappers around `PrintFormat`. Logs trade requests, results, OrderCheck output, account snapshots, and human-readable retcode decoding. Debug output is gated behind `InpDebugMode`. |
| **Utils.mqh** | Stateless helpers: `NormaliseLots`, `GetAsk/Bid`, `IsNewBar`, `IsTradingAllowed`, `IsSymbolTradeable`, `IsWithinSession`, `CountMyPositions`. |
| **SignalEngine.mqh** | Creates MA indicator handles on init, reads buffers, detects crossover on completed bars. Returns `SIGNAL_BUY`, `SIGNAL_SELL`, or `SIGNAL_NONE`. Swap this module to change strategy. |
| **RiskManager.mqh** | Master `PreTradeCheck()` gate: permissions → symbol → session → spread → max positions → cooldown → free margin → margin level → equity DD → daily loss. Also computes lot size (fixed or risk-per-trade mode). |
| **TradeExec.mqh** | Builds `MqlTradeRequest`, auto-detects filling mode, validates via `OrderCheck`, sends via `OrderSend`, classifies retcodes, logs every step. |
| **PositionMgr.mqh** | Iterates EA-owned positions applying trailing stop and break-even. Provides `HasDuplicateDirection()` to prevent re-entering the same side. |

---

## How to Compile in MetaEditor

1. **Copy the project** into your MT5 data folder:
   ```
   <MT5 Data Folder>/MQL5/Experts/ProGridEA/
   ```
   To find your data folder: open MetaTrader 5 → **File → Open Data Folder**.

2. **Open MetaEditor** (F4 from MT5, or standalone).

3. In the Navigator pane, expand `Experts → ProGridEA` and double-click **ProGridEA.mq5**.

4. Press **F7** (Compile). You should see:
   ```
   0 error(s), 0 warning(s)
   ```

> **Tip:** If MetaEditor shows warnings about unreferenced variables for the section-separator inputs (`_G1_`, `_G2_`, etc.), those are harmless cosmetic dividers.

---

## How to Run in the Strategy Tester (Backtest)

1. In MetaTrader 5, press **Ctrl+R** to open the **Strategy Tester**.
2. Settings:
   - **Expert:** `ProGridEA`
   - **Symbol:** e.g. `EURUSD`
   - **Period:** e.g. `H1`
   - **Date range:** pick any historical range
   - **Modelling:** `Every tick` or `OHLC on M1` (faster)
   - **Deposit:** e.g. `10000 USD`
3. Click **Inputs** tab to customise parameters.
4. Click **Start**.
5. After completion, review **Results**, **Graph**, and **Journal** tabs.

### Optimisation

1. In the Inputs tab, check the boxes next to parameters you want to optimise (e.g. `InpFastMA`, `InpSlowMA`, `InpStopLoss`).
2. Set Start / Step / Stop values.
3. Switch to **Slow complete algorithm** or **Fast genetic based algorithm**.
4. Click **Start** → review **Optimisation Results** tab.

---

## How to Attach to a Live/Demo Chart

1. In MetaTrader 5, ensure **AutoTrading** is enabled (toolbar button should be green).
2. Open a chart for your desired symbol and timeframe.
3. In the Navigator panel, expand **Expert Advisors → ProGridEA**.
4. Drag **ProGridEA** onto the chart (or double-click it).
5. In the pop-up:
   - **Common** tab: check "Allow algorithmic trading".
   - **Inputs** tab: configure parameters.
6. Click **OK**. The EA name and a smiley face should appear in the chart title bar.
7. Monitor output in the **Experts** tab at the bottom of the terminal.

---

## Input Parameters Reference

| Parameter | Default | Description |
|---|---|---|
| InpMagicNumber | 123456 | Unique ID for this EA instance |
| InpTradeComment | "ProGrid" | Comment tag on every order |
| InpDebugMode | false | Enable verbose debug logs |
| InpFastMA | 10 | Fast moving average period |
| InpSlowMA | 50 | Slow moving average period |
| InpMAMethod | SMA | MA calculation method |
| InpMAPrice | Close | Applied price |
| InpOneTradePerBar | true | Only signal once per bar |
| InpLotMode | Fixed | Fixed lot or risk-per-trade |
| InpFixedLots | 0.01 | Fixed lot size |
| InpRiskPercent | 1.0% | Risk % when in risk mode |
| InpStopLoss | 200 pts | Stop loss distance |
| InpTakeProfit | 400 pts | Take profit distance |
| InpMaxSpreadPts | 30 | Max spread filter |
| InpMaxOpenPos | 3 | Max simultaneous positions |
| InpCooldownSec | 10 | Seconds between trades |
| InpMaxDDPercent | 10% | Equity drawdown kill switch |
| InpMinFreeMargin | 100 | Min free margin to trade |
| InpMinMarginLevel | 150% | Min margin level gate |
| InpDailyLossLimit | 5% | Daily loss cut-off |
| InpUseSessionFilter | false | Restrict to trading hours |
| InpUseTrailingStop | false | Enable trailing stop |
| InpUseBreakEven | false | Enable break-even |

---

## Production Safeguards

The EA will **refuse to open a trade** if any of these conditions are met:

- AutoTrading disabled (terminal, account, or EA)
- Symbol not tradeable
- Outside configured session window
- Spread exceeds max threshold
- Max open positions reached
- Cooldown timer active
- Free margin below minimum
- Margin level below minimum
- Equity drawdown exceeds limit
- Daily loss limit hit
- Duplicate direction already open

Every blocked trade is logged with the specific reason.

---

## Swapping the Strategy

To replace the MA crossover with your own strategy:

1. Edit `Modules/SignalEngine.mqh`.
2. Modify `SignalInit()` to create your indicator handles.
3. Modify `SignalDeinit()` to release them.
4. Modify `GenerateSignal()` to return `SIGNAL_BUY`, `SIGNAL_SELL`, or `SIGNAL_NONE`.
5. Add any new inputs to `Modules/Config.mqh` under the Strategy section.
6. Recompile (F7).

The rest of the EA (risk, execution, position management) stays untouched.

---

## Next Improvements

1. **Multi-symbol support** – run one EA across multiple symbols
2. **Partial close / scale-out** – take partial profit at TP1
3. **Pending order support** – limit/stop orders via `TRADE_ACTION_PENDING`
4. **News filter** – skip trading around high-impact events
5. **Equity curve trading** – disable EA during losing streaks
6. **Dashboard panel** – on-chart GUI with account stats / position table
7. **Push/email notifications** – alerts on trade events
8. **External config file** – read settings from CSV/JSON
9. **Monte Carlo analysis** – stress-test in optimiser
10. **Unit tests** – script-based tests for individual modules

---

## License

MIT – use freely, modify as needed, no warranty.