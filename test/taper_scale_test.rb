# encoding: UTF-8
#
# 收分曲线 + 精确输入（绝对尺寸）的无头测试。
#
# 运行：ruby test/taper_scale_test.rb

require_relative 'test_helper'

class DeformMathTest < Minitest::Test
  MATH = Ban::TaperScale::DeformMath

  def test_linear_scale_endpoints_and_middle
    assert_in_delta 1.0, MATH.taper_scale(0.0, 0.5), 1e-9
    assert_in_delta 0.75, MATH.taper_scale(0.5, 0.5), 1e-9
    assert_in_delta 0.5, MATH.taper_scale(1.0, 0.5), 1e-9
  end

  def test_smooth_curve_slows_down_at_both_ends
    # smoothstep(0.25) = 0.15625
    assert_in_delta 0.921875, MATH.taper_scale(0.25, 0.5, { curve: :smooth }), 1e-9
    # 中点仍与直线相同
    assert_in_delta 0.75, MATH.taper_scale(0.5, 0.5, { curve: :smooth }), 1e-9
  end

  def test_bulge_widens_only_the_middle
    profile = { curve: :linear, bulge: 0.3 }
    assert_in_delta 1.0, MATH.taper_scale(0.0, 0.5, profile), 1e-9
    assert_in_delta 1.05, MATH.taper_scale(0.5, 0.5, profile), 1e-9
    assert_in_delta 0.5, MATH.taper_scale(1.0, 0.5, profile), 1e-9
  end

  def test_negative_bulge_makes_a_waist
    profile = { curve: :linear, bulge: -0.4 }
    assert_in_delta 0.35, MATH.taper_scale(0.5, 0.5, profile), 1e-9
    assert_in_delta 0.5, MATH.taper_scale(1.0, 0.5, profile), 1e-9
  end

  def test_scale_never_goes_negative
    scale = MATH.taper_scale(0.5, 0.001, { curve: :linear, bulge: -0.95 })
    assert_in_delta DeformMathTest::MATH::MIN_SCALE, scale, 1e-9
  end

  def test_taper_point_geometry_linear
    box = TestSupport.box([10.0, 10.0, 20.0])
    point = Geom::Point3d.new(10, 5, 20)

    result = MATH.taper_point(box, 2, 0, [0.5, 0.5], point)
    assert_in_delta 7.5, result.x, 1e-9
    assert_in_delta 5.0, result.y, 1e-9
    assert_in_delta 20.0, result.z, 1e-9
  end

  def test_taper_point_geometry_bulge
    box = TestSupport.box([10.0, 10.0, 20.0])
    point = Geom::Point3d.new(10, 5, 10)

    result = MATH.taper_point(box, 2, 0, [0.5, 0.5], point,
                              { curve: :linear, bulge: 0.3 })
    assert_in_delta 10.25, result.x, 1e-9
  end

  def test_taper_point_anchor_one_keeps_top
    box = TestSupport.box([10.0, 10.0, 20.0])
    point = Geom::Point3d.new(10, 5, 0)

    result = MATH.taper_point(box, 2, 1, [0.5, 0.5], point)
    assert_in_delta 7.5, result.x, 1e-9
  end

  def test_profile_normalization
    assert_equal({ curve: :linear, bulge: 0.0 }, MATH.normalize_profile(nil))
    assert_equal({ curve: :smooth, bulge: 0.0 }, MATH.normalize_profile(:smooth))
    assert_equal({ curve: :linear, bulge: 0.0 }, MATH.normalize_profile({ curve: :bogus }))
    assert_in_delta 0.95, MATH.normalize_profile({ bulge: 9.0 })[:bulge], 1e-9
    assert_in_delta(-0.95, MATH.normalize_profile({ bulge: -9.0 })[:bulge], 1e-9)
  end

  def test_profile_labels
    assert_equal '直线', MATH.profile_label({ curve: :linear, bulge: 0.0 })
    assert_equal 'S 形', MATH.profile_label({ curve: :smooth, bulge: 0.0 })
    assert_equal '鼓形 +0.30', MATH.profile_label({ curve: :linear, bulge: 0.3 })
    assert_equal '收腰 -0.30', MATH.profile_label({ curve: :linear, bulge: -0.3 })
    assert_equal 'S 形 + 鼓形 +0.30', MATH.profile_label({ curve: :smooth, bulge: 0.3 })
  end

  def test_same_profile_with_tolerance
    assert MATH.same_profile?({ curve: :smooth, bulge: 0.3 },
                              { curve: :smooth, bulge: 0.3000001 })
    refute MATH.same_profile?({ curve: :smooth, bulge: 0.3 },
                              { curve: :linear, bulge: 0.3 })
  end
