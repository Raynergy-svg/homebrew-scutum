class IrondomeSentinel < Formula
  desc "macOS LaunchAgent + local defensive pipeline"
  homepage "https://raw.githubusercontent.com/Raynergy-svg/Scutum/v1.0.0/irondome-README.md"
  url "https://github.com/Raynergy-svg/Scutum/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "7a136c28ebd8ee40f5015b17c23483e3d69a3a7cfc72de727edd39119be5be3d"
  license "MIT"
  revision 13

  depends_on "python"
  depends_on "ollama"

  def install
    libexec.install Dir["*"]

    old_label = "com." + "irondome" + ".sentinel"
    new_label = "com.scutum.sentinel"
    old_plist_name = "#{old_label}.plist"
    new_plist_name = "#{new_label}.plist"

    if (libexec/"launchd"/old_plist_name).exist?
      mv (libexec/"launchd"/old_plist_name), (libexec/"launchd"/new_plist_name)
      inreplace (libexec/"launchd"/new_plist_name), old_label, new_label
    end

    if (libexec/"scripts"/"irondome-sentinel-install-launchagent.zsh").exist?
      inreplace (libexec/"scripts"/"irondome-sentinel-install-launchagent.zsh"), old_plist_name, new_plist_name
      inreplace (libexec/"scripts"/"irondome-sentinel-install-launchagent.zsh"), old_label, new_label
    end

    if (libexec/"scripts"/"irondome-polling-test.zsh").exist?
      inreplace (libexec/"scripts"/"irondome-polling-test.zsh"), old_plist_name, new_plist_name
      inreplace (libexec/"scripts"/"irondome-polling-test.zsh"), old_label, new_label
    end

    if (libexec/"irondome-SENTINEL.md").exist?
      inreplace (libexec/"irondome-SENTINEL.md"), old_plist_name, new_plist_name
      inreplace (libexec/"irondome-SENTINEL.md"), old_label, new_label
    end

    python3 = Formula["python"].opt_bin/"python3"

    (bin/"irondome-sentinel").write <<~EOS
      #!/bin/bash
      export PYTHONUNBUFFERED=1
      exec "#{python3}" "#{pkgshare}/scripts/irondome-sentinel.py" "$@"
    EOS

    chmod 0755, bin/"irondome-sentinel"

    (pkgshare/"scripts/irondome-sentinel-setup.py").write <<~'PY'
      #!/usr/bin/env python3
      import argparse
      import json
      import os
      import re
      import secrets
      import shutil
      import subprocess
      import sys
      import urllib.error
      import urllib.request
      from pathlib import Path


      def _print(s: str = "") -> None:
        sys.stdout.write(s + "\n")
        sys.stdout.flush()


      def _run(cmd: list[str], *, check: bool = True, quiet: bool = False) -> subprocess.CompletedProcess:
        stdout = subprocess.DEVNULL if quiet else None
        stderr = subprocess.DEVNULL if quiet else None
        return subprocess.run(cmd, check=check, stdout=stdout, stderr=stderr, text=True)


      def _plistbuddy_exists(plist: Path, key_path: str) -> bool:
        result = subprocess.run(
          ["/usr/libexec/PlistBuddy", "-c", f"Print {key_path}", str(plist)],
          stdout=subprocess.DEVNULL,
          stderr=subprocess.DEVNULL,
          text=True,
        )
        return result.returncode == 0


      def _plistbuddy_get(plist: Path, key_path: str) -> str:
        result = subprocess.run(
          ["/usr/libexec/PlistBuddy", "-c", f"Print {key_path}", str(plist)],
          stdout=subprocess.PIPE,
          stderr=subprocess.DEVNULL,
          text=True,
        )
        if result.returncode != 0:
          return ""
        return (result.stdout or "").strip()


      def _pb_quote(value: str) -> str:
        return json.dumps(value)


      def _plistbuddy_ensure_dict(plist: Path, key_path: str) -> None:
        if _plistbuddy_exists(plist, key_path):
          return
        _run(["/usr/libexec/PlistBuddy", "-c", f"Add {key_path} dict", str(plist)], quiet=True)


      def _plistbuddy_set_string(plist: Path, key_path: str, value: str) -> None:
        q = _pb_quote(value)
        if _plistbuddy_exists(plist, key_path):
          _run(["/usr/libexec/PlistBuddy", "-c", f"Set {key_path} {q}", str(plist)], quiet=True)
        else:
          _run(["/usr/libexec/PlistBuddy", "-c", f"Add {key_path} string {q}", str(plist)], quiet=True)


      def _prompt(label: str, default: str | None = None, *, required: bool = False) -> str:
        while True:
          suffix = f" [{default}]" if default else ""
          value = input(f"{label}{suffix}: ").strip()
          if not value and default:
            value = default
          if required and not value:
            _print("Please enter a value.")
            continue
          return value


      def _prompt_yes_no(label: str, default: bool = False) -> bool:
        d = "Y/n" if default else "y/N"
        while True:
          raw = input(f"{label} [{d}]: ").strip().lower()
          if not raw:
            return default
          if raw in {"y", "yes"}:
            return True
          if raw in {"n", "no"}:
            return False
          _print("Please answer y or n.")


      def _prompt_int(label: str, default: int) -> int:
        while True:
          raw = _prompt(label, str(default), required=True)
          raw = re.sub(r"\s+", "", raw)
          if raw.isdigit() and int(raw) > 0:
            return int(raw)
          _print("Please enter a positive integer.")


      def _normalize_handle(value: str) -> str:
        value = value.strip()
        if not value:
          return value
        if "@" in value:
          return value.lower()
        if value.startswith("+"):
          digits = re.sub(r"\D", "", value)
          return f"+{digits}" if digits else value
        digits = re.sub(r"\D", "", value)
        if len(digits) == 10:
          return f"+1{digits}"
        if len(digits) == 11 and digits.startswith("1"):
          return f"+1{digits[1:]}"
        return value


      def _choose_backend(default: str) -> str:
        options = {"auto", "chatdb", "osascript", "applescript"}
        while True:
          raw = _prompt("Polling backend (auto/chatdb/osascript)", default)
          raw = raw.strip().lower()
          if raw == "applescript":
            raw = "osascript"
          if raw in options:
            return raw
          _print("Please enter: auto, chatdb, or osascript.")


      def _write_reference_env(path: Path, env: dict[str, str]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        lines = ["# Reference-only (LaunchAgent plist is source of truth)"]
        for k in sorted(env.keys()):
          v = env[k]
          lines.append(f"{k}={v}")
        data = "\n".join(lines) + "\n"
        path.write_text(data, encoding="utf-8")
        os.chmod(path, 0o600)


      def _normalize_ollama_host(value: str) -> str:
        v = (value or "").strip()
        if not v:
          return "http://127.0.0.1:11434"
        if v.startswith("http://") or v.startswith("https://"):
          return v
        return f"http://{v}"


      def _check_ollama_if_requested(router_model: str) -> None:
        if (router_model or "").strip().lower() != "ollama":
          return

        _print("")
        _print("\033[1mOllama check\033[0m")

        if shutil.which("ollama") is None:
          _print("Ollama was selected as router_model but the 'ollama' binary was not found.")
          _print("Install it via Homebrew: brew install ollama")
          return

        try:
          subprocess.run(["ollama", "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
        except Exception:
          pass

        host = _normalize_ollama_host(os.environ.get("OLLAMA_HOST", ""))
        url = host.rstrip("/") + "/api/version"
        try:
          with urllib.request.urlopen(url, timeout=1.5) as resp:
            _ = resp.read(4096)
          _print(f"\033[32mOK\033[0m  Ollama daemon reachable at {host}")
        except Exception:
          _print(f"\033[33mNOTE\033[0m  Ollama installed, but daemon not reachable at {host}.")
          _print("Start it with one of:")
          _print("  - brew services start ollama")
          _print("  - ollama serve")


      def main() -> int:
        parser = argparse.ArgumentParser(
          prog="irondome-sentinel-setup",
          description="Interactive post-install setup for IronDome Sentinel (LaunchAgent config).",
          add_help=True,
        )
        parser.add_argument(
          "--no-launchctl",
          action="store_true",
          help="Do not start/stop the LaunchAgent (only write files).",
        )
        args = parser.parse_args()

        pkgshare = Path(__file__).resolve().parents[1]
        install_helper = pkgshare / "scripts" / "irondome-sentinel-install-launchagent.zsh"
        plist = Path.home() / "Library" / "LaunchAgents" / "com.scutum.sentinel.plist"
        reference_env = Path.home() / ".irondome" / "sentinel.env"
        config_dir = Path.home() / "Library" / "Application Support" / "IronDome"
        config_path = config_dir / "config.json"

        _print("\033[1mIronDome Sentinel Setup\033[0m")
        _print("Configure your LaunchAgent + command authorization.")
        _print("")

        _print("\033[1mStep 1/4 — Identity\033[0m")
        from_email = _normalize_handle(_prompt("iMessage email (used to send commands)", required=True))
        from_phone = _normalize_handle(_prompt("Phone number (optional)", default=""))
        default_to = from_phone or from_email
        sentinel_to = _normalize_handle(_prompt("Send alerts/replies TO", default_to, required=True))

        allowed = []
        for h in [from_email, from_phone, sentinel_to]:
          if h and h not in allowed:
            allowed.append(h)

        _print("")
        _print("\033[1mStep 2/4 — Shared secret\033[0m")
        use_secret = _prompt_yes_no("Require a shared secret prefix for commands?", default=False)
        shared_secret = ""
        if use_secret:
          shared_secret = secrets.token_urlsafe(16)
          _print("\033[33m⚠ IMPORTANT\033[0m  This secret is shown once. Save it.")
          _print("\033[1m" + shared_secret + "\033[0m")
          input("Press Enter to continue…")

        _print("")
        _print("\033[1mStep 3/4 — Polling & Interval\033[0m")
        existing_backend = _plistbuddy_get(plist, ":EnvironmentVariables:SENTINEL_POLL_BACKEND") or "auto"
        backend = _choose_backend(existing_backend)
        existing_poll_seconds_raw = _plistbuddy_get(plist, ":EnvironmentVariables:SENTINEL_POLL_SECONDS")
        try:
          existing_poll_seconds = int(existing_poll_seconds_raw) if existing_poll_seconds_raw else 5
        except Exception:
          existing_poll_seconds = 5
        poll_seconds = _prompt_int("Poll interval seconds", existing_poll_seconds)

        existing_interval_raw = _plistbuddy_get(plist, ":EnvironmentVariables:IRONDOME_INTERVAL_SECONDS")
        try:
          existing_interval_seconds = int(existing_interval_raw) if existing_interval_raw else 60
        except Exception:
          existing_interval_seconds = 60
        interval_seconds = _prompt_int("Scan interval seconds (IRONDOME_INTERVAL_SECONDS)", existing_interval_seconds)

        _print("")
        _print("\033[1mStep 4/4 — Apply\033[0m")

        if not install_helper.exists():
          _print(f"ERROR: missing install helper: {install_helper}")
          return 1

        _run(["/bin/zsh", str(install_helper)], quiet=True)
        if not plist.exists():
          _print(f"ERROR: expected LaunchAgent plist at: {plist}")
          return 1

        _plistbuddy_ensure_dict(plist, ":EnvironmentVariables")

        _plistbuddy_set_string(plist, ":EnvironmentVariables:SENTINEL_TO", sentinel_to)
        _plistbuddy_set_string(plist, ":EnvironmentVariables:SENTINEL_ALLOWED_HANDLES", ",".join(allowed))
        _plistbuddy_set_string(plist, ":EnvironmentVariables:SENTINEL_POLL_BACKEND", backend)
        _plistbuddy_set_string(plist, ":EnvironmentVariables:SENTINEL_POLL_SECONDS", str(poll_seconds))
        _plistbuddy_set_string(plist, ":EnvironmentVariables:IRONDOME_INTERVAL_SECONDS", str(interval_seconds))
        if use_secret:
          _plistbuddy_set_string(plist, ":EnvironmentVariables:SENTINEL_SHARED_SECRET", shared_secret)
        else:
          if _plistbuddy_exists(plist, ":EnvironmentVariables:SENTINEL_SHARED_SECRET"):
            subprocess.run(
              ["/usr/libexec/PlistBuddy", "-c", "Delete :EnvironmentVariables:SENTINEL_SHARED_SECRET", str(plist)],
              stdout=subprocess.DEVNULL,
              stderr=subprocess.DEVNULL,
              text=True,
            )

        _run(["/usr/bin/plutil", "-lint", str(plist)], quiet=True)

        existing_router_model = ""
        if config_path.exists():
          try:
            obj = json.loads(config_path.read_text(encoding="utf-8"))
            if isinstance(obj, dict):
              existing_router_model = str(obj.get("router_model", "") or "").strip()
          except Exception:
            existing_router_model = ""
        if not existing_router_model:
          existing_router_model = "spectrum"
        router_model = _prompt("router_model (writes config.json)", existing_router_model, required=True).strip() or "spectrum"

        config_dir.mkdir(parents=True, exist_ok=True)
        config_obj: dict[str, object] = {}
        if config_path.exists():
          try:
            existing = json.loads(config_path.read_text(encoding="utf-8"))
            if isinstance(existing, dict):
              config_obj.update(existing)
          except Exception:
            pass
        config_obj["router_model"] = router_model
        config_path.write_text(json.dumps(config_obj, indent=2, sort_keys=True) + "\n", encoding="utf-8")

        _check_ollama_if_requested(router_model)

        env_ref = {
          "SENTINEL_TO": sentinel_to,
          "SENTINEL_ALLOWED_HANDLES": ",".join(allowed),
          "SENTINEL_POLL_BACKEND": backend,
          "SENTINEL_POLL_SECONDS": str(poll_seconds),
          "IRONDOME_INTERVAL_SECONDS": str(interval_seconds),
          "ROUTER_MODEL": router_model,
        }
        if use_secret:
          env_ref["SENTINEL_SHARED_SECRET"] = shared_secret
        _write_reference_env(reference_env, env_ref)

        uid = str(os.getuid())
        label = "com.scutum.sentinel"
        gui = f"gui/{uid}"
        if not args.no_launchctl:
          subprocess.run(["/bin/launchctl", "bootout", gui, str(plist)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
          subprocess.run(["/bin/launchctl", "bootstrap", gui, str(plist)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
          subprocess.run(["/bin/launchctl", "enable", f"{gui}/{label}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
          subprocess.run(["/bin/launchctl", "kickstart", "-k", f"{gui}/{label}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        base_dir = _plistbuddy_get(plist, ":EnvironmentVariables:IRONDOME_BASE_DIR") or str(Path.home() / ".irondome")
        workdir = _plistbuddy_get(plist, ":EnvironmentVariables:IRONDOME_WORKDIR") or str(Path(base_dir) / "work" / "sentinel")
        sentinel_log = str(Path(workdir) / "sentinel.log")

        _print("")
        _print("\033[1m✅ Setup complete\033[0m")
        _print("")
        _print("Files:")
        _print(f"  LaunchAgent: {plist}")
        _print(f"  Reference env: {reference_env} (reference-only)")
        _print("")
        _print("Configuration:")
        _print(f"  Sent to: {sentinel_to}")
        _print("  Authorized: " + ", ".join(allowed))
        _print(f"  Poll backend: {backend}")
        _print(f"  Poll seconds: {poll_seconds}")
        _print(f"  Scan interval: {interval_seconds}")
        _print(f"  router_model: {router_model}")
        _print(f"  config.json: {config_path}")
        _print(f"  Shared secret: {'enabled' if use_secret else 'disabled'}")
        _print("")
        _print("Required actions:")
        _print("  1) System Settings → Privacy & Security → Full Disk Access")
        _print(f"     Add: {sys.executable}")
        for p in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", str(Path.home() / ".continue" / ".venv" / "bin" / "python")]:
          if os.path.exists(p) and p != sys.executable:
            _print(f"     Also add (if used): {p}")
        _print("  2) System Settings → Privacy & Security → Automation")
        _print("     Allow your Python to control Messages")
        _print("")
        _print("Manage the agent:")
        _print(f"  launchctl print {gui}/{label}")
        _print(f"  launchctl kickstart -k {gui}/{label}")
        _print(f"  launchctl bootout {gui} {plist}")
        _print(f"  launchctl bootstrap {gui} {plist}")
        _print("")
        _print("View logs:")
        _print(f"  tail -n 200 -f {sentinel_log}")
        _print("")
        _print("Test commands:")
        if use_secret:
          _print(f"  {shared_secret} status")
          _print(f"  {shared_secret} ping")
        else:
          _print("  status")
          _print("  ping")
        _print("")
        _print("Note: Sentinel replies are always sent to SENTINEL_TO.")
        return 0


      if __name__ == "__main__":
        raise SystemExit(main())
    PY

    chmod 0755, pkgshare/"scripts/irondome-sentinel-setup.py"

    (bin/"irondome-sentinel-setup").write <<~EOS
      #!/bin/bash
      set -euo pipefail
      exec "#{python3}" "#{opt_pkgshare}/scripts/irondome-sentinel-setup.py" "$@"
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

      Ollama (local LLM):
        - Installed automatically as a dependency.
        - If you set router_model=ollama, ensure the daemon is running:

            brew services start ollama

          (or run: ollama serve)

      Next steps:
        1) Run interactive setup:

          irondome-sentinel-setup

        2) Configure Messages permissions (Automation) and Full Disk Access for the Python that runs Sentinel.

      Remote commands (Messages):
        - Only handles in the allowlist can send commands (setup auto-populates this).
        - If a shared secret is enabled, every command must start with:

            <secret> <command>

        - Replies are always sent to SENTINEL_TO (not necessarily back to the sender thread).
        - Some commands are multi-step and require a follow-up confirmation message (e.g. ACCEPT/DENY).

      Manual LaunchAgent install:

           zsh "#{opt_pkgshare}/scripts/irondome-sentinel-install-launchagent.zsh"

      Config:
        ~/Library/Application Support/IronDome/config.json
    EOS
  end

  test do
    assert_match "Iron Dome Sentinel", shell_output("#{bin}/irondome-sentinel --help")
    assert_match(/ollama/i, shell_output("#{Formula['ollama'].opt_bin}/ollama --version"))
  end
end
