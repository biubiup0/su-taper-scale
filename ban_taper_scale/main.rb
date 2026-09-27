# encoding: UTF-8
#
# 变形框收分缩放 —— 命令与界面注册

require 'sketchup.rb'
require File.join(File.dirname(__FILE__), 'settings.rb')
require File.join(File.dirname(__FILE__), 'vec_math.rb')
require File.join(File.dirname(__FILE__), 'deform_box.rb')
require File.join(File.dirname(__FILE__), 'deform_math.rb')
require File.join(File.dirname(__FILE__), 'vertex_set.rb')
require File.join(File.dirname(__FILE__), 'tool.rb')

module Ban
  module TaperScale
    @ui_ready = false

    # 菜单 / 工具栏是否注册成功（自检用）
    def self.ui_ready?
      @ui_ready == true
    end

    # 启动工具。要求当前有选择集。
    def self.start_tool
      model = Sketchup.active_model
      if model.nil?
        UI.messagebox('当前没有打开模型。')
        return
      end
      if model.selection.empty?
        UI.messagebox('请先选中要变形的对象（组 / 组件 / 几何体），再执行本命令。')
        return
      end
      model.select_tool(Tool.new)
    end

    unless file_loaded?(__FILE__)
      command = UI::Command.new('变形框收分缩放') { Ban::TaperScale.start_tool }
      command.tooltip = '变形框收分缩放'
      command.status_bar_text = '对所选对象建立变形框：拉伸缩放 / 收分，可输入精确比例或目标尺寸'
      command.set_validation_proc do
        model = Sketchup.active_model
        model && !model.selection.empty? ? MF_ENABLED : MF_GRAYED
      end

      icon_dir = File.join(File.dirname(__FILE__), 'icons')
      small = File.join(icon_dir, 'taper_scale_24.png')
      large = File.join(icon_dir, 'taper_scale_32.png')
      command.small_icon = small if File.exist?(small)
      command.large_icon = large if File.exist?(large)

      toolbar = UI::Toolbar.new('变形框收分缩放')
      toolbar.add_item(command)
      toolbar.restore

      menu = UI.menu('Plugins')
      menu.add_item(command)

      @ui_ready = true
      file_loaded(__FILE__)
    end
  end
end
