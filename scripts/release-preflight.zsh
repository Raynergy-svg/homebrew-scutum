#!/bin/zsh
set -euo pipefail

formula_path="${1:-}"

if [[ -z "$formula_path" ]]; then
  script_dir="$(cd "$(dirname "${(%):-%N}")" && pwd)"
  formula_path="$script_dir/../Formula/irondome-sentinel.rb"
fi

if [[ ! -f "$formula_path" ]]; then
  print -u2 -- "ERROR: formula not found: $formula_path"
  exit 2
fi

repo_root="$(cd "$(dirname "$formula_path")/.." && pwd)"

url="$(ruby -e 'p=ARGV[0]; s=File.read(p); m=s.match(/\burl\s+"([^"]+)"/); abort("no url") unless m; puts m[1]' "$formula_path")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

src_tgz="$work/src.tgz"
src_dir="$work/src"
mkdir -p "$src_dir"

print -- "Downloading: $url"
/usr/bin/curl -fsSL "$url" -o "$src_tgz"

tar -xzf "$src_tgz" -C "$src_dir"

src_root="$(/usr/bin/find "$src_dir" -mindepth 1 -maxdepth 1 -type d | /usr/bin/head -n 1)"
if [[ -z "$src_root" || ! -d "$src_root" ]]; then
  print -u2 -- "ERROR: could not locate extracted source root"
  exit 2
fi

# Extract normalized targets from formula AST.
# Output lines:
#   T|<target>                 (inreplace first arg)
#   M|<src>|<dst>              (mv src,dst)
parsed_lines="$(ruby - "$formula_path" <<'RUBY'
require 'ripper'

path = ARGV[0]
src = File.read(path)
sexp = Ripper.sexp(src)

def string_from_string_literal(node, env)
  return nil unless node.is_a?(Array) && node[0] == :string_literal
  content = node[1]
  return "" if content.is_a?(Array) && content[0] == :string_content && content.length == 1
  return nil unless content.is_a?(Array) && content[0] == :string_content

  out = ""
  (content[1..] || []).each do |p|
    next unless p.is_a?(Array)
    case p[0]
    when :@tstring_content
      out << p[1].to_s
    when :string_embexpr
      # Typical shape: [:string_embexpr, [[:var_ref, [:@ident, "x", ..]]]]
      inner = p[1]
      inner = inner[0] if inner.is_a?(Array) && inner.length == 1
      v = eval_stringish(inner, env)
      return nil if v.nil?
      out << v
    else
      return nil
    end
  end
  out
end

def array_elems(node)
  return [] unless node.is_a?(Array) && node[0] == :array
  inner = node[1]
  return [] if inner.nil?
  return inner[0] if inner.is_a?(Array) && inner.length == 1 && inner[0].is_a?(Array)
  inner.is_a?(Array) ? inner : []
end

def eval_stringish(node, env)
  return nil unless node.is_a?(Array)
  case node[0]
  when :string_literal
    string_from_string_literal(node, env)
  when :var_ref
    ident = node[1]
    return nil unless ident.is_a?(Array) && ident[0] == :@ident
    env[ident[1].to_s]
  when :@tstring_content
    node[1].to_s
  when :method_add_arg
    # Support: ["a","b"].join(".")
    call = node[1]
    args = node[2]
    if call.is_a?(Array) && call[0] == :call
      recv = call[1]
      meth = call[3]
      if recv.is_a?(Array) && recv[0] == :array && meth.is_a?(Array) && meth[0] == :@ident && meth[1] == 'join'
        join_arg = nil
        if args.is_a?(Array) && args[0] == :arg_paren
          add_block = args[1]
          if add_block.is_a?(Array) && add_block[0] == :args_add_block
            first = add_block[1]&.first
            join_arg = eval_stringish(first, env)
          end
        end
        join_arg ||= ""
        parts = array_elems(recv).map { |e| eval_stringish(e, env) }.compact
        return parts.join(join_arg)
      end
    end
    nil
  else
    nil
  end
end

def eval_path_expr(node, env)
  return nil unless node.is_a?(Array)

  # Unwrap parens.
  if node[0] == :paren
    inner = node[1]
    return nil unless inner.is_a?(Array)
    inner = inner[0] if inner.length == 1
    return eval_path_expr(inner, env)
  end

  case node[0]
  when :binary
    lhs = node[1]
    op = node[2]
    rhs = node[3]
    return nil unless op == :/
    base = nil
    if lhs.is_a?(Array) && lhs[0] == :vcall
      ident = lhs[1]
      if ident.is_a?(Array) && ident[0] == :@ident
        base = ident[1].to_s
      end
    elsif lhs.is_a?(Array) && lhs[0] == :var_ref
      ident = lhs[1]
      if ident.is_a?(Array) && ident[0] == :@ident
        base = env[ident[1].to_s]
      end
    end
    s = eval_stringish(rhs, env)
    return nil if base.nil? || s.nil?
    return "#{base}/#{s}"
  when :string_literal
    eval_stringish(node, env)
  when :var_ref
    eval_stringish(node, env)
  else
    nil
  end
end

env = {}
inreplace = []
proven = {}
moves = []

walk = lambda do |n|
  return unless n.is_a?(Array)

  # Capture simple assignments to help resolve later inreplace targets.
  if n[0] == :assign
    lhs = n[1]
    rhs = n[2]
    if lhs.is_a?(Array) && lhs[0] == :var_field
      ident = lhs[1]
      if ident.is_a?(Array) && ident[0] == :@ident
        name = ident[1].to_s
        val = eval_stringish(rhs, env) || eval_path_expr(rhs, env)
        env[name] = val if val.is_a?(String) && !val.empty?
      end
    end
  end

  # Proof rules: targets created by formula.
  if n[0] == :command_call
    recv = n[1]
    meth = n[3]
    args = n[4]
    meth_name = (meth.is_a?(Array) && meth[0] == :@ident) ? meth[1].to_s : ""

    if meth_name == 'write'
      p = eval_path_expr(recv, env)
      proven[p] = true if p.is_a?(String) && !p.empty?
    elsif meth_name == 'install'
      base = nil
      if recv.is_a?(Array) && recv[0] == :vcall
        ident = recv[1]
        base = ident[1].to_s if ident.is_a?(Array) && ident[0] == :@ident
      end
      if base
        first = nil
        if args.is_a?(Array) && args[0] == :args_add_block
          first = args[1]&.first
        end
        name = eval_stringish(first, env)
        if name && !name.empty?
          proven["#{base}/#{name}"] = true
        end
      end
    end
  end

  # inreplace targets.
  if n[0] == :command
    ident = n[1]
    if ident.is_a?(Array) && ident[0] == :@ident
      name = ident[1]
      args_add_block = n[2]
      if args_add_block.is_a?(Array) && args_add_block[0] == :args_add_block
        args = args_add_block[1]
        if args.is_a?(Array) && !args.empty?
          if name == 'inreplace'
            t = eval_path_expr(args[0], env)
            inreplace << t if t && !t.empty?
          elsif name == 'mv' && args.length >= 2
            src = eval_path_expr(args[0], env)
            dst = eval_path_expr(args[1], env)
            if src && !src.empty? && dst && !dst.empty?
              moves << [src, dst]
            end
          end
        end
      end
    end
  end

  n.each { |child| walk.call(child) if child.is_a?(Array) }
end

walk.call(sexp)

filtered = inreplace.compact.uniq.reject { |t| proven[t] }

moves.uniq.each do |src, dst|
  puts "M|#{src}|#{dst}"
end
filtered.sort.each do |t|
  puts "T|#{t}"
end
RUBY
)"

