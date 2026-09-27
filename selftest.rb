# encoding: UTF-8
#
# 变形框收分缩放 —— 真实 SketchUp 环境自检
#
# 用法：安装扩展并重启 SketchUp 后，在 Ruby 控制台执行
#     load '/路径/selftest.rb'
#
# 脚本会临时创建一根 10" x 10" x 100" 的柱子，跑一遍收分与还原，
# 校验收分结果，最后自动撤销，不留下任何测试几何。

unless defined?(Ban::TaperScale::VertexSet)
  raise '未找到 Ban::TaperScale，请先安装「变形框收分缩放」扩展并重启 SketchUp。'
end

module BanTaperScaleSelfTest
  BOX = Ban::TaperScale::DeformBox
  MATH = Ban::TaperScale::DeformMath
  TOLERANCE = 0.0001

  def self.run
    @passed = []
    @failed = []

    model = Sketchup.active_model
    model.start_operation('收分缩放自检', true)
    begin
      group = build_column(model)
      vertices = collect_vertices(group)
      check_baseline(vertices)
      set = run_taper(model, group)
      check_tapered(vertices)
      check_reset(set)
    ensure
      model.abort_operation
    end

    report
  end

  # ---- 测试动作 ------------------------------------------------------------

  def self.build_column(model)
    group = model.active_entities.add_group
    face = group.entities.add_face(
      [0, 0, 0], [10, 0, 0], [10, 10, 0], [0, 10, 0]
    )
    face.pushpull(100)
    group
  end

  def self.collect_vertices(group)
    group.entities.grep(Sketchup::Edge).map(&:vertices).flatten.uniq
  end

  def self.modify(model, group)
    box = BOX.from_points([
      Geom::Point3d.new(0, 0, 0),
      Geom::Point3d.new(10, 10, 100)
    ])
    set = Ban::TaperScale::VertexSet.new
    set.collect([group], Geom::Transformation.new, model.active_entities,
                unique: true, explode_curves: false)
    [box, set]
  end

  def self.run_taper(model, group)
    box, set = modify(model, group)
    set.apply do |point|
      MATH.taper_point(box, 2, 0, [0.6, 0.6], point)
    end
    set
  end

  # 同一个 VertexSet 还原回收集时的位置
  def self.check_reset(set)
    set.reset
    positions = set.vertices.map { |vertex| vertex.position }
    top = positions.select { |point| near?(point.z, 100) }
    check('还原后顶面回到 10 x 10',
          top.map { |point| point.x.round(4) }.sort == [0.0, 10.0] &&
          top.map { |point| point.y.round(4) }.sort == [0.0, 10.0],
          top.map { |point| point.x.round(4) }.sort.inspect)
  end

  # ---- 断言 ---------------------------------------------------------------

  def self.check_baseline(vertices)
    bottom = bottom_vertices(vertices)
    top = top_vertices(vertices)
    check('柱子底面 4 个顶点存在', bottom.size == 4, bottom.size.to_s)
    check('柱子顶面 4 个顶点存在', top.size == 4, top.size.to_s)
    check('顶面初始高度为 100', near?(top.first.z, 100), top.first.z.to_s)
  end

  def self.check_tapered(vertices)
    bottom = bottom_vertices(vertices)
    top = top_vertices(vertices)

    check('收分：底面保持不变',
          xs(bottom).sort == [0.0, 10.0] && ys(bottom).sort == [0.0, 10.0],
          "x=#{xs(bottom).sort.inspect} y=#{ys(bottom).sort.inspect}")
    check('收分：顶面缩为 6 x 6',
          xs(top).all? { |x| near?(x, 2.0) || near?(x, 8.0) } &&
          ys(top).all? { |y| near?(y, 2.0) || near?(y, 8.0) },
          "x=#{xs(top).sort.inspect} y=#{ys(top).sort.inspect}")
    check('收分：高度不变',
          top.all? { |v| near?(v.z, 100) },
          top.map(&:z).uniq.inspect)
  end

  # ---- 工具方法 -----------------------------------------------------------

  def self.bottom_vertices(vertices)
    vertices.select { |vertex| near?(vertex.position.z, 0) }
  end

  def self.top_vertices(vertices)
    vertices.select { |vertex| near?(vertex.position.z, 100) }
  end

  def self.xs(vertices)
    vertices.map { |vertex| vertex.position.x.round(4) }
  end

  def self.ys(vertices)
    vertices.map { |vertex| vertex.position.y.round(4) }
  end

  def self.near?(a, b)
    (a - b).abs < TOLERANCE
  end

  def self.check(name, passed, detail = nil)
    if passed
      @passed << name
      puts "  ✅ #{name}"
    else
      @failed << name
      puts "  ❌ #{name}#{detail ? "  -> #{detail}" : ''}"
    end
  end

  def self.report
    puts ''
    if @failed.empty?
      puts "✅ 全部通过：#{@passed.size} 项 —— 插件在当前 SketchUp 版本上工作正常。"
    else
      puts "❌ 失败 #{@failed.size} / #{@passed.size + @failed.size} 项，请把上面的输出发给我。"
    end
    @failed.empty?
  end
end

BanTaperScaleSelfTest.run
