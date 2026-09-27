# encoding: UTF-8
#
# 静态扫描：找出本插件里"只定义、没被引用"的方法与常量。
#
# 用法：ruby tools/find_dead.rb
#
# 注意：SketchUp 会调用 Tool 的回调（activate / draw / onMouseMove …），
# 它们在仓库里没有被显式调用，属于"外部调用"，用白名单排除。

ROOT = File.expand_path('..', __dir__)
FILES = Dir[File.join(ROOT, 'ban_taper_scale.rb'),
            File.join(ROOT, 'ban_taper_scale', '**', '*.rb'),
            File.join(ROOT, 'selftest.rb')]

SOURCES = {}
FILES.each { |file| SOURCES[file] = File.read(file) }
ALL = SOURCES.values.join("\n")

# SketchUp 调用的回调 / 生命周期方法
EXTERNAL = %w[
  activate deactivate resume suspend enableVCB? getMenu draw getExtents
  onMouseMove onLButtonDown onLButtonUp onCancel onUserText onKeyDown onSetCursor
].freeze

def defined_methods(source)
  names = []
  source.scan(/^(\s*)def\s+(self\.)?([a-zA-Z_][a-zA-Z0-9_]*[?!=]?)/) do |_indent, self_dot, name|
    names << [name, self_dot ? :class_method : :instance_method]
  end
  names
end

def defined_constants(source)
  source.scan(/^\s{2,}([A-Z][A-Z0-9_]*)\s*=/).flatten
end

# 统计引用次数（定义处算 1 次）
def reference_count(name)
  base = name.sub(/[?!=]\z/, '')
  pattern =
    if name.end_with?('=')
      /(?<![a-zA-Z0-9_])#{Regexp.escape(base)}\s*=(?!=)/
    else
      /(?<![a-zA-Z0-9_])#{Regexp.escape(base)}(?![a-zA-Z0-9_])/
    end
  ALL.scan(pattern).size
end

puts '=== 未被引用的方法（排除 SketchUp 回调）==='
found = false
SOURCES.each do |file, source|
  defined_methods(source).each do |name, kind|
    next if EXTERNAL.include?(name)
    next if reference_count(name) > 1

    puts format('  %-26s %-16s %s', name, kind, File.basename(file))
    found = true
  end
end
puts '  (无)' unless found

puts
puts '=== 未被引用的常量 ==='
found = false
SOURCES.each do |file, source|
  defined_constants(source).each do |name|
    next if ALL.scan(/\b#{Regexp.escape(name)}\b/).size > 1

    puts format('  %-26s %s', name, File.basename(file))
    found = true
  end
end
puts '  (无)' unless found
