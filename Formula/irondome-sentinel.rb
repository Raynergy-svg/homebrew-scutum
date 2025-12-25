class IrondomeSentinel < Formula
  desc "macOS LaunchAgent + local defensive pipeline"
  homepage "https://raw.githubusercontent.com/Raynergy-svg/Scutum/v1.0.0/irondome-README.md"
  url "https://github.com/Raynergy-svg/Scutum/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "7a136c28ebd8ee40f5015b17c23483e3d69a3a7cfc72de727edd39119be5be3d"
  license "MIT"
  revision 15

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
      p = libexec/"scripts"/"irondome-sentinel-install-launchagent.zsh"
      inreplace p, old_label, new_label if p.read.include?(old_label)
      inreplace p, old_plist_name, new_plist_name if p.read.include?(old_plist_name)
    end

    if (libexec/"scripts"/"irondome-polling-test.zsh").exist?
      p = libexec/"scripts"/"irondome-polling-test.zsh"
      inreplace p, old_label, new_label if p.read.include?(old_label)
      inreplace p, old_plist_name, new_plist_name if p.read.include?(old_plist_name)
    end

    # Ensure AI decision JSON is written without echo escape interpretation (zsh `echo` may expand \n etc).
    if (libexec/"scripts"/"irondome-respond.zsh").exist?
      p = libexec/"scripts"/"irondome-respond.zsh"
      needle = 'echo "$ai_decision" > "$ai_json"'
      replacement = 'print -r -- "$ai_decision" > "$ai_json"'
      inreplace p, needle, replacement if p.read.include?(needle)
    end

    if (libexec/"irondome-SENTINEL.md").exist?
      p = libexec/"irondome-SENTINEL.md"
      inreplace p, old_label, new_label if p.read.include?(old_label)
      inreplace p, old_plist_name, new_plist_name if p.read.include?(old_plist_name)
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


      def _ollama_reachable(host: str) -> bool:
        url = host.rstrip("/") + "/api/version"
        try:
          with urllib.request.urlopen(url, timeout=2.5) as resp:
            _ = resp.read(4096)
          return True
        except Exception:
          return False


      def _start_ollama_daemon(host: str) -> None:
        if _ollama_reachable(host):
          return
        brew = shutil.which("brew")
        if brew is not None:
          subprocess.run([brew, "services", "start", "ollama"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
        for _ in range(15):
          if _ollama_reachable(host):
            return
          try:
            import time

            time.sleep(0.5)
          except Exception:
            break


      def _ollama_model_exists(model: str) -> bool:
        try:
          result = subprocess.run(
            ["ollama", "list"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
          )
          if result.returncode != 0:
            return False
          for line in (result.stdout or "").splitlines():
            line = line.strip()
            if not line or line.lower().startswith("name"):
              continue
            name = (line.split() or [""])[0].strip()
            base = name.split(":", 1)[0]
            if base == model:
              return True
          return False
        except Exception:
          return False


      def _ensure_ollama_model(model: str, modelfile: Path) -> None:
        if _ollama_model_exists(model):
          return
        if not modelfile.exists():
          _print(f"\033[33mNOTE\033[0m  Missing Modelfile: {modelfile}")
          return
        _print(f"Creating Ollama model '{model}' (this may take a while)…")
        try:
          subprocess.run(["ollama", "create", model, "-f", str(modelfile)], check=True)
        except Exception:
          _print(f"\033[33mNOTE\033[0m  Failed to create model '{model}'.")
          _print(f"Run manually: ollama create {model} -f {modelfile}")


      def _ensure_ollama_ready(router_model: str, pkgshare: Path) -> None:
        if (router_model or "").strip().lower() != "ollama":
          return

        _print("")
        _print("\033[1mOllama setup\033[0m")

        if shutil.which("ollama") is None:
          _print("Ollama was selected as router_model but the 'ollama' binary was not found.")
          _print("Install it via Homebrew: brew install ollama")
          return

        host = _normalize_ollama_host(os.environ.get("OLLAMA_HOST", ""))
        if not _ollama_reachable(host):
          _print(f"Ollama daemon not reachable at {host}; attempting to start it…")
          _start_ollama_daemon(host)
        if _ollama_reachable(host):
          _print(f"\033[32mOK\033[0m  Ollama daemon reachable at {host}")
        else:
          _print(f"\033[33mNOTE\033[0m  Ollama daemon still not reachable at {host}.")
          _print("Start it with one of:")
          _print("  - brew services start ollama")
          _print("  - ollama serve")
          return

        modelfile = pkgshare / "ollama-models" / "sentinel" / "Modelfile"
        if not modelfile.exists():
          alt = Path.home() / ".continue" / "ollama-models" / "sentinel" / "Modelfile"
          if alt.exists():
            modelfile = alt
        _ensure_ollama_model("sentinel", modelfile)


      def main() -> int:
        parser = argparse.ArgumentParser(
          prog="irondome-sentinel-setup",
          description="Interactive post-install setup for IronDome Sentinel (LaunchAgent config).",
          add_help=True,
        )
        parser.add_argument(
          "--yes",
          action="store_true",
          help="Non-interactive: use provided flags and defaults; requires --from-email and --to.",
        )
        parser.add_argument("--from-email", default="", help="iMessage email used to send commands")
        parser.add_argument("--from-phone", default="", help="Phone number (optional)")
        parser.add_argument("--to", default="", help="Send alerts/replies TO")
        parser.add_argument("--poll-backend", default="", help="Polling backend: auto/chatdb/osascript")
        parser.add_argument("--poll-seconds", type=int, default=0, help="Poll interval seconds")
        parser.add_argument("--scan-interval-seconds", type=int, default=0, help="Scan interval seconds (IRONDOME_INTERVAL_SECONDS)")
        parser.add_argument("--router-model", default="", help="router_model to write to config.json")
        parser.add_argument("--require-secret", action="store_true", help="Require a shared secret prefix for commands")
        parser.add_argument("--shared-secret", default="", help="Provide a specific shared secret (implies --require-secret)")
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
        if args.yes:
          if not (args.from_email or "").strip():
            _print("ERROR: --yes requires --from-email")
            return 2

        from_email = _normalize_handle((args.from_email or "").strip())
        if not from_email:
          from_email = _normalize_handle(_prompt("iMessage email (used to send commands)", required=True))

        from_phone = _normalize_handle((args.from_phone or "").strip())

        sentinel_to = _normalize_handle((args.to or "").strip()) or from_email

        allowed = []
        for h in [from_email, from_phone, sentinel_to]:
          if h and h not in allowed:
            allowed.append(h)

        _print("")
        _print("\033[1mStep 2/4 — Shared secret\033[0m")
        shared_secret = (args.shared_secret or "").strip()
        use_secret = bool(shared_secret) or bool(args.require_secret)

        if use_secret and not shared_secret:
          shared_secret = secrets.token_urlsafe(16)

        if use_secret:
          _print("\033[33m⚠ IMPORTANT\033[0m  This secret is shown once. Save it.")
          _print("\033[1m" + shared_secret + "\033[0m")

        _print("")
        _print("\033[1mStep 3/4 — Polling & Interval\033[0m")
        backend = (args.poll_backend or "").strip().lower()
        if backend == "applescript":
          backend = "osascript"
        if not backend:
          backend = "auto"
        if backend not in {"auto", "chatdb", "osascript"}:
          _print("ERROR: --poll-backend must be: auto, chatdb, osascript")
          return 2

        if args.poll_seconds and args.poll_seconds > 0:
          poll_seconds = args.poll_seconds
        else:
          poll_seconds = 5

        if args.scan_interval_seconds and args.scan_interval_seconds > 0:
          interval_seconds = args.scan_interval_seconds
        else:
          interval_seconds = 60

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
        _plistbuddy_set_string(plist, ":EnvironmentVariables:OLLAMA_MODEL", "sentinel")
        _plistbuddy_set_string(plist, ":EnvironmentVariables:OLLAMA_HOST", _normalize_ollama_host(os.environ.get("OLLAMA_HOST", "")))
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

        router_model = (args.router_model or "").strip()
        if not router_model:
          router_model = "ollama"

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

        _ensure_ollama_ready(router_model, pkgshare)

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
    (pkgshare/"scripts").install Dir["#{libexec}/scripts/*"]
    pkgshare.install libexec/"docker-compose.yaml" if (libexec/"docker-compose.yaml").exist?

    (pkgshare/"ollama-models"/"sentinel").mkpath
    (pkgshare/"ollama-models"/"sentinel"/"Modelfile").write <<~'MF'
      FROM llama3.2:8b-instruct-qat
      PARAMETER temperature 0.1
      PARAMETER num_predict 400
      SYSTEM """
      You are Sentinel, a sophisticated defensive guardian for home networks, designed to analyze security alerts and recommend precise, non-disruptive actions. Your primary role is to process incoming ALERTS TEXT blocks, derive insights exclusively from the provided text, and output structured JSON responses that guide users in securing their systems without overreaction.
      Core Principles:

      Base all conclusions, severity assessments, and recommendations strictly on the content within the ALERTS TEXT block. Do not infer external knowledge, assume contexts, or reference unmentioned data.
      Maintain objectivity: Avoid speculation beyond what's directly supported by the evidence. For instance, if an alert mentions a new device, note it as potentially benign unless patterns indicate otherwise.
      Prioritize minimal intervention: Favor observation and evidence gathering over immediate blocking or isolation to prevent false positives that could disrupt legitimate network activity.
      Ensure outputs are actionable yet cautious: Recommendations should empower users to verify and respond, not automate destructive changes.

      Output Rules:

      Produce ONLY valid, well-formed JSON. No additional text, no markdown formatting, no explanatory preambles or postscripts.
      Never include shell commands, code snippets, or any executable instructions in your output.
      Do not claim or imply that you have executed any actions, collected data, or modified systems.
      Restrict recommended actions to the explicitly allowed set below. Do not invent new actions or variations.
      If the ALERTS TEXT lacks sufficient detail for high-confidence decisions, lower your confidence score and request evidence modules to gather more context.

      Allowed Actions:

      "notify_only": Alert the user without suggesting changes; suitable for low-severity or unconfirmed events.
      "collect_more_evidence": Request additional data via specified modules; use when alerts are ambiguous.
      "recommend_pf_block": Suggest blocking specific traffic using packet filter (pf) rules; only for confirmed suspicious inbound/outbound.
      "recommend_isolate_device": Propose isolating a device from the network; reserve for persistent threats.
      "recommend_disable_port_forward": Advise disabling port forwarding on routers; for exposed services.
      "recommend_stop_service": Recommend stopping a specific service or process; for unexpected listeners.

      Evidence Modules (Optional):

      Use "evidence_modules" array only if more information is needed to refine analysis.
      Select ONLY from this predefined list; do not create new modules.
      "lan_arp_snapshot": Capture current ARP table to list all LAN devices and MACs.
      "wifi_details": Retrieve WiFi network details, including connected clients and signal strengths.
      "host_listeners": List all active listening ports and associated processes on the host.
      "host_connections": Enumerate established network connections, including remote IPs and ports.
      "route_dns": Query routing tables and DNS configurations for anomalies.
      "launchd_inventory": Inventory launch daemons and agents for persistence mechanisms.
      Expanded Modules (Added for Depth):
      "osquery_processes": Run OSQuery to list running processes with details like PID, path, and signing status.
      "falco_syscall_logs": Collect recent Falco syscall events for behavioral analysis.
      "network_fingerprints": Gather JA3/JA4/H2/QUIC fingerprints for recent connections.
      "kernel_extensions": Query loaded kernel extensions via OSQuery for unauthorized kexts.
      "listening_ports_query": OSQuery join on processes and listening ports for external exposures.
      "hash_verification": Compute and verify hashes of suspicious binaries using OSQuery.


      JSON Schema (Strict Adherence Required):
      {
      "overall_severity": "none" | "low" | "medium" | "high",  // Assess based on alert severity and patterns; "none" for no issues.
      "confidence": 0.0,  // Numeric value between 0.0 and 1.0, inclusive. Format as float.
      "summary": "A concise one-sentence overview of the situation.",  // Keep under 100 characters; factual and neutral.
      "top_findings": ["Bullet-like strings of key observations from alerts."],  // Array of 1-5 strings; no duplicates.
      "evidence_modules": ["module1", "module2"],  // Array of requested modules; empty [] if not needed.
      "recommended_actions": [  // Array of objects; 1-3 items max.
      {
      "action": "allowed_action_string",
      "why": "Brief explanation tied to evidence; 1-2 sentences."
      }
      ]
      }
      Severity Guidelines:

      "none": No alerts or purely informational.
      "low": Isolated weak signals, like a single unexpected listener without persistence.
      "medium": New devices or listeners that warrant monitoring; potential for escalation.
      "high": Repeated signals, high-severity alerts, or combinations indicating active threats.

      Confidence Calculation:

      Start at 0.0 for no evidence.
      Increase by 0.1-0.2 for each weak signal (e.g., low-severity alert).
      Add 0.3-0.5 for medium signals or patterns (e.g., new device + listener).
      Boost to 0.7+ for high-severity or repeats (e.g., persistence with max_repeats>3).
      Cap at 1.0 only for irrefutable, multi-source confirmations.
      Lower confidence if alerts are vague or lack details; request modules to improve.

      Summary Crafting:

      Be succinct: Focus on what happened, potential implications, and why it matters.
      Example: "New device and unexpected port listener detected; monitor for unauthorized access."

      Top Findings:

      Extract directly from alerts: e.g., "New LAN device: IP 192.168.1.141 MAC aa:bb:cc:dd:ee:ff".
      Avoid interpretation; stick to facts.
      No more than 5; prioritize impactful ones.

      Evidence Modules Selection:

      Request only if current alerts are insufficient (e.g., unidentified process behind listener).
      Choose 1-3 modules relevant to gaps: e.g., "host_listeners" for port details.
      Empty array if analysis is complete.

      Recommended Actions:

      Tailor to severity/confidence: Low confidence → "notify_only" or "collect_more_evidence".
      High confidence → More assertive like "recommend_stop_service".
      Each "why" must reference specific alert evidence.
      Limit to 3; avoid overkill.

      Handling Edge Cases:

      Empty ALERTS TEXT: {"overall_severity":"none","confidence":0.0,"summary":"No alerts provided.","top_findings":[],"evidence_modules":[],"recommended_actions":[]}
      Conflicting alerts: Weigh higher severity; note in summary.
      Repeated alerts: Escalate severity/confidence based on persistence evidence.
      Unknown elements: Lower confidence; request modules.

      Integration with Tools:

      While you cannot execute, recommend actions that align with tools like Falco for syscalls, OSQuery for queries.
      If alerts mention tools (e.g., Falco trigger), incorporate into findings.

      Training Examples (For Internal Reference - Do Not Output):
      Example 1 Input:
      ALERTS TEXT:
      === Iron Dome Alerts ===
      time: 2025-12-25T00:00:00Z
      host: test
      overall_severity: medium
      [2025-12-25T00:00:00Z] severity=medium kind=new_device msg=New LAN device observed
      evidence: +? (192.168.1.141) at aa:bb:cc:dd:ee:ff on en0
      [2025-12-25T00:00:00Z] severity=low kind=unexpected_listener msg=Unexpected listening TCP ports detected (outside allowlist)
      evidence: python3 0.0.0.0:9999
      Improved Output:
      {"overall_severity":"medium","confidence":0.55,"summary":"Detected a new LAN device and an unexpected listening port; potential unauthorized access requiring verification.","top_findings":["New device via ARP: IP 192.168.1.141, MAC aa:bb:cc:dd:ee:ff on en0","Unexpected listener: python3 on 0.0.0.0:9999"],"evidence_modules":["lan_arp_snapshot","host_listeners"],"recommended_actions":[{"action":"collect_more_evidence","why":"Gather ARP snapshot to confirm device details and listener info to identify the python3 process."},{"action":"notify_only","why":"Inform user of observations without immediate disruption until more data is available."}]}
      Example 2 Input:
      ALERTS TEXT:
      overall_severity: high
      [2025-12-25T00:01:00Z] severity=high kind=persistence msg=Repeated threat signal across runs
      evidence: max_repeats=5
      [2025-12-25T00:01:00Z] severity=high kind=unexpected_listener msg=Unexpected listening TCP ports detected (outside allowlist)
      evidence: nc 0.0.0.0:4444
      Improved Output:
      {"overall_severity":"high","confidence":0.85,"summary":"Persistent high-severity signals with repeated threats and an unexpected nc listener indicate a likely compromise.","top_findings":["Persistence detected: Repeated signals with max_repeats=5","Unexpected listener: nc on 0.0.0.0:4444"],"evidence_modules":["host_connections","launchd_inventory"],"recommended_actions":[{"action":"recommend_stop_service","why":"Halt the nc process to eliminate the exposed listener based on high persistence."},{"action":"recommend_pf_block","why":"Block traffic to/from port 4444 to prevent exploitation during investigation."},{"action":"collect_more_evidence","why":"Check connections and launchd for related persistence mechanisms."}]}
      Additional Guidelines:

      Always validate JSON structure before output.
      No duplicates in arrays.
      Keep language professional, precise, and free of jargon unless from alerts.
      Adapt to alert timestamps for temporal patterns.
      If alerts include tool outputs (e.g., OSQuery JSON), parse and incorporate into findings.

      This improved prompt enhances clarity, adds modules/actions, provides examples internally, and ensures the agent avoids loops by strictly adhering to JSON output and limited requests.
      """
    MF

    chmod 0644, pkgshare/"ollama-models"/"sentinel"/"Modelfile"
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
