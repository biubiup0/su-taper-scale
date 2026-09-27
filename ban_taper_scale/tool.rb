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
      # 拖动时吸附到几何特征点的屏幕半径（像素）
      SNAP_PX = 12
      DRAG_TOLERANCE_PX = 2
      VERTEX_PREVIEW_LIMIT = 80_000

      MODE_ORDER = [:stretch, :taper].freeze
      MODE_LABEL = { stretch: '拉伸缩放', taper: '收分' }.freeze
      MODE_HINT = {
        stretch: '角点 + 面心手柄',
        taper: '只有面心手柄（沿轴收分）'
      }.freeze
      FLASH_SECONDS = 1.8

      # 工具状态：等待选择对象 / 已有变形框
      STATE_SELECT = :select
      STATE_EDIT   = :edit

      DRAW_OPEN_SQUARE     = 1
      DRAW_FILLED_SQUARE   = 2
      DRAW_FILLED_TRIANGLE = 7

      COLOR_BOX           = Sketchup::Color.new(130, 130, 130)
      COLOR_BOX_ACTIVE    = Sketchup::Color.new(255, 152, 0)
      COLOR_BOX_TAPER     = Sketchup::Color.new(150, 90, 220)
      COLOR_TAPER_GUIDE   = Sketchup::Color.new(0, 168, 122)
      COLOR_FACE_HANDLE   = Sketchup::Color.new(0, 122, 255)
      COLOR_CORNER_HANDLE = Sketchup::Color.new(255, 255, 255)
      COLOR_HOT           = Sketchup::Color.new(255, 140, 0)
      COLOR_DRAG          = Sketchup::Color.new(255, 45, 0)
      COLOR_AXIS_LOCK     = Sketchup::Color.new(0, 170, 120)
      COLOR_PREVIEW       = Sketchup::Color.new(0, 200, 255)
      COLOR_SNAP          = Sketchup::Color.new(255, 0, 170)
      # 左上角按钮：半透明橙色圆角底
      COLOR_BUTTON_BG     = Sketchup::Color.new(255, 150, 0, 150)
      COLOR_BUTTON_EDGE   = Sketchup::Color.new(200, 100, 0, 230)
      COLOR_BUTTON_TEXT   = Sketchup::Color.new(60, 30, 0, 255)

      # 左上角「切换模式」按钮：x, y, 宽, 高（逻辑像素）
      MODE_BUTTON = [16, 18, 116, 34].freeze
      BUTTON_RADIUS = 8
      BUTTON_FONT = 14
      # 按钮文字锚点（绝对值，相对按钮左上角）
      #
      # draw_text 的锚点 = 文字左上角，所以要让文字在按钮里精确居中：
      #   汉字字身近似正方形，所以 4 个字的宽度 = 4 × 字号 = 4 × 14 = 56
      #   x = (按钮宽 - 文字宽) / 2 = (116 - 56) / 2 = 30
      #   y = (按钮高 - 字号)   / 2 = (34 - 14)  / 2 = 10
      BUTTON_TEXT_OFFSET = [30, 10].freeze
      BUTTON_TEXT = '切换模式'
      # 左上角文字（模式 / 变形框 / 变形量…）起始位置，与按钮留出间隔
      HUD_TOP = 74

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
      CONSTRAIN_MASK = Tool.modifier_mask(:CONSTRAIN_MODIFIER_MASK)
      # Shift 或 Ctrl/Option 点击 = 加选
      ADD_MASK = COPY_MASK | CONSTRAIN_MASK

      def initialize
        @mode = :stretch
        @state = STATE_EDIT
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
        @preview_entity = nil
        @snap_tooltip = ''
        @snapped = false
        @snap_point = nil
        @snap_kind = ''
        @flash_text = ''
        @flash_until = nil
      end

      # ------------------------------------------------------------ 生命周期

      def activate
        model = Sketchup.active_model
        if model.nil?
          UI.messagebox('当前没有打开模型。')
          return
        end

        @drag = nil
        @hover = nil
        @message = ''
        refresh_context(model)
        if @targets.empty?
          # 先点命令、再选对象
          enter_select_state(model)
        else
          @state = STATE_EDIT
          @box = build_box
        end
        update_ui
        model.active_view.invalidate
      end

      def deactivate(view)
        cancel_drag(view) if @drag
        @preview_entity = nil
        set_vcb('', '')
        Sketchup.status_text = ''
        view.invalidate if view
      end

      def resume(view)
        model = Sketchup.active_model
        refresh_context(model)
        @drag = nil
        @hover = nil
        if @targets.empty?
          enter_select_state(model)
        else
          @state = STATE_EDIT
          @box = build_box
        end
        update_ui
        view.invalidate
      end

      # 进入"等待选择对象"状态
      def enter_select_state(model)
        @state = STATE_SELECT
        @box = nil
        @hover = nil
        @preview_entity = nil
        @message = ''
        model.selection.clear
        refresh_context(model)
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

        id = menu.add_item('拖动时吸附到几何（端点/中点/圆心）') { toggle_snap }
        menu.set_validation_proc(id) { Settings.snap? ? MF_CHECKED : MF_ENABLED }

        # 面心拉伸的两种行为（二选一）
        id = menu.add_item('面心拉伸：保持造型（只拉伸中段）') { set_middle_stretch(true) }
        menu.set_validation_proc(id) { Settings.middle_stretch? ? MF_CHECKED : MF_ENABLED }

        id = menu.add_item('面心拉伸：整体缩放（旧行为）') { set_middle_stretch(false) }
        menu.set_validation_proc(id) { Settings.middle_stretch? ? MF_ENABLED : MF_CHECKED }

        menu.add_separator
        menu.add_item('退出工具') { Sketchup.active_model.select_tool(nil) }
        true
      rescue StandardError
        true
      end

      def set_mode(mode)
        return if @mode == mode

        # 锁定状态下允许切换：先结束当前交互
        if @drag
          return unless @drag[:sticky]

          cancel_drag(Sketchup.active_model.active_view)
        end

        @mode = mode
        @hover = nil
        @flash_text = "模式：#{MODE_LABEL[mode]}（#{MODE_HINT[mode]}）"
        @flash_until = Time.now + FLASH_SECONDS
        update_ui
        Sketchup.active_model.active_view.invalidate
        schedule_redraw
      end

      # 提示淡出后重画一次
      def schedule_redraw
        view = Sketchup.active_model.active_view
        UI.start_timer(FLASH_SECONDS, false) do
          begin
            view.invalidate
          rescue StandardError
            nil
          end
        end
      rescue StandardError
        nil
      end

      def toggle_object_axes
        Settings.object_axes = !Settings.object_axes?
        @box = @targets.empty? ? nil : build_box
        Sketchup.active_model.active_view.invalidate
      end

      def toggle_explode_curves
        Settings.explode_curves = !Settings.explode_curves?
      end

      def toggle_snap
        Settings.snap = !Settings.snap?
      end

      def set_middle_stretch(value)
        Settings.middle_stretch = value
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
        elsif @state == STATE_SELECT
          entity = pick_entity(view, x, y)
          return if same_entity?(entity, @preview_entity)

          @preview_entity = entity
          view.invalidate
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

        # 左上角「切换模式」按钮
        if @state == STATE_EDIT && mode_button_hit?(x, y)
          index = MODE_ORDER.index(@mode) || 0
          set_mode(MODE_ORDER[(index + 1) % MODE_ORDER.size])
          view.invalidate
          return
        end

        model = Sketchup.active_model
        if @state == STATE_SELECT
          handle_selection_click(model, view, x, y, flags)
          return
        end

        handle = pick_handle(view, x, y)
        unless handle
          # 点空白处：回到"重新选择对象"
          enter_select_state(model)
          update_ui
          view.invalidate
          return
        end

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

      # 选择状态下的点击：选中点击到的对象，然后建立变形框
      def handle_selection_click(model, view, x, y, flags)
        add = (flags & ADD_MASK) != 0
        entity = pick_entity(view, x, y)

        if entity.nil?
          model.selection.clear unless add
          refresh_context(model)
          @message = '没点到对象，请点击组 / 组件 / 几何体'
          update_ui
          view.invalidate
          return
        end

        selected = model.selection.to_a
        if add && selected.include?(entity)
          model.selection.remove(entity)
        else
          model.selection.clear unless add
          model.selection.add(entity)
        end

        refresh_context(model)
        if @targets.empty?
          @state = STATE_SELECT
          @box = nil
          @preview_entity = entity
          @message = '继续点击可加选（Shift / Ctrl）；至少要选中一个对象'
        else
          @state = STATE_EDIT
          @box = build_box
          @preview_entity = nil
          @message = ''
        end
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
        elsif Settings.middle_stretch? && handle[:type] == :face
          # 面心拉伸：只拉伸中段，两端造型原样保留
          drag[:vertex_set] = collect_vertices
          drag[:cut] = middle_cut_position(drag[:vertex_set], handle, @box)
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
        if @preview_entity
          begin
            preview = @preview_entity.bounds
            bounds.add((0..7).map { |index| preview.corner(index) })
          rescue StandardError
            nil
          end
        end
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
        if @state == STATE_SELECT
          draw_preview(view)
          draw_hud(view)
          return
        end

        return if @box.nil?

        draw_box(view)
        draw_axis_lock(view) if @drag
        draw_input_point(view)
        draw_taper_guide(view) if @mode == :taper
        draw_handles(view)
        draw_hud(view)
      rescue StandardError
        nil
      end

      # 拖动时把拾取点画出来：既画 SketchUp 原生推理点，也画插件自己找到的特征点，
      # 不然用户看不到"吸到哪儿了"
      def draw_input_point(view)
        return unless @drag

        if @snapped && @ip.respond_to?(:draw)
          begin
            @ip.draw(view)
          rescue StandardError
            nil
          end
        end

        return if @snap_point.nil?

        view.line_stipple = ''
        view.line_width = 2
        view.drawing_color = COLOR_SNAP
        view.draw_points([@snap_point], px(9), DRAW_FILLED_SQUARE, COLOR_SNAP)
        view.draw_points([@snap_point], px(15), DRAW_OPEN_SQUARE, COLOR_SNAP)
      rescue StandardError
        nil
      end

      # 选择状态下高亮鼠标指向的对象
      def draw_preview(view)
        box = @preview_entity ? box_for(@preview_entity) : nil
        return if box.nil?

        view.line_stipple = ''
        view.line_width = 2
        view.drawing_color = COLOR_PREVIEW
        view.draw(GL_LINES, box_edges(box))
      end

      # 锁定状态下画出方向轴，让"锁轴"看得见
      def draw_axis_lock(view)
        return if @drag.nil?

        handle = @drag[:handle]
        box = @drag[:base_box]
        handle_axes(handle).each do |axis|
          draw_axis_line(view, box, axis, @drag[:anchor_point])
        end
      end

      def draw_axis_line(view, box, axis, point)
        direction = box.axes[axis]
        reach = box.sizes[axis] * 0.75 + 2.0
        first = VecMath.point_plus(point, VecMath.scale(direction, -reach))
        second = VecMath.point_plus(point, VecMath.scale(direction, reach))

        view.line_stipple = '-'
        view.line_width = 2
        view.drawing_color = COLOR_AXIS_LOCK
        view.draw(GL_LINES, [first, second])
        view.line_stipple = ''
      end

      # 手柄对应的方向轴：面心手柄 1 条，角点手柄 3 条
      def handle_axes(handle)
        return [0, 1, 2] if handle[:type] == :corner

        [handle[:axis]]
      end

      def handle_axis_label(handle)
        handle_axes(handle).map { |axis| AXIS_LABEL[axis] }.join('/')
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

      # ---- 拾取对象（选择状态）--------------------------------------------

      def same_entity?(first, second)
        return true if first.nil? && second.nil?
        return false if first.nil? || second.nil?

        first == second
      end

      # 拾取鼠标下的对象：只取"当前上下文"里的那一层（优先组/组件）
      def pick_entity(view, x, y)
        return nil unless view.respond_to?(:pick_helper)

        model = Sketchup.active_model
        active = model.active_entities
        picker = view.pick_helper
        picker.do_pick(x * dpi, y * dpi)
        count = picker.count

        count.times do |index|
          entity = element_at(picker, index)
          next unless instance?(entity)

          return entity if in_active_context?(entity, active)
        end

        count.times do |index|
          entity = element_at(picker, index)
          next if entity.nil? || instance?(entity)

          return entity if in_active_context?(entity, active)
        end

        picker.respond_to?(:best_picked) ? picker.best_picked : nil
      rescue StandardError
        nil
      end

      def element_at(picker, index)
        return nil unless picker.respond_to?(:element_at)

        picker.element_at(index)
      rescue StandardError
        nil
      end

      def in_active_context?(entity, active_entities)
        return true if entity.nil?

        entity.parent == active_entities
      rescue StandardError
        true
      end

      # 单个对象的变形框（预览用）
      def box_for(entity)
        if instance?(entity) && Settings.object_axes?
          instance_box(entity)
        else
          bounds = entity.bounds
          DeformBox.from_points([bounds.min, bounds.max])
        end
      rescue StandardError
        nil
      end

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

      # 鼠标位置 -> 世界坐标。
      #  1) 先看 SketchUp 原生推理点（端点 / 中点 / 圆心 / 交点 …）
      #  2) 再用插件自己的几何特征点吸附（组/组件的角点、中心、端点、中点、圆心）
      #  3) 都没有时按鼠标射线投影，保证拖动平滑
      def drag_point(view, x, y)
        @ip.pick(view, x * dpi, y * dpi, @ref_ip)
        @snap_tooltip = input_point_tooltip
        @snapped = snapped?

        if Settings.snap?
          if @snapped
            @snap_point = @ip.position
            @snap_kind = snap_label
            return @snap_point
          end

          found = feature_snap_point(view, x, y)
          if found
            @snap_point = found[0]
            @snap_kind = found[1]
            return @snap_point
          end
        end

        @snap_point = nil
        @snap_kind = ''

        handle = @drag[:handle]
        base = @drag[:anchor_point]
        if handle[:type] == :face
          axis_line_point(view, x, y, base, @drag[:base_box].axes[handle[:axis]]) || @ip.position
        else
          screen_plane_point(view, x, y, base) || @ip.position
        end
      end

      # ---- 自研吸附（不依赖 SketchUp 推理，保证有可见的拾取点）--------------

      # @return [Array(Geom::Point3d, String), nil]
      def feature_snap_point(view, x, y)
        candidates = candidate_features(view, x, y)
        return nil if candidates.empty?

        best = nil
        best_distance = SNAP_PX.to_f
        candidates.each do |point, kind|
          screen = view.screen_coords(point)
          next unless screen

          distance = Math.sqrt(
            (screen.x - x * dpi)**2 + (screen.y - y * dpi)**2
          )
          next if distance > best_distance

          best = [point, kind]
          best_distance = distance
        end
        best
      rescue StandardError
        nil
      end

      # 鼠标附近实体的特征点：组/组件取包围盒 8 角点 + 6 面心 + 中心，
      # 散几何取端点 / 中点 / 圆心 / 面心
      def candidate_features(view, x, y)
        return [] unless view.respond_to?(:pick_helper)

        picker = view.pick_helper
        picker.do_pick(x * dpi, y * dpi, px(SNAP_PX))
        count = picker.respond_to?(:count) ? picker.count : 0

        list = []
        count.times do |index|
          entity = element_at(picker, index)
          next if entity.nil?

          list.concat(feature_points(entity))
          break if list.size > 240 # 安全阀
        end
        list
      rescue StandardError
        []
      end

      def feature_points(entity)
        list = []
        if instance?(entity)
          bounds = entity.bounds
          (0..7).each { |index| list << [bounds.corner(index), '角点'] }
          list << [bounds.center, '中心']
          (0..5).each do |index|
            list << [face_center_of_bounds(bounds, index), '面心']
          end
        elsif entity.is_a?(Sketchup::Edge)
          head = entity.start.position
          tail = entity.end.position
          list << [head, '端点'] << [tail, '端点']
          list << [midpoint(head, tail), '中点']
          curve = entity.curve
          if curve.is_a?(Sketchup::ArcCurve) && curve.respond_to?(:center)
            list << [curve.center, '圆心']
          end
        elsif entity.is_a?(Sketchup::Face)
          entity.vertices.each { |vertex| list << [vertex.position, '端点'] }
          list << [entity.bounds.center, '面心']
        end
        list
      rescue StandardError
        list
      end

      # 包围盒的 6 个面中心
      def face_center_of_bounds(bounds, index)
        low = bounds.min
        high = bounds.max
        center = bounds.center
        case index
        when 0 then Geom::Point3d.new(low.x, center.y, center.z)
        when 1 then Geom::Point3d.new(high.x, center.y, center.z)
        when 2 then Geom::Point3d.new(center.x, low.y, center.z)
        when 3 then Geom::Point3d.new(center.x, high.y, center.z)
        when 4 then Geom::Point3d.new(center.x, center.y, low.z)
        else Geom::Point3d.new(center.x, center.y, high.z)
        end
      end

      def midpoint(first, second)
        Geom::Point3d.new(
          (first.x + second.x) * 0.5,
          (first.y + second.y) * 0.5,
          (first.z + second.z) * 0.5
        )
      end

      # 是否处在推理吸附状态
      def snapped?
        return true if @ip.vertex || @ip.edge || @ip.face

        !@snap_tooltip.to_s.strip.empty?
      end

      def input_point_tooltip
        return '' unless @ip.respond_to?(:tooltip)

        @ip.tooltip.to_s.strip
      rescue StandardError
        ''
      end

      # 吸附类型的可读名称（显示在提示里）
      def snap_label
        return '端点' if @ip.vertex
        return '边线' if @ip.edge
        return '表面' if @ip.face
        return @snap_tooltip unless @snap_tooltip.to_s.empty?

        ''
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
          if drag[:cut] && drag[:vertex_set]
            apply_middle_stretch(spec)
            return
          end

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

      # 中段拉伸：固定端那侧不动，超切分面的一侧整体平移
      def apply_middle_stretch(spec)
        drag = @drag
        handle = drag[:handle]
        box = drag[:base_box]
        axis = handle[:axis]
        anchor = 1 - handle[:side]
        delta = spec[:sizes][axis] - box.sizes[axis]
        return if delta.abs < 1.0e-9

        cut = drag[:cut]
        vertex_set = drag[:vertex_set]
        vertex_set.apply do |world|
          middle_stretch_point(box, axis, anchor, cut, delta, world)
        end
      end

      # ta = 距固定端的归一化距离；ta <= cut 的部分不动，其余整体平移 delta
      def middle_stretch_point(box, axis, anchor_side, cut, delta, point)
        t = box.normalize(point)[axis]
        ta = anchor_side.to_i.zero? ? t : (1.0 - t)
        return point if ta <= cut

        distance = anchor_side.to_i.zero? ? delta : -delta
        VecMath.point_plus(point, VecMath.scale(box.axes[axis], distance))
      end

      # 在"不切断任何特征"的位置找切分面：取相邻顶点之间最大的空档中点，
      # 并限制在 15% ~ 85% 之间，避免贴到两端
      def middle_cut_position(vertex_set, handle, box)
        return 0.5 if vertex_set.nil? || vertex_set.size.zero?

        axis = handle[:axis]
        anchor = (1 - handle[:side]).to_i
        values = vertex_set.original_positions.map do |point|
          t = box.normalize(point)[axis]
          anchor.zero? ? t : (1.0 - t)
        end
        values.sort!

        best_gap = 0.0
        best_cut = 0.5
        previous = nil
        values.each do |value|
          if previous
            gap = value - previous
            middle = (value + previous) * 0.5
            if gap > best_gap && middle >= 0.15 && middle <= 0.85
              best_gap = gap
              best_cut = middle
            end
          end
          previous = value
        end
        best_cut
      rescue StandardError
        0.5
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
          locked = "已锁定框 #{handle_axis_label(@drag[:handle])} 轴"
          Sketchup.status_text =
            "变形中（#{MODE_LABEL[@mode]}）：#{locked} —— 移动鼠标缩放，再点一下应用；" \
            '右键「精确输入…」可输入增量（正数延长 / 负数缩短）；Esc 取消。'
          set_vcb(vcb_label, vcb_value)
        elsif @state == STATE_SELECT
          Sketchup.status_text =
            '变形框收分缩放：请点击要变形的对象（组 / 组件 / 几何体）；' \
            'Shift 或 Ctrl(Windows)/Option(Mac) 点击可加选；Esc 退出。' +
            (@message.empty? ? '' : "  [#{@message}]")
          set_vcb('', '')
        else
          Sketchup.status_text =
            "变形框收分缩放（#{MODE_LABEL[@mode]}）：点一下手柄锁定方向轴 → 移动鼠标缩放 → 再点一下应用；" \
            '也可直接按住拖动；右键「精确输入…」输入增量；点左上角「切换模式」按钮切换 拉伸/收分；' \
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
        view.drawing_color = if @drag || @hover
                               COLOR_BOX_ACTIVE
                             elsif @mode == :taper
                               COLOR_BOX_TAPER
                             else
                               COLOR_BOX
                             end
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
        lines = []
        if @state == STATE_SELECT
          lines << '请点击要变形的对象（组 / 组件 / 几何体）'
          lines << 'Shift / Ctrl 点击 = 加选；Esc 退出'
        else
          draw_mode_button(view)
          lines << "模式：#{MODE_LABEL[@mode]}（#{MODE_HINT[@mode]}）"
        end
        if @drag
          lines << "已锁定：框 #{handle_axis_label(@drag[:handle])} 轴（移动鼠标缩放，再点一下应用）"
          lines << "拾取：#{@snap_kind}" unless @snap_kind.to_s.empty?
          if @drag[:cut]
            lines << format('保持造型：只拉伸中段（切分在 %.0f%% 处）', @drag[:cut] * 100)
          end
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
          point = Geom::Point3d.new(px(18), px(HUD_TOP + 17 * index), 0)
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

        # 大字提示放在 HUD 文字下面，避免互相压住
        draw_flash(view, HUD_TOP + 17 * lines.size + 16)
      end

      # 切换模式时的大字提示（1.8 秒后自动消失）
      def draw_flash(view, top)
        return if @flash_until.nil? || @flash_text.to_s.empty?
        return if Time.now > @flash_until

        point = Geom::Point3d.new(px(18), px(top + 20), 0)
        begin
          view.draw_text(point, @flash_text, { size: px(22) })
        rescue StandardError
          begin
            view.draw_text(point, @flash_text)
          rescue StandardError
            nil
          end
        end
      end

      # ---- 左上角「切换模式」按钮 ------------------------------------------

      def mode_button_rect
        x, y, width, height = MODE_BUTTON
        [x, y, x + width, y + height]
      end

      def mode_button_hit?(x, y)
        left, top, right, bottom = mode_button_rect
        x >= left && x <= right && y >= top && y <= bottom
      end

      def draw_mode_button(view)
        left, top, right, bottom = mode_button_rect
        corners = rounded_rect_points(left, top, right, bottom, BUTTON_RADIUS)

        view.line_stipple = ''
        view.line_width = 1
        begin
          view.drawing_color = COLOR_BUTTON_BG
          view.draw2d(GL_POLYGON, corners)
        rescue StandardError
          begin
            view.draw2d(GL_QUADS, corners)
          rescue StandardError
            nil
          end
        end
        begin
          view.drawing_color = COLOR_BUTTON_EDGE
          view.draw2d(GL_LINE_LOOP, corners)
        rescue StandardError
          nil
        end

        text = BUTTON_TEXT
        # 锚点 = 文字左上角，按绝对值精确居中
        label = Geom::Point3d.new(px(left + BUTTON_TEXT_OFFSET[0]),
                                  px(top + BUTTON_TEXT_OFFSET[1]), 0)
        begin
          view.draw_text(label, text,
                         { size: px(BUTTON_FONT), color: COLOR_BUTTON_TEXT })
        rescue StandardError
          begin
            view.draw_text(label, text)
          rescue StandardError
            nil
          end
        end
      rescue StandardError
        nil
      end

      # 圆角矩形轮廓点（屏幕坐标，用于 draw2d）
      def rounded_rect_points(left, top, right, bottom, radius, segments = 5)
        points = []
        arcs = [
          [right - radius, top + radius, -Math::PI / 2, 0],
          [right - radius, bottom - radius, 0, Math::PI / 2],
          [left + radius, bottom - radius, Math::PI / 2, Math::PI],
          [left + radius, top + radius, Math::PI, Math::PI * 1.5]
        ]
        arcs.each do |center_x, center_y, start_angle, end_angle|
          (0..segments).each do |index|
            angle = start_angle + (end_angle - start_angle) * index / segments
            points << Geom::Point3d.new(
              px(center_x + Math.cos(angle) * radius),
              px(center_y + Math.sin(angle) * radius),
              0
            )
          end
        end
        points
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
