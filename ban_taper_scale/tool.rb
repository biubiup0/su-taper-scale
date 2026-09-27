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
      # 「保持造型」的切分面（拉伸区）默认放在物体中部这一段。
      MID_BAND_LO = 0.48
      MID_BAND_HI = 0.52
      # 切分面必须落在"干净空档"里：空档至少要占全长的 20%。
      # 顶点密集（连续曲面 / 带锥度的曲面）时找不到这种空档，
      # 硬切会把一排面从中间劈开造成折痕，所以此时退回整体缩放。
      MIN_CLEAN_GAP_RATIO = 0.20
      # 切分面不能贴着顶点，按空档宽度留出余量（另有 2% 上限）
      CUT_INSET_RATIO = 0.25
      MAX_CUT_INSET = 0.02
      # 判断"边是否平行于拖动轴"的容差（cos 约 2.6°）
      PARALLEL_COS = 0.999
      # SketchUp 内置指针 ID：0 = 系统默认箭头
      DEFAULT_CURSOR_ID = 0

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
      COLOR_ZONE          = Sketchup::Color.new(255, 120, 0)
      COLOR_ZONE_FILL     = Sketchup::Color.new(255, 140, 0, 48)
      COLOR_ZONE_WARN     = Sketchup::Color.new(230, 40, 40)
      # 左上角按钮：半透明橙色圆角底
      COLOR_BUTTON_BG     = Sketchup::Color.new(255, 150, 0, 150)
      COLOR_BUTTON_EDGE   = Sketchup::Color.new(200, 100, 0, 230)
      COLOR_BUTTON_TEXT   = Sketchup::Color.new(60, 30, 0, 255)
      # 收分模式下的按钮（紫色，和变形框同色，避免误以为还在拉伸缩放）
      COLOR_BUTTON_BG_TAPER   = Sketchup::Color.new(150, 90, 220, 150)
      COLOR_BUTTON_EDGE_TAPER = Sketchup::Color.new(100, 50, 170, 230)
      MODE_BADGE_STRETCH = Sketchup::Color.new(200, 110, 0, 255)
      MODE_BADGE_TAPER   = Sketchup::Color.new(120, 60, 200, 255)
      MODE_BADGE_FONT    = 15

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
        @zone_axis_hint = nil
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

        reset_cursor
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
        # 启动时提示当前模式（避免不知道现在处于哪种模式）
        @flash_text = "模式：#{MODE_LABEL[@mode]}（#{MODE_HINT[@mode]}）"
        @flash_until = Time.now + FLASH_SECONDS
        update_ui
        model.active_view.invalidate
        schedule_redraw
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
        # 中键旋转（Orbit）会把工具 suspend 掉，回来时 SketchUp 有时把"旋转"
        # 的指针留在原地，这里显式设回默认箭头。
        reset_cursor
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

      # 显式把鼠标指针设回默认箭头（0 = 内置箭头指针）
      def reset_cursor
        UI.set_cursor(DEFAULT_CURSOR_ID)
      rescue StandardError
        false
      end

      # SketchUp 询问"这个工具用什么指针"时调用：设回箭头并告诉它不用再改，
      # 否则旋转视图后指针会一直停在"旋转"图标上。
      def onSetCursor
        reset_cursor ? true : false
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

        id = menu.add_item('面心拉伸：拉伸区域设置…（1~2 个区域）') { edit_stretch_zones }
        menu.set_validation_proc(id) { Settings.stretch_zones.empty? ? MF_ENABLED : MF_CHECKED }

        id = menu.add_item('面心拉伸：拉伸区域＝自动（物体中部）') { set_stretch_zones('', false) }
        menu.set_validation_proc(id) { Settings.stretch_zones.empty? ? MF_CHECKED : MF_ENABLED }

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

      # 右键「拉伸区域设置…」：填 1~2 个区间，留空 = 自动取物体中部
      def edit_stretch_zones
        current = Settings.stretch_zones
        defaults = [
          current[0] ? Settings.format_zones([current[0]]) : '',
          current[1] ? Settings.format_zones([current[1]]) : ''
        ]
        captures = [
          '拉伸区 1（%，留空＝自动取物体中部，例如 30-40）',
          '拉伸区 2（%，可留空；与区域 1 互不相连，例如 60-70）'
        ]
        results = UI.inputbox(captures, defaults,
                              '拉伸区域设置（0% = 变形框起点，100% = 另一端）')
        return if results.nil? || results == false

        text = results.map { |value| value.to_s.strip }.reject(&:empty?).join(',')
        if text.empty?
          Settings.stretch_zones_text = ''
        else
          zones = Settings.parse_zones(text)
          if zones.nil?
            UI.messagebox("拉伸区填得不对：#{text}\n\n" \
                          "写法：30-40 或 30%~40%；两个区用逗号隔开，例如 30-40,60-70\n" \
                          '取值范围 0%~100%，最多 2 个区间。')
          else
            Settings.stretch_zones_text = Settings.format_zones(zones)
            # 设了拉伸区就是想"保持造型"，顺手把模式切回来，免得用户纳闷为什么没反应
            Settings.middle_stretch = true
          end
        end
        update_ui
        Sketchup.active_model.active_view.invalidate
      rescue StandardError => error
        UI.messagebox("拉伸区域设置失败：#{error.message}")
      end

      # 直接写入区间文本（空字符串 = 自动）；notify 为 true 时弹一句确认
      def set_stretch_zones(text, notify = true)
        Settings.stretch_zones_text = text
        update_ui
        Sketchup.active_model.active_view.invalidate
        UI.messagebox('拉伸区已设为：自动（物体中部）') if notify
      rescue StandardError
        nil
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
          @zone_axis_hint = handle[:axis] if handle && handle[:type] == :face
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
        @zone_axis_hint = handle[:axis] if handle[:type] == :face
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
          zones = Settings.stretch_zones
          if zones.empty?
            drag[:cut] = middle_cut_position(drag[:vertex_set], handle, @box)
          else
            drag[:zones] = zones
            # 平直与否在这里算一次，绘制时直接用（免得每帧扫全模型的边）
            edges = drag[:vertex_set].original_edges
            drag[:zones_clean] = zones.map do |low, high|
              zone_straight?(@box, handle[:axis], low, high, edges)
            end
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
        draw_mode_badge(view)
        draw_axis_lock(view) if @drag
        draw_cut_plane(view)
        draw_zones(view)
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

      # 画出"拉伸区"：跨切分面的那一圈框线。
      # 这一段就是被拉长（或被压短）的地方，别的部分整体平移。
      def draw_cut_plane(view)
        return if @drag.nil?

        cut = @drag[:cut]
        return if cut.nil?

        handle = @drag[:handle]
        box = @drag[:base_box]
        axis = handle[:axis]
        anchor = (1 - handle[:side]).to_i
        fraction = anchor.zero? ? cut : (1.0 - cut)
        others = (0...3).reject { |index| index == axis }
        corners = [[0, 0], [0, 1], [1, 1], [1, 0]].map do |first, second|
          fractions = [0.0, 0.0, 0.0]
          fractions[axis] = fraction
          fractions[others[0]] = first.to_f
          fractions[others[1]] = second.to_f
          box_fraction_point(box, fractions)
        end

        view.line_stipple = '-'
        view.line_width = 2
        view.drawing_color = COLOR_HOT
        view.draw(GL_LINE_LOOP, corners)
        view.line_stipple = ''
      rescue StandardError
        nil
      end

      def box_fraction_point(box, fractions)
        point = box.origin
        3.times do |index|
          point = VecMath.point_plus(
            point, VecMath.scale(box.axes[index], box.sizes[index] * fractions[index])
          )
        end
        point
      end

      # 画出用户设置的拉伸区：半透明橙色带 + 边框 + 编号文字。
      # 拖动中按当前拖动的轴画；没拖动时鼠标指到哪个面心手柄，就按那条轴画。
      def draw_zones(view)
        zones = active_zones
        return if zones.empty?

        box = @drag ? @drag[:base_box] : @box
        axis = active_zone_axis
        return if box.nil? || axis.nil?

        zones.each_with_index do |(low, high), index|
          draw_zone(view, box, axis, low, high, index + 1, zone_clean?(zones, index))
        end
      rescue StandardError
        nil
      end

      # 这个拉伸区的两条边界是不是落在"平直"的位置（不压斜面 / 锥面）
      def zone_clean?(zones, index)
        if @drag && @drag[:zones_clean]
          return @drag[:zones_clean][index] != false
        end

        edges = @drag && @drag[:vertex_set] ? @drag[:vertex_set].original_edges : nil
        box = @drag ? @drag[:base_box] : @box
        axis = active_zone_axis
        return true if box.nil? || axis.nil?

        zone_straight?(box, axis, zones[index][0], zones[index][1], edges)
      end

      def active_zones
        return @drag[:zones] if @drag && @drag[:zones]
        return [] unless @state == STATE_EDIT && Settings.middle_stretch?

        Settings.stretch_zones
      end

      def active_zone_axis
        handle = @drag ? @drag[:handle] : @hover
        return handle[:axis] if handle && handle[:type] == :face

        # 没拖动也没指着手柄时：用上次用过的轴，或者变形框最长的那条轴
        @zone_axis_hint || longest_axis
      end

      def longest_axis
        return nil if @box.nil?

        (0...3).max_by { |axis| @box.sizes[axis] }
      end

      def draw_zone(view, box, axis, low, high, index, clean)
        others = (0...3).reject { |position| position == axis }
        corner_at = lambda do |fraction|
          [[0, 0], [0, 1], [1, 1], [1, 0]].map do |first, second|
            fractions = [0.0, 0.0, 0.0]
            fractions[axis] = fraction
            fractions[others[0]] = first.to_f
            fractions[others[1]] = second.to_f
            box_fraction_point(box, fractions)
          end
        end
        near_side = corner_at.call(low)
        far_side = corner_at.call(high)

        quads = []
        4.times do |position|
          following = (position + 1) % 4
          quads << near_side[position] << near_side[following]
          quads << far_side[following] << far_side[position]
        end
        view.drawing_color = COLOR_ZONE_FILL
        view.draw(GL_QUADS, quads)
        view.draw(GL_QUADS, near_side + far_side)

        color = clean ? COLOR_ZONE : COLOR_ZONE_WARN
        view.line_stipple = ''
        view.line_width = 2
        view.drawing_color = color
        view.draw(GL_LINE_LOOP, near_side)
        view.draw(GL_LINE_LOOP, far_side)
        view.draw(GL_LINES, (0...4).flat_map { |position| [near_side[position], far_side[position]] })

        draw_zone_label(view, near_side, far_side, index, low, high, color)
      rescue StandardError
        nil
      end

      def draw_zone_label(view, near_side, far_side, index, low, high, color)
        anchor = (near_side + far_side).compact.min_by { |point| point.y }
        screen = view.screen_coords(anchor)
        return if screen.nil?

        text = format('拉伸区%d %.0f%%~%.0f%%', index, low * 100, high * 100)
        label = Geom::Point3d.new(screen.x + px(6), screen.y - px(8), 0)
        begin
          view.draw_text(label, text, { size: px(13), color: color })
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

      # 拉伸区的两条边界是不是"平直"的（跨过边界的边都平行于拖动轴）
      def zone_straight?(box, axis, low, high, edges)
        return true if edges.nil? || edges.empty?

        [low, high].all? do |fraction|
          edges.all? do |from, to|
            before = box.normalize(from)[axis] - fraction
            after = box.normalize(to)[axis] - fraction
            next true unless before * after < 0

            axis_parallel?(from, to, box, axis)
          end
        end
      rescue StandardError
        true
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
          if drag[:zones] && drag[:vertex_set]
            apply_zone_stretch(spec)
            return
          end
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

      # 自定义拉伸区（1~2 个互不相连的区间）：
      # 总伸长量按区间宽度分配，区间内部沿轴线性拉伸，区间之间和区间之外刚性平移。
      # 于是只有你设置的这一段被拉长 / 压短，别处的造型一点不动。
      def apply_zone_stretch(spec)
        drag = @drag
        handle = drag[:handle]
        box = drag[:base_box]
        axis = handle[:axis]
        anchor = (1 - handle[:side]).to_i
        delta = spec[:sizes][axis] - box.sizes[axis]
        return if delta.abs < 1.0e-9

        zones = drag[:zones].map { |low, high| zone_in_anchor_space(low, high, anchor) }
        total = zones.inject(0.0) { |sum, (low, high)| sum + (high - low) }
        return if total <= 0.0

        direction = anchor.zero? ? 1.0 : -1.0
        drag[:vertex_set].apply do |world|
          t = box.normalize(world)[axis]
          ta = anchor.zero? ? t : (1.0 - t)
          travelled = zone_travel(ta, zones)
          shift = delta * travelled / total
          next world if shift.abs < 1.0e-9

          VecMath.point_plus(world, VecMath.scale(box.axes[axis], direction * shift))
        end
      end

      # 顶点在拉伸区里"走"了多远（0 = 一点没动，区间宽度之和 = 整体平移到位）
      def zone_travel(t, zones)
        travelled = 0.0
        zones.each do |low, high|
          width = high - low
          next if width <= 0.0

          inside = (t - low) / width
          inside = 0.0 if inside < 0.0
          inside = 1.0 if inside > 1.0
          travelled += inside * width
        end
        travelled
      end

      # 用户填的区间是"从变形框起点量"的；这里换算成"从固定端量"（与拖动方向无关）
      def zone_in_anchor_space(low, high, anchor)
        anchor.to_i.zero? ? [low, high] : [1.0 - high, 1.0 - low]
      end

      # ta = 距固定端的归一化距离；ta <= cut 的部分不动，其余整体平移 delta
      def middle_stretch_point(box, axis, anchor_side, cut, delta, point)
        t = box.normalize(point)[axis]
        ta = anchor_side.to_i.zero? ? t : (1.0 - t)
        return point if ta <= cut

        distance = anchor_side.to_i.zero? ? delta : -delta
        VecMath.point_plus(point, VecMath.scale(box.axes[axis], distance))
      end

      # 找"保持造型"的切分面（也就是拉伸区）。
      #
      # 切分面必须同时满足两个条件，形状才不会被拉坏：
      #   1. 落在够宽的空档里（相邻顶点层之间，宽度 ≥ 全长的 20%），
      #      这样不会把一排面从中间劈开；
      #   2. 跨过切分面的每一条边都平行于拖动轴——这时跨切分面的面都是
      #      "顺着轴"的侧面，拉长它们等于把物体加长；斜角、凹槽、锥面
      #      这些造型不跨切分面，于是原样保留。
      # 位置优先取物体中部的 48%~52%，做不到时取离中部最近的有效位置。
      # 找不到有效位置时返回 nil，调用方退回整体缩放。
      def middle_cut_position(vertex_set, handle, box)
        return nil if vertex_set.nil? || vertex_set.size.zero?

        axis = handle[:axis]
        anchor = (1 - handle[:side]).to_i
        values = vertex_set.original_positions.map do |point|
          t = box.normalize(point)[axis]
          anchor.zero? ? t : (1.0 - t)
        end
        values.sort!

        extent = values.last - values.first
        return nil if extent <= 1.0e-6

        spans = []
        previous = nil
        values.each do |value|
          spans << [previous, value] if previous && (value - previous) >= extent * MIN_CLEAN_GAP_RATIO
          previous = value
        end
        return nil if spans.empty?

        # ta 是从"固定端"量的：ta 越接近 0.5 就越接近物体中部
        edges = vertex_set.original_edges
        candidates = spans.map { |from, to| preferred_cut(from, to) }
        candidates.sort_by! { |cut| [(cut - 0.5).abs, cut] }
        candidates.each do |cut|
          return cut if straight_cut?(cut, axis, anchor, box, edges)
        end
        nil
      rescue StandardError
        nil
      end

      # 在空档 [from, to] 内取最贴近物体中部 48%~52% 的切分面
      def preferred_cut(from, to)
        width = to - from
        inset = [width * CUT_INSET_RATIO, MAX_CUT_INSET].min
        low = from + inset
        high = to - inset
        return (low + high) * 0.5 if high <= low

        target_low = [low, MID_BAND_LO].max
        target_high = [high, MID_BAND_HI].min
        return (target_low + target_high) * 0.5 if target_low <= target_high

        # 中部落在空档之外时，取空档里离中部最近的位置
        [[0.5, low].max, high].min
      end

      # 切分面是否"平直"：跨过它的边都必须平行于拖动轴
      def straight_cut?(cut, axis, anchor, box, edges)
        plane = anchor.zero? ? cut : (1.0 - cut)
        edges.all? do |from, to|
          before = box.normalize(from)[axis] - plane
          after = box.normalize(to)[axis] - plane
          next true unless before * after < 0

          axis_parallel?(from, to, box, axis)
        end
      end

      def axis_parallel?(from, to, box, axis)
        direction = VecMath.point_minus(to, from)
        length = VecMath.length(direction)
        return true if length <= 1.0e-9

        VecMath.dot(direction, box.axes[axis]).abs >= length * PARALLEL_COS
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

      # [[0.3, 0.4], [0.6, 0.7]] -> "30%~40% + 60%~70%"
      def zone_label(zones)
        zones.map { |low, high| format('%.0f%%~%.0f%%', low * 100, high * 100) }.join(' + ')
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

      # 在变形框最高角的上方写出当前模式名（橙=拉伸缩放，紫=收分），
      # 避免用户误以为在做另一种变形
      def draw_mode_badge(view)
        return if @box.nil?

        top = @box.corners.map { |point| view.screen_coords(point) }.compact.min_by { |point| point.y }
        return if top.nil?

        text = MODE_LABEL[@mode]
        color = @mode == :taper ? MODE_BADGE_TAPER : MODE_BADGE_STRETCH
        half = px(4 * MODE_BADGE_FONT / 2)
        label = Geom::Point3d.new(top.x - half, top.y - px(MODE_BADGE_FONT + 6), 0)
        begin
          view.draw_text(label, text, { size: px(MODE_BADGE_FONT), color: color })
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
          if @drag[:zones]
            lines << "保持造型：拉伸区 #{zone_label(@drag[:zones])}（其他部分整体平移）"
          elsif @drag[:cut]
            lines << format('保持造型：只拉伸中段（切分在 %.0f%% 处）', @drag[:cut] * 100)
          elsif Settings.middle_stretch? && @drag[:vertex_set]
            lines << '保持造型：中部没有平直的切分位置，本次按整体缩放'
          end
        elsif @state == STATE_EDIT && Settings.middle_stretch? && !Settings.stretch_zones.empty?
          lines << "拉伸区（面心拉伸）：#{zone_label(Settings.stretch_zones)}"
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
          view.drawing_color = @mode == :taper ? COLOR_BUTTON_BG_TAPER : COLOR_BUTTON_BG
          view.draw2d(GL_POLYGON, corners)
        rescue StandardError
          begin
            view.draw2d(GL_QUADS, corners)
          rescue StandardError
            nil
          end
        end
        begin
          view.drawing_color = @mode == :taper ? COLOR_BUTTON_EDGE_TAPER : COLOR_BUTTON_EDGE
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
