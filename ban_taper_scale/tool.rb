# encoding: UTF-8
#
# 变形框工具：拖动手柄对所选对象做"拉伸缩放"或"收分"。
#
#  · 拉伸缩放：仿射变换，直接作用于实体/组/组件的放置矩阵，不改变组件结构与贴图。
#  · 收分：非仿射，逐顶点变形（保留材质、UV、柔化平滑、组结构），可实时预览。

require 'sketchup.rb'
require File.join(File.dirname(__FILE__), 'settings.rb')
require File.join(File.dirname(__FILE__), 'vec_math.rb')
require File.join(File.dirname(__FILE__), 'deform_box.rb')
require File.join(File.dirname(__FILE__), 'deform_math.rb')
require File.join(File.dirname(__FILE__), 'vertex_set.rb')

module Ban
  module TaperScale
    class Tool
      OP_NAME = '变形框收分缩放'.freeze

      PICK_PX = 11
      # 屏幕距离相差在这个范围内视为"重合"，此时取离相机更近的手柄
      PICK_TIE_PX = 0.5
      DRAG_TOLERANCE_PX = 2
      VERTEX_PREVIEW_LIMIT = 80_000

      MODE_ORDER = [:stretch, :taper].freeze
      MODE_LABEL = { stretch: '拉伸缩放', taper: '收分' }.freeze

      DRAW_OPEN_SQUARE     = 1
      DRAW_FILLED_SQUARE   = 2
      DRAW_FILLED_TRIANGLE = 7

      COLOR_BOX           = Sketchup::Color.new(130, 130, 130)
      COLOR_BOX_ACTIVE    = Sketchup::Color.new(255, 152, 0)
      COLOR_TAPER_GUIDE   = Sketchup::Color.new(0, 168, 122)
      COLOR_FACE_HANDLE   = Sketchup::Color.new(0, 122, 255)
      COLOR_CORNER_HANDLE = Sketchup::Color.new(255, 255, 255)
      COLOR_HOT           = Sketchup::Color.new(255, 140, 0)
      COLOR_DRAG          = Sketchup::Color.new(255, 45, 0)
      COLOR_TEXT          = Sketchup::Color.new(50, 50, 50)
      COLOR_AXIS_LOCK     = Sketchup::Color.new(0, 170, 120)

      AXIS_LABEL = ['X', 'Y', 'Z'].freeze

      # 模型长度单位序号 -> 英寸换算
      UNIT_TO_INCH = {
        0 => 1.0,                    # 英寸
        1 => 12.0,                   # 英尺
        2 => 1.0 / 25.4,             # 毫米
        3 => 1.0 / 2.54,             # 厘米
        4 => 39.37007874015748       # 米
      }.freeze

      UNIT_NAME = { 0 => 'in', 1 => 'ft', 2 => 'mm', 3 => 'cm', 4 => 'm' }.freeze

      # 取修饰键掩码常量（不同版本/平台位置不同）
      def self.modifier_mask(name)
        return Sketchup.const_get(name) if Sketchup.const_defined?(name)
        return Object.const_get(name) if Object.const_defined?(name)

        0
      end

      COPY_MASK = Tool.modifier_mask(:COPY_MODIFIER_MASK)

      def initialize
        @mode = :stretch
        @box = nil
        @targets = []
        @parent_entities = nil
        @edit_tr = Geom::Transformation.new
        @drag = nil
        @hover = nil
        @ip = Sketchup::InputPoint.new
        @ref_ip = Sketchup::InputPoint.new
        @dpi = nil
        @message = ''
      end

      # ------------------------------------------------------------ 生命周期

      def activate
        model = Sketchup.active_model
        refresh_context(model)
        if @targets.empty?
          UI.messagebox('请先选中要变形的对象（组 / 组件 / 几何体），再启用本工具。')
          UI.start_timer(0.0, false) { model.select_tool(nil) }
          return
        end
        @box = build_box
        @hover = nil
        @drag = nil
        @message = ''
        update_ui
        model.active_view.invalidate
      end

      def deactivate(view)
        cancel_drag(view) if @drag
        set_vcb('', '')
        Sketchup.status_text = ''
        view.invalidate if view
      end

      def resume(view)
        refresh_context(Sketchup.active_model)
        @box = @targets.empty? ? nil : build_box
        @drag = nil
        @hover = nil
        update_ui
        view.invalidate
      end

      def suspend(_view)
        nil
      end

      def enableVCB?
        true
      end

      # ------------------------------------------------------------ 右键菜单

      def getMenu(menu)
        id = menu.add_item('精确输入…') { exact_input }
        menu.set_validation_proc(id) { (@drag || @hover) ? MF_ENABLED : MF_GRAYED }

        id = menu.add_item('应用（结束本次变形）') { commit_drag(Sketchup.active_model.active_view) }
        menu.set_validation_proc(id) { @drag ? MF_ENABLED : MF_GRAYED }

        id = menu.add_item('取消当前锁定') { cancel_drag(Sketchup.active_model.active_view) }
        menu.set_validation_proc(id) { @drag ? MF_ENABLED : MF_GRAYED }

        menu.add_separator

        MODE_ORDER.each do |mode|
          id = menu.add_item("#{MODE_LABEL[mode]}模式") { set_mode(mode) }
          menu.set_validation_proc(id) { @mode == mode ? MF_CHECKED : MF_ENABLED }
        end

        menu.add_separator

        id = menu.add_item('变形框对齐对象坐标') { toggle_object_axes }
        menu.set_validation_proc(id) { Settings.object_axes? ? MF_CHECKED : MF_ENABLED }

        id = menu.add_item('收分时炸开圆/弧曲线') { toggle_explode_curves }
        menu.set_validation_proc(id) { Settings.explode_curves? ? MF_CHECKED : MF_ENABLED }

        menu.add_separator
        menu.add_item('退出工具') { Sketchup.active_model.select_tool(nil) }
        true
      rescue StandardError
        true
      end

      def set_mode(mode)
        return if @drag || @mode == mode

        @mode = mode
        @hover = nil
        update_ui
        Sketchup.active_model.active_view.invalidate
      end

      def toggle_object_axes
        Settings.object_axes = !Settings.object_axes?
        @box = @targets.empty? ? nil : build_box
        Sketchup.active_model.active_view.invalidate
      end

      def toggle_explode_curves
        Settings.explode_curves = !Settings.explode_curves?
      end

      # ---- 精确输入（右键）------------------------------------------------

      # 右键「精确输入…」：
      #   拉伸缩放 → 输入沿轴的增量，正数延长、负数缩短（无单位按模型单位）
      #   收分     → 输入两个方向的收分比
      def exact_input
        handle = @drag ? @drag[:handle] : @hover
        if handle.nil?
          UI.messagebox('请先点一下变形框上的手柄（缩放点），再进行精确输入。')
          return
        end

        model = Sketchup.active_model
        temporary = false
        unless @drag
          model.start_operation(OP_NAME, false)
          refresh_context(model)
          @box ||= build_box
          handle = find_handle(handle)
          if handle.nil?
            cancel_click(model, model.active_view)
            return
          end
          start_drag(handle, false, nil, nil)
          @drag[:sticky] = true
          temporary = true
        end

        values = prompt_exact_values
        if values.nil?
          cancel_drag(model.active_view) if temporary
          return
        end

        spec = spec_from_exact_values(values)
        if spec.nil?
          UI.beep
          cancel_drag(model.active_view) if temporary
          return
        end

        @drag[:spec] = spec
        @drag[:moved] = true
        apply_spec(spec)
        commit_drag(model.active_view)
        @message = "已精确输入：#{describe_spec(spec)}"
        update_ui
      end

      # 弹出输入框，返回 {:kind=>:deltas, :list=>[[axis, inches], ...]}
      # 或 {:kind=>:factors, :list=>[ratio, ratio]}
      def prompt_exact_values
        handle = @drag[:handle]

        if @drag[:mode] == :taper
          axis = handle[:axis]
          labels = DeformMath.perpendicular_axes(axis).map do |j|
            "方向 #{AXIS_LABEL[j]} 收分比"
          end
          defaults = @drag[:spec][:factors].map { |factor| format('%.3f', factor) }
          input = UI.inputbox(labels, defaults, '精确收分比')
          return nil unless input

          { kind: :factors, list: input.map { |text| text.to_f } }
        else
          axes = handle[:type] == :corner ? [0, 1, 2] : [handle[:axis]]
          unit = unit_name
          labels = axes.map do |axis|
            "沿框 #{AXIS_LABEL[axis]} 轴增量（#{unit}，正数延长 / 负数缩短）"
          end
          input = UI.inputbox(labels, Array.new(axes.size, '0'), '精确缩放')
          return nil unless input

          list = axes.each_with_index.map { |axis, index| [axis, parse_length_input(input[index])] }
          { kind: :deltas, list: list }
        end
      end

      def spec_from_exact_values(values)
        box = @drag[:base_box]
        handle = @drag[:handle]

        if values[:kind] == :factors
          return nil if values[:list].size != 2

          { kind: :taper, axis: handle[:axis], anchor: 1 - handle[:side],
            factors: values[:list].map { |factor| DeformMath.clamp_factor(factor) } }
        else
          return nil if values[:list].empty?

          spec_from_deltas(values[:list], handle, box)
        end
      end

      def spec_from_deltas(list, handle, box)
        sizes = box.sizes.dup
        anchors = [0, 0, 0]
        list.each do |axis, delta|
          anchors[axis] = 1 - axis_side_of(handle, axis)
          sizes[axis] = DeformBox.clamp_size(box.sizes[axis] + delta)
        end
        { kind: :stretch, anchors: anchors, sizes: sizes }
      end

      def axis_side_of(handle, axis)
        return handle[:corner][axis] if handle[:type] == :corner
        return handle[:side] if handle[:axis] == axis

        0
      end

      def parse_length_input(text)
        value = text.to_s.strip
        return 0.0 if value.empty?

        if value =~ /\A[-+]?(?:\d+\.?\d*|\.\d+)\z/
          value.to_f * model_unit_factor
        else
          value.to_l.to_f
        end
      rescue StandardError
        0.0
      end

      def model_unit_factor
        UNIT_TO_INCH[length_unit] || 1.0
      end

      def unit_name
        UNIT_NAME[length_unit] || 'in'
      end

      def length_unit
        Sketchup.active_model.options['UnitsOptions']['LengthUnit']
      rescue StandardError
        2 # 默认按毫米
      end

      def describe_spec(spec)
        box = @drag ? @drag[:base_box] : nil
        if spec[:kind] == :stretch && box
          (0...3).map do |axis|
            delta = spec[:sizes][axis] - box.sizes[axis]
            next nil if delta.abs < 1.0e-9

            format('%+.2f%s', delta / model_unit_factor, unit_name)
          end.compact.join('，')
        elsif spec[:kind] == :taper
          spec[:factors].map { |factor| format('%.3f', factor) }.join(' × ')
        else
          ''
        end
      end

      # ------------------------------------------------------------ 鼠标事件

      def onMouseMove(_flags, x, y, view)
        if @drag
          update_drag(x, y, view)
        else
          handle = pick_handle(view, x, y)
          return if same_handle?(handle, @hover)

          @hover = handle
          update_ui
          view.invalidate
        end
      end

      def onLButtonDown(flags, x, y, view)
        if @drag
          # 已经锁定方向轴：再点一下 = 应用当前结果
          commit_drag(view) if @drag[:sticky]
          return
        end

        handle = pick_handle(view, x, y)
        return unless handle

        model = Sketchup.active_model
        model.start_operation(OP_NAME, false)

        copy = (flags & COPY_MASK) != 0
        if copy && !copy_selection(model)
          copy = false
          @message = '复制模式仅支持组/组件，本次改为原地变形'
        end

        refresh_context(model)
        @box = build_box if @box.nil? || copy
        handle = find_handle(handle) if handle
        return cancel_click(model, view) unless handle

        start_drag(handle, copy, x, y)
        update_ui
        view.invalidate
      end

      def start_drag(handle, copy, x, y)
        drag = {
          handle: handle,
          mode: @mode,
          copy: copy,
          base_box: @box,
          anchor_point: handle[:pos],
          down: (x && y) ? [x, y] : nil,
          spec: initial_spec(handle),
          applied_local: Geom::Transformation.new,
          moved: false,
          sticky: false,
          vertex_set: nil
        }

        if @mode == :taper
          drag[:vertex_set] = collect_vertices
          if drag[:vertex_set].size > VERTEX_PREVIEW_LIMIT
            @message = '顶点数量较多，实时预览可能会略卡'
          end
        end

        @drag = drag
        @ref_ip = Sketchup::InputPoint.new(handle[:pos])
        drag
      end

      def onLButtonUp(_flags, x, y, view)
        return unless @drag

        update_drag(x, y, view)
        if @drag[:moved]
          commit_drag(view)
        else
          # 单击手柄：锁定方向轴，之后移动鼠标即可缩放，再点一下应用
          @drag[:sticky] = true
          update_ui
          view.invalidate
        end
      end

      def onKeyDown(key, _repeat, _flags, view)
        return false unless key == 9 # Tab

        return false if @drag

        index = MODE_ORDER.index(@mode) || 0
        set_mode(MODE_ORDER[(index + 1) % MODE_ORDER.size])
        view.invalidate
        true
      end

      # reason: 0 = Esc，1 = 工具被重新激活，2 = 撤销/重做
      def onCancel(reason, view)
        if @drag
          cancel_drag(view)
        elsif reason == 2
          # 撤销 / 重做：刷新变形框，工具保持激活
          model = Sketchup.active_model
          refresh_context(model)
          @box = @targets.empty? ? nil : build_box
          update_ui
          view.invalidate
        else
          model = Sketchup.active_model
          model.select_tool(nil)
        end
      end

      # 数值输入：精确比例 / 目标尺寸
      def onUserText(text, view)
        return if @drag.nil?

        values = parse_values(text)
        if values.nil?
          UI.beep
          return
        end

        spec = spec_from_values(values)
        if spec.nil?
          UI.beep
          return
        end

        @drag[:spec] = spec
        @drag[:moved] = true
        apply_spec(spec)
        commit_drag(view)
      end

      # ------------------------------------------------------------ 绘制

      def getExtents
        bounds = Geom::BoundingBox.new
        bounds.add(@box.corners) if @box
        @targets.each do |entity|
          begin
            next unless entity.valid?

            box = entity.bounds
            bounds.add((0..7).map { |index| box.corner(index) })
          rescue StandardError
            nil
          end
        end
        bounds.add(ORIGIN) if bounds.empty?
        bounds
      end

      def draw(view)
        return if @box.nil?

        draw_box(view)
        draw_axis_lock(view) if @drag
        draw_taper_guide(view) if @mode == :taper
        draw_handles(view)
        draw_hud(view)
      end

      # 锁定状态下画出方向轴，让"锁轴"看得见
      def draw_axis_lock(view)
        handle = @drag[:handle]
        box = @drag[:base_box]
        direction = box.axes[handle[:axis]]
        point = @drag[:anchor_point]
        reach = box.sizes[handle[:axis]] * 0.75 + 2.0
        first = VecMath.point_plus(point, VecMath.scale(direction, -reach))
        second = VecMath.point_plus(point, VecMath.scale(direction, reach))

        view.line_stipple = '-'
        view.line_width = 2
        view.drawing_color = COLOR_AXIS_LOCK
        view.draw(GL_LINES, [first, second])
        view.line_stipple = ''
      end

      # ------------------------------------------------------------ 私有

      private

      def dpi
        @dpi ||= begin
          value = UI.respond_to?(:scale_factor) ? UI.scale_factor.to_f : 1.0
          value.positive? ? value : 1.0
        end
      end

      # 逻辑像素 -> 设备像素（View 的屏幕坐标系）
      def px(value)
        (value * dpi).round
      end

      def refresh_context(model)
        @targets = model.selection.to_a
        @parent_entities = model.active_entities
        @edit_tr = edit_transform(model)
      end

      def edit_transform(model)
        transformation = Geom::Transformation.new
        path = model.active_path
        return transformation unless path

        path.each { |entity| transformation = transformation * entity.transformation }
        transformation
      end

      # 变形框：单个组/组件时按对象自身轴向，否则按世界轴向。
      def build_box
        return nil if @targets.empty?

        if @targets.size == 1 && instance?(@targets.first) && Settings.object_axes?
          instance_box(@targets.first)
        else
          points = []
          collect_bounds_points(@targets, @edit_tr, points, 0)
          DeformBox.from_points(points)
        end
      end

      def instance_box(instance)
        transformation = @edit_tr * instance.transformation
        definition = definition_of(instance)
        return nil unless definition

        bounds = definition.bounds
        points = (0..7).map { |index| transformation * bounds.corner(index) }
        axes = [
          Geom::Vector3d.new(transformation.xaxis.x, transformation.xaxis.y, transformation.xaxis.z),
          Geom::Vector3d.new(transformation.yaxis.x, transformation.yaxis.y, transformation.yaxis.z),
          Geom::Vector3d.new(transformation.zaxis.x, transformation.zaxis.y, transformation.zaxis.z)
        ]
        DeformBox.from_points(points, axes)
      end

      def collect_bounds_points(entities, transformation, points, depth)
        return points if depth > 10

        entities.each do |entity|
          if instance?(entity)
            child = definition_of(entity)
            next unless child

            collect_bounds_points(child.entities, transformation * entity.transformation,
                                  points, depth + 1)
          elsif entity.respond_to?(:bounds)
            bounds = entity.bounds
            (0..7).each { |index| points << (transformation * bounds.corner(index)) }
          end
        end
        points
      end

      def instance?(entity)
        entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
      end

      def definition_of(instance)
        if instance.respond_to?(:definition)
          begin
            definition = instance.definition
            return definition if definition
          rescue StandardError
            nil
          end
        end
        return instance.entities.parent if instance.is_a?(Sketchup::Group)

        nil
      rescue StandardError
        nil
      end

      # ---- 手柄 ---------------------------------------------------------

      def handles
        return [] if @box.nil?

        list = []
        3.times do |axis|
          [0, 1].each do |side|
            list << { type: :face, axis: axis, side: side,
                      pos: @box.face_center(axis, side) }
          end
        end

        if @mode == :stretch
          [0, 1].each do |i|
            [0, 1].each do |j|
              [0, 1].each do |k|
                list << { type: :corner, corner: [i, j, k], pos: @box.corner(i, j, k) }
              end
            end
          end
        end
        list
      end

      def handle_key(handle)
        return nil if handle.nil?

        [handle[:type], handle[:axis], handle[:side], handle[:corner]]
      end

      def same_handle?(first, second)
        handle_key(first) == handle_key(second)
      end

      def find_handle(reference)
        key = handle_key(reference)
        handles.find { |handle| handle_key(handle) == key }
      end

      def pick_handle(view, x, y)
        handle = pick_handle_with_scale(view, x, y, dpi)
        if handle.nil? && dpi != 1.0
          # 兜底：若当前 DPI 假设取不到手柄，再按不缩放试一次
          handle = pick_handle_with_scale(view, x, y, 1.0)
          @dpi = 1.0 if handle
        end
        handle
      end

      def pick_handle_with_scale(view, x, y, scale)
        mouse_x = x * scale
        mouse_y = y * scale
        eye = camera_eye(view)

        best = nil
        best_distance = PICK_PX.to_f
        best_camera_distance = nil

        handles.each do |handle|
          screen = view.screen_coords(handle[:pos])
          next unless screen

          distance = Math.sqrt((screen.x - mouse_x)**2 + (screen.y - mouse_y)**2)
          next if distance > PICK_PX

          camera_distance = eye ? VecMath.distance(eye, handle[:pos]) : 0.0
          if best.nil? || nearer_handle?(distance, camera_distance, best_distance, best_camera_distance)
            best = handle
            best_distance = distance
            best_camera_distance = camera_distance
          end
        end
        best
      end

      # 屏幕距离优先；几近重合时取离相机更近的那个
      def nearer_handle?(distance, camera_distance, best_distance, best_camera_distance)
        return true if distance < best_distance - PICK_TIE_PX
        return false if distance > best_distance + PICK_TIE_PX

        camera_distance < (best_camera_distance || Float::INFINITY)
      end

      def camera_eye(view)
        view.camera.eye
      rescue StandardError
        nil
      end

      # ---- 拖动 ---------------------------------------------------------

      def update_drag(x, y, view)
        drag = @drag
        if drag[:down]
          moved_x = x - drag[:down][0]
          moved_y = y - drag[:down][1]
          if Math.sqrt(moved_x * moved_x + moved_y * moved_y) > DRAG_TOLERANCE_PX
            drag[:moved] = true
          end
        end

        point = drag_point(view, x, y)
        return unless point

        spec = compute_spec(point)
        return if same_spec?(spec, drag[:spec])

        drag[:spec] = spec
        apply_spec(spec)
        update_ui
        view.invalidate
      end

      def same_spec?(first, second)
        return false if first.nil? || second.nil?
        return false unless first[:kind] == second[:kind]

        if first[:kind] == :stretch
          (0...3).all? { |i| (first[:sizes][i] - second[:sizes][i]).abs < 1.0e-7 }
        else
          (0...2).all? { |i| (first[:factors][i] - second[:factors][i]).abs < 1.0e-6 }
        end
      end

      # 鼠标位置 -> 世界坐标（优先使用 SketchUp 的推理点，可精确吸附到目标点）
      def drag_point(view, x, y)
        @ip.pick(view, x, y, @ref_ip)
        return @ip.position if @ip.vertex || @ip.edge || @ip.face

        handle = @drag[:handle]
        base = @drag[:anchor_point]
        if handle[:type] == :face
          axis_line_point(view, x, y, base, @drag[:base_box].axes[handle[:axis]]) || @ip.position
        else
          screen_plane_point(view, x, y, base) || @ip.position
        end
      end

      # 鼠标射线与给定直线的最近点（沿轴拖动更稳定）
      def axis_line_point(view, x, y, base, direction)
        return nil unless view.respond_to?(:pickray)

        ray = view.pickray(x * dpi, y * dpi)
        return nil unless ray

        origin = ray[0]
        ray_direction = ray[1]
        w0 = VecMath.point_minus(origin, base)
        a = VecMath.dot(ray_direction, ray_direction)
        b = VecMath.dot(ray_direction, direction)
        c = VecMath.dot(direction, direction)
        d = VecMath.dot(w0, ray_direction)
        e = VecMath.dot(w0, direction)
        denominator = a * c - b * b
        return nil if denominator.abs < 1.0e-9

        t = (a * e - b * d) / denominator
        VecMath.point_plus(base, VecMath.scale(direction, t))
      end

      # 屏幕平面上的拖动点（拖动角点时使用）
      def screen_plane_point(view, x, y, base)
        return nil unless view.respond_to?(:pickray)

        ray = view.pickray(x * dpi, y * dpi)
        return nil unless ray

        origin = ray[0]
        direction = ray[1]
        normal = view.camera.direction
        denominator = VecMath.dot(direction, normal)
        return nil if denominator.abs < 1.0e-9

        t = VecMath.dot(VecMath.point_minus(base, origin), normal) / denominator
        VecMath.point_plus(origin, VecMath.scale(direction, t))
      end

      # ---- 变形方案 -----------------------------------------------------

      def initial_spec(handle)
        if @mode == :taper
          { kind: :taper, axis: handle[:axis], anchor: 1 - handle[:side],
            factors: [1.0, 1.0] }
        else
          { kind: :stretch, anchors: [0, 0, 0], sizes: @box.sizes.dup }
        end
      end

      def compute_spec(point)
        drag = @drag
        handle = drag[:handle]
        box = drag[:base_box]

        if drag[:mode] == :stretch
          sizes = box.sizes.dup
          anchors = [0, 0, 0]

          if handle[:type] == :face
            axis = handle[:axis]
            side = handle[:side]
            anchors[axis] = 1 - side
            coordinate = box.project(point, axis)
            sizes[axis] = DeformBox.clamp_size(side == 1 ? coordinate : box.sizes[axis] - coordinate)
          else
            3.times do |axis|
              side = handle[:corner][axis]
              anchors[axis] = 1 - side
              coordinate = box.project(point, axis)
              sizes[axis] = DeformBox.clamp_size(side == 1 ? coordinate : box.sizes[axis] - coordinate)
            end
          end
          { kind: :stretch, anchors: anchors, sizes: sizes }
        else
          axis = handle[:axis]
          factors = DeformMath.perpendicular_axes(axis).map do |j|
            delta = VecMath.dot(
              VecMath.point_minus(point, drag[:anchor_point]), box.axes[j]
            )
            DeformMath.clamp_factor(1.0 + delta / (box.sizes[j] * 0.5))
          end
          { kind: :taper, axis: axis, anchor: 1 - handle[:side], factors: factors }
        end
      end

      def apply_spec(spec)
        drag = @drag
        if spec[:kind] == :stretch
          new_box = DeformMath.stretch_box(drag[:base_box], spec[:anchors], spec[:sizes])
          world = stretch_transformation(drag[:base_box], new_box)
          local = @edit_tr.inverse * world * @edit_tr
          delta = local * drag[:applied_local].inverse
          return if identity?(delta)

          transform_targets(delta)
          drag[:applied_local] = local
        else
          box = drag[:base_box]
          axis = spec[:axis]
          anchor = spec[:anchor]
          factors = spec[:factors]
          drag[:vertex_set].apply do |world|
            DeformMath.taper_point(box, axis, anchor, factors, world)
          end
        end
      end

      def stretch_transformation(base, new_box)
        scales = (0...3).map { |i| new_box.sizes[i] / base.sizes[i] }
        rotation = Geom::Transformation.axes(ORIGIN, base.axes[0], base.axes[1], base.axes[2])
        scaling = Geom::Transformation.scaling(scales[0], scales[1], scales[2])
        # T(p) = O' + R · S · R⁻¹ · (p - O)
        Geom::Transformation.translation(
          Geom::Vector3d.new(new_box.origin.x, new_box.origin.y, new_box.origin.z)
        ) *
          rotation * scaling * rotation.inverse *
          Geom::Transformation.translation(VecMath.point_minus(ORIGIN, base.origin))
      end

      def identity?(transformation)
        values = transformation.to_a
        identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        (0...16).all? { |i| (values[i] - identity[i]).abs < 1.0e-9 }
      end

      def transform_targets(delta)
        return if @targets.empty?

        @parent_entities.transform_entities(delta, @targets)
      rescue StandardError
        @targets.each do |entity|
          begin
            entity.transform!(delta)
          rescue StandardError
            nil
          end
        end
      end

      def collect_vertices
        set = VertexSet.new
        set.collect(@targets, @edit_tr, @parent_entities,
                    unique: true, explode_curves: Settings.explode_curves?)
        set
      end

      def copy_selection(model)
        copies = []
        model.selection.each do |entity|
          next unless instance?(entity)

          begin
            copy = entity.copy
            copies << copy if copy
          rescue StandardError
            nil
          end
        end
        return false if copies.empty?

        model.selection.clear
        model.selection.add(copies)
        true
      end

      # ---- 提交 / 取消 ---------------------------------------------------

      def commit_drag(view)
        drag = @drag
        return if drag.nil?

        @drag = nil
        model = Sketchup.active_model

        unless drag[:moved]
          rollback_operation
          update_ui
          view.invalidate
          return
        end

        if drag[:mode] == :stretch
          spec = drag[:spec]
          @box = DeformMath.stretch_box(drag[:base_box], spec[:anchors], spec[:sizes])
        else
          @box = drag[:base_box]
          keep_valid_selection(model)
        end

        model.commit_operation
        @message = ''
        update_ui
        view.invalidate
      end

      def cancel_click(_model, view)
        rollback_operation
        update_ui
        view.invalidate
      end

      def cancel_drag(view)
        drag = @drag
        @drag = nil
        return if drag.nil?

        if drag[:vertex_set]
          begin
            drag[:vertex_set].reset
          rescue StandardError
            nil
          end
        end

        if drag[:mode] == :stretch && !identity?(drag[:applied_local])
          begin
            transform_targets(drag[:applied_local].inverse)
          rescue StandardError
            nil
          end
        end

        rollback_operation
        update_ui
        view.invalidate
      end

      def rollback_operation
        model = Sketchup.active_model
        if model.respond_to?(:abort_operation)
          model.abort_operation
        else
          model.commit_operation
        end
      rescue StandardError
        begin
          model.commit_operation
        rescue StandardError
          nil
        end
      end

      def keep_valid_selection(model)
        valid = @targets.select { |entity| entity.valid? }
        if valid.empty?
          @message = '选择集已失效，请重新选择后再次执行'
          return
        end

        model.selection.clear
        model.selection.add(valid)
        @targets = valid
      end

      # ---- 数值输入 ------------------------------------------------------

      def parse_values(text)
        return nil if text.nil?

        parts = text.split(/[,;，；\s]+/).reject { |part| part.strip.empty? }
        return nil if parts.empty? || parts.size > 3

        values = parts.map { |part| parse_value(part) }
        return nil if values.any? { |value| value.nil? }

        values
      end

      # 拖动时输入框（VCB）的解析规则：
      #   1.5x / *1.5   -> 比例
      #   100 / -100    -> 无单位数值（拉伸 = 按模型单位的增量，收分 = 比例）
      #   100mm / 3"    -> 带单位的长度
      def parse_value(text)
        value = text.strip
        return nil if value.empty?

        if value =~ /\A[xX*]\s*([-+]?(?:\d+\.?\d*|\.\d+))\z/ ||
           value =~ /\A([-+]?(?:\d+\.?\d*|\.\d+))\s*[xX*]\z/
          { kind: :ratio, value: Regexp.last_match(1).to_f }
        elsif value =~ /\A[-+]?(?:\d+\.?\d*|\.\d+)\z/
          { kind: :number, value: value.to_f }
        elsif value =~ /\A[-+]?(?:\d+\.?\d*|\.\d+)\s*[a-zA-Z"'°]+\z/
          { kind: :length, value: value.to_l.to_f }
        end
      end

      def spec_from_values(values)
        handle = @drag[:handle]
        box = @drag[:base_box]

        if @mode == :stretch
          stretch_spec_from_values(values, handle, box)
        else
          taper_spec_from_values(values, handle, box)
        end
      end

      def stretch_spec_from_values(values, handle, box)
        if values.size == 1
          value = values.first
          axes = handle[:type] == :corner ? [0, 1, 2] : [handle[:axis]]

          if value[:kind] == :ratio
            sizes = box.sizes.dup
            anchors = [0, 0, 0]
            axes.each do |axis|
              anchors[axis] = 1 - axis_side_of(handle, axis)
              sizes[axis] = DeformBox.clamp_size(box.sizes[axis] * value[:value])
            end
            { kind: :stretch, anchors: anchors, sizes: sizes }
          else
            delta = delta_of(value)
            spec_from_deltas(axes.map { |axis| [axis, delta] }, handle, box)
          end
        elsif values.size == 3
          return nil if values.any? { |value| value[:kind] == :ratio }

          list = (0...3).map { |axis| [axis, delta_of(values[axis])] }
          spec_from_deltas(list, handle, box)
        end
      end

      # 无单位数值按模型单位换算成英寸增量
      def delta_of(value)
        value[:kind] == :number ? value[:value] * model_unit_factor : value[:value]
      end

      def taper_spec_from_values(values, handle, box)
        axis = handle[:axis]
        perpendicular = DeformMath.perpendicular_axes(axis)
        anchor = 1 - handle[:side]

        factors =
          case values.size
          when 1
            value = values.first
            if value[:kind] == :ratio || value[:kind] == :number
              [value[:value], value[:value]]
            else
              perpendicular.map { |j| value[:value] / box.sizes[j] }
            end
          when 2
            perpendicular.each_with_index.map do |j, index|
              value = values[index]
              if value[:kind] == :ratio || value[:kind] == :number
                value[:value]
              else
                value[:value] / box.sizes[j]
              end
            end
          else
            return nil
          end

        { kind: :taper, axis: axis, anchor: anchor,
          factors: factors.map { |factor| DeformMath.clamp_factor(factor) } }
      end

      # ---- 界面提示 ------------------------------------------------------

      def update_ui
        if @drag
          locked = "已锁定框 #{AXIS_LABEL[@drag[:handle][:axis]]} 轴"
          Sketchup.status_text =
            "变形中（#{MODE_LABEL[@mode]}）：#{locked} —— 移动鼠标缩放，再点一下应用；" \
            '右键「精确输入…」可输入增量（正数延长 / 负数缩短）；Esc 取消。'
          set_vcb(vcb_label, vcb_value)
        else
          Sketchup.status_text =
            "变形框收分缩放（#{MODE_LABEL[@mode]}）：点一下手柄锁定方向轴 → 移动鼠标缩放 → 再点一下应用；" \
            '也可直接按住拖动；右键「精确输入…」输入增量；Tab 切换 拉伸/收分；' \
            'Ctrl(Windows)/Option(Mac) 点手柄 = 变形副本；Esc 退出。' +
            (@message.empty? ? '' : "  [#{@message}]")
          set_vcb('变形框', @box ? format_sizes(@box.sizes) : '')
        end
      end

      def vcb_label
        @mode == :taper ? '收分比' : '比例/尺寸'
      end

      def vcb_value
        spec = @drag && @drag[:spec]
        return '' unless spec

        if spec[:kind] == :stretch
          text = describe_spec(spec)
          text.empty? ? '0' : text
        else
          spec[:factors].map { |factor| format('%.3f', factor) }.join(', ')
        end
      end

      def set_vcb(label, value)
        Sketchup.vcb_label = label
        Sketchup.vcb_value = value
      rescue StandardError
        nil
      end

      def format_sizes(sizes)
        sizes.map { |size| Sketchup.format_length(size.abs) }.join(' × ')
      end

      # ---- 绘制细节 ------------------------------------------------------

      def box_edges(box, mapper = nil)
        points = []
        at = lambda do |i, j, k|
          point = box.corner(i, j, k)
          mapper ? mapper.call(point) : point
        end

        [0, 1].each do |j|
          [0, 1].each do |k|
            points << at.call(0, j, k) << at.call(1, j, k)
          end
        end
        [0, 1].each do |i|
          [0, 1].each do |k|
            points << at.call(i, 0, k) << at.call(i, 1, k)
          end
        end
        [0, 1].each do |i|
          [0, 1].each do |j|
            points << at.call(i, j, 0) << at.call(i, j, 1)
          end
        end
        points
      end

      def draw_box(view)
        view.line_stipple = ''
        view.line_width = (@drag || @hover) ? 2 : 1
        view.drawing_color = (@drag || @hover) ? COLOR_BOX_ACTIVE : COLOR_BOX
        view.draw(GL_LINES, box_edges(@box))
      end

      def draw_taper_guide(view)
        spec = @drag && @drag[:spec]
        return unless spec && spec[:kind] == :taper
        return unless @drag[:moved]

        box = @drag[:base_box]
        axis = spec[:axis]
        anchor = spec[:anchor]
        factors = spec[:factors]
        mapper = lambda { |point| DeformMath.taper_point(box, axis, anchor, factors, point) }

        view.line_stipple = '-'
        view.line_width = 2
        view.drawing_color = COLOR_TAPER_GUIDE
        view.draw(GL_LINES, box_edges(box, mapper))
        view.line_stipple = ''
      end

      def draw_handles(view)
        handles.each do |handle|
          if @drag && same_handle?(handle, @drag[:handle])
            view.draw_points([handle[:pos]], px(13), DRAW_FILLED_SQUARE, COLOR_DRAG)
          elsif @hover && same_handle?(handle, @hover)
            view.draw_points([handle[:pos]], px(12), DRAW_FILLED_SQUARE, COLOR_HOT)
          elsif handle[:type] == :face
            view.draw_points([handle[:pos]], px(9), DRAW_FILLED_TRIANGLE, COLOR_FACE_HANDLE)
          else
            view.draw_points([handle[:pos]], px(8), DRAW_FILLED_SQUARE, COLOR_CORNER_HANDLE)
          end
        end
      end

      def draw_hud(view)
        lines = ["模式：#{MODE_LABEL[@mode]}    (Tab 切换)"]
        if @drag
          lines << "已锁定：框 #{AXIS_LABEL[@drag[:handle][:axis]]} 轴（移动鼠标缩放，再点一下应用）"
        end
        spec = @drag && @drag[:spec]

        if spec && spec[:kind] == :stretch
          lines << "变形量：#{describe_spec(spec)}"
          lines << "目标尺寸：#{format_sizes(spec[:sizes])}"
        elsif spec
          lines << "收分比：#{spec[:factors].map { |f| format('%.3f', f) }.join(' : ')}"
          lines << "端面尺寸：#{format_sizes(end_face_sizes(spec))}"
        elsif @box
          lines << "变形框：#{format_sizes(@box.sizes)}"
        end
        lines << @message unless @message.empty?

        lines.each_with_index do |text, index|
          point = Geom::Point3d.new(px(18), px(26 + 17 * index), 0)
          begin
            view.draw_text(point, text, { size: px(13) })
          rescue StandardError
            begin
              view.draw_text(point, text)
            rescue StandardError
              nil
            end
          end
        end
      end

      def end_face_sizes(spec)
        box = @drag[:base_box]
        DeformMath.perpendicular_axes(spec[:axis]).each_with_index.map do |axis, index|
          box.sizes[axis] * spec[:factors][index]
        end
      end
    end
  end
end