end

class StretchAbsoluteInputTest < Minitest::Test
  MM = TestSupport::MM

  def sizes_mm
    [1000 * MM, 800 * MM, 2000 * MM]
  end

  def test_plain_number_sets_target_size
    _tool, spec = TestSupport.spec_for('1200', sizes: sizes_mm)
    refute_nil spec
    assert_in_delta 1200 * MM, spec[:sizes][2], 1e-9
    assert_in_delta 1000 * MM, spec[:sizes][0], 1e-9
    assert_in_delta 800 * MM, spec[:sizes][1], 1e-9
    assert_equal 0, spec[:anchors][2]
  end

  def test_plus_prefix_is_delta
    _tool, spec = TestSupport.spec_for('+100', sizes: sizes_mm)
    assert_in_delta 2100 * MM, spec[:sizes][2], 1e-9
  end

  def test_minus_prefix_is_delta
    _tool, spec = TestSupport.spec_for('-100', sizes: sizes_mm)
    assert_in_delta 1900 * MM, spec[:sizes][2], 1e-9
  end

  def test_length_with_unit_sets_target_size
    _tool, spec = TestSupport.spec_for('1200mm', sizes: sizes_mm)
    assert_in_delta 1200 * MM, spec[:sizes][2], 1e-9
  end

  def test_ratio_still_works
    _tool, spec = TestSupport.spec_for('1.5x', sizes: sizes_mm)
    assert_in_delta 3000 * MM, spec[:sizes][2], 1e-9
  end

  def test_three_values_set_three_target_sizes
    _tool, spec = TestSupport.spec_for('1200mm,800mm,1500mm', sizes: sizes_mm)
    assert_in_delta 1200 * MM, spec[:sizes][0], 1e-9
    assert_in_delta 800 * MM, spec[:sizes][1], 1e-9
    assert_in_delta 1500 * MM, spec[:sizes][2], 1e-9
  end

  def test_corner_single_value_sets_all_three
    tool = TestSupport.tool(sizes: sizes_mm, handle: { type: :corner, corner: [1, 1, 1] })
    values = tool.send(:parse_values, '1500')
    spec = tool.send(:spec_from_values, values)
    assert_in_delta 1500 * MM, spec[:sizes][0], 1e-9
    assert_in_delta 1500 * MM, spec[:sizes][1], 1e-9
    assert_in_delta 1500 * MM, spec[:sizes][2], 1e-9
  end

  def test_two_values_are_rejected_for_stretch
    _tool, spec = TestSupport.spec_for('100,200', sizes: sizes_mm)
    assert_nil spec
  end
end

class TaperInputTest < Minitest::Test
  MM = TestSupport::MM

  def sizes_mm
    [1000 * MM, 800 * MM, 2000 * MM]
  end

  def test_plain_number_is_ratio
    _tool, spec = TestSupport.spec_for('0.6', mode: :taper, sizes: sizes_mm)
    assert_in_delta 0.6, spec[:factors][0], 1e-9
    assert_in_delta 0.6, spec[:factors][1], 1e-9
  end

  def test_length_is_end_section_size
    _tool, spec = TestSupport.spec_for('600mm', mode: :taper, sizes: sizes_mm)
    assert_in_delta 0.6, spec[:factors][0], 1e-9
    assert_in_delta 0.75, spec[:factors][1], 1e-9
  end

  def test_two_ratios
    _tool, spec = TestSupport.spec_for('0.6,0.8', mode: :taper, sizes: sizes_mm)
    assert_in_delta 0.6, spec[:factors][0], 1e-9
    assert_in_delta 0.8, spec[:factors][1], 1e-9
  end

  def test_two_end_section_sizes
    _tool, spec = TestSupport.spec_for('600mm,900mm', mode: :taper, sizes: sizes_mm)
    assert_in_delta 0.6, spec[:factors][0], 1e-9
    assert_in_delta 900.0 / 800.0, spec[:factors][1], 1e-9
  end

  def test_profile_is_carried_into_spec
    tool = TestSupport.tool(mode: :taper, sizes: sizes_mm)
    tool.instance_variable_get(:@drag)[:profile] = { curve: :smooth, bulge: -0.2 }
    values = tool.send(:parse_values, '0.6')
    spec = tool.send(:spec_from_values, values)
    assert_equal :smooth, spec[:profile][:curve]
  end
