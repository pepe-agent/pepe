// Dashboard charts: one LiveView hook ("Chart") and one look for every chart.
//
// The server never sends an ECharts option. It sends a small spec (see `chart/1` in
// `PepeWeb.DashUI`) and this file turns it into the option, so a chart cannot drift from the
// rest of the dashboard: fonts, hairlines and the muted palette live here and nowhere else.
//
//   {kind: "bar" | "line", labels: [...], unit: "count" | "tokens" | "money" | "percent" | "seconds", currency: "$",
//    goal: {value: 95, label: "95%"} (optional dashed reference line),
//    series: [{name, values: [...], tone: "gold" | "slate" | "teal" | "red"}]}
import echarts from "../vendor/echarts.custom.js"

// Closed, low-chroma colors on purpose: they sit on a near-black page and should read as part
// of it, not as stickers. Gold leads, slate is "the comparison", teal is volume, red is only
// ever for something that went wrong.
const TONES = {gold: "#d6a93c", slate: "#56697a", teal: "#2f9e91", red: "#c9645c"}
const INK = "#6e7e8b"
const HAIRLINE = "rgba(255,255,255,.06)"
const AXIS = "rgba(255,255,255,.10)"
const FONT = "Manrope, ui-sans-serif, system-ui, sans-serif"

function formatter({unit, currency}) {
  const compact = new Intl.NumberFormat(undefined, {notation: "compact", maximumFractionDigits: 1})
  const whole = new Intl.NumberFormat(undefined, {maximumFractionDigits: 0})
  const money = new Intl.NumberFormat(undefined, {minimumFractionDigits: 2, maximumFractionDigits: 2})

  return (value) => {
    const n = Number(value) || 0
    if (unit === "money") return `${currency || ""}${money.format(n)}`
    if (unit === "percent") return `${Math.round(n * 10) / 10}%`
    if (unit === "seconds") return `${Math.round(n * 10) / 10}s`
    if (unit === "tokens") return compact.format(n)
    return whole.format(n)
  }
}

// A dashed reference line across the plot (a target, a limit), on the lead series only.
function goalLine(goal) {
  return {
    silent: true,
    symbol: "none",
    animation: false,
    lineStyle: {type: "dashed", width: 1, color: "rgba(255,255,255,.28)"},
    label: {formatter: goal.label || "", color: INK, fontSize: 11.5, fontFamily: FONT, position: "insideEndTop"},
    data: [{yAxis: goal.value}],
  }
}

function series(spec, index, many, goal) {
  const color = TONES[spec.tone] || TONES.gold
  const base = {name: spec.name, data: spec.values, itemStyle: {color}}
  if (goal && index === 0) base.markLine = goalLine(goal)

  if (spec.kind === "bar") {
    return {...base, type: "bar", barMaxWidth: 22, itemStyle: {color, borderRadius: [3, 3, 0, 0]}}
  }

  return {
    ...base,
    type: "line",
    smooth: 0.25,
    showSymbol: false,
    symbolSize: 7,
    lineStyle: {width: 2, color},
    // Only the lead series gets a wash under it; two washes on top of each other turn to mud.
    areaStyle: index === 0 && !many ? {color, opacity: 0.08} : undefined,
  }
}

function build(spec) {
  const fmt = formatter(spec)
  const many = spec.series.length > 1

  return {
    animationDuration: 350,
    textStyle: {fontFamily: FONT, color: INK},
    aria: {enabled: true},
    grid: {left: 4, right: 10, top: many ? 34 : 12, bottom: 2, containLabel: true},
    legend: many
      ? {
          top: 0,
          right: 0,
          icon: "roundRect",
          itemWidth: 10,
          itemHeight: 4,
          itemGap: 18,
          textStyle: {color: INK, fontSize: 12, fontFamily: FONT},
        }
      : undefined,
    tooltip: {
      trigger: "axis",
      backgroundColor: "#0f1921",
      borderColor: "rgba(255,255,255,.12)",
      borderWidth: 1,
      padding: [8, 12],
      textStyle: {color: "#dce6ed", fontSize: 12.5, fontFamily: FONT},
      axisPointer: {type: spec.kind === "bar" ? "shadow" : "line", lineStyle: {color: "rgba(255,255,255,.16)"}, shadowStyle: {color: "rgba(255,255,255,.03)"}},
      valueFormatter: fmt,
    },
    xAxis: {
      type: "category",
      data: spec.labels,
      boundaryGap: spec.kind === "bar",
      axisLine: {lineStyle: {color: AXIS}},
      axisTick: {show: false},
      axisLabel: {color: INK, fontSize: 11.5, fontFamily: FONT, margin: 10},
    },
    yAxis: {
      type: "value",
      splitNumber: 4,
      // A rate cannot pass 100: fix the top so a 96% week does not stretch to 120%.
      max: spec.unit === "percent" ? 100 : undefined,
      min: spec.unit === "percent" ? 0 : undefined,
      interval: spec.unit === "percent" ? 25 : undefined,
      axisLine: {show: false},
      axisTick: {show: false},
      axisLabel: {color: INK, fontSize: 11.5, fontFamily: FONT, formatter: fmt},
      splitLine: {lineStyle: {color: HAIRLINE}},
    },
    series: spec.series.map((s, i) => series({...s, kind: spec.kind}, i, many, spec.goal)),
  }
}

export const Chart = {
  mounted() {
    // The server owns `this.el` (its data-spec changes on every refresh); ECharts owns the
    // child that `phx-update="ignore"` protects from LiveView's patching.
    this.canvas = this.el.firstElementChild
    this.chart = echarts.init(this.canvas, null, {renderer: "svg"})
    this.resizer = new ResizeObserver(() => this.chart.resize())
    this.resizer.observe(this.canvas)
    this.draw()
  },

  updated() {
    this.draw()
  },

  destroyed() {
    if (this.resizer) this.resizer.disconnect()
    if (this.chart) this.chart.dispose()
  },

  draw() {
    let spec
    try {
      spec = JSON.parse(this.el.dataset.spec)
    } catch (_error) {
      return
    }
    this.chart.setOption(build(spec), true)
  },
}
