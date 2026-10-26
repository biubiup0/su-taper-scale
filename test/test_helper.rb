# encoding: UTF-8
#
# 无头测试入口：用 test/support/sketchup.rb 替身加载插件，不需要真机 SketchUp。
#
# 运行：ruby test/taper_scale_test.rb

$LOAD_PATH.unshift(File.expand_path('support', __dir__))

require 'sketchup'
require 'minitest/autorun'

ROOT = File.expand_path('..', __dir__)
PLUGIN_DIR = File.join(ROOT, 'ban_taper_scale')

require File.join(PLUGIN_DIR, 'tool.rb')

module TestSupport
  MM = 1.0 / 25.4

  def self.box(sizes = [10.0, 10.0, 20.0])
    Ban::TaperScale::DeformBox.new(
      ORIGIN,
      [Geom::Vector3d.new(1, 0, 0),
       Geom::Vector3d.new(0, 1, 0),
       Geom::Vector3d.new(0, 0, 1)],
      sizes
    )
  end

  def self.tool(mode: :stretch, sizes: [10.0, 10.0, 20.0], handle: nil)
    tool = Ban::TaperScale::Tool.new
    tool.instance_variable_set(:@mode, mode)
    box = box(sizes)
    handle ||= { type: :face, axis: 2, side: 1 }
    spec = if mode == :stretch
             { kind: :stretch, anchors: [0, 0, 0], sizes: box.sizes.dup }
           else
             { kind: :taper, axis: 2, anchor: 0, factors: [1.0, 1.0] }
           end
    tool.instance_variable_set(
      :@drag,
      { handle: handle, mode: mode, base_box: box, spec: spec,
        profile: { curve: :linear, bulge: 0.0 }, vertex_set: nil }
    )
    tool
  end

  def self.spec_for(text, mode: :stretch, sizes: [10.0, 10.0, 20.0])
    tool = tool(mode: mode, sizes: sizes)
    values = tool.send(:parse_values, text)
    return [tool, nil] if values.nil?

    [tool, tool.send(:spec_from_values, values)]
  end
end
