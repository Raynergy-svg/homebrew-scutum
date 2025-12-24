class IrondomeSentinel < Formula
  desc "macOS LaunchAgent + local defensive pipeline"
  homepage "https://raw.githubusercontent.com/Raynergy-svg/Scutum/v1.0.0/irondome-README.md"
  url "https://github.com/Raynergy-svg/Scutum/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "7a136c28ebd8ee40f5015b17c23483e3d69a3a7cfc72de727edd39119be5be3d"
  license "MIT"
  revision 12

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

    setup = <<~'EOS'
      #!/bin/bash
      set -euo pipefail

      PKGSHARE="__PKGSHARE__"
      PYTHON3="__PYTHON3__"

        usage() {
          /usr/bin/printf '%s\n' "irondome-sentinel-setup"
          /usr/bin/printf '%s\n' ""
          /usr/bin/printf '%s\n' "Interactive post-install setup:"
          /usr/bin/printf '%s\n' "- Prompts for SENTINEL_TO, SENTINEL_ALLOWED_HANDLES, IRONDOME_INTERVAL_SECONDS"
          /usr/bin/printf '%s\n' "- Updates ~/Library/LaunchAgents/com.tortuga.scutum.sentinel.plist EnvironmentVariables"
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
          "$PYTHON3" -c "import json,sys; print(json.dumps(sys.argv[1]))" "${1-}"
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

        /bin/zsh "$PKGSHARE/scripts/irondome-sentinel-install-launchagent.zsh" >/dev/null 2>&1 || true

        plist="$HOME/Library/LaunchAgents/com.tortuga.scutum.sentinel.plist"
        if [[ ! -f "$plist" ]]; then
          /usr/bin/printf '%s\n' "ERROR: expected LaunchAgent plist at: $plist" >&2
          exit 1
        fi

        existing_to="$(pb_get "$plist" ":EnvironmentVariables:SENTINEL_TO" || true)"
        existing_allowed="$(pb_get "$plist" ":EnvironmentVariables:SENTINEL_ALLOWED_HANDLES" || true)"
        existing_interval="$(pb_get "$plist" ":EnvironmentVariables:IRONDOME_INTERVAL_SECONDS" || true)"
        existing_interval="${existing_interval:-60}"

        # The shipped LaunchAgent template historically included a placeholder number.
        # Never present that as the user's default.
        if [[ "$existing_to" == "+14133550676" ]]; then
          existing_to=""
        fi
        if [[ "$existing_allowed" == "+14133550676" ]]; then
          existing_allowed=""
        fi

        config_dir="$HOME/Library/Application Support/IronDome"
        config_path="$config_dir/config.json"
        existing_router_model="$(/usr/bin/plutil -extract router_model raw -o - "$config_path" 2>/dev/null || true)"
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
        if [[ ! -f "$config_path" ]]; then
          /usr/bin/printf '%s\n' '{}' >"$config_path"
        fi
        /usr/bin/plutil -replace router_model -string "$router_model" "$config_path"

        uidn="$(/usr/bin/id -u)"
        label="com.tortuga.scutum.sentinel"
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

    (bin/"irondome-sentinel-setup").write(
      setup.gsub("__PKGSHARE__", opt_pkgshare.to_s)
           .gsub("__PYTHON3__", python3.to_s),
    )

    chmod 0755, bin/"irondome-sentinel-setup"

    # Alias command
    bin.install_symlink "irondome-sentinel" => "irondome"

    # Ship templates/scripts for local setup.
    pkgshare.install libexec/"launchd"
    pkgshare.install libexec/"scripts"
    pkgshare.install libexec/"docker-compose.yaml" if (libexec/"docker-compose.yaml").exist?

    # Stop shipping Buddy (subagent) artifacts.
    rm_f pkgshare/"launchd/com.irondome.buddy.plist"
    rm_f pkgshare/"scripts/irondome-buddy-install-launchagent.zsh"
    rm_f pkgshare/"scripts/irondome-respond.zsh"

        # Normalize the shipped LaunchAgent template to the canonical label + filename.
        # The upstream source tarball may still ship the legacy name, so patch it first then rename.
        legacy_label = ["com", "irondome", "sentinel"].join(".")
        canonical_label = ["com", "tortuga", "scutum", "sentinel"].join(".")
        legacy_plist = pkgshare/"launchd/#{legacy_label}.plist"
        canonical_plist = pkgshare/"launchd/#{canonical_label}.plist"

        if legacy_plist.exist?
      inreplace legacy_plist,
        "<string>+14133550676</string>",
        "<string></string>"

      inreplace legacy_plist,
        "<string>#{legacy_label}</string>",
        "<string>#{canonical_label}</string>"

      inreplace legacy_plist,
        "/tmp/#{legacy_label}.out.log",
        "/tmp/#{canonical_label}.out.log"

      inreplace legacy_plist,
        "/tmp/#{legacy_label}.err.log",
        "/tmp/#{canonical_label}.err.log"

      mv legacy_plist, canonical_plist
        else
      # Newer tarballs may already ship the canonical plist name.
      inreplace canonical_plist,
        "<string>+14133550676</string>",
        "<string></string>"
        end

        # Ensure installer scripts reference the canonical plist/label.
        inreplace pkgshare/"scripts/irondome-sentinel-install-launchagent.zsh",
              legacy_label,
              canonical_label

        if (pkgshare/"scripts/irondome-polling-test.zsh").exist?
      inreplace pkgshare/"scripts/irondome-polling-test.zsh",
            legacy_label,
            canonical_label
        end

    # The installer script prints the launchctl service; on first install the service may not exist yet.
    # Avoid exiting non-zero (and emitting an alarming error) in that case.
    inreplace pkgshare/"scripts/irondome-sentinel-install-launchagent.zsh",
              'launchctl print "gui/$uidn/$label" | head -n 80',
              'launchctl print "gui/$uidn/$label" 2>/dev/null | head -n 80 || true'

    # Stop using the AI responder/subagent in the default pipeline.
    inreplace pkgshare/"scripts/irondome-run.zsh",
              "# Orchestrator: scan -> detect -> respond",
              "# Orchestrator: scan -> detect -> playbook"

    inreplace pkgshare/"scripts/irondome-run.zsh",
              '/bin/zsh "$script_dir/irondome-respond.zsh" "$workdir"',
              ""

    # Remove Ollama/Buddy references from evidence collection.
    inreplace pkgshare/"scripts/irondome-scan.zsh",
              'echo "=== Iron Dome Buddy (evidence report) ==="',
              'echo "=== Iron Dome Sentinel (evidence report) ==="'

    inreplace pkgshare/"scripts/irondome-scan.zsh",
              'echo "- actions:  $workdir/actions-latest.txt (generated by irondome-respond.zsh)"',
              'echo "- actions:  $workdir/actions-latest.txt (optional)"'

    scan_ollama_block = <<~'SH'
      echo "[ollama] Status"
      if command -v ollama >/dev/null 2>&1; then
        ollama ps || true
      else
        echo "ollama not found"
      fi
      echo

SH

    inreplace pkgshare/"scripts/irondome-scan.zsh", scan_ollama_block, ""

    inreplace pkgshare/"scripts/irondome-detect.zsh",
              "# Allowlist is conservative: 11434 (ollama), 22 (ssh), 80/443 (web), 5353 (mDNS), 53 (dns), 631 (ipp).",
              "# Allowlist is conservative: 22 (ssh), 80/443 (web), 5353 (mDNS), 53 (dns), 631 (ipp)."

    inreplace pkgshare/"scripts/irondome-detect.zsh",
              "allow_ports_re=':(22|53|80|443|631|5353|11434)\\b'",
              "allow_ports_re=':(22|53|80|443|631|5353)\\b'"

    # Add iMessage command: `remove` (wipes LaunchAgent plist + local IronDome base dir; confirmation required).
    # Patched in at install-time so we can ship fixes via Homebrew `revision` without retagging the source.
    python_remove_search = <<~'PY'
      if normalized == "log":
        return self._tail_log(60)

      # Power control.
  PY

    python_remove_replace = <<~'PY'
      if normalized == "log":
        return self._tail_log(60)

      if normalized in {"remove", "uninstall", "wipe"}:
        self._state["remove_pending"] = {
          "requested_by": _normalize_handle(sender_handle),
          "expires_epoch": int(time.time()) + 300,
        }
        self._save_state()
        return (
          "Remove requested. Reply 'remove confirm' within 5 minutes to proceed.\n"
          "This will: bootout Sentinel LaunchAgent, delete ~/Library/LaunchAgents/com.tortuga.scutum.sentinel.plist,\n"
          "and delete ~/Library/Application Support/IronDome (config/work/state).\n"
          "It will NOT uninstall the Homebrew formula.\n"
        )

      if normalized in {"remove confirm", "uninstall confirm", "wipe confirm"}:
        pending = self._state.get("remove_pending")
        if not isinstance(pending, dict):
          pending = {}
        try:
          expires = int(pending.get("expires_epoch") or 0)
        except Exception:
          expires = 0
        req_by = _normalize_handle(str(pending.get("requested_by") or ""))
        if not expires or not req_by:
          return "No pending remove. Send 'remove' first."
        if int(time.time()) > expires:
          self._state["remove_pending"] = {}
          self._save_state()
          return "Remove request expired. Send 'remove' again."
        if req_by != _normalize_handle(sender_handle):
          return "Remove request is pending for a different sender."

        # Best effort: stop job + remove local artifacts.
        self.send_message("[Iron Dome] Removing local Sentinel config + LaunchAgent now. After reinstall, run: irondome-sentinel-setup")
        self._stop = True
        uidn = str(os.getuid())
        plist_path = Path("~/Library/LaunchAgents/com.tortuga.scutum.sentinel.plist").expanduser()
        try:
          subprocess.run(["/bin/launchctl", "bootout", f"gui/{uidn}", str(plist_path)], capture_output=True, text=True)
        except Exception:
          pass
        try:
          plist_path.unlink()
        except Exception:
          pass
        try:
          shutil.rmtree(self.base_dir)
        except Exception:
          pass
        self._state["remove_pending"] = {}
        self._save_state()
        return None

      # Power control.
  PY

    inreplace pkgshare/"scripts/irondome-sentinel.py", python_remove_search, python_remove_replace

    # Mention `remove` in help output.
    inreplace pkgshare/"scripts/irondome-sentinel.py",
          '            "- log",',
          "            \"- log\",\n            \"- remove (wipes LaunchAgent + local config; confirm required)\"," 

    # Treat `remove` as a command attempt (so it gets an Unknown-command response if misspelled).
    inreplace pkgshare/"scripts/irondome-sentinel.py",
          "            \"log\",\n            \"shutdown\",\n",
          "            \"log\",\n            \"remove\",\n            \"shutdown\",\n"

    # Prevent double-replies: dedupe inbound messages by message_id.
    python_state_search = <<~'PY'
          "last_message_id": "",
          "last_alert_hash": "",
  PY

    python_state_replace = <<~'PY'
          "last_message_id": "",
          "recent_message_ids": [],
          "last_alert_hash": "",
  PY

    inreplace pkgshare/"scripts/irondome-sentinel.py", python_state_search, python_state_replace

    python_poll_search = <<~'PY'
      newest_seen = last_id
      responses: list[str] = []

      for handle in sorted(self.allowed_handles):
        msgs = self.poll_messages(handle, limit=25)
        for m in msgs:
          if not m.message_id:
            continue
  PY

    python_poll_replace = <<~'PY'
      newest_seen = last_id
      responses: list[str] = []

      recent = self._state.get("recent_message_ids")
      if not isinstance(recent, list):
        recent = []
      recent_set = {str(x) for x in recent if str(x)}
      processed_this_cycle: set[str] = set()

      for handle in sorted(self.allowed_handles):
        msgs = self.poll_messages(handle, limit=25)
        for m in msgs:
          mid = (m.message_id or "").strip()
          if not mid:
            continue

          if mid in processed_this_cycle or mid in recent_set:
            continue
  PY

    inreplace pkgshare/"scripts/irondome-sentinel.py", python_poll_search, python_poll_replace

    python_poll_search2 = <<~'PY'
          if last_id and self._compare_message_ids(m.message_id, last_id) <= 0:
            continue
  PY

    python_poll_replace2 = <<~'PY'
          if last_id and self._compare_message_ids(mid, last_id) <= 0:
            continue
  PY

    inreplace pkgshare/"scripts/irondome-sentinel.py", python_poll_search2, python_poll_replace2

    python_poll_search3 = <<~'PY'
            if consumed:
              if self._compare_message_ids(m.message_id, newest_seen) > 0:
                newest_seen = m.message_id
              continue
  PY

    python_poll_replace3 = <<~'PY'
            if consumed:
              processed_this_cycle.add(mid)
              if self._compare_message_ids(mid, newest_seen) > 0:
                newest_seen = mid
              continue
  PY

    inreplace pkgshare/"scripts/irondome-sentinel.py", python_poll_search3, python_poll_replace3

    python_poll_search4 = <<~'PY'
          if self._compare_message_ids(m.message_id, newest_seen) > 0:
            newest_seen = m.message_id

      if newest_seen and newest_seen != last_id:
        self._state["last_message_id"] = newest_seen
        self._save_state()
  PY

    python_poll_replace4 = <<~'PY'
          processed_this_cycle.add(mid)
          recent.append(mid)
          if self._compare_message_ids(mid, newest_seen) > 0:
            newest_seen = mid

      recent = [str(x) for x in recent if str(x)]
      if len(recent) > 200:
        recent = recent[-200:]
      self._state["recent_message_ids"] = recent

      if newest_seen and newest_seen != last_id:
        self._state["last_message_id"] = newest_seen
      if processed_this_cycle or (newest_seen and newest_seen != last_id):
        self._save_state()
  PY

    inreplace pkgshare/"scripts/irondome-sentinel.py", python_poll_search4, python_poll_replace4
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

      Config:
        ~/Library/Application Support/IronDome/config.json
    EOS
  end

  test do
    assert_match "Iron Dome Sentinel", shell_output("#{bin}/irondome-sentinel --help")
  end
end
