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
    end
  end
end
