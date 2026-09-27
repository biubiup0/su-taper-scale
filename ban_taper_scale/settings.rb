# encoding: UTF-8

module Ban
  module TaperScale
    # 少量可持久化的偏好设置。
    module Settings
      SECTION = 'BanTaperScale'.freeze

      module_function

      def explode_curves?
        value = Sketchup.read_default(SECTION, 'explode_curves', true)
        value.nil? ? true : value
      end

      def explode_curves=(value)
        Sketchup.write_default(SECTION, 'explode_curves', value ? true : false)
      end

      def object_axes?
        value = Sketchup.read_default(SECTION, 'object_axes', true)
        value.nil? ? true : value
      end

      def object_axes=(value)
        Sketchup.write_default(SECTION, 'object_axes', value ? true : false)
      end

      # 拖动时是否吸附到几何（端点 / 中点 / 圆心 / 交点 / 边线 / 表面）
      def snap?
        value = Sketchup.read_default(SECTION, 'snap', true)
        value.nil? ? true : value
      end

      def snap=(value)
        Sketchup.write_default(SECTION, 'snap', value ? true : false)
      end

      # 面心拉伸时是否"保持造型"（只拉伸中段，两端特征原样平移/不动）
      def middle_stretch?
        value = Sketchup.read_default(SECTION, 'middle_stretch', true)
        value.nil? ? true : value
      end

      def middle_stretch=(value)
        Sketchup.write_default(SECTION, 'middle_stretch', value ? true : false)
      end

      # 面心"保持造型"拉伸的拉伸区。
      # 留空 = 自动（取物体中部的平直位置）；也可以手动指定 1~2 个互不相连的区间，
      # 写成 "30-40" 或 "30-40,60-70"（百分比，按变形框轴线量，0% = 变形框起点）。
      ZONE_LIMIT = 2
      MIN_ZONE_WIDTH = 0.001

      def stretch_zones_text
        value = Sketchup.read_default(SECTION, 'stretch_zones', '')
        value.is_a?(String) ? value : ''
      end

      def stretch_zones_text=(value)
        Sketchup.write_default(SECTION, 'stretch_zones', value.to_s)
      end

      # 当前生效的拉伸区（归一化到 0~1）；自动模式返回空数组
      def stretch_zones
        Settings.parse_zones(stretch_zones_text) || []
      end

      # "30-40,60-70" / "30%~40%" -> [[0.3, 0.4], [0.6, 0.7]]
      # 解析不了返回 nil（调用方负责提示用户）
      def parse_zones(text)
        return [] if text.nil? || text.to_s.strip.empty?

        ranges = text.to_s.split(/[,，;；]+/).map do |piece|
          numbers = piece.scan(/\d+(?:\.\d+)?/).map(&:to_f)
          return nil if numbers.size != 2

          low, high = numbers.minmax
          return nil if low < 0.0 || high > 100.0
          return nil if (high - low) < MIN_ZONE_WIDTH * 100.0

          [low / 100.0, high / 100.0]
        end
        return nil if ranges.empty? || ranges.size > ZONE_LIMIT

        Settings.merge_zones(ranges)
      end

      # 相邻 / 重叠的区间合并成一个（否则宽度分配会重复计算）
      def merge_zones(ranges)
        merged = []
        ranges.sort_by { |low, _high| low }.each do |low, high|
          if merged.empty? || low > merged.last[1] + 1.0e-9
            merged << [low, high]
          else
            merged.last[1] = [merged.last[1], high].max
          end
        end
        merged
      end

      def format_zones(zones)
        zones.map { |low, high| format('%.1f-%.1f', low * 100, high * 100) }.join(',')
      end
    end
  end
end
