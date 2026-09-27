# encoding: UTF-8
#
# 变形框收分缩放 —— 扩展加载入口（安装到 Plugins 目录的引导文件）

require 'sketchup.rb'
require 'extensions.rb'

module Ban
  module TaperScale
    EXTENSION_NAME    = '变形框收分缩放'.freeze
    EXTENSION_VERSION = '1.1.0'.freeze
    EXTENSION_ID      = 'ban_taper_scale'.freeze

    unless file_loaded?(__FILE__)
      extension = SketchupExtension.new(
        EXTENSION_NAME,
        File.join(EXTENSION_ID, 'main')
      )
      extension.description = '用一个可自由摆放的变形框对所选对象做拉伸缩放与收分（锥化），' \
                              '支持拖动实时预览、吸附到目标点以及输入精确比例/目标尺寸。'
      extension.version     = EXTENSION_VERSION
      extension.creator     = 'ban'
      extension.copyright   = "© #{Time.now.year} ban"

      Sketchup.register_extension(extension, true)
      file_loaded(__FILE__)
    end
  end
end
