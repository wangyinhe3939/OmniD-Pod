# Read-only bundle comparison. Do not follow versioned-framework symlinks.
require 'find'
require 'digest'

def manifest(root)
  root = File.realpath(root)
  result = {}
  Find.find(root) do |path|
    next if path == root
    stat = File.lstat(path)
    relative = path.delete_prefix(root + '/')
    value = if stat.symlink?
      File.readlink(path)
    elsif stat.file?
      Digest::SHA256.file(path).hexdigest
    end
    result[relative] = [stat.ftype, stat.mode & 0o777, value]
  end
  result
end

abort 'Provide the built bundle and copied or mounted bundle.' unless ARGV.length == 2
expected, actual = ARGV.map { |root| manifest(root) }
abort 'Bundle contents, permissions or link targets differ.' unless expected == actual
puts "完整 App 包一致：#{actual.length} 个条目，文件内容、权限和链接目标相同。"
