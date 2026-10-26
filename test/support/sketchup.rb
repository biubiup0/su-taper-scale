# encoding: UTF-8
#
# 极简 SketchUp API 替身：只实现无头测试需要的那一小部分。
# 不参与插件打包，也不会被 SketchUp 加载。

module Geom
  class Vector3d
    attr_reader :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def length
      Math.sqrt(@x * @x + @y * @y + @z * @z)
    end
  end

  class Point3d
    attr_reader :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def to_a
      [@x, @y, @z]
    end
  end

  class Transformation
    def initialize(*_args)
      @values = [1.0, 0.0, 0.0, 0.0,
                 0.0, 1.0, 0.0, 0.0,
                 0.0, 0.0, 1.0, 0.0,
                 0.0, 0.0, 0.0, 1.0]
    end

    def self.axes(*_args)
      new
    end

    def self.scaling(*_args)
      new
    end

    def self.translation(*_args)
      new
    end

    def inverse
      self
    end

    def *(other)
      other
    end

    def to_a
      @values
    end
  end
end

ORIGIN = Geom::Point3d.new(0, 0, 0)

# SketchUp 给 String 加了 to_l（带单位字符串 -> 英寸）。测试里实现同样的约定。
class String
  UNIT_INCH = {
    'mm' => 1.0 / 25.4,
    'cm' => 1.0 / 2.54,
    'm' => 39.37007874015748,
    'in' => 1.0,
    '"' => 1.0,
    'ft' => 12.0,
    "'" => 12.0
  }.freeze

  def to_l
    match = strip.downcase.match(/\A([-+]?(?:\d+\.?\d*|\.\d+))\s*(mm|cm|m|in|ft|"|')?\z/)
    return 0.0 unless match

    match[1].to_f * (UNIT_INCH[match[2]] || 1.0)
  end
end


GL_LINES = 1
GL_LINE_LOOP = 2
GL_QUADS = 3
GL_POLYGON = 4

VK_RIGHT = 39
VK_LEFT = 37
VK_UP = 38
VK_DOWN = 40

MF_ENABLED = 0
MF_GRAYED = 1
MF_CHECKED = 8

module Sketchup
  COPY_MODIFIER_MASK = 0x0008
  CONSTRAIN_MODIFIER_MASK = 0x0010

  class Color
    def initialize(*_args); end
  end

  class InputPoint
    def initialize(*_args)
      @position = Geom::Point3d.new(0, 0, 0)
    end

    attr_reader :position

    def pick(*_args); end

    def tooltip
      ''
    end

    def vertex
      nil
    end

    def edge
      nil
    end

    def face
      nil
    end
  end

  class Group; end
  class ComponentInstance; end
  class Edge; end
  class Face; end
  class Vertex; end
  class ArcCurve; end

  class Selection
    def initialize
      @items = []
    end

    def clear
      @items.clear
    end

    def add(item)
      @items << item
    end

    def remove(item)
      @items.delete(item)
    end

    def to_a
      @items.dup
    end
  end

  class Model
    def initialize
      @options = { 'UnitsOptions' => { 'LengthUnit' => 2 } }
      @selection = Selection.new
    end

    attr_reader :options, :selection
  end

  @model = Model.new
  @defaults = {}

  class << self
    attr_reader :model

    def active_model
      @model
    end

    def read_default(section, key, default = nil)
      @defaults.fetch([section, key], default)
    end

    def write_default(section, key, value)
      @defaults[[section, key]] = value
    end

    def format_length(value)
      format('%.2fmm', value.to_f / (1.0 / 25.4))
    end

    def status_text=(_value); end

    def vcb_label=(_value); end

    def vcb_value=(_value); end
  end
end

module UI
  def self.messagebox(_text)
    nil
  end

  def self.beep
    nil
  end

  def self.inputbox(*_args)
    nil
  end

  def self.set_cursor(_cursor)
    true
  end

  def self.start_timer(*_args)
    nil
  end

  def self.scale_factor
    1.0
  end
end
