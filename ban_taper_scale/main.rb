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

    # 启动工具。不需要先选中对象：启动后直接点击要变形的对象即可。
    def self.start_tool
      model = Sketchup.active_model
      if model.nil?
        UI.messagebox('当前没有打开模型。')
        return
      end
      model.select_tool(Tool.new)
    end

    unless file_loaded?(__FILE__)
      command = UI::Command.new('变形框收分缩放') { Ban::TaperScale.start_tool }
      command.tooltip = '变形框收分缩放'
      command.status_bar_text = '点这里，然后直接在模型里点击要变形的对象（组 / 组件 / 几何体）'
      # 始终可点：点了之后再选择对象
      command.set_validation_proc { MF_ENABLED }

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
