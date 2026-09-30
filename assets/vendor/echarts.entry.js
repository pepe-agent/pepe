import * as echarts from "echarts/core"
import {LineChart, BarChart} from "echarts/charts"
import {GridComponent, TooltipComponent, LegendComponent, AriaComponent, MarkLineComponent} from "echarts/components"
import {SVGRenderer} from "echarts/renderers"
echarts.use([LineChart, BarChart, GridComponent, TooltipComponent, LegendComponent, AriaComponent, MarkLineComponent, SVGRenderer])
export default echarts
