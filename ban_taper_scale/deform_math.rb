# encoding: UTF-8
#
# 两种变形的数学定义。
#
# 1) 拉伸缩放（仿射）：各轴独立缩放，可指定每条轴的固定端。
# 2) 收分（非仿射）：沿某条轴按曲线过渡——固定端的截面比例保持 1，
#    另一端截面在两个垂直方向上分别按 factors 缩放，
#    中间截面按位置（可带曲线）插值。这正是柱/塔的"收分"效果。
#
# 收分曲线：
#   s(t) = 1 + (factor - 1) · curve(t) + bulge · sin(π·t)
#   curve(t) 是 0→1 的过渡曲线（直线 / S 形），bulge 只影响中段：
#   正数中段外鼓（鼓形），负数中段内收（收腰 / 花瓶）。
#   两端截面始终精确等于 1 和 factor，所以端面尺寸输入不受曲线影响。
#
# 只依赖 Geom，可脱离 SketchUp 单独测试。

require File.join(File.dirname(__FILE__), 'vec_math.rb')

module Ban
  module TaperScale
    module DeformMath
      MIN_SCALE = 0.02
      MAX_SCALE = 20.0
      # 曲度上限：再大就容易把截面翻到负数（收腰收到看不见）
      MAX_BULGE = 0.95
      CURVE_LABELS = { linear: '直线', smooth: 'S 形' }.freeze

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

      def stretch_box(box, anchors, new_sizes)
        box.with(new_sizes, stretch_origin(box, anchors, new_sizes))
      end

      # 收分：axis 为收分轴，anchor_side 是保持不动的端面（0 或 1），
      # factors 是另一端在两个垂直轴上的缩放比例（按轴序号升序）。
      # profile 为收分曲线 { curve: :linear / :smooth, bulge: -0.95..0.95 }，
      # 省略 = 直线（与旧版本完全一致）。
      def taper_point(box, axis, anchor_side, factors, point, profile = nil)
        n = box.normalize(point)
        t = anchor_side.to_i.zero? ? n[axis] : (1.0 - n[axis])

        result = n.dup
        index = 0
        [0, 1, 2].each do |j|
          next if j == axis

          scale = taper_scale(t, factors[index], profile)
          index += 1
          # 截面绕轴线（框中心）缩放
          result[j] = 0.5 + (n[j] - 0.5) * scale
        end

        box.point_at(result[0], result[1], result[2])
      end

      # t（0 = 固定端，1 = 收分端）处的截面缩放比例。
      # 曲线与曲度只改中段：t=0 恒为 1，t=1 恒为 factor。
      def taper_scale(t, factor, profile = nil)
        shape = normalize_profile(profile)
        position = t.to_f
        position = 0.0 if position < 0.0
        position = 1.0 if position > 1.0

        wave = Math.sin(Math::PI * position) * shape[:bulge]
        clamp_factor(1.0 + (factor - 1.0) * curve_weight(position, shape[:curve]) + wave)
      end

      # 归一化成固定的 hash，坏值一律退回直线
      def normalize_profile(profile)
        return { curve: :linear, bulge: 0.0 } if profile.nil?

        if profile.is_a?(Symbol) || profile.is_a?(String)
          curve = profile.to_s.to_sym
          return { curve: CURVE_LABELS.key?(curve) ? curve : :linear, bulge: 0.0 }
        end

        curve = (profile[:curve] || profile['curve'] || :linear).to_s.to_sym
        curve = :linear unless CURVE_LABELS.key?(curve)
        bulge = (profile[:bulge] || profile['bulge'] || 0.0).to_f
        bulge = MAX_BULGE if bulge > MAX_BULGE
        bulge = -MAX_BULGE if bulge < -MAX_BULGE
        { curve: curve, bulge: bulge }
      end

      # 0→1 的过渡曲线
      def curve_weight(t, curve)
        case curve
        when :smooth then t * t * (3.0 - 2.0 * t)
        else t
        end
      end

      # "鼓形 +0.30" / "收腰 -0.30" / "S 形 + 鼓形 +0.30"
      def profile_label(profile)
        shape = normalize_profile(profile)
        base = CURVE_LABELS[shape[:curve]]
        bulge = shape[:bulge]
        return base if bulge.abs < 1.0e-6

        kind = bulge.positive? ? '鼓形' : '收腰'
        return format('%s %+.2f', kind, bulge) if shape[:curve] == :linear

        format('%s + %s %+.2f', base, kind, bulge)
      end

      def same_profile?(first, second)
        one = normalize_profile(first)
        two = normalize_profile(second)
        one[:curve] == two[:curve] && (one[:bulge] - two[:bulge]).abs < 1.0e-6
      end

      # 收分轴在上、下面之间的垂直轴序号（按轴号升序）
      def perpendicular_axes(axis)
        [0, 1, 2] - [axis]
      end

      def clamp_factor(value)
        return MIN_SCALE if value < MIN_SCALE
        return MAX_SCALE if value > MAX_SCALE

        value
      end
    end
  end
end