end

class TaperGuideTest < Minitest::Test
  def guide(mode_profile)
    tool = TestSupport.tool(mode: :taper)
    tool.instance_variable_get(:@drag)[:profile] = mode_profile
    spec = { kind: :taper, axis: 2, anchor: 0, factors: [0.5, 0.5] }
    tool.send(:taper_guide_segments, spec)
  end

  def test_guide_segment_count
    # 4 条沿轴的棱 × 24 段 + 两端各 4 条截面边
    assert_equal 208, guide({ curve: :linear, bulge: 0.0 }).size
  end

  def test_bulge_bulges_outside_the_linear_cone
    linear_max = guide({ curve: :linear, bulge: 0.0 }).map(&:x).max
    bulge_max = guide({ curve: :linear, bulge: 0.3 }).map(&:x).max
    assert_in_delta 10.0, linear_max, 1e-6
    # 曲度 +0.3 让中段明显鼓出（最大值出现在 ~30% 高度，因为直线收分同时在缩小截面）
    assert_operator bulge_max, :>, linear_max + 0.4
    assert_operator bulge_max, :<, 10.5
  end
end

class ExactDialogParseTest < Minitest::Test
  MM = TestSupport::MM

  def tool
    @tool ||= TestSupport.tool(sizes: [1000 * MM, 800 * MM, 2000 * MM])
  end

  def test_empty_means_keep
    assert_equal({ kind: :keep }, tool.send(:parse_size_input, ''))
    assert_equal({ kind: :keep }, tool.send(:parse_size_input, '   '))
  end

  def test_absolute_sizes
    assert_equal({ kind: :size, inches: 1200 * MM },
                 tool.send(:parse_size_input, '1200'))
    assert_equal({ kind: :size, inches: 1200 * MM },
                 tool.send(:parse_size_input, '1200mm'))
  end

  def test_signed_values_are_deltas
    assert_equal({ kind: :delta, inches: 100 * MM },
                 tool.send(:parse_size_input, '+100'))
    assert_equal({ kind: :delta, inches: -100 * MM },
                 tool.send(:parse_size_input, '-100'))
    assert_equal({ kind: :delta, inches: -100 * MM },
                 tool.send(:parse_size_input, '-100mm'))
  end

  def test_garbage_is_ignored
    assert_equal({ kind: :keep }, tool.send(:parse_size_input, 'abc'))
    assert_equal({ kind: :keep }, tool.send(:parse_size_input, '1.5x'))
  end
end

class SettingsTest < Minitest::Test
  SETTINGS = Ban::TaperScale::Settings

  def setup
    SETTINGS.taper_profile = { curve: :linear, bulge: 0.0 }
  end

  def test_default_profile_is_linear
    assert_equal({ curve: :linear, bulge: 0.0 }, SETTINGS.taper_profile)
  end

  def test_round_trip
    SETTINGS.taper_profile = { curve: :smooth, bulge: 0.4 }
    assert_equal({ curve: :smooth, bulge: 0.4 }, SETTINGS.taper_profile)
  end

  def test_invalid_curve_falls_back_to_linear
    SETTINGS.taper_profile = { curve: :bogus, bulge: 0.2 }
    assert_equal :linear, SETTINGS.taper_profile[:curve]
  end

  def test_bulge_is_clamped
    SETTINGS.taper_profile = { curve: :linear, bulge: 9.0 }
    assert_in_delta SETTINGS::MAX_TAPER_BULGE, SETTINGS.taper_profile[:bulge], 1e-9
    SETTINGS.taper_profile = { curve: :linear, bulge: -9.0 }
    assert_in_delta(-SETTINGS::MAX_TAPER_BULGE, SETTINGS.taper_profile[:bulge], 1e-9)
  end
end
