"""Export the historical price/realization comparison (requires matplotlib)."""
import datetime as dt
import json
import sys
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as dates

history = json.loads(Path(sys.argv[1]).read_text())
analysis = json.loads(Path(sys.argv[2]).read_text())
output = Path(sys.argv[3])
utc = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc)
market = [m for m in history["markets"] if history["start"] <= m["t"] < history["end"]]
plt.rcParams.update({"font.size": 10, "axes.spines.top": False, "axes.spines.right": False})
fig, axes = plt.subplots(3, 1, figsize=(11, 10), sharex=True, layout="constrained")
colors = {"ETH": "#177c85", "BTC": "#c07b10"}
for i, asset in enumerate(("ETH", "BTC")):
    axes[0].plot([utc(m["t"]) for m in market],
                 [100 * int(m["prices"][i]) / int(market[0]["prices"][i]) for m in market],
                 color=colors[asset], label=asset)
axes[0].set_ylabel("Crypto oracle index (start = 100)")
axes[0].set_title("90 days of historical inputs — 4 July to 1 October 2026", loc="left", weight="bold")
axes[0].legend(loc="upper left")
axes[1].step([utc(m["t"]) for m in market], [int(m["prices"][2])/1e8 for m in market],
             where="post", color="#674da0", label="PRIME money-market oracle")
axes[1].set_ylabel("PRIME oracle value (USD)")
axes[1].legend(loc="upper left")
for label, style, suffix in [("baseline-90d", "-", "observed pool"), ("perfect-90d", "--", "perfect arbitrage")]:
    for asset in ("ETH", "BTC"):
        r = next(c for c in analysis["cases"] if c["label"] == label and c["asset"] == asset)
        axes[2].plot([utc(x["t"]) for x in r["history"]], [x["cryptoReturnPct"] for x in r["history"]],
                     style, color=colors[asset], label=f"{asset}: {suffix}")
axes[2].set_ylabel("Additional funded crypto (%)")
axes[2].legend(loc="upper left", ncols=2)
axes[2].xaxis.set_major_formatter(dates.DateFormatter("%d %b", tz=dt.timezone.utc))
for ax in axes:
    ax.grid(alpha=.18)
    ax.axvline(utc(history["start"]+60*86400), color="#777777", linewidth=.9, linestyle=":")
axes[2].set_xlabel("UTC date · dotted line starts held-out period · gas paid externally")
fig.suptitle("Price gains and unconverted source carry are excluded from funded crypto return", fontsize=11)
fig.savefig(output.with_suffix(".svg"))
fig.savefig(output.with_suffix(".png"), dpi=150)
# Matplotlib emits trailing spaces in SVG path data; normalize for repo checks.
svg = output.with_suffix(".svg")
svg.write_text("\n".join(line.rstrip() for line in svg.read_text().splitlines()) + "\n")
