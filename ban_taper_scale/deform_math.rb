# encoding: UTF-8
#
# 两种变形的数学定义。
#
# 1) 拉伸缩放（仿射）：各轴独立缩放，可指定每条轴的固定端。
# 2) 收分（非仿射）：沿某条轴线性过渡——固定端的截面比例保持 1，
#    另一端截面在两个垂直方向上分别按 factors 缩放，
#    中间截面按位置线性插值。这正是柱/塔的"收分"效果。
#
# 只依赖 Geom，可脱离 SketchUp 单独测试。

require File.join(File.dirname(__FILE__), 'vec_math.rb')

module Ban
  module TaperScale
    module DeformMath
      module_function

      # 拉伸后变形框的原点位置：固定端为 1 的轴需要平移原点。
      def stretch_origin(box, anchors, new_sizes)
        origin = box.origin
        3.times do |i|
          next unless anchors[i].to_i == 1

          origin = VecMath.point_plus(
            origin,
            VecMath.scale(box.axes[i], box.sizes[i] - new_sizes[i])
          )
        end
        origin
      end

      # 把点从原框映射到"拉伸后"的新框。
      def stretch_point(box, anchors, new_sizes, point)
        origin = stretch_origin(box, anchors, new_sizes)
        n = box.normalize(point)
        result = VecMath.point_plus(origin, VecMath.scale(box.axes[0], n[0] * new_sizes[0]))
        result = VecMath.point_plus(result, VecMath.scale(box.axes[1], n[1] * new_sizes[1]))
        VecMath.point_plus(result, VecMath.scale(box.axes[2], n[2] * new_sizes[2]))
      end

      def stretch_box(box, anchors, new_sizes)
        box.with(new_sizes, stretch_origin(box, anchors, new_sizes))
      end

      # 收分：axis 为收分轴，anchor_side 是保持不动的端面（0 或 1），
      # factors 是另一端在两个垂直轴上的缩放比例（按轴序号升序）。
      def taper_point(box, axis, anchor_side, factors, point)
        n = box.normalize(point)
        t = anchor_side.to_i.zero? ? n[axis] : (1.0 - n[axis])

        result = n.dup
        index = 0
        [0, 1, 2].each do |j|
          next if j == axis

          factor = factors[index]
          index += 1
          scale = 1.0 + (factor - 1.0) * t
          # 截面绕轴线（框中心）缩放
          result[j] = 0.5 + (n[j] - 0.5) * scale
        end

        box.point_at(result[0], result[1], result[2])
      end

      # 收分轴在上、下面之间的垂直轴序号（按轴号升序）
      def perpendicular_axes(axis)
        [0, 1, 2] - [axis]
      end

      def clamp_factor(value)
        return 0.02 if value < 0.02
        return 20.0 if value > 20.0

        value
      end
    end
  end
end
