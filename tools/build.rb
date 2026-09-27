# encoding: UTF-8
#
# 生成工具栏图标并打包成 ban_taper_scale.rbz
#
# 用法：ruby tools/build.rb

require 'fileutils'
require 'zlib'

ROOT = File.expand_path('..', __dir__)
ICON_DIR = File.join(ROOT, 'ban_taper_scale', 'icons')
RBZ = File.join(ROOT, 'ban_taper_scale.rbz')

# ---- 图标（纯 Ruby 写 PNG，不依赖任何库）--------------------------------

def png_chunk(type, data)
  [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N')
end

def write_png(path, size, pixels)
  raw = +''
  pixels.each do |row|
    raw << 0.chr
    row.each { |pixel| raw << pixel.pack('C4') }
  end

  png = +"\x89PNG\r\n\x1a\n".b
  png << png_chunk('IHDR', [size, size, 8, 6, 0, 0, 0].pack('N2C5'))
  png << png_chunk('IDAT', Zlib::Deflate.deflate(raw))
  png << png_chunk('IEND', '')
  File.binwrite(path, png)
end

FILL   = [30, 122, 210, 255]
EDGE   = [12, 70, 130, 255]
ACCENT = [255, 145, 0, 255]
CLEAR  = [0, 0, 0, 0]

# 收分造型：底部宽、顶部窄的棱台，顶端一条高亮线

def trapezoid_icon(size)
  pixels = Array.new(size) { Array.new(size) { CLEAR.dup } }

  margin = size * 0.10
  top_y = margin + size * 0.06
  bottom_y = size - margin - size * 0.06
  center = (size - 1) / 2.0
  top_half = size * 0.17
  bottom_half = size * 0.34

  (0...size).each do |y|
    next if y < top_y || y > bottom_y

    ratio = (y - top_y) / (bottom_y - top_y)
    half = top_half + (bottom_half - top_half) * ratio
    left = (center - half).round
    right = (center + half).round

    (left..right).each do |x|
      next if x.negative? || x >= size

      border = x <= left || x >= right
      pixels[y][x] = border ? EDGE.dup : FILL.dup
    end
  end

  top_row = top_y.round
  [top_row, top_row + 1].each do |y|
    next if y.negative? || y >= size

    left = (center - top_half - size * 0.10).round
    right = (center + top_half + size * 0.10).round
    (left..right).each do |x|
      next if x.negative? || x >= size

      pixels[y][x] = ACCENT.dup
    end
  end

  pixels
end

def make_icons
  FileUtils.mkdir_p(ICON_DIR)
  [24, 32].each do |size|
    path = File.join(ICON_DIR, "taper_scale_#{size}.png")
    write_png(path, size, trapezoid_icon(size))
    puts "生成 #{path} (#{File.size(path)} 字节)"
  end
end

# ---- 打包 ----------------------------------------------------------------

def build_rbz
  File.delete(RBZ) if File.exist?(RBZ)
  Dir.chdir(ROOT) do
    ok = system('zip', '-r', '-X', RBZ, 'ban_taper_scale.rb', 'ban_taper_scale',
                '-x', '*.DS_Store')
    unless ok
      warn '打包失败：需要系统 zip 命令（macOS / Linux 自带；Windows 可用 PowerShell 的 Compress-Archive）'
      return false
    end
  end
  puts "打包完成 #{RBZ} (#{File.size(RBZ)} 字节)"
  true
end

make_icons
build_rbz
