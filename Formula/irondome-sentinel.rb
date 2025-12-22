class IrondomeSentinel < Formula
  desc "macOS LaunchAgent + local defensive pipeline"
  homepage "https://github.com/Raynergy-svg/Scutum"
  url "https://github.com/Raynergy-svg/Scutum/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "7a136c28ebd8ee40f5015b17c23483e3d69a3a7cfc72de727edd39119be5be3d"
  license "MIT"
  revision 5

  depends_on "python"

  def install
    libexec.install Dir["*"]

    python3 = Formula["python"].opt_bin/"python3"

    (bin/"irondome-sentinel").write <<~EOS
      #!/bin/bash
      export PYTHONUNBUFFERED=1
      exec "#{python3}" "#{pkgshare}/scripts/irondome-sentinel.py" "$@"
    EOS

    chmod 0755, bin/"irondome-sentinel"

    (bin/"irondome-sentinel-setup").write <<~EOS
      #!/bin/bash
      set -euo pipefail

      PKGSHARE="#{opt_pkgshare}"
      PYTHON3="#{python3}"

      usage() {
        /usr/bin/printf '%s\n' "irondome-sentinel-setup"
        /usr/bin/printf '%s\n' ""
        /usr/bin/printf '%s\n' "Interactive post-install setup:"
        /usr/bin/printf '%s\n' "- Prompts for SENTINEL_TO, SENTINEL_ALLOWED_HANDLES, IRONDOME_INTERVAL_SECONDS"
        /usr/bin/printf '%s\n' "- Updates ~/Library/LaunchAgents/com.irondome.sentinel.plist EnvironmentVariables"
        /usr/bin/printf '%s\n' "- Updates ~/Library/Application Support/IronDome/config.json (router_model)"
        /usr/bin/printf '%s\n' "- Reloads the LaunchAgent"
        /usr/bin/printf '%s\n' ""
        /usr/bin/printf '%s\n' "Usage:"
        /usr/bin/printf '%s\n' "  irondome-sentinel-setup"
        /usr/bin/printf '%s\n' "  irondome-sentinel-setup --help"
      }

      if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        exit 0
      fi

      pb_quote() {
        local s="${1-}"
        s="${s//\\/\\\\}"
        s="${s//\"/\\\"}"
        printf '"%s"' "$s"
      }

      pb_exists() {
        /usr/libexec/PlistBuddy -c "Print $2" "$1" >/dev/null 2>&1
      }

      pb_get() {
        /usr/libexec/PlistBuddy -c "Print $2" "$1" 2>/dev/null | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
      }

      pb_ensure_dict() {
        if ! pb_exists "$1" "$2"; then
          /usr/libexec/PlistBuddy -c "Add $2 dict" "$1" >/dev/null
        fi
      }

      pb_set_string() {
        local plist="$1" path="$2" value="${3-}"
        local q
        q="$(pb_quote "$value")"
        if pb_exists "$plist" "$path"; then
          /usr/libexec/PlistBuddy -c "Set $path $q" "$plist" >/dev/null
        else
          /usr/libexec/PlistBuddy -c "Add $path string $q" "$plist" >/dev/null
        fi
      }

      prompt_default() {
        local label="$1" default="${2-}" input=""
        if [[ -n "$default" ]]; then
          IFS= read -r -p "$label [$default]: " input || true
          input="${input:-$default}"
        else
          IFS= read -r -p "$label: " input || true
        fi
        printf '%s' "$input"
      }

      prompt_int_default() {
        local label="$1" default="$2" input=""
        while true; do
          input="$(prompt_default "$label" "$default")"
          input="$(printf '%s' "$input" | /usr/bin/tr -d '[:space:]')"
          if [[ "$input" =~ ^[0-9]+$ ]] && (( input > 0 )); then
            printf '%s' "$input"
            return 0
          fi
          /usr/bin/printf '%s\n' "Please enter a positive integer." >&2
        done
      }

      /usr/bin/printf '%s\n' "== IronDome Sentinel setup =="
      /usr/bin/printf '%s\n' "(This will install/reload the LaunchAgent, then prompt for your preferences.)"
      /usr/bin/printf '\n'

      /bin/zsh "$PKGSHARE/scripts/irondome-sentinel-install-launchagent.zsh" >/dev/null

      plist="$HOME/Library/LaunchAgents/com.irondome.sentinel.plist"
      if [[ ! -f "$plist" ]]; then
        /usr/bin/printf '%s\n' "ERROR: expected LaunchAgent plist at: $plist" >&2
        exit 1
      fi

      existing_to="$(pb_get "$plist" ":EnvironmentVariables:SENTINEL_TO" || true)"
      existing_allowed="$(pb_get "$plist" ":EnvironmentVariables:SENTINEL_ALLOWED_HANDLES" || true)"
      existing_interval="$(pb_get "$plist" ":EnvironmentVariables:IRONDOME_INTERVAL_SECONDS" || true)"
      existing_interval="${existing_interval:-60}"

      config_dir="$HOME/Library/Application Support/IronDome"
      config_path="$config_dir/config.json"
      existing_router_model="$("$PYTHON3" -c 'import sys; exec("import json,os\n" \
"p=sys.argv[1]\n" \
"try:\n" \
"  with open(p, \\\"r\\\", encoding=\\\"utf-8\\\") as f: obj=json.load(f)\n" \
"except Exception: obj={}\n" \
"v=obj.get(\\\"router_model\\\", \\\"\\\") if isinstance(obj, dict) else \\\"\\\"\n" \
"print(v.strip() if isinstance(v, str) else \\\"\\\")\n")' "$config_path" 2>/dev/null || true)"
      existing_router_model="${existing_router_model:-spectrum}"

      sentinel_to="$(prompt_default "SENTINEL_TO (phone or Apple ID email)" "$existing_to")"
      sentinel_to="$(printf '%s' "$sentinel_to" | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

      default_allowed="$existing_allowed"
      if [[ -z "$default_allowed" ]]; then
        default_allowed="$sentinel_to"
      fi
      sentinel_allowed="$(prompt_default "SENTINEL_ALLOWED_HANDLES (comma-separated)" "$default_allowed")"
      sentinel_allowed="$(printf '%s' "$sentinel_allowed" | /usr/bin/tr -d '[:space:]')"

      interval_seconds="$(prompt_int_default "IRONDOME_INTERVAL_SECONDS" "$existing_interval")"
      router_model="$(prompt_default "router_model (writes config.json)" "$existing_router_model")"
      router_model="$(printf '%s' "$router_model" | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      router_model="${router_model:-spectrum}"

      pb_ensure_dict "$plist" ":EnvironmentVariables"
      pb_set_string "$plist" ":EnvironmentVariables:SENTINEL_TO" "$sentinel_to"
      pb_set_string "$plist" ":EnvironmentVariables:SENTINEL_ALLOWED_HANDLES" "$sentinel_allowed"
      pb_set_string "$plist" ":EnvironmentVariables:IRONDOME_INTERVAL_SECONDS" "$interval_seconds"
      /usr/bin/plutil -lint "$plist" >/dev/null

      /bin/mkdir -p "$config_dir"
      "$PYTHON3" -c 'import sys; exec("import json,os\n" \
"path=sys.argv[1]\n" \
"router_model=(sys.argv[2] if len(sys.argv)>2 else \\\"\\\").strip() or \\\"spectrum\\\"\n" \
"data={}\n" \
"try:\n" \
"  if os.path.exists(path):\n" \
"    with open(path, \\\"r\\\", encoding=\\\"utf-8\\\") as f: obj=json.load(f)\n" \
"  else:\n" \
"    obj={}\n" \
"except Exception: obj={}\n" \
"data=obj if isinstance(obj, dict) else {}\n" \
"data[\\\"router_model\\\"]=router_model\n" \
"tmp=path+\\\".tmp\\\"\n" \
"with open(tmp, \\\"w\\\", encoding=\\\"utf-8\\\") as f:\n" \
"  json.dump(data, f, ensure_ascii=False, indent=2)\n" \
"  f.write(\\\"\\\\n\\\")\n" \
"os.replace(tmp, path)\n")' "$config_path" "$router_model"

      uidn="$(/usr/bin/id -u)"
      label="com.irondome.sentinel"
      gui_target="gui/$uidn"

      /bin/launchctl bootout "$gui_target" "$plist" >/dev/null 2>&1 || true
      /bin/launchctl bootstrap "$gui_target" "$plist" >/dev/null 2>&1 || true
      /bin/launchctl enable "$gui_target/$label" >/dev/null 2>&1 || true
      /bin/launchctl kickstart -k "$gui_target/$label" >/dev/null 2>&1 || true

      /usr/bin/printf '\n'
      /usr/bin/printf '%s\n' "Configured Sentinel:"
      /usr/bin/printf '%s\n' "  LaunchAgent: $plist"
      /usr/bin/printf '%s\n' "  SENTINEL_TO: $sentinel_to"
      /usr/bin/printf '%s\n' "  ALLOWED: $sentinel_allowed"
      /usr/bin/printf '%s\n' "  INTERVAL: $interval_seconds"
      /usr/bin/printf '%s\n' "  router_model: $router_model"
      /usr/bin/printf '%s\n' "  config.json: $config_path"
      /usr/bin/printf '\n'
      /usr/bin/printf '%s\n' "macOS permissions (System Settings → Privacy & Security):"
      /usr/bin/printf '%s\n' "  - Full Disk Access: $PYTHON3"
      /usr/bin/printf '%s\n' "  - Automation: allow Messages access for $PYTHON3"
    EOS

    chmod 0755, bin/"irondome-sentinel-setup"

    # Alias command
    bin.install_symlink "irondome-sentinel" => "irondome"

    # Ship templates/scripts for local setup.
    pkgshare.install libexec/"launchd"
    pkgshare.install libexec/"scripts"
    pkgshare.install libexec/"docker-compose.yaml" if (libexec/"docker-compose.yaml").exist?
  end

  def caveats
    <<~EOS
      Irondome-Sentinel installs scripts and LaunchAgent templates.

      Next steps:
        1) Run interactive setup:

           irondome-sentinel-setup

        2) Configure Messages permissions (Automation) and Full Disk Access for the Python used by Homebrew.

      Manual LaunchAgent install:

           zsh "#{opt_pkgshare}/scripts/irondome-sentinel-install-launchagent.zsh"

      Optional Buddy (pipeline loop without iMessage):

           zsh "#{opt_pkgshare}/scripts/irondome-buddy-install-launchagent.zsh"

      Config:
        ~/Library/Application Support/IronDome/config.json
    EOS
  end

  test do
    assert_match "Iron Dome Sentinel", shell_output("#{bin}/irondome-sentinel --help")
  end
end
