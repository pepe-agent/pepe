# Apache ECharts (trimmed build)

`echarts.custom.js` is [Apache ECharts](https://echarts.apache.org) 6.1.0 (Apache-2.0, see
`echarts.LICENSE.txt` and `echarts.NOTICE.txt`), cut down to what the dashboard draws: line and
bar series, grid, tooltip, legend, reference lines and the SVG renderer. Nothing else is linked in.

To rebuild it (for an upgrade or another chart type), in an empty folder:

    npm i echarts esbuild
    # copy echarts.entry.js here and add the chart/component you need
    npx esbuild echarts.entry.js --bundle --minify --format=esm --legal-comments=none --outfile=echarts.custom.js
