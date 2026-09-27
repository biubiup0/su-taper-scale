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
    end
  end
end