resolve_tarball_path() {
  local target="$1"
  local tarball_path="$target"

  case "$target" in
    pkgshare/*|opt_pkgshare/*)
      tarball_path="${target#*/}"
      ;;
    libexec/*)
      tarball_path="${target#libexec/}"
      ;;
    prefix/*)
      tarball_path="${target#prefix/}"
      ;;
  esac

  print -- "$tarball_path"
}

typeset -A move_dsts
missing=0

# First enforce move preconditions: either src or dst must exist in the tarball.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  if [[ "$line" == M\|* ]]; then
    src="${line#M|}"
    dst="${src#*|}"
    src="${src%%|*}"
    src="${src//$'\r'/}"
    dst="${dst//$'\r'/}"
    move_dsts[$dst]=1

    src_tb="$(resolve_tarball_path "$src")"
    dst_tb="$(resolve_tarball_path "$dst")"
    if [[ ! -e "$src_root/$src_tb" && ! -e "$src_root/$dst_tb" ]]; then
      print -u2 -- "Missing in tarball: $src_tb (or $dst_tb) required for mv $src -> $dst"
      missing=1
    fi
  fi
done <<< "$parsed_lines"

# Then validate inreplace targets (skipping mv-created dst paths).
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  if [[ "$line" == T\|* ]]; then
    target="${line#T|}"
    target="${target//$'\r'/}"
    [[ -z "$target" ]] && continue
    if [[ -n "${move_dsts[$target]-}" ]]; then
      continue
    fi

    tarball_path="$(resolve_tarball_path "$target")"
    if [[ ! -e "$src_root/$tarball_path" ]]; then
      print -u2 -- "Missing in tarball: $tarball_path (from inreplace target: $target)"
      missing=1
    fi
  fi
done <<< "$parsed_lines"

if (( missing )); then
  exit 1
fi

# Sanity: ensure the tap itself doesn't contain the old label (guardrail).
# Exclude this preflight script (it necessarily references the old label in the check).
if /usr/bin/grep -R --line-number --fixed-string 'com.irondome.sentinel' \
  --exclude='release-preflight.zsh' --exclude-dir='.git' \
  "$repo_root" >/dev/null 2>&1; then
  print -u2 -- "ERROR: old label 'com.irondome.sentinel' still present in tap repo (update to canonical label)."
  exit 1
fi

print -- "OK: inreplace targets exist in tarball"
