# encoding: UTF-8
#
# 变形框收分缩放 —— 扩展加载入口（安装到 Plugins 目录的引导文件）

require 'sketchup.rb'
require 'extensions.rb'

module Ban
  module TaperScale
    EXTENSION_NAME    = '变形框收分缩放'.freeze
    EXTENSION_VERSION = '1.4.1'.freeze
    EXTENSION_ID      = 'ban_taper_scale'.freeze

    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new(
        EXTENSION_NAME,
        File.join(EXTENSION_ID, 'main')
      )
      extension.description = '点命令后直接在模型里点击要变形的对象：用一个可自由摆放的变形框做拉伸缩放与收分（锥化），' \
                              '支持锁定方向轴、吸附到角点/中心/端点、以及精确增量输入。'
      extension.version     = EXTENSION_VERSION
      extension.creator     = 'ban'
      extension.copyright   = "© #{Time.now.year} ban"

      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
