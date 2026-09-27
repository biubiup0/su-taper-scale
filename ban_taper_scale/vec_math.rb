# encoding: UTF-8
#
# 向量运算辅助。
#
# 重要：SketchUp 的 Geom::Vector3d 里
#     vector * vector  -> 叉积（Vector3d）
#     vector % vector  -> 点积（Float）
# 而且 **没有** "vector * 数字" 这种标量乘法（会抛
# "Cannot convert argument to Geom::Vector3d"）。
# 为了不踩这个坑，本插件所有向量运算都走这里，按分量算。

module Ban
  module TaperScale
    module VecMath
      module_function

      def scale(vector, factor)
        Geom::Vector3d.new(
          vector.x * factor,
          vector.y * factor,
          vector.z * factor
        )
      end

      def add(first, second)
        Geom::Vector3d.new(
          first.x + second.x,
          first.y + second.y,
          first.z + second.z
        )
      end

      def sub(first, second)
        Geom::Vector3d.new(
          first.x - second.x,
          first.y - second.y,
          first.z - second.z
        )
      end

      def dot(first, second)
        first.x * second.x + first.y * second.y + first.z * second.z
      end

      def cross(first, second)
        Geom::Vector3d.new(
          first.y * second.z - first.z * second.y,
          first.z * second.x - first.x * second.z,
          first.x * second.y - first.y * second.x
        )
      end

      def length(vector)
        Math.sqrt(dot(vector, vector))
      end

      def normalize(vector)
        size = length(vector)
        return nil if size < 1.0e-12

        scale(vector, 1.0 / size)
      end

      # 点 + 向量
      def point_plus(point, vector)
        Geom::Point3d.new(
          point.x + vector.x,
          point.y + vector.y,
          point.z + vector.z
        )
      end

      # 点 - 点 -> 向量
      def point_minus(first, second)
        Geom::Vector3d.new(
          first.x - second.x,
          first.y - second.y,
          first.z - second.z
        )
      end

      def distance(first, second)
        length(point_minus(first, second))
      end
    end
  end
end
