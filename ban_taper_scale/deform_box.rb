# encoding: UTF-8
#
# 变形框：用一个有向长方体定义变形空间。
# 本文件只依赖 Geom::Point3d / Geom::Vector3d，可以脱离 SketchUp 单独测试。

require File.join(File.dirname(__FILE__), 'vec_math.rb')

module Ban
  module TaperScale
    class DeformBox
      # 允许的最小尺寸（inch），避免退化包围盒导致除零。
      MIN_SIZE = 0.002

      DEFAULT_AXES = [
        Geom::Vector3d.new(1, 0, 0),
        Geom::Vector3d.new(0, 1, 0),
        Geom::Vector3d.new(0, 0, 1)
      ].freeze

      attr_reader :origin, :axes, :sizes

      def initialize(origin, axes, sizes)
        @origin = Geom::Point3d.new(origin.x, origin.y, origin.z)
        @axes = DeformBox.orthonormal(axes)
        @sizes = sizes.map { |size| DeformBox.clamp_size(size.to_f) }
      end

      # 由一组点（世界坐标）求包围盒，axes 指定包围盒的朝向（默认世界坐标轴）。
      def self.from_points(points, axes = nil)
        pts = points.compact
        raise ArgumentError, 'points 不能为空' if pts.empty?

        ax = orthonormal(axes || DEFAULT_AXES)
        base = centroid(pts)
        mins = []
        maxs = []
        3.times do |i|
          projections = pts.map do |point|
            VecMath.dot(VecMath.point_minus(point, base), ax[i])
          end
          mins << projections.min
          maxs << projections.max
        end

        origin = base
        3.times { |i| origin = VecMath.point_plus(origin, VecMath.scale(ax[i], mins[i])) }
        new(origin, ax, (0...3).map { |i| maxs[i] - mins[i] })
      end

      def self.centroid(points)
        x = 0.0
        y = 0.0
        z = 0.0
        points.each do |point|
          x += point.x
          y += point.y
          z += point.z
        end
        count = points.size.to_f
        Geom::Point3d.new(x / count, y / count, z / count)
      end

      def self.unit(vector)
        VecMath.normalize(vector)
      end

      # Gram-Schmidt 正交化，保证三个轴互相垂直且保持右手系。
      def self.orthonormal(axes)
        first = unit(axes[0]) || DEFAULT_AXES[0]

        second_raw = VecMath.sub(
          axes[1],
          VecMath.scale(first, VecMath.dot(axes[1], first))
        )
        second = unit(second_raw) || DEFAULT_AXES[1]

        third_raw = VecMath.sub(
          VecMath.sub(
            axes[2],
            VecMath.scale(first, VecMath.dot(axes[2], first))
          ),
          VecMath.scale(second, VecMath.dot(axes[2], second))
        )
        third = unit(third_raw) || VecMath.cross(first, second)

        [first, second, third]
      end

      def self.clamp_size(value)
        return value if value.abs >= MIN_SIZE

        value.negative? ? -MIN_SIZE : MIN_SIZE
      end

      # ---- 几何查询 ------------------------------------------------------

      # 归一化坐标 (0..1) -> 世界坐标
      def point_at(x, y, z)
        point = VecMath.point_plus(@origin, VecMath.scale(@axes[0], x * @sizes[0]))
        point = VecMath.point_plus(point, VecMath.scale(@axes[1], y * @sizes[1]))
        VecMath.point_plus(point, VecMath.scale(@axes[2], z * @sizes[2]))
      end

      # 世界坐标 -> 归一化坐标
      def normalize(point)
        delta = VecMath.point_minus(point, @origin)
        [
          VecMath.dot(delta, @axes[0]) / @sizes[0],
          VecMath.dot(delta, @axes[1]) / @sizes[1],
          VecMath.dot(delta, @axes[2]) / @sizes[2]
        ]
      end

      # 点到原点的距离在指定轴上的投影长度
      def project(point, axis_index)
        VecMath.dot(VecMath.point_minus(point, @origin), @axes[axis_index])
      end

      def corner(i, j, k)
        point_at(i, j, k)
      end

      def corners
        list = []
        [0, 1].each do |i|
          [0, 1].each do |j|
            [0, 1].each { |k| list << corner(i, j, k) }
          end
        end
        list
      end

      # axis_index 轴上的某个端面中心，side 取 0 或 1
      def face_center(axis_index, side)
        coords = [0.5, 0.5, 0.5]
        coords[axis_index] = side
        point_at(coords[0], coords[1], coords[2])
      end

      def with(sizes, origin = nil)
        DeformBox.new(origin || @origin, @axes, sizes)
      end
    end
  end
end
